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
            LogService.error("Failed to start hook server: \(error)", category: "ClaudeCode")
        }
    }

    func installHooks() {
        do {
            let port = serverPort > 0 ? serverPort : hookServer.port
            try HookInstaller.install(port: port)
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install hooks: \(error)", category: "ClaudeCode")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            isHookInstalled = false
        } catch {
            LogService.error("Failed to uninstall hooks: \(error)", category: "ClaudeCode")
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

        func updateContext() {
            if let cwd = event.cwd { sessions[sessionId]?.cwd = cwd }
            if let msg = event.message, !msg.isEmpty { sessions[sessionId]?.lastMessage = msg }
            sessions[sessionId]?.lastEventName = eventName
        }

        switch eventName {
        case "SessionStart":
            sessions[sessionId] = ClaudeState(sessionId: sessionId)
            updateContext()
            loadTranscriptMessages(for: sessionId)

        case "UserPromptSubmit":
            ensureSession()
            sessions[sessionId]?.status = .working
            updateContext()
            sessions[sessionId]?.lastEventTime = now
            loadTranscriptMessages(for: sessionId)

        case "PreToolUse":
            ensureSession()
            sessions[sessionId]?.status = .working
            sessions[sessionId]?.currentTool = event.toolName
            sessions[sessionId]?.isPreToolUse = true
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "PostToolUse":
            ensureSession()
            sessions[sessionId]?.status = .working
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.isPreToolUse = false
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "Notification":
            ensureSession()
            sessions[sessionId]?.status = .waiting
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "Stop":
            if sessions[sessionId] != nil {
                sessions[sessionId]?.status = .idle
                sessions[sessionId]?.currentTool = nil
                updateContext()
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
        let prev = activeSession?.id
        activeSession = sessions.values
            .filter { $0.status == .working }
            .sorted { $0.lastEventTime > $1.lastEventTime }
            .first ?? sessions.values.sorted { $0.lastEventTime > $1.lastEventTime }.first
        if activeSession?.id != prev {
            let statusStr: String
            switch activeSession?.status {
            case .working: statusStr = "working"
            case .waiting: statusStr = "waiting"
            case .idle: statusStr = "idle"
            case nil: statusStr = "nil"
            }
            LogService.info("Active session: \(prev?.prefix(8) ?? "nil") -> \(activeSession?.id.prefix(8) ?? "nil"), status=\(statusStr)", category: "ClaudeCode")
        }
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

    // MARK: - Transcript Reading

    private func loadTranscriptMessages(for sessionId: String) {
        guard let cwd = sessions[sessionId]?.cwd else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let messages = Self.parseTranscriptMessages(sessionId: sessionId, cwd: cwd)
            guard let self, let messages, !messages.firstUser.isEmpty || !messages.lastUser.isEmpty else { return }
            DispatchQueue.main.async {
                guard self.sessions[sessionId] != nil else { return }
                if !messages.firstUser.isEmpty {
                    self.sessions[sessionId]?.firstUserMessage = messages.firstUser
                }
                if !messages.lastUser.isEmpty {
                    self.sessions[sessionId]?.lastUserMessage = messages.lastUser
                }
            }
        }
    }

    private static func claudeProjectsDir(for cwd: String) -> String {
        let encoded = "-" + cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "-")
        return NSString(string: "~/.claude/projects/\(encoded)").expandingTildeInPath
    }

    private struct TranscriptMessages {
        var firstUser: String = ""
        var lastUser: String = ""
    }

    private static func parseTranscriptMessages(sessionId: String, cwd: String) -> TranscriptMessages? {
        let dir = claudeProjectsDir(for: cwd)
        let path = "\(dir)/\(sessionId).jsonl"
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        var result = TranscriptMessages()
        var foundFirst = false

        for line in data.components(separatedBy: "\n") {
            guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            guard obj["type"] as? String == "user", let message = obj["message"] as? [String: Any] else { continue }

            let text = extractText(from: message)
            guard !text.isEmpty else { continue }

            if !foundFirst {
                result.firstUser = String(text.prefix(80))
                foundFirst = true
            }
            result.lastUser = String(text.prefix(80))
        }
        return result
    }

    private static func extractText(from message: [String: Any]) -> String {
        guard let content = message["content"] else { return "" }
        if let str = content as? String {
            return str
        }
        if let array = content as? [[String: Any]] {
            for item in array {
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    return text
                }
            }
        }
        return ""
    }
}
