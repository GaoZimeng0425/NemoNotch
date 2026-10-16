import Foundation
import UserNotifications

/// Reminds via a system notification when a session has been sitting in
/// waiting-for-approval for too long, and retracts the notification when the
/// approval is answered (evlat's waiting reminder, retract-on-answer
/// included). waitingForInput deliberately does NOT remind — a parked prompt
/// is the normal end of a turn, not a call for help.
///
/// The decision is the pure `WaitingReminder.plan`; this class only observes
/// the store + settings, runs it on a 30s tick (the threshold crosses without
/// any store change, so observation alone can't fire it), and performs the
/// notification I/O.
@MainActor
final class WaitingReminderMonitor {
    private let store: AISessionStore
    private let appSettings: AppSettings
    private let permissionMonitor: NotificationPermissionMonitor?
    /// Sessions already reminded; a session leaves the set (and any delivered
    /// notification is retracted) when it stops waiting for approval.
    private var reminded: Set<String> = []
    private var tickTimer: Timer?
    private var started = false

    init(store: AISessionStore, appSettings: AppSettings, permissionMonitor: NotificationPermissionMonitor?) {
        self.store = store
        self.appSettings = appSettings
        self.permissionMonitor = permissionMonitor
        LogService.info("WaitingReminderMonitor init", category: "WaitingReminder")
    }

    func start() {
        guard !started else { return }
        started = true
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        observe()
    }

    /// Re-armable observation, mirroring AIStatusWindowController.observe():
    /// re-arm BEFORE acting so a change during evaluation isn't lost.
    private func observe() {
        withObservationTracking {
            _ = store.sortedSessions.map { "\($0.id):\($0.phase)" }
            _ = appSettings.waitingReminderEnabled
            _ = appSettings.waitingReminderMinutes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
                self?.evaluate()
            }
        }
    }

    private func evaluate() {
        let authorized = permissionMonitor?.status == .authorized
        let plan = WaitingReminder.plan(
            sessions: store.sortedSessions.map { session in
                WaitingReminder.Candidate(
                    id: session.id,
                    isWaiting: session.phase.isWaitingForApproval,
                    waited: waitedDuration(of: session)
                )
            },
            enabled: appSettings.waitingReminderEnabled,
            authorized: authorized,
            threshold: WaitingReminder.threshold(minutes: appSettings.waitingReminderMinutes),
            alreadyReminded: reminded
        )
        for id in plan.remind {
            remind(sessionId: id)
            reminded.insert(id)
        }
        for id in plan.retract {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: ["WaitingReminder.\(id)"])
            LogService.info("Retracted waiting reminder for \(id.prefix(8))", category: "WaitingReminder")
        }
        reminded.subtract(plan.retract)
    }

    private func waitedDuration(of session: AISessionState) -> TimeInterval {
        guard let began = session.phaseChangedAt else { return 0 }
        return Date().timeIntervalSince(began)
    }

    private func remind(sessionId: String) {
        guard let session = store.get(sessionId) else { return }
        let minutes = Int(WaitingReminder.threshold(minutes: appSettings.waitingReminderMinutes) / 60)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "waiting_reminder.title")
        content.body = String(
            format: String(localized: "waiting_reminder.body"),
            session.projectFolder ?? "session",
            session.phase.approvalToolName ?? "tool",
            minutes
        )
        let request = UNNotificationRequest(identifier: "WaitingReminder.\(sessionId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        LogService.info(
            "Reminded: \(sessionId.prefix(8)) waiting \(minutes)min (\(session.projectFolder ?? "?"))",
            category: "WaitingReminder"
        )
    }
}

/// Pure decision core, unit-tested: given the current candidates, whether the
/// feature is on, and what was already reminded — what to remind and what to
/// retract now.
enum WaitingReminder {
    struct Candidate: Equatable {
        let id: String
        let isWaiting: Bool
        let waited: TimeInterval
    }

    struct Plan: Equatable {
        var remind: [String] = []
        var retract: [String] = []
    }

    /// Threshold clamped to ≥ 1 minute so a 0-minute setting can't spam a
    /// notification on every tick.
    static func threshold(minutes: Int) -> TimeInterval {
        TimeInterval(max(minutes, 1) * 60)
    }

    static func plan(
        sessions: [Candidate],
        enabled: Bool,
        authorized: Bool,
        threshold: TimeInterval,
        alreadyReminded: Set<String>
    ) -> Plan {
        var plan = Plan()
        guard enabled, authorized else {
            // Off (or no permission): retract anything still delivered so a
            // disabled reminder doesn't leave stale notifications behind.
            plan.retract = Array(alreadyReminded)
            return plan
        }
        for session in sessions where session.isWaiting {
            if alreadyReminded.contains(session.id) {
                continue
            }
            if session.waited >= threshold {
                plan.remind.append(session.id)
            }
        }
        let waiting = Set(sessions.filter(\.isWaiting).map(\.id))
        plan.retract = alreadyReminded.subtracting(waiting).sorted()
        return plan
    }
}
