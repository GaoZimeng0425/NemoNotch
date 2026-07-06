import Foundation

/// Fourth AIProvider. zcode (ZCode.app's GLM agent CLI) emits Claude-shaped
/// hook events through the shared hook-sender.sh → HookServer pipeline. This
/// provider maps them into AISessionStore. Notify + live status only: no
/// conversation/token parsing, no notch-side approval (zcode's TUI owns it).
@MainActor
@Observable
final class ZcodeProvider: AIProvider {
    let source: AISource = .zcode
    var isHookInstalled = false

    private let store: AISessionStore
    private var timeoutTimer: Timer?
    private weak var hookServer: HookServer?

    init(store: AISessionStore) {
        self.store = store
        isHookInstalled = HookInstaller.isInstalled(.zcode)
        LogService.info("ZcodeProvider init (hookInstalled=\(isHookInstalled))", category: "ZcodeProvider")
    }

    func setHookServer(_ server: HookServer) {
        hookServer = server
    }

    func installHooks() {
        do {
            try HookInstaller.install(.zcode)
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install zcode hooks: \(error)", category: "ZcodeProvider")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall(.zcode)
            isHookInstalled = false
            store.removeAll(source: .zcode)
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        } catch {
            LogService.error("Failed to uninstall zcode hooks: \(error)", category: "ZcodeProvider")
        }
    }

    /// Notify-only — zcode's own TUI owns the approval decision.
    func respondToPermission(sessionId: String, approved: Bool) {}

    // MARK: - Event Handling

    func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()
        LogService.debug(
            "zcode event \(event.hookEventName) session \(sessionId.prefix(10))",
            category: "ZcodeProvider"
        )

        switch event.hookEventName {
        case "SessionStart":
            var session = AISessionState(sessionId: sessionId, source: .zcode)
            session.phase = .idle
            applyContext(to: &session, event: event)
            store.upsert(session)

        case "UserPromptSubmit":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .processing)
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PreToolUse":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = event.toolName
                s.isPreToolUse = true
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PostToolUse":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        // A failed tool call still ends that tool; the agent gets the error and
        // keeps working, so treat it like PostToolUse (back to processing).
        case "PostToolUseFailure":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "Stop":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .waitingForInput)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        // zcode has no SessionEnd or Notification event (only SessionStart);
        // ended sessions are reaped by the stale-session timeout below.
        default:
            break
        }

        scheduleTimeoutCleanup()
    }

    private func applyContext(to session: inout AISessionState, event: HookEvent) {
        if let cwd = event.cwd { session.cwd = cwd }
        if let model = event.model, !model.isEmpty { session.model = model }
        if let msg = event.message, !msg.isEmpty { session.lastMessage = msg }
        session.lastEventName = event.hookEventName
    }

    // MARK: - Timeout (mirrors opencode)

    private static let cleanupTickInterval: TimeInterval = 60
    private static let silentDemoteThreshold: TimeInterval = 300
    private static let removeStaleThreshold: TimeInterval = 1800

    private func scheduleTimeoutCleanup() {
        guard timeoutTimer == nil else { return }
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: Self.cleanupTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupStaleSessions()
            }
        }
    }

    private func cleanupStaleSessions() {
        let now = Date()
        let demoteCutoff = now.addingTimeInterval(-Self.silentDemoteThreshold)
        let removeCutoff = now.addingTimeInterval(-Self.removeStaleThreshold)

        for session in store.sessions(for: .zcode) where session.lastEventTime < demoteCutoff {
            if case .waitingForInput = session.phase {
                store.mutate(session.id) { s in
                    s.phase = s.phase.transition(to: .idle)
                }
                LogService.info(
                    "Demoted silent zcode session \(session.id.prefix(8)) to idle",
                    category: "ZcodeProvider"
                )
            }
        }

        for session in store.sessions(for: .zcode) where session.lastEventTime < removeCutoff {
            store.remove(session.id)
            LogService.info("Removed stale zcode session \(session.id.prefix(8))", category: "ZcodeProvider")
        }

        if store.sessions(for: .zcode).isEmpty {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
    }
}
