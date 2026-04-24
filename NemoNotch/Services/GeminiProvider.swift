import Foundation

@Observable
final class GeminiProvider {
    let source: AISource = .gemini
    var sessions: [String: AISessionState] = [:]
    var activeSession: AISessionState?
    var isHookInstalled = false

    private var timeoutTimer: Timer?
    private var sessionFiles: [String: String] = [:]

    init() {
        isHookInstalled = HookInstaller.isInstalled(.gemini)
    }

    func installHooks() {
        do {
            try HookInstaller.install(.gemini)
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install Gemini hooks: \(error)", category: "GeminiProvider")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall(.gemini)
            isHookInstalled = false
        } catch {
            LogService.error("Failed to uninstall Gemini hooks: \(error)", category: "GeminiProvider")
        }
    }

    func respondToPermission(sessionId: String, approved: Bool) { }

    // MARK: - Event Handling

    func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()

        switch event.hookEventName {
        case "SessionStart":
            var session = AISessionState(sessionId: sessionId, source: .gemini)
            session.phase = .idle
            applyContext(to: &session, event: event)
            if let cwd = event.cwd {
                sessionFiles[sessionId] = GeminiConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd)
            }
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "UserPromptSubmit":
            var session = ensureSession(sessionId)
            session.phase = session.phase.transition(to: .processing)
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "PreToolUse":
            var session = ensureSession(sessionId)
            session.phase = session.phase.transition(to: .processing)
            session.currentTool = event.toolName
            session.isPreToolUse = true
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            if let toolName = event.toolName, toolName == "invoke_subagent" {
                session.subagentState.startTask(
                    taskToolId: event.toolUseId ?? UUID().uuidString,
                    description: "Subagent"
                )
            }
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "PostToolUse":
            var session = ensureSession(sessionId)
            session.currentTool = nil
            session.isPreToolUse = false
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            if let toolName = event.toolName, toolName == "invoke_subagent" {
                session.subagentState.stopTask(taskToolId: event.toolUseId ?? "")
            }
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "Notification":
            var session = ensureSession(sessionId)
            session.phase = session.phase.transition(to: .waitingForInput)
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            sessions[sessionId] = session

        case "Stop":
            if var session = sessions[sessionId] {
                session.phase = session.phase.transition(to: .waitingForInput)
                session.currentTool = nil
                session.isPreToolUse = false
                applyContext(to: &session, event: event)
                session.lastEventTime = now
                sessions[sessionId] = session
                parseConversation(for: sessionId)
            }

        case "SessionEnd":
            sessionFiles.removeValue(forKey: sessionId)
            sessions.removeValue(forKey: sessionId)

        default:
            break
        }

        updateActiveSession()
        scheduleTimeoutCleanup()
    }

    // MARK: - Helpers

    private func ensureSession(_ sessionId: String) -> AISessionState {
        if let existing = sessions[sessionId] { return existing }
        return AISessionState(sessionId: sessionId, source: .gemini)
    }

    private func applyContext(to session: inout AISessionState, event: HookEvent) {
        if let cwd = event.cwd { session.cwd = cwd }
        if let msg = event.message, !msg.isEmpty { session.lastMessage = msg }
        session.lastEventName = event.hookEventName
    }

    // MARK: - Conversation Parsing

    private func parseConversation(for sessionId: String) {
        guard let filePath = sessionFiles[sessionId] ?? resolveFile(for: sessionId) else { return }
        sessionFiles[sessionId] = filePath

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = GeminiConversationParser.parseFull(filePath: filePath)

            DispatchQueue.main.async {
                guard let self, var session = self.sessions[sessionId] else { return }

                if let result {
                    session.messages = result.messages
                    session.inputTokens = result.inputTokens
                    session.outputTokens = result.outputTokens
                    session.cacheReadTokens = result.cachedTokens
                    if let model = result.lastModel {
                        session.model = model
                    }

                    let userMessages = result.messages.filter { $0.role == .user }
                    if let first = userMessages.first, session.firstUserMessage == nil {
                        session.firstUserMessage = String(first.content.prefix(80))
                    }
                    if let last = userMessages.last {
                        session.lastUserMessage = String(last.content.prefix(80))
                    }
                }

                self.sessions[sessionId] = session
            }
        }
    }

    private func resolveFile(for sessionId: String) -> String? {
        guard let cwd = sessions[sessionId]?.cwd else { return nil }
        return GeminiConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd)
    }

    // MARK: - Active Session

    private func updateActiveSession() {
        let prev = activeSession?.id
        let sortedSessions = sessions.values.sorted { sessionPriority($0) > sessionPriority($1) }
        activeSession = sortedSessions.first

        if activeSession?.id != prev {
            LogService.info("Gemini active session: \(prev?.prefix(8) ?? "nil") -> \(activeSession?.id.prefix(8) ?? "nil")", category: "GeminiProvider")
        }
    }

    private func sessionPriority(_ session: AISessionState) -> Int {
        switch session.phase {
        case .processing: return 80
        case .compacting: return 70
        case .waitingForInput: return 50
        case .idle: return 10
        case .ended: return 0
        case .waitingForApproval: return 100
        }
    }

    // MARK: - Timeout

    private func scheduleTimeoutCleanup() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.cleanupStaleSessions()
        }
    }

    private func cleanupStaleSessions() {
        let threshold = Date().addingTimeInterval(-1800)
        let staleIds = sessions.filter { $0.value.lastEventTime < threshold }.map(\.key)
        for id in staleIds {
            sessionFiles.removeValue(forKey: id)
            sessions.removeValue(forKey: id)
        }
        updateActiveSession()
    }
}
