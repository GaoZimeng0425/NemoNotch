import Foundation

@MainActor
@Observable
final class ClaudeProvider: AIProvider {
    let source: AISource = .claude
    var isHookInstalled = false

    private let store: AISessionStore
    private let watcherManager = InterruptWatcherManager()
    private let agentWatcherManager = AgentFileWatcherManager()
    private var timeoutTimer: Timer?
    private weak var hookServer: HookServer?

    init(store: AISessionStore) {
        self.store = store
        isHookInstalled = HookInstaller.isInstalled(.claude)

        watcherManager.onInterrupt = { [weak self] sessionId in
            self?.handleInterrupt(sessionId: sessionId)
        }
        watcherManager.onClear = { [weak self] sessionId in
            self?.handleClear(sessionId: sessionId)
        }
    }

    func setHookServer(_ server: HookServer) {
        hookServer = server
    }

    // MARK: - Startup Scan

    func scanExistingSessions() {
        let fm = FileManager.default
        let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return }

        let threshold = Date().addingTimeInterval(-3600)
        var discovered = 0

        for dir in projectDirs {
            let fullDir = "\(projectsDir)/\(dir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullDir, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(atPath: fullDir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let filePath = "\(fullDir)/\(file)"
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate > threshold else { continue }

                let sessionId = String(file.dropLast(5)) // remove ".jsonl"
                if store.contains(sessionId) { continue }

                var session = AISessionState(sessionId: sessionId, source: .claude)
                session.lastEventTime = modDate

                let cwdEncoded = dir.hasPrefix("-") ? String(dir.dropFirst()) : dir
                let cwd = "/" + cwdEncoded.replacingOccurrences(of: "-", with: "/")
                session.cwd = cwd

                let result = ConversationParser.parseFullResult(filePath: filePath)
                session.messages = result.messages
                // Record how far we've already read. Without this the first hook
                // event re-parses the whole JSONL from offset 0 on the MainActor
                // (up to several MB) and duplicate-appends every message. See the
                // freeze-investigation: the post-"Allow" stall walked this path.
                session.lastParsedOffset = result.newOffset
                session.inputTokens = result.inputTokens
                session.outputTokens = result.outputTokens
                session.cacheReadTokens = result.cacheReadTokens
                session.cacheCreationTokens = result.cacheCreationTokens
                if result.lastContextTokens > 0 { session.lastContextTokens = result.lastContextTokens }
                if let model = result.lastModel { session.model = model }

                let userMessages = result.messages.filter { $0.role == .user }
                if let first = userMessages.first { session.firstUserMessage = String(first.content.prefix(80)) }
                if let last = userMessages.last { session.lastUserMessage = String(last.content.prefix(80)) }

                session.phase = .idle
                store.upsert(session)
                discovered += 1
            }
        }

        if discovered > 0 {
            LogService.info("Claude: discovered \(discovered) existing session(s)", category: "ClaudeProvider")
            scheduleTimeoutCleanup()
        }
    }

    func installHooks() {
        do {
            try HookInstaller.install(.claude)
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install hooks: \(error)", category: "ClaudeProvider")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall(.claude)
            isHookInstalled = false
        } catch {
            LogService.error("Failed to uninstall hooks: \(error)", category: "ClaudeProvider")
        }
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        hookServer?.respondToPermission(sessionId: sessionId, approved: approved)
        store.mutate(sessionId) { session in
            session.phase = session.phase.transition(to: .processing)
        }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()

        switch event.hookEventName {
        case "SessionStart":
            var session = AISessionState(sessionId: sessionId, source: .claude)
            session.phase = .idle
            applyContext(to: &session, event: event)
            store.upsert(session)
            if let cwd = event.cwd {
                watcherManager.startWatching(sessionId: sessionId, cwd: cwd)
            }
            parseConversation(for: sessionId)

        case "UserPromptSubmit":
            store.mutateOrCreate(sessionId, source: .claude) { session in
                session.phase = session.phase.transition(to: .processing)
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }
            parseConversation(for: sessionId)

        case "PreToolUse":
            store.mutateOrCreate(sessionId, source: .claude) { session in
                session.phase = session.phase.transition(to: .processing)
                session.currentTool = event.toolName
                session.isPreToolUse = true
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
                if let toolName = event.toolName, ["Task", "Agent"].contains(toolName) {
                    self.applySubagentStart(to: &session, event: event)
                }
            }
            parseConversation(for: sessionId)

        case "PostToolUse":
            // A tool finishing while we still show an approval prompt means it
            // was approved in the terminal (or the request timed out). Drop the
            // stale pending request and clear the button so it can't be clicked
            // into a void.
            if store.get(sessionId)?.phase.isWaitingForApproval == true {
                hookServer?.clearPendingPermissions(sessionId: sessionId)
            }
            store.mutateOrCreate(sessionId, source: .claude) { session in
                session.currentTool = nil
                session.isPreToolUse = false
                if session.phase.isWaitingForApproval {
                    session.phase = session.phase.transition(to: .processing)
                }
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
                if let toolName = event.toolName, ["Task", "Agent"].contains(toolName) {
                    session.subagentState.stopTask(taskToolId: event.toolUseId ?? "")
                }
            }
            if let toolName = event.toolName, ["Task", "Agent"].contains(toolName) {
                agentWatcherManager.stopWatching(sessionId: sessionId, taskToolId: event.toolUseId ?? "")
            }
            parseConversation(for: sessionId)

        case "Notification":
            store.mutateOrCreate(sessionId, source: .claude) { session in
                session.phase = session.phase.transition(to: .waitingForInput)
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }

        case "PermissionRequest":
            let ctx = PermissionContext(
                toolUseId: event.toolUseId ?? event.toolName ?? "unknown",
                toolName: event.toolName ?? "unknown",
                toolInput: event.message,
                receivedAt: now
            )
            store.mutateOrCreate(sessionId, source: .claude) { session in
                session.phase = session.phase.transition(to: .waitingForApproval(ctx))
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }
            LogService.info(
                "Permission request: \(ctx.toolName) (\(ctx.toolUseId)) for session \(sessionId.prefix(8))",
                category: "ClaudeProvider"
            )

        case "Stop":
            guard store.contains(sessionId) else { return }
            store.mutate(sessionId) { session in
                session.phase = session.phase.transition(to: .waitingForInput)
                session.currentTool = nil
                session.isPreToolUse = false
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }
            parseConversation(for: sessionId)

        case "SessionEnd":
            hookServer?.cancelPendingPermissions(sessionId: sessionId)
            watcherManager.stopWatching(sessionId: sessionId)
            agentWatcherManager.stopAll(sessionId: sessionId)
            store.remove(sessionId)

        default:
            break
        }

        scheduleTimeoutCleanup()
    }

    // MARK: - Helpers

    private func applyContext(to session: inout AISessionState, event: HookEvent) {
        if let cwd = event.cwd { session.cwd = cwd }
        if let msg = event.message, !msg.isEmpty { session.lastMessage = msg }
        session.lastEventName = event.hookEventName
    }

    private func applySubagentStart(to session: inout AISessionState, event: HookEvent) {
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
            let cwd = session.cwd
            startAgentFileWatcher(sessionId: sessionId, taskToolId: taskToolId, cwd: cwd, agentId: agentId)
        }
    }

    private func startAgentFileWatcher(sessionId: String, taskToolId: String, cwd: String?, agentId: String) {
        guard let cwd else { return }
        let dir = ConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd)
            .map { ($0 as NSString).deletingLastPathComponent } ?? ""

        let nestedPath = "\(dir)/\(sessionId)/subagents/agent-\(agentId).jsonl"
        let flatPath = "\(dir)/agent-\(agentId).jsonl"
        let filePath = FileManager.default.fileExists(atPath: nestedPath) ? nestedPath : flatPath

        agentWatcherManager
            .startWatching(sessionId: sessionId, taskToolId: taskToolId, agentFilePath: filePath) { [weak self] tools in
                self?.updateSubagentTools(sessionId: sessionId, taskToolId: taskToolId, tools: tools)
            }
    }

    // MARK: - Interrupt & Clear

    private func handleInterrupt(sessionId: String) {
        guard store.contains(sessionId) else { return }
        store.mutate(sessionId) { session in
            session.phase = session.phase.transition(to: .idle)
            session.currentTool = nil
            session.lastEventTime = Date()
        }
        LogService.info("Interrupt detected for session \(sessionId.prefix(8))", category: "ClaudeProvider")
    }

    func handleClear(sessionId: String) {
        guard store.contains(sessionId) else { return }
        store.mutate(sessionId) { session in
            session.messages = []
            // clear = 从头重建:offset 归零会重放整个文件,token 计数必须同步
            // 归零,否则历史 usage 会被再次累加(显示翻倍)。
            session.inputTokens = 0
            session.outputTokens = 0
            session.thoughtTokens = 0
            session.cacheReadTokens = 0
            session.cacheCreationTokens = 0
            session.lastContextTokens = 0
            session.lastParsedOffset = 0
            session.phase = session.phase.transition(to: .idle)
        }
        LogService.info("Clear detected for session \(sessionId.prefix(8))", category: "ClaudeProvider")
    }

    // MARK: - Conversation Parsing

    private func parseConversation(for sessionId: String) {
        guard let session = store.get(sessionId),
              let cwd = session.cwd,
              let filePath = ConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd) else { return }

        Task {
            // offset 必须在 Task 内捕获:事件背靠背到达时,在事件处理时捕获会让
            // 两个 Task 解析同一区段(消息重复、token 双计)。Task 继承 MainActor
            // 串行执行,后到的 Task 捕获到的已是前一个应用后的 offset。
            let offset = self.store.get(sessionId)?.lastParsedOffset ?? 0
            let result = ConversationParser.parseIncremental(filePath: filePath, fromOffset: offset)

            guard self.store.contains(sessionId) else { return }
            self.store.mutate(sessionId) { session in
                if result.cleared { session.messages = [] }
                for message in result.messages {
                    session.upsertMessage(message)
                }
                session.lastParsedOffset = max(session.lastParsedOffset, result.newOffset)
                session.inputTokens += result.inputTokens
                session.outputTokens += result.outputTokens
                session.cacheReadTokens += result.cacheReadTokens
                session.cacheCreationTokens += result.cacheCreationTokens
                if result.lastContextTokens > 0 { session.lastContextTokens = result.lastContextTokens }
                if let model = result.lastModel { session.model = model }

                let userMessages = result.messages.filter { $0.role == .user }
                if let first = userMessages.first, session.firstUserMessage == nil {
                    session.firstUserMessage = String(first.content.prefix(80))
                }
                if let last = userMessages.last {
                    session.lastUserMessage = String(last.content.prefix(80))
                }
            }

            if result.interrupted {
                self.handleInterrupt(sessionId: sessionId)
            }
        }
    }

    // MARK: - Subagent File Updates

    func updateSubagentTools(sessionId: String, taskToolId: String, tools: [SubagentToolCall]) {
        store.mutate(sessionId) { session in
            session.subagentState.updateTools(taskToolId: taskToolId, tools: tools)
        }
    }

    // MARK: - Timeout

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

        for session in store.sessions(for: .claude) where session.lastEventTime < demoteCutoff {
            // Demote ANY active phase, not just .waitingForInput — an aborted or
            // Stop-missed session stuck in .processing would otherwise spin for
            // up to 30 min (removeStaleThreshold).
            if case .idle = session.phase { continue }
            if case .ended = session.phase { continue }
            store.mutate(session.id) { s in
                s.phase = s.phase.transition(to: .idle)
                s.currentTool = nil
                s.isPreToolUse = false
            }
            LogService.info(
                "Demoted silent session \(session.id.prefix(8)) to idle (\(Int(now.timeIntervalSince(session.lastEventTime)))s silent)",
                category: "ClaudeProvider"
            )
        }

        for session in store.sessions(for: .claude) where session.lastEventTime < removeCutoff {
            watcherManager.stopWatching(sessionId: session.id)
            store.remove(session.id)
            LogService.info("Removed stale session \(session.id.prefix(8))", category: "ClaudeProvider")
        }

        if store.sessions(for: .claude).isEmpty {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
    }
}

typealias ClaudeCodeService = ClaudeProvider
