import Foundation

@MainActor
@Observable
final class AICLIMonitorService {
    let store: AISessionStore
    let claudeProvider: ClaudeProvider
    let geminiProvider: GeminiProvider
    let opencodeProvider: OpencodeProvider
    let hookServer: HookServer
    weak var hermesService: HermesService?

    var serverRunning = false

    init() {
        let store = AISessionStore()
        let claude = ClaudeProvider(store: store)
        let gemini = GeminiProvider(store: store)
        let opencode = OpencodeProvider(store: store)
        self.store = store
        claudeProvider = claude
        geminiProvider = gemini
        opencodeProvider = opencode
        hookServer = HookServer()

        claude.setHookServer(hookServer)
        gemini.setHookServer(hookServer)
        opencode.setHookServer(hookServer)
        claude.scanExistingSessions()
        gemini.scanExistingSessions()

        // Refresh hook-sender.sh on launch when hooks are installed, so socket
        // path / script version migrations take effect without requiring the
        // user to click Reinstall in Settings.
        if claude.isHookInstalled || gemini.isHookInstalled || opencode.isHookInstalled {
            do {
                try HookInstaller.ensureScriptExists()
            } catch {
                LogService.warn("Failed to refresh hook script: \(error)", category: "AICLIMonitorService")
            }
        }

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
        claudeProvider.isHookInstalled || geminiProvider.isHookInstalled || opencodeProvider.isHookInstalled
    }

    func installHooks() {
        claudeProvider.installHooks()
        geminiProvider.installHooks()
        opencodeProvider.installHooks()
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        guard let session = store.get(sessionId) else { return }
        switch session.source {
        case .claude: claudeProvider.respondToPermission(sessionId: sessionId, approved: approved)
        case .gemini: geminiProvider.respondToPermission(sessionId: sessionId, approved: approved)
        case .opencode: opencodeProvider.respondToPermission(sessionId: sessionId, approved: approved)
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
            // opencode session ids are `ses_…`; a foreign untagged emitter
            // (e.g. another opencode plugin) can race ahead of our tagged event,
            // so attribute by id format before the Claude fallback creates a
            // `.claude` phantom for an opencode session.
            if event.sessionId?.hasPrefix("ses_") == true {
                source = "opencode"
            } else {
                let combined = "\(event.message ?? "") \(event.toolName ?? "") \(event.cwd ?? "")".lowercased()
                if combined.contains("gemini") || combined.contains("glm") {
                    source = "gemini"
                }
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
        case "opencode":
            opencodeProvider.handleEvent(event)
        default:
            // Final fallback: route by which provider owns the session.
            if let existing = store.get(event.sessionId ?? "") {
                switch existing.source {
                case .gemini: geminiProvider.handleEvent(event)
                case .claude: claudeProvider.handleEvent(event)
                case .opencode: opencodeProvider.handleEvent(event)
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
        try? OpencodePluginInstaller.install()
        opencodeProvider.isHookInstalled = OpencodePluginInstaller.isInstalled
    }
}
