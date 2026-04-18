import Foundation

@Observable
final class ClaudeCodeService {
    var sessions: [String: ClaudeState] = [:]
    var activeSession: ClaudeState?
    var isHookInstalled = false
    var serverRunning = false

    let hookServer = HookServer()

    private var timeoutTimer: Timer?

    init() {
        hookServer.onEventReceived = { [weak self] event in
            self?.handleEvent(event)
        }
        isHookInstalled = HookInstaller.isInstalled()
    }

    func startServer() {
        do {
            try hookServer.start()
            serverRunning = true
            if !isHookInstalled {
                try? HookInstaller.install(port: hookServer.port)
                isHookInstalled = HookInstaller.isInstalled()
            }
        } catch {
            print("[NemoNotch] Failed to start hook server: \(error)")
        }
    }

    func installHooks() {
        do {
            try HookInstaller.install(port: hookServer.port)
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

        switch eventName {
        case "SessionStart":
            sessions[sessionId] = ClaudeState(sessionId: sessionId)
            updateActiveSession()

        case "PreToolUse":
            if sessions[sessionId] == nil {
                sessions[sessionId] = ClaudeState(sessionId: sessionId)
            }
            sessions[sessionId]?.status = .working
            sessions[sessionId]?.currentTool = event.toolName
            sessions[sessionId]?.lastEventTime = now
            updateActiveSession()

        case "PostToolUse", "Notification":
            if sessions[sessionId] != nil {
                sessions[sessionId]?.lastEventTime = now
                if sessions[sessionId]?.status == .working {
                    sessions[sessionId]?.status = .idle
                    sessions[sessionId]?.currentTool = nil
                }
            }
            updateActiveSession()

        case "Stop", "SessionEnd":
            if sessions[sessionId] != nil {
                sessions[sessionId]?.status = .idle
                sessions[sessionId]?.currentTool = nil
                sessions[sessionId]?.lastEventTime = now
            }
            if eventName == "SessionEnd" {
                sessions.removeValue(forKey: sessionId)
            }
            updateActiveSession()

        default:
            break
        }

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
