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
    /// 每会话串行解析链:见 parseConversation 的说明。随会话回收(SessionEnd /
    /// stale 超时)清理,防止按会话 id 无界增长。
    private var parseChains: [String: Task<Void, Never>] = [:]

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
        let store = self.store
        // 启动扫描的全部文件 I/O 与解析(1 小时内的会话动辄数 MB)挪到后台,
        // store 写入回到主线程;应用前重查 contains,迟到的扫描不会覆盖期间
        // 由 hook 事件创建的活跃会话。
        Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                Self.scanDiskSessions()
            }.value

            guard let self, !discovered.isEmpty else { return }
            for session in discovered where !store.contains(session.id) {
                store.upsert(session)
            }
            LogService.info("Claude: discovered \(discovered.count) existing session(s)", category: "ClaudeProvider")
            scheduleTimeoutCleanup()
        }
    }

    /// 纯磁盘扫描 + 解析,不触碰任何 actor 隔离状态,可运行在任意线程。
    private nonisolated static func scanDiskSessions() -> [AISessionState] {
        let fm = FileManager.default
        let projectsDir = NSString(string: "~/.claude/projects").expandingTildeInPath
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }

        let threshold = Date().addingTimeInterval(-3600)
        var found: [AISessionState] = []

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

                var session = AISessionState(sessionId: sessionId, source: .claude)
                session.lastEventTime = modDate

                let cwdEncoded = dir.hasPrefix("-") ? String(dir.dropFirst()) : dir
                let cwd = "/" + cwdEncoded.replacingOccurrences(of: "-", with: "/")
                session.cwd = cwd

                let result = ConversationParser.parseFullResult(filePath: filePath)
                session.messages = result.messages
                // Record how far we've already read. Without this the first hook
                // event re-parses the whole JSONL from offset 0 (up to several
                // MB) and duplicate-appends every message. See the
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
                found.append(session)
            }
        }

        return found
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
            parseChains.removeValue(forKey: sessionId)
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

        // 解析挪到后台线程后,await 挂起期间 MainActor 上的任务会相互交错,
        // 单纯"Task 内捕获 offset"不再能防止两个在飞任务捕获相同 offset
        // (H06 竞态复活)。按会话串行链:等前一个任务应用完毕后再捕获。
        let previous = parseChains[sessionId]
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.store.contains(sessionId),
                  let current = self.store.get(sessionId) else { return }
            let offset = current.lastParsedOffset
            let result = await Task.detached(priority: .userInitiated) {
                ConversationParser.parseIncremental(filePath: filePath, fromOffset: offset)
            }.value

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
        parseChains[sessionId] = task
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
            parseChains.removeValue(forKey: session.id)
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
