import Foundation

@MainActor
@Observable
final class GeminiProvider: AIProvider {
    let source: AISource = .gemini
    var isHookInstalled = false

    private let store: AISessionStore
    private let watcherManager = GeminiWatcherManager()
    private let agentWatcherManager = AgentFileWatcherManager()
    private var timeoutTimer: Timer?
    private var sessionFiles: [String: String] = [:]
    private weak var hookServer: HookServer?

    init(store: AISessionStore) {
        self.store = store
        isHookInstalled = HookInstaller.isInstalled(.gemini)

        watcherManager.onChanged = { [weak self] sessionId in
            self?.parseConversation(for: sessionId)
        }
        watcherManager.onClear = { [weak self] sessionId in
            self?.handleClear(sessionId: sessionId)
        }
    }

    func setHookServer(_ server: HookServer) {
        hookServer = server
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
            var session = AISessionState(sessionId: sessionId, source: .gemini)
            session.phase = .idle
            applyContext(to: &session, event: event)
            store.upsert(session)
            if let cwd = event.cwd {
                watcherManager.startWatching(sessionId: sessionId, cwd: cwd)
            }
            parseConversation(for: sessionId)

        case "BeforeAgent":
            store.mutateOrCreate(sessionId, source: .gemini) { session in
                session.phase = session.phase.transition(to: .processing)
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }
            parseConversation(for: sessionId)

        case "BeforeTool":
            store.mutateOrCreate(sessionId, source: .gemini) { session in
                session.phase = session.phase.transition(to: .processing)
                session.currentTool = event.toolName
                session.isPreToolUse = true
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
                if let toolName = event.toolName, ["invoke_subagent", "Task", "Agent"].contains(toolName) {
                    self.applySubagentStart(to: &session, event: event)
                }
            }
            parseConversation(for: sessionId)

        case "AfterTool":
            store.mutateOrCreate(sessionId, source: .gemini) { session in
                session.currentTool = nil
                session.isPreToolUse = false
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
                if let toolName = event.toolName, ["invoke_subagent", "Task", "Agent"].contains(toolName) {
                    session.subagentState.stopTask(taskToolId: event.toolUseId ?? "")
                }
            }
            if let toolName = event.toolName, ["invoke_subagent", "Task", "Agent"].contains(toolName) {
                agentWatcherManager.stopWatching(sessionId: sessionId, taskToolId: event.toolUseId ?? "")
            }
            parseConversation(for: sessionId)

        case "Notification":
            store.mutateOrCreate(sessionId, source: .gemini) { session in
                session.phase = session.phase.transition(to: .waitingForInput)
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }
            parseConversation(for: sessionId)

        case "AfterAgent":
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
            watcherManager.stopWatching(sessionId: sessionId)
            agentWatcherManager.stopAll(sessionId: sessionId)
            sessionFiles.removeValue(forKey: sessionId)
            store.remove(sessionId)

        default:
            break
        }

        scheduleTimeoutCleanup()
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

        if let agentId, let cwd = session.cwd {
            let sessionId = session.id
            // Gemini subagent files are JSONL in the same tmp dir
            let projectName = GeminiConversationParser.projectName(for: cwd) ?? ""
            let filePath = NSHomeDirectory() + "/.gemini/tmp/\(projectName)/chats/agent-\(agentId).jsonl"

            agentWatcherManager
                .startWatching(
                    sessionId: sessionId,
                    taskToolId: taskToolId,
                    agentFilePath: filePath
                ) { [weak self] tools in
                    self?.updateSubagentTools(sessionId: sessionId, taskToolId: taskToolId, tools: tools)
                }
        }
    }

    func updateSubagentTools(sessionId: String, taskToolId: String, tools: [SubagentToolCall]) {
        store.mutate(sessionId) { session in
            session.subagentState.updateTools(taskToolId: taskToolId, tools: tools)
        }
    }

    // MARK: - Startup Scan

    func scanExistingSessions() {
        let projectsPath = NSHomeDirectory() + "/.gemini/projects.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: projectsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: String] else {
            return
        }

        let fm = FileManager.default
        let threshold = Date().addingTimeInterval(-3600)
        var discovered = 0

        for (cwd, projectName) in projects {
            let chatsDir = NSHomeDirectory() + "/.gemini/tmp/\(projectName)/chats"
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            for file in files where file.hasSuffix(".json") || file.hasSuffix(".jsonl") {
                let filePath = chatsDir + "/" + file

                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate > threshold else { continue }

                var sessionId: String?
                if file.hasSuffix(".jsonl") {
                    if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)),
                       let firstLineData = try? handle.read(upToCount: 1024),
                       let firstLine = String(data: firstLineData, encoding: .utf8)?.components(separatedBy: "\n")
                       .first,
                       let firstJson = try? JSONSerialization
                       .jsonObject(with: firstLine.data(using: .utf8) ?? Data()) as? [String: Any] {
                        sessionId = firstJson["sessionId"] as? String
                        try? handle.close()
                    }
                } else {
                    guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                          let sessionJson = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any]
                    else { continue }
                    sessionId = sessionJson["sessionId"] as? String
                }

                guard let sid = sessionId, !store.contains(sid) else { continue }

                var state = AISessionState(sessionId: sid, source: .gemini)
                state.cwd = cwd
                state.lastEventTime = modDate
                sessionFiles[sid] = filePath

                applyParsedContent(to: &state, filePath: filePath)
                state.phase = .idle // Resurrected sessions start idle — phase will be promoted by future hook events.
                store.upsert(state)
                watcherManager.startWatching(sessionId: sid, cwd: cwd)
                discovered += 1
            }
        }

        if discovered > 0 {
            LogService.info("Gemini: discovered \(discovered) existing session(s)", category: "GeminiProvider")
            scheduleTimeoutCleanup()
        }
    }

    private func applyParsedContent(to session: inout AISessionState, filePath: String) {
        if filePath.hasSuffix(".jsonl") {
            let res = GeminiConversationParser.parseIncrementalJSONL(filePath: filePath, fromOffset: 0)
            for msg in res.common.messages {
                session.upsertMessage(msg)
            }
            session.inputTokens = res.common.inputTokens
            session.outputTokens = res.common.outputTokens
            session.thoughtTokens = res.thoughtTokens
            session.cacheReadTokens = res.cachedTokens
            if let model = res.common.lastModel { session.model = model }
            session.lastContextTokens = res.lastContextTokens
            session.lastParsedOffset = res.newOffset
        } else {
            guard let result = GeminiConversationParser.parseDetailed(filePath: filePath) else { return }
            session.messages = result.common.messages
            session.inputTokens = result.common.inputTokens
            session.outputTokens = result.common.outputTokens
            session.thoughtTokens = result.thoughtTokens
            session.cacheReadTokens = result.cachedTokens
            session.lastContextTokens = result.lastContextTokens
            if let model = result.common.lastModel { session.model = model }
        }

        let userMessages = session.messages.filter { $0.role == .user }
        if let first = userMessages.first, session.firstUserMessage == nil {
            session.firstUserMessage = String(first.content.prefix(80))
        }
        if let last = userMessages.last {
            session.lastUserMessage = String(last.content.prefix(80))
        }

        let meaningful = session.messages.filter { ![.tool, .toolResult, .system].contains($0.role) }
        if let lastMsg = meaningful.last {
            switch lastMsg.role {
            case .user, .thought: session.phase = .processing
            case .assistant: session.phase = .waitingForInput
            default: session.phase = .idle
            }
        }
    }

    private func handleClear(sessionId: String) {
        guard store.contains(sessionId) else { return }
        store.mutate(sessionId) { session in
            session.messages = []
            session.lastParsedOffset = 0
            session.phase = session.phase.transition(to: .idle)
        }
    }

    // MARK: - Helpers

    private func applyContext(to session: inout AISessionState, event: HookEvent) {
        if let cwd = event.cwd { session.cwd = cwd }
        if let msg = event.message, !msg.isEmpty { session.lastMessage = msg }
        session.lastEventName = event.hookEventName
    }

    // MARK: - Conversation Parsing

    private func parseConversation(for sessionId: String) {
        guard let session = store.get(sessionId),
              let cwd = session.cwd,
              let filePath = GeminiConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd) else { return }

        let offset = session.lastParsedOffset
        Task {
            if filePath.hasSuffix(".jsonl") {
                let result = GeminiConversationParser.parseIncrementalJSONL(filePath: filePath, fromOffset: offset)
                guard self.store.contains(sessionId) else { return }
                self.store.mutate(sessionId) { session in
                    if result.cleared { session.messages = [] }
                    for msg in result.common.messages {
                        session.upsertMessage(msg)
                    }
                    session.lastParsedOffset = result.newOffset
                    session.inputTokens += result.common.inputTokens
                    session.outputTokens += result.common.outputTokens
                    session.thoughtTokens += result.thoughtTokens
                    session.cacheReadTokens += result.cachedTokens
                    session.lastContextTokens = result.lastContextTokens
                    if let model = result.common.lastModel { session.model = model }

                    let userMessages = result.common.messages.filter { $0.role == .user }
                    if let first = userMessages.first, session.firstUserMessage == nil {
                        session.firstUserMessage = String(first.content.prefix(80))
                    }
                    if let last = userMessages.last {
                        session.lastUserMessage = String(last.content.prefix(80))
                    }
                }
            } else {
                // Legacy .json - always parse full
                guard let result = GeminiConversationParser.parseDetailed(filePath: filePath) else { return }
                guard self.store.contains(sessionId) else { return }
                self.store.mutate(sessionId) { session in
                    session.messages = result.common.messages
                    session.inputTokens = result.common.inputTokens
                    session.outputTokens = result.common.outputTokens
                    session.thoughtTokens = result.thoughtTokens
                    session.cacheReadTokens = result.cachedTokens
                    session.lastContextTokens = result.lastContextTokens
                    if let model = result.common.lastModel { session.model = model }
                }
            }
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

        for session in store.sessions(for: .gemini) where session.lastEventTime < demoteCutoff {
            if case .waitingForInput = session.phase {
                store.mutate(session.id) { s in
                    s.phase = s.phase.transition(to: .idle)
                }
                LogService.info(
                    "Demoted silent session \(session.id.prefix(8)) to idle (\(Int(now.timeIntervalSince(session.lastEventTime)))s silent)",
                    category: "GeminiProvider"
                )
            }
        }

        for session in store.sessions(for: .gemini) where session.lastEventTime < removeCutoff {
            watcherManager.stopWatching(sessionId: session.id)
            agentWatcherManager.stopAll(sessionId: session.id)
            sessionFiles.removeValue(forKey: session.id)
            store.remove(session.id)
            LogService.info("Removed stale session \(session.id.prefix(8))", category: "GeminiProvider")
        }

        if store.sessions(for: .gemini).isEmpty {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
    }
}

// MARK: - GeminiWatcher

final class GeminiWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private let filePath: String
    private let sessionId: String
    private let queue = DispatchQueue(label: "com.nemonotch.geminiwatcher", qos: .utility)

    var onChanged: ((String) -> Void)?
    var onClear: ((String) -> Void)?

    init(sessionId: String, filePath: String) {
        self.sessionId = sessionId
        self.filePath = filePath
    }

    func start() {
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return }
        fileHandle = handle

        let fd = handle.fileDescriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )
        source?.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChanged?(self.sessionId) }
        }
        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }
}

final class GeminiWatcherManager {
    private var watchers: [String: GeminiWatcher] = [:]
    var onChanged: ((String) -> Void)?
    var onClear: ((String) -> Void)?

    func startWatching(sessionId: String, cwd: String) {
        guard let filePath = GeminiConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd) else { return }
        guard watchers[sessionId] == nil else { return }
        let watcher = GeminiWatcher(sessionId: sessionId, filePath: filePath)
        watcher.onChanged = { [weak self] sessionId in self?.onChanged?(sessionId) }
        watcher.onClear = { [weak self] sessionId in self?.onClear?(sessionId) }
        watchers[sessionId] = watcher
        watcher.start()
    }

    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
    }

    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        watchers.removeAll()
    }
}
