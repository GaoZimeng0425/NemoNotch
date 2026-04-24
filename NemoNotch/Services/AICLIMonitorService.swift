import Foundation

@Observable
final class AICLIMonitorService {
    let claudeProvider: ClaudeProvider
    let geminiProvider: GeminiProvider
    let hookServer: HookServer

    var serverRunning = false

    init() {
        let claude = ClaudeProvider()
        let gemini = GeminiProvider()
        self.claudeProvider = claude
        self.geminiProvider = gemini
        self.hookServer = HookServer()

        claude.setHookServer(hookServer)

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
        let claudeActive = claudeProvider.activeSession
        let geminiActive = geminiProvider.activeSession

        guard let claudeActive, let geminiActive else {
            return claudeActive ?? geminiActive
        }

        return sessionPriority(claudeActive) >= sessionPriority(geminiActive) ? claudeActive : geminiActive
    }

    var anyHookInstalled: Bool {
        claudeProvider.isHookInstalled || geminiProvider.isHookInstalled
    }

    func installHooks() {
        claudeProvider.installHooks()
        geminiProvider.installHooks()
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        if claudeProvider.sessions[sessionId] != nil {
            claudeProvider.respondToPermission(sessionId: sessionId, approved: approved)
        }
    }

    // MARK: - Event Routing

    private func routeEvent(_ event: HookEvent) {
        let source = event.cliSource ?? "claude"
        switch source {
        case "gemini":
            geminiProvider.handleEvent(event)
        default:
            claudeProvider.handleEvent(event)
        }
    }

    private func handleServerReady() {
        serverRunning = true
        try? HookInstaller.install(.claude)
        try? HookInstaller.install(.gemini)
        claudeProvider.isHookInstalled = HookInstaller.isInstalled(.claude)
        geminiProvider.isHookInstalled = HookInstaller.isInstalled(.gemini)
    }

    // MARK: - Priority

    private func sessionPriority(_ session: AISessionState) -> Int {
        switch session.phase {
        case .waitingForApproval: return 100
        case .processing: return 80
        case .compacting: return 70
        case .waitingForInput: return 50
        case .idle: return 10
        case .ended: return 0
        }
    }
}
