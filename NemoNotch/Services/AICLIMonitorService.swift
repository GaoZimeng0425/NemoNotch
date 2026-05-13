import Foundation

@MainActor
@Observable
final class AICLIMonitorService {
    let store: AISessionStore
    let claudeProvider: ClaudeProvider
    let geminiProvider: GeminiProvider
    let hookServer: HookServer
    weak var hermesService: HermesService?

    var serverRunning = false

    init() {
        let store = AISessionStore()
        let claude = ClaudeProvider(store: store)
        let gemini = GeminiProvider(store: store)
        self.store = store
        claudeProvider = claude
        geminiProvider = gemini
        hookServer = HookServer()

        claude.setHookServer(hookServer)
        gemini.setHookServer(hookServer)
        claude.scanExistingSessions()
        gemini.scanExistingSessions()

        hookServer.onEventReceived = { [weak self] event in
            self?.routeEvent(event)
        }
        hookServer.onReady = { [weak self] in
            self?.handleServerReady()
        }
    }

    func startServer() {
        hookServer.start()
    }

    var activeSession: AISessionState? {
        store.activeSession
    }

    var anyHookInstalled: Bool {
        claudeProvider.isHookInstalled || geminiProvider.isHookInstalled
    }

    func installHooks() {
        claudeProvider.installHooks()
        geminiProvider.installHooks()
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        guard let session = store.get(sessionId) else { return }
        switch session.source {
        case .claude: claudeProvider.respondToPermission(sessionId: sessionId, approved: approved)
        case .gemini: geminiProvider.respondToPermission(sessionId: sessionId, approved: approved)
        }
    }

    // MARK: - Event Routing

    private func routeEvent(_ event: HookEvent) {
        var source = event.cliSource ?? "unknown"
        LogService.debug(
            "Incoming event: \(event.hookEventName), raw source: \(event.cliSource ?? "nil"), session: \(event.sessionId ?? "nil")",
            category: "AICLIMonitorService"
        )

        if source == "unknown" {
            let combined = "\(event.message ?? "") \(event.toolName ?? "") \(event.cwd ?? "")".lowercased()
            if combined.contains("gemini") || combined.contains("glm") {
                source = "gemini"
            }
        }

        LogService.info("Routing event \(event.hookEventName) to \(source)", category: "AICLIMonitorService")

        switch source {
        case "hermes":
            hermesService?.handleHookEvent(event)
        case "gemini":
            geminiProvider.handleEvent(event)
        case "claude":
            claudeProvider.handleEvent(event)
        default:
            // Final fallback: route by which provider owns the session.
            if let existing = store.get(event.sessionId ?? "") {
                switch existing.source {
                case .gemini: geminiProvider.handleEvent(event)
                case .claude: claudeProvider.handleEvent(event)
                }
            } else {
                claudeProvider.handleEvent(event)
            }
        }
    }

    private func handleServerReady() {
        serverRunning = true
        try? HookInstaller.install(.claude)
        try? HookInstaller.install(.gemini)
        claudeProvider.isHookInstalled = HookInstaller.isInstalled(.claude)
        geminiProvider.isHookInstalled = HookInstaller.isInstalled(.gemini)
    }
}
