import AppKit
import Foundation

/// Tracks the macOS session lock state so the lock-screen AI panel knows when
/// to present.
///
/// Three detection layers (belt, braces, and a probe):
/// 1. `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` distributed
///    notifications — the primary signal.
/// 2. `NSWorkspace.sessionDidBecomeActive` as an early unlock signal — macOS
///    sometimes delivers the unlocked notification noticeably after the
///    user-perceived unlock.
/// 3. While we believe the session is locked, a 500ms poll of
///    `CGSessionCopyCurrentDictionary`'s `CGSSessionScreenIsLocked` catches
///    both late notifications with one idempotent handler (the state setters
///    guard on no-change).
@MainActor
@Observable
final class LockScreenMonitor {
    private(set) var isLocked = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Re-present cadence shared with the panel controller's self-check.
    static let pollInterval: TimeInterval = 0.5

    init() {
        let nc = DistributedNotificationCenter.default()
        let lockNames: [NSNotification.Name] = [
            .init("com.apple.screenIsLocked"),
            .init("com.apple.screenIsUnlocked"),
        ]
        for name in lockNames {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                // Extract outside the Task: Notification isn't Sendable, so
                // only the plain Bool may cross the isolation boundary.
                let locked = notification.name.rawValue == "com.apple.screenIsLocked"
                Task { @MainActor [weak self] in
                    self?.setLocked(locked, reason: "notification")
                }
            }
            observers.append(token)
        }

        let workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setLocked(false, reason: "session-active")
            }
        }
        observers.append(workspaceToken)

        LogService.info("LockScreenMonitor init", category: "LockScreenMonitor")
    }

    deinit {
        MainActor.assumeIsolated {
            observers.forEach(DistributedNotificationCenter.default().removeObserver)
            pollTask?.cancel()
        }
    }

    private func setLocked(_ locked: Bool, reason: String) {
        guard isLocked != locked else { return }
        LogService.info("lock state → \(locked) (\(reason))", category: "LockScreenMonitor")
        isLocked = locked
        if locked {
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// Polls the canonical session lock state while locked. Fires the unlock
    /// transition the instant the OS flips, ahead of any late notification.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self, !Task.isCancelled else { return }
                if !Self.isSessionScreenLocked() {
                    self.setLocked(false, reason: "poll")
                    return
                }
            }
        }
    }

    private static func isSessionScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
