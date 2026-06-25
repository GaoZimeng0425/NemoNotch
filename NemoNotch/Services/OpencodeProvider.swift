import Foundation

/// Third AIProvider. Receives opencode lifecycle events (pushed by the
/// NemoNotch opencode plugin via HookServer) and maps them into AISessionStore.
/// Notify-only: no conversation/token parsing, no notch-side approval.
@MainActor
@Observable
final class OpencodeProvider: AIProvider {
    let source: AISource = .opencode
    var isHookInstalled = false

    private let store: AISessionStore
    private var timeoutTimer: Timer?
    private weak var hookServer: HookServer?

    init(store: AISessionStore) {
        self.store = store
        isHookInstalled = OpencodePluginInstaller.isInstalled
        LogService.info("OpencodeProvider init (hookInstalled=\(isHookInstalled))", category: "OpencodeProvider")
    }

    func setHookServer(_ server: HookServer) {
        hookServer = server
    }

    func installHooks() {
        do {
            try OpencodePluginInstaller.install()
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install opencode plugin: \(error)", category: "OpencodeProvider")
        }
    }

    func uninstallHooks() {
        do {
            try OpencodePluginInstaller.uninstall()
            isHookInstalled = false
        } catch {
            LogService.error("Failed to uninstall opencode plugin: \(error)", category: "OpencodeProvider")
        }
    }

    /// Notify-only — opencode's own TUI owns the approval decision.
    func respondToPermission(sessionId: String, approved: Bool) {}

    // MARK: - Event Handling

    func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()
        LogService.debug(
            "opencode event \(event.hookEventName) session \(sessionId.prefix(10))",
            category: "OpencodeProvider"
        )

        switch event.hookEventName {
        case "UserPromptSubmit":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .processing)
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PreToolUse":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = event.toolName
                s.isPreToolUse = true
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PostToolUse":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "Notification":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                let ctx = PermissionContext(
                    toolUseId: event.toolUseId ?? UUID().uuidString,
                    toolName: event.toolName ?? "permission",
                    toolInput: event.message,
                    receivedAt: now
                )
                s.phase = s.phase.transition(to: .waitingForApproval(ctx))
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PreCompact":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .compacting)
                s.lastEventTime = now
            }

        case "Stop":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .waitingForInput)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

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

    // MARK: - Timeout (mirrors Claude/Gemini)

    private static let cleanupTickInterval: TimeInterval = 60
    private static let silentDemoteThreshold: TimeInterval = 300 // 5 min → clear badge
    private static let removeStaleThreshold: TimeInterval = 1800 // 30 min → drop session

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

        for session in store.sessions(for: .opencode) where session.lastEventTime < demoteCutoff {
            if case .waitingForInput = session.phase {
                store.mutate(session.id) { s in
                    s.phase = s.phase.transition(to: .idle)
                }
                LogService.info(
                    "Demoted silent opencode session \(session.id.prefix(8)) to idle",
                    category: "OpencodeProvider"
                )
            }
        }

        for session in store.sessions(for: .opencode) where session.lastEventTime < removeCutoff {
            store.remove(session.id)
            LogService.info("Removed stale opencode session \(session.id.prefix(8))", category: "OpencodeProvider")
        }

        if store.sessions(for: .opencode).isEmpty {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
    }
}
