import AppKit
import Foundation
import UserNotifications

@MainActor
@Observable
final class PomodoroTimerService {
    // MARK: - State types

    enum State: Equatable {
        case idle
        case running(RunningContext)
        case paused(RunningContext)
        case justFinished(FinishedContext)

        var isActive: Bool {
            switch self {
            case .idle: return false
            case .running, .paused, .justFinished: return true
            }
        }
    }

    struct RunningContext: Equatable {
        let phase: PomodoroPhase
        let taskID: UUID?
        let plannedDuration: TimeInterval
        var startedAt: Date
        var accumulatedElapsed: TimeInterval
        let autoFlow: Bool
    }

    struct FinishedContext: Equatable {
        let phase: PomodoroPhase
        let taskID: UUID?
        let outcome: PomodoroRecord.Outcome
    }

    // MARK: - Observable

    private(set) var state: State = .idle
    private(set) var workCounterSinceLongBreak: Int = 0
    private(set) var pulseToken: UUID = .init()
    private(set) var lastUsedDuration: TimeInterval = 25 * 60
    private(set) var lastAutoFlow: Bool = false

    // MARK: - Dependencies

    private let taskStore: TaskStore
    private let historyStore: PomodoroHistoryStore
    private let appSettings: AppSettings
    private let permissionMonitor: NotificationPermissionMonitor?

    // MARK: - Privates

    // nonisolated(unsafe) so deinit (which is nonisolated) can invalidate/remove them
    // without a concurrency violation. All write access is on MainActor.
    private nonisolated(unsafe) var tickTimer: Timer?
    private nonisolated(unsafe) var advanceTimer: Timer?
    private nonisolated(unsafe) var sleepObserver: NSObjectProtocol?

    // MARK: - Init

    init(
        taskStore: TaskStore,
        historyStore: PomodoroHistoryStore,
        appSettings: AppSettings,
        permissionMonitor: NotificationPermissionMonitor?
    ) {
        self.taskStore = taskStore
        self.historyStore = historyStore
        self.appSettings = appSettings
        self.permissionMonitor = permissionMonitor
        LogService.info("PomodoroTimerService init", category: "PomodoroTimer")

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWillSleep()
            }
        }
    }

    deinit {
        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        tickTimer?.invalidate()
        advanceTimer?.invalidate()
    }

    // MARK: - Computed

    var currentPhase: PomodoroPhase {
        switch state {
        case .idle: return .idle
        case let .running(ctx), let .paused(ctx): return ctx.phase
        case let .justFinished(ctx): return ctx.phase
        }
    }

    var remainingSeconds: Int {
        switch state {
        case .idle: return 0
        case let .running(ctx):
            let elapsed = ctx.accumulatedElapsed + Date().timeIntervalSince(ctx.startedAt)
            return max(0, Int((ctx.plannedDuration - elapsed).rounded(.up)))
        case let .paused(ctx):
            return max(0, Int((ctx.plannedDuration - ctx.accumulatedElapsed).rounded(.up)))
        case .justFinished: return 0
        }
    }

    var remainingFraction: Double {
        switch state {
        case .idle: return 0
        case let .running(ctx):
            let elapsed = ctx.accumulatedElapsed + Date().timeIntervalSince(ctx.startedAt)
            return max(0, min(1, (ctx.plannedDuration - elapsed) / ctx.plannedDuration))
        case let .paused(ctx):
            return max(0, min(1, (ctx.plannedDuration - ctx.accumulatedElapsed) / ctx.plannedDuration))
        case .justFinished: return 0
        }
    }

    // MARK: - Transitions

    func start(taskID: UUID?, duration: TimeInterval, autoFlow: Bool) {
        if case .running = state {
            completeEarly()
        } else if case .paused = state {
            completeEarly()
        }
        lastUsedDuration = duration
        lastAutoFlow = autoFlow
        let ctx = RunningContext(
            phase: .work,
            taskID: taskID,
            plannedDuration: duration,
            startedAt: Date(),
            accumulatedElapsed: 0,
            autoFlow: autoFlow
        )
        state = .running(ctx)
        LogService.info(
            "Pomodoro start: phase=\(ctx.phase) duration=\(duration) autoFlow=\(autoFlow) task=\(taskID?.uuidString ?? "nil")",
            category: "PomodoroTimer"
        )
        startTickTimer()
    }

    func pause() {
        guard case var .running(ctx) = state else { return }
        ctx.accumulatedElapsed += Date().timeIntervalSince(ctx.startedAt)
        state = .paused(ctx)
        stopTickTimer()
        LogService.debug("Pomodoro pause @ \(ctx.accumulatedElapsed)s", category: "PomodoroTimer")
    }

    func resume() {
        guard case var .paused(ctx) = state else { return }
        ctx.startedAt = Date()
        state = .running(ctx)
        startTickTimer()
        LogService.debug("Pomodoro resume", category: "PomodoroTimer")
    }

    // MARK: - Transitions (exits)

    func completeEarly() {
        finish(outcome: .partial)
    }

    func abandon() {
        finish(outcome: .abandoned)
    }

    /// Called when the tick timer detects elapsed >= planned.
    private func naturalEnd() {
        finish(outcome: .completed)
    }

    /// Test hook: pretend the tick timer fired naturalEnd.
    func simulateNaturalEnd() {
        naturalEnd()
    }

    /// Test hook: start in an arbitrary phase.
    func startForTesting(phase: PomodoroPhase, taskID: UUID?, duration: TimeInterval, autoFlow: Bool) {
        if case .running = state { completeEarly() }
        else if case .paused = state { completeEarly() }
        lastAutoFlow = autoFlow
        let ctx = RunningContext(
            phase: phase,
            taskID: taskID,
            plannedDuration: duration,
            startedAt: Date(),
            accumulatedElapsed: 0,
            autoFlow: autoFlow
        )
        state = .running(ctx)
        startTickTimer()
    }

    private func finish(outcome: PomodoroRecord.Outcome) {
        let ctx: RunningContext
        switch state {
        case let .running(c): ctx = c
        case let .paused(c): ctx = c
        default: return
        }

        let actualElapsed: TimeInterval = {
            switch outcome {
            case .completed: return ctx.plannedDuration
            case .partial, .abandoned:
                let live: TimeInterval = if case .running = state {
                    ctx.accumulatedElapsed + Date().timeIntervalSince(ctx.startedAt)
                } else {
                    ctx.accumulatedElapsed
                }
                return min(live, ctx.plannedDuration)
            }
        }()

        let record = PomodoroRecord(
            id: UUID(),
            taskID: ctx.taskID,
            phase: ctx.phase,
            plannedDuration: ctx.plannedDuration,
            actualDuration: actualElapsed,
            startedAt: ctx.startedAt.addingTimeInterval(-ctx.accumulatedElapsed),
            endedAt: Date(),
            outcome: outcome
        )
        historyStore.append(record)

        if ctx.phase == .work,
           outcome != .abandoned,
           let taskID = ctx.taskID {
            taskStore.incrementCompletedPomodoros(taskID)
        }

        lastAutoFlow = ctx.autoFlow

        state = .justFinished(FinishedContext(
            phase: ctx.phase,
            taskID: ctx.taskID,
            outcome: outcome
        ))
        LogService.info(
            "Pomodoro finish: phase=\(ctx.phase) outcome=\(outcome) actual=\(actualElapsed)",
            category: "PomodoroTimer"
        )

        stopTickTimer()
        scheduleAdvance()

        if outcome != .abandoned {
            triggerEndAlerts(phase: ctx.phase, taskID: ctx.taskID, outcome: outcome)
        }
    }

    // MARK: - autoFlow advance

    func advance() {
        guard case let .justFinished(ctx) = state else { return }

        guard ctx.outcome == .completed else {
            state = .idle
            return
        }

        guard lastAutoFlow else {
            state = .idle
            return
        }

        let nextPhase: PomodoroPhase
        let nextDuration: TimeInterval
        switch ctx.phase {
        case .work:
            workCounterSinceLongBreak += 1
            if workCounterSinceLongBreak % appSettings.pomodoroLongBreakInterval == 0 {
                nextPhase = .longBreak
                nextDuration = appSettings.pomodoroLongBreakDuration
            } else {
                nextPhase = .shortBreak
                nextDuration = appSettings.pomodoroShortBreakDuration
            }
        case .shortBreak:
            nextPhase = .work
            nextDuration = appSettings.pomodoroWorkDuration
        case .longBreak:
            workCounterSinceLongBreak = 0
            nextPhase = .work
            nextDuration = appSettings.pomodoroWorkDuration
        case .idle:
            state = .idle
            return
        }

        state = .running(RunningContext(
            phase: nextPhase,
            taskID: nil,
            plannedDuration: nextDuration,
            startedAt: Date(),
            accumulatedElapsed: 0,
            autoFlow: true
        ))
        LogService.info(
            "Pomodoro advance: → \(nextPhase) (counter=\(workCounterSinceLongBreak))",
            category: "PomodoroTimer"
        )
        startTickTimer()
    }

    // MARK: - Tick timer

    private func startTickTimer() {
        stopTickTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTick()
            }
        }
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func handleTick() {
        guard case .running = state else {
            stopTickTimer()
            return
        }
        if remainingSeconds == 0 {
            naturalEnd()
        }
    }

    // MARK: - Auto-advance out of justFinished

    private func scheduleAdvance() {
        advanceTimer?.invalidate()
        advanceTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advance()
                self?.startTickTimerIfRunning()
            }
        }
    }

    private func startTickTimerIfRunning() {
        if case .running = state {
            startTickTimer()
        }
    }

    // MARK: - End alerts

    private func triggerEndAlerts(
        phase: PomodoroPhase,
        taskID: UUID?,
        outcome: PomodoroRecord.Outcome
    ) {
        // 1. Sound (gated by user setting)
        if appSettings.pomodoroSoundEnabled {
            let soundName: NSSound.Name = (phase == .work) ? .init("Glass") : .init("Hero")
            NSSound(named: soundName)?.play()
        }

        // 2. System notification (gated by user setting + system permission)
        if appSettings.pomodoroNotificationEnabled,
           permissionMonitor?.status == .authorized {
            let content = UNMutableNotificationContent()
            content.title = endAlertTitle(phase: phase)
            content.body = endAlertBody(phase: phase, taskID: taskID)
            content.sound = nil
            let req = UNNotificationRequest(
                identifier: "pomodoro.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }

        // 3. Notch ring pulse
        pulseToken = UUID()
    }

    private func endAlertTitle(phase: PomodoroPhase) -> String {
        switch phase {
        case .work:
            return String(localized: "pomodoro.notification.workEnd.title")
        case .shortBreak, .longBreak:
            return String(localized: "pomodoro.notification.breakEnd.title")
        case .idle:
            return ""
        }
    }

    private func endAlertBody(phase: PomodoroPhase, taskID: UUID?) -> String {
        let minutes = switch phase {
        case .work: Int(appSettings.pomodoroWorkDuration / 60)
        case .shortBreak: Int(appSettings.pomodoroShortBreakDuration / 60)
        case .longBreak: Int(appSettings.pomodoroLongBreakDuration / 60)
        case .idle: 0
        }
        if let taskID,
           let task = taskStore.tasks.first(where: { $0.id == taskID }) {
            return String(
                format: String(localized: "pomodoro.notification.body.withTask"),
                task.title,
                minutes
            )
        } else {
            return String(
                format: String(localized: "pomodoro.notification.body.noTask"),
                minutes
            )
        }
    }

    // MARK: - System sleep

    private func handleSystemWillSleep() {
        LogService.info(
            "PomodoroTimerService: system will sleep — abandoning if active",
            category: "PomodoroTimer"
        )
        switch state {
        case .running, .paused:
            abandon()
        default:
            break
        }
    }

    func handleSystemWillSleepForTesting() {
        handleSystemWillSleep()
    }
}
