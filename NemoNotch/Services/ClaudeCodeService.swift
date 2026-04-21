import Foundation

@Observable
final class ClaudeCodeService {
    var sessions: [String: ClaudeState] = [:]
    var activeSession: ClaudeState?
    var isHookInstalled = false
    var serverRunning = false

    let hookServer = HookServer()
    private let watcherManager = InterruptWatcherManager()

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
        if sessions[sessionId] != nil {
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .processing) ?? .processing
            updateActiveSession()
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()

        func ensureSession() {
            if sessions[sessionId] == nil {
                sessions[sessionId] = ClaudeState(sessionId: sessionId)
            }
        }

        func updateContext() {
            if let cwd = event.cwd { sessions[sessionId]?.cwd = cwd }
            if let msg = event.message, !msg.isEmpty { sessions[sessionId]?.lastMessage = msg }
            sessions[sessionId]?.lastEventName = event.hookEventName
        }

        switch event.hookEventName {
        case "SessionStart":
            sessions[sessionId] = ClaudeState(sessionId: sessionId)
            sessions[sessionId]?.phase = .idle
            updateContext()
            if let cwd = event.cwd {
                watcherManager.startWatching(sessionId: sessionId, cwd: cwd)
            }
            parseConversation(for: sessionId)

        case "UserPromptSubmit":
            ensureSession()
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .processing) ?? .processing
            updateContext()
            sessions[sessionId]?.lastEventTime = now
            parseConversation(for: sessionId)

        case "PreToolUse":
            ensureSession()
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .processing) ?? .processing
            sessions[sessionId]?.currentTool = event.toolName
            sessions[sessionId]?.isPreToolUse = true
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "PostToolUse":
            ensureSession()
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.isPreToolUse = false
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "Notification":
            ensureSession()
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .waitingForInput) ?? .waitingForInput
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "PermissionRequest":
            ensureSession()
            let ctx = PermissionContext(
                toolUseId: event.toolName ?? "unknown",
                toolName: event.toolName ?? "unknown",
                toolInput: event.message,
                receivedAt: now
            )
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .waitingForApproval(ctx)) ?? .waitingForApproval(ctx)
            updateContext()
            sessions[sessionId]?.lastEventTime = now
            LogService.info("Permission request: \(ctx.toolName) for session \(sessionId.prefix(8))", category: "ClaudeCode")

        case "Stop":
            if sessions[sessionId] != nil {
                sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .idle) ?? .idle
                sessions[sessionId]?.currentTool = nil
                sessions[sessionId]?.isPreToolUse = false
                updateContext()
                sessions[sessionId]?.lastEventTime = now
                parseConversation(for: sessionId)
            }

        case "SessionEnd":
            watcherManager.stopWatching(sessionId: sessionId)
            sessions.removeValue(forKey: sessionId)

        default:
            break
        }

        updateActiveSession()
        scheduleTimeoutCleanup()
    }

    // MARK: - Interrupt & Clear

    private func handleInterrupt(sessionId: String) {
        guard sessions[sessionId] != nil else { return }
        sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .idle) ?? .idle
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.lastEventTime = Date()
        updateActiveSession()
        LogService.info("Interrupt detected for session \(sessionId.prefix(8))", category: "ClaudeCode")
    }

    private func handleClear(sessionId: String) {
        guard sessions[sessionId] != nil else { return }
        sessions[sessionId]?.messages = []
        sessions[sessionId]?.lastParsedOffset = 0
        sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .idle) ?? .idle
        LogService.info("Clear detected for session \(sessionId.prefix(8))", category: "ClaudeCode")
    }

    // MARK: - Conversation Parsing

    private func parseConversation(for sessionId: String) {
        guard let cwd = sessions[sessionId]?.cwd else { return }
        guard let filePath = ConversationParser.conversationPath(sessionId: sessionId, cwd: cwd) else { return }

        let offset = sessions[sessionId]?.lastParsedOffset ?? 0
        let result = ConversationParser.parseIncremental(filePath: filePath, fromOffset: offset)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessions[sessionId] != nil else { return }

            if result.cleared {
                self.sessions[sessionId]?.messages = []
            }
            self.sessions[sessionId]?.messages.append(contentsOf: result.messages)
            self.sessions[sessionId]?.lastParsedOffset = result.newOffset
            self.sessions[sessionId]?.inputTokens += result.inputTokens
            self.sessions[sessionId]?.outputTokens += result.outputTokens

            let userMessages = result.messages.filter { $0.role == .user }
            if let first = userMessages.first, self.sessions[sessionId]?.firstUserMessage == nil {
                self.sessions[sessionId]?.firstUserMessage = String(first.content.prefix(80))
            }
            if let last = userMessages.last {
                self.sessions[sessionId]?.lastUserMessage = String(last.content.prefix(80))
            }

            if result.interrupted {
                self.handleInterrupt(sessionId: sessionId)
            }
        }
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
        for (id, state) in sessions {
            if state.lastEventTime < threshold {
                watcherManager.stopWatching(sessionId: id)
                sessions.removeValue(forKey: id)
            }
        }
        updateActiveSession()
    }
}
