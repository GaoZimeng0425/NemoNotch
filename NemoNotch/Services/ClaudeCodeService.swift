import Foundation

@Observable
final class ClaudeCodeService {
    var sessions: [String: ClaudeState] = [:]
    var activeSession: ClaudeState?
    var isHookInstalled = false
    var serverRunning = false
    var serverPort: UInt16 = 0

    let hookServer = HookServer()

    private var timeoutTimer: Timer?

    init() {
        hookServer.onEventReceived = { [weak self] event in
            self?.handleEvent(event)
        }
        hookServer.onReady = { [weak self] port in
            guard let self else { return }
            self.serverRunning = true
            self.serverPort = port
            // Install or update hooks now that we know the actual port the server bound to.
            // This handles the race where port 49200 is taken and we fall back to 49201+.
            try? HookInstaller.install(port: port)
            self.isHookInstalled = HookInstaller.isInstalled()
        }
        isHookInstalled = HookInstaller.isInstalled()
    }

    func startServer() {
        do {
            try hookServer.start()
        } catch {
            print("[NemoNotch] Failed to start hook server: \(error)")
        }
    }

    func installHooks() {
        do {
            let port = serverPort > 0 ? serverPort : hookServer.port
            try HookInstaller.install(port: port)
            isHookInstalled = true
        } catch {
            print("[NemoNotch] Failed to install hooks: \(error)")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            isHookInstalled = false
        } catch {
            print("[NemoNotch] Failed to uninstall hooks: \(error)")
        }
    }

    private func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }

        let eventName = event.hookEventName
        let now = Date()

        func ensureSession() {
            if sessions[sessionId] == nil {
                sessions[sessionId] = ClaudeState(sessionId: sessionId)
            }
        }

        switch eventName {
        case "SessionStart":
            sessions[sessionId] = ClaudeState(sessionId: sessionId)

        case "UserPromptSubmit":
            ensureSession()
            sessions[sessionId]?.status = .working
            sessions[sessionId]?.lastEventTime = now

        case "PreToolUse":
            ensureSession()
            sessions[sessionId]?.status = .working
            sessions[sessionId]?.currentTool = event.toolName
            sessions[sessionId]?.lastEventTime = now

        case "PostToolUse":
            // Tool finished, but Claude is still processing the result.
            // Keep status as .working — only Stop/SessionEnd flips to idle.
            ensureSession()
            sessions[sessionId]?.status = .working
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.lastEventTime = now

        case "Notification":
            // Notification is a side-channel (permission prompts, idle alerts).
            // It does NOT mean Claude is idle — keep current status untouched.
            ensureSession()
            sessions[sessionId]?.lastEventTime = now

        case "Stop":
            if sessions[sessionId] != nil {
                sessions[sessionId]?.status = .idle
                sessions[sessionId]?.currentTool = nil
                sessions[sessionId]?.lastEventTime = now
            }

        case "SessionEnd":
            sessions.removeValue(forKey: sessionId)

        default:
            break
        }

        updateActiveSession()
        scheduleTimeoutCleanup()
    }

    private func updateActiveSession() {
        activeSession = sessions.values
            .filter { $0.status == .working }
            .sorted { $0.lastEventTime > $1.lastEventTime }
            .first ?? sessions.values.sorted { $0.lastEventTime > $1.lastEventTime }.first
    }

    private func scheduleTimeoutCleanup() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.cleanupStaleSessions()
        }
    }

    private func cleanupStaleSessions() {
        let threshold = Date().addingTimeInterval(-1800)
        for (id, state) in sessions {
            if state.lastEventTime < threshold {
                sessions.removeValue(forKey: id)
            }
        }
        updateActiveSession()
    }
}
