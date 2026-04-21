import Foundation

@Observable
final class ClaudeCodeService {
    var sessions: [String: ClaudeState] = [:]
    var activeSession: ClaudeState?
    var isHookInstalled = false
    var serverRunning = false

    let hookServer = HookServer()
    private let watcherManager = InterruptWatcherManager()
    private let agentWatcherManager = AgentFileWatcherManager()

    private var timeoutTimer: Timer?

    init() {
        hookServer.onEventReceived = { [weak self] event in
            self?.handleEvent(event)
        }
        hookServer.onReady = { [weak self] in
            guard let self else { return }
            self.serverRunning = true
            try? HookInstaller.install()
            self.isHookInstalled = HookInstaller.isInstalled()
        }
        isHookInstalled = HookInstaller.isInstalled()

        watcherManager.onInterrupt = { [weak self] sessionId in
            self?.handleInterrupt(sessionId: sessionId)
        }
        watcherManager.onClear = { [weak self] sessionId in
            self?.handleClear(sessionId: sessionId)
        }
    }

    func startServer() {
        hookServer.start()
    }

    func installHooks() {
        do {
            try HookInstaller.install()
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

    // MARK: - Permission Response

    func respondToPermission(sessionId: String, approved: Bool) {
        hookServer.respondToPermission(sessionId: sessionId, approved: approved)
        if var session = sessions[sessionId] {
            session.phase = session.phase.transition(to: .processing)
            sessions[sessionId] = session
            updateActiveSession()
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()

        switch event.hookEventName {
        case "SessionStart":
            var session = ClaudeState(sessionId: sessionId)
            session.phase = .idle
            applyContext(to: &session, event: event)
            sessions[sessionId] = session
            if let cwd = event.cwd {
                watcherManager.startWatching(sessionId: sessionId, cwd: cwd)
            }
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
            if let toolName = event.toolName, ["Task", "Agent"].contains(toolName) {
                applySubagentStart(to: &session, event: event)
            }
            sessions[sessionId] = session

        case "PostToolUse":
            var session = ensureSession(sessionId)
            session.currentTool = nil
            session.isPreToolUse = false
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            if let toolName = event.toolName, ["Task", "Agent"].contains(toolName) {
                applySubagentStop(to: &session, event: event)
                agentWatcherManager.stopWatching(sessionId: sessionId, taskToolId: event.toolUseId ?? "")
            }
            sessions[sessionId] = session

        case "Notification":
            var session = ensureSession(sessionId)
            session.phase = session.phase.transition(to: .waitingForInput)
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            sessions[sessionId] = session

        case "PermissionRequest":
            var session = ensureSession(sessionId)
            let ctx = PermissionContext(
                toolUseId: event.toolUseId ?? event.toolName ?? "unknown",
                toolName: event.toolName ?? "unknown",
                toolInput: event.message,
                receivedAt: now
            )
            session.phase = session.phase.transition(to: .waitingForApproval(ctx))
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            sessions[sessionId] = session
            LogService.info("Permission request: \(ctx.toolName) (\(ctx.toolUseId)) for session \(sessionId.prefix(8))", category: "ClaudeCode")

        case "Stop":
            if var session = sessions[sessionId] {
                session.phase = session.phase.transition(to: .idle)
                session.currentTool = nil
                session.isPreToolUse = false
                applyContext(to: &session, event: event)
                session.lastEventTime = now
                sessions[sessionId] = session
                parseConversation(for: sessionId)
            }

        case "SessionEnd":
            hookServer.cancelPendingPermissions(sessionId: sessionId)
            watcherManager.stopWatching(sessionId: sessionId)
            agentWatcherManager.stopAll(sessionId: sessionId)
            sessions.removeValue(forKey: sessionId)

        default:
            break
        }

        updateActiveSession()
        scheduleTimeoutCleanup()
    }

    // MARK: - Helpers

    private func ensureSession(_ sessionId: String) -> ClaudeState {
        if let existing = sessions[sessionId] { return existing }
        return ClaudeState(sessionId: sessionId)
    }

    private func applyContext(to session: inout ClaudeState, event: HookEvent) {
        if let cwd = event.cwd { session.cwd = cwd }
        if let msg = event.message, !msg.isEmpty { session.lastMessage = msg }
        session.lastEventName = event.hookEventName
    }

    private func applySubagentStart(to session: inout ClaudeState, event: HookEvent) {
        let taskToolId = event.toolUseId ?? UUID().uuidString
        var description: String?
        var agentId: String?
        if let input = event.message,
           let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            description = json["description"] as? String ?? json["prompt"] as? String
            agentId = json["agentId"] as? String ?? json["subagent_id"] as? String
        }
        session.subagentState.startTask(taskToolId: taskToolId, description: description)
        if let agentId {
            session.subagentState.setAgentId(taskToolId: taskToolId, agentId: agentId)
            let sessionId = session.id
            startAgentFileWatcher(sessionId: sessionId, taskToolId: taskToolId, cwd: session.cwd, agentId: agentId)
        }
    }

    private func startAgentFileWatcher(sessionId: String, taskToolId: String, cwd: String?, agentId: String) {
        guard let cwd else { return }
        let dir = ConversationParser.conversationPath(sessionId: sessionId, cwd: cwd)
            .map { ($0 as NSString).deletingLastPathComponent } ?? ""

        let nestedPath = "\(dir)/\(sessionId)/subagents/agent-\(agentId).jsonl"
        let flatPath = "\(dir)/agent-\(agentId).jsonl"
        let filePath = FileManager.default.fileExists(atPath: nestedPath) ? nestedPath : flatPath

        agentWatcherManager.startWatching(sessionId: sessionId, taskToolId: taskToolId, agentFilePath: filePath) { [weak self] tools in
            self?.updateSubagentTools(sessionId: sessionId, taskToolId: taskToolId, tools: tools)
        }
    }

    private func applySubagentStop(to session: inout ClaudeState, event: HookEvent) {
        let taskToolId = event.toolUseId ?? ""
        session.subagentState.stopTask(taskToolId: taskToolId)
    }

    // MARK: - Interrupt & Clear

    private func handleInterrupt(sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        session.phase = session.phase.transition(to: .idle)
        session.currentTool = nil
        session.lastEventTime = Date()
        sessions[sessionId] = session
        updateActiveSession()
        LogService.info("Interrupt detected for session \(sessionId.prefix(8))", category: "ClaudeCode")
    }

    private func handleClear(sessionId: String) {
        guard var session = sessions[sessionId] else { return }
        session.messages = []
        session.lastParsedOffset = 0
        session.phase = session.phase.transition(to: .idle)
        sessions[sessionId] = session
        LogService.info("Clear detected for session \(sessionId.prefix(8))", category: "ClaudeCode")
    }

    // MARK: - Conversation Parsing

    private func parseConversation(for sessionId: String) {
        guard let session = sessions[sessionId],
              let cwd = session.cwd,
              let filePath = ConversationParser.conversationPath(sessionId: sessionId, cwd: cwd) else { return }

        let offset = session.lastParsedOffset
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ConversationParser.parseIncremental(filePath: filePath, fromOffset: offset)

            DispatchQueue.main.async {
                guard let self, var session = self.sessions[sessionId] else { return }

                if result.cleared {
                    session.messages = []
                }
                session.messages.append(contentsOf: result.messages)
                session.lastParsedOffset = result.newOffset
                session.inputTokens += result.inputTokens
                session.outputTokens += result.outputTokens
                session.cacheReadTokens += result.cacheReadTokens
                session.cacheCreationTokens += result.cacheCreationTokens
                if result.lastContextTokens > 0 {
                    session.lastContextTokens = result.lastContextTokens
                }
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

                self.sessions[sessionId] = session

                if result.inputTokens > 0 || result.cacheReadTokens > 0 {
                    LogService.debug("Tokens +\(result.inputTokens)in +\(result.outputTokens)out +\(result.cacheReadTokens)cr +\(result.cacheCreationTokens)cc, ctx=\(result.lastContextTokens), model=\(result.lastModel ?? "?") → totals: \(session.inputTokens)in \(session.outputTokens)out \(session.cacheReadTokens)cr \(session.cacheCreationTokens)cc", category: "ClaudeCode")
                }

                if result.interrupted {
                    self.handleInterrupt(sessionId: sessionId)
                }
            }
        }
    }

    // MARK: - Subagent File Updates

    func updateSubagentTools(sessionId: String, taskToolId: String, tools: [SubagentToolCall]) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateTools(taskToolId: taskToolId, tools: tools)
        sessions[sessionId] = session
    }

    // MARK: - Active Session

    private func updateActiveSession() {
        let prev = activeSession?.id
        let sortedSessions = sessions.values.sorted { sessionPriority($0) > sessionPriority($1) }
        activeSession = sortedSessions.first

        if activeSession?.id != prev {
            let phaseStr: String
            if let phase = activeSession?.phase {
                phaseStr = String(describing: phase)
            } else {
                phaseStr = "nil"
            }
            LogService.info("Active session: \(prev?.prefix(8) ?? "nil") -> \(activeSession?.id.prefix(8) ?? "nil"), phase=\(phaseStr)", category: "ClaudeCode")
        }
    }

    private func sessionPriority(_ session: ClaudeState) -> Int {
        switch session.phase {
        case .waitingForApproval: return 100
        case .processing: return 80
        case .compacting: return 70
        case .waitingForInput: return 50
        case .idle: return 10
        case .ended: return 0
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
            watcherManager.stopWatching(sessionId: id)
            sessions.removeValue(forKey: id)
        }
        updateActiveSession()
    }
}
