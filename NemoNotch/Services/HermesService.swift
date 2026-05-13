import Foundation

@MainActor
@Observable
final class HermesService: MultiAgentMonitor {
    var agents: [String: MonitoredAgent] = [:]
    var activeAgent: MonitoredAgent?
    var isOnline = false
    var isInstalled = false
    var isHookInstalled = false
    let displayName = "Hermes"
    let iconEmoji = ""

    private let hermesDir: String

    /// sessionId → recently parsed messages (max 20)
    var sessionMessages: [String: [ChatMessage]] = [:]
    private var lastMessageCounts: [String: Int] = [:]
    private var lastModDates: [String: Date] = [:]

    /// FSEvent stream for directory monitoring
    private var eventStream: FSEventStreamRef?
    /// Rescan timer for profile discovery (rare)
    private var rescanTimer: Timer?

    init() {
        hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        isInstalled = FileManager.default.fileExists(atPath: hermesDir)
        isHookInstalled = HermesHookInstaller.isInstalled
        isOnline = isInstalled
        LogService.info(
            "HermesService initialized, installed=\(isInstalled), hooks=\(isHookInstalled)",
            category: "HermesService"
        )
    }

    func connect() {
        guard isInstalled else { return }
        LogService.info("Starting Hermes monitoring (FSEvents)", category: "HermesService")
        startWatching()
        refreshSessions()
    }

    func disconnect() {
        stopWatching()
        sessionMessages = [:]
        lastMessageCounts = [:]
        lastModDates = [:]
        isOnline = false
        LogService.info("Disconnected from Hermes monitoring", category: "HermesService")
    }

    // MARK: - FSEvents Directory Watching

    private func startWatching() {
        stopWatching()

        let directoriesToWatch = sessionDirectories()
        guard !directoriesToWatch.isEmpty else { return }

        let paths = directoriesToWatch as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, eventInfo, numEvents, eventPaths, _, _ in
                guard let info = eventInfo else { return }
                let service = Unmanaged<HermesService>.fromOpaque(info).takeUnretainedValue()
                // Must extract paths synchronously — pointer is invalid after callback returns
                let nsArray = unsafeBitCast(eventPaths, to: NSArray.self)
                let pathStrings = (0 ..< Int(numEvents)).compactMap { nsArray.object(at: $0) as? String }
                Task { @MainActor in
                    service.onFileEvents(paths: pathStrings)
                }
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            LogService.error("Failed to create FSEventStream", category: "HermesService")
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        eventStream = stream

        // Periodically rescan for new profile directories
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.restartWatchingIfDirectoriesChanged()
            }
        }

        LogService.info("FSEventStream started for \(directoriesToWatch.count) directories", category: "HermesService")
    }

    private func stopWatching() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    /// All session directories to watch: default + each named profile.
    private func sessionDirectories() -> [String] {
        let fm = FileManager.default
        var dirs = [hermesDir + "/sessions"]

        let profilesDir = hermesDir + "/profiles"
        if let profiles = try? fm.contentsOfDirectory(atPath: profilesDir) {
            for name in profiles {
                let dir = "\(profilesDir)/\(name)/sessions"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(dir)
                }
            }
        }
        return dirs
    }

    private func restartWatchingIfDirectoriesChanged() {
        let current = Set(sessionDirectories())
        let watched = Set(eventStream.map { _ in sessionDirectories() } ?? [])
        if current != watched {
            LogService.info("Session directories changed, restarting FSEventStream", category: "HermesService")
            startWatching()
            refreshSessions()
        }
        evictStaleAgents()
    }

    /// Remove agents whose session file hasn't been modified recently.
    private func evictStaleAgents() {
        let threshold: TimeInterval = 15
        let now = Date()
        var evicted = 0
        for (id, agent) in agents {
            guard now.timeIntervalSince(agent.lastEventTime) > threshold else { continue }
            agents.removeValue(forKey: id)
            sessionMessages.removeValue(forKey: id)
            lastMessageCounts.removeValue(forKey: id)
            lastModDates.removeValue(forKey: id)
            evicted += 1
        }
        if evicted > 0 {
            updateActiveAgent()
            LogService.info("Evicted \(evicted) stale agent(s)", category: "HermesService")
        }
    }

    /// Callback from FSEventStream — filter and parse changed session files.
    private func onFileEvents(paths: [String]) {
        var changedFiles: [(path: String, sessionId: String)] = []

        for path in paths {
            guard path.hasSuffix(".json"), path.contains("session_") else { continue }
            let filename = (path as NSString).lastPathComponent
            guard filename.hasPrefix("session_") else { continue }
            let sessionId = String(filename.dropFirst("session_".count).dropLast(".json".count))
            changedFiles.append((path, sessionId))
        }

        guard !changedFiles.isEmpty else { return }
        parseChangedFiles(changedFiles)
    }

    // MARK: - Session File Parsing

    /// Full scan — called on connect and when directories change.
    private func refreshSessions() {
        Task.detached { [weak self] in
            let files = HermesConversationParser.findAllSessionFiles()
            let now = Date()
            let activeThreshold: TimeInterval = 600
            var updates: [(sessionId: String, messages: [ChatMessage], count: Int, isActive: Bool)] = []
            var currentSessionIds: Set<String> = []

            for file in files {
                currentSessionIds.insert(file.sessionId)

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let isActive = now.timeIntervalSince(modDate) < activeThreshold
                let lastCount = await self?.lastMessageCounts[file.sessionId] ?? 0

                if lastCount > 0 {
                    guard let lastMod = await self?.lastModDates[file.sessionId], modDate > lastMod else {
                        if isActive {
                            await MainActor.run { [weak self] in
                                self?.ensureAgentExists(sessionId: file.sessionId)
                            }
                        }
                        continue
                    }
                }

                guard let count = HermesConversationParser.readMessageCount(filePath: file.path),
                      count > lastCount else { continue }

                let parsed = HermesConversationParser.parseFull(filePath: file.path)
                let recent = Array(parsed.messages.suffix(20))
                updates.append((file.sessionId, recent, count, isActive))
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                for update in updates {
                    sessionMessages[update.sessionId] = update.messages
                    lastMessageCounts[update.sessionId] = update.count
                    if update.isActive {
                        ensureAgentExists(sessionId: update.sessionId)
                    }
                    if let lastMsg = update.messages.last?.content {
                        updateAgentLastMessage(sessionId: update.sessionId, message: lastMsg)
                    }
                    if !update.messages.isEmpty {
                        LogService.debug(
                            "Parsed \(update.messages.count) messages for session \(update.sessionId)",
                            category: "HermesService"
                        )
                    }
                }

                let stale = lastMessageCounts.keys.filter { !currentSessionIds.contains($0) }
                for id in stale {
                    lastMessageCounts.removeValue(forKey: id)
                    lastModDates.removeValue(forKey: id)
                    sessionMessages.removeValue(forKey: id)
                }
            }
        }
    }

    /// Incremental parse — called when FSEvents reports changed files.
    private func parseChangedFiles(_ files: [(path: String, sessionId: String)]) {
        Task.detached { [weak self] in
            let now = Date()
            let activeThreshold: TimeInterval = 600
            var updates: [(sessionId: String, messages: [ChatMessage], count: Int, isActive: Bool)] = []

            for file in files {
                let lastCount = await self?.lastMessageCounts[file.sessionId] ?? 0

                guard let count = HermesConversationParser.readMessageCount(filePath: file.path),
                      count > lastCount else { continue }

                let parsed = HermesConversationParser.parseFull(filePath: file.path)
                let recent = Array(parsed.messages.suffix(20))

                let isActive: Bool = if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                                        let modDate = attrs[.modificationDate] as? Date {
                    now.timeIntervalSince(modDate) < activeThreshold
                } else {
                    true
                }

                updates.append((file.sessionId, recent, count, isActive))
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                for update in updates {
                    sessionMessages[update.sessionId] = update.messages
                    lastMessageCounts[update.sessionId] = update.count
                    if update.isActive {
                        ensureAgentExists(sessionId: update.sessionId)
                    }
                    if let lastMsg = update.messages.last?.content {
                        updateAgentLastMessage(sessionId: update.sessionId, message: lastMsg)
                    }
                    LogService.debug(
                        "FSEvent: parsed \(update.messages.count) messages for session \(update.sessionId)",
                        category: "HermesService"
                    )
                }
            }
        }
    }

    private func ensureAgentExists(sessionId: String) {
        if var agent = agents[sessionId] {
            agent.lastEventTime = Date()
            agents[sessionId] = agent
        } else {
            upsertAgent(id: sessionId, state: .working)
        }
    }

    private func updateAgentLastMessage(sessionId: String, message: String) {
        guard var agent = agents[sessionId] else { return }
        agent.lastMessage = String(message.prefix(100))
        agents[sessionId] = agent
    }

    // MARK: - Hook Install / Uninstall

    func installHooks() {
        do {
            try HermesHookInstaller.install()
            isHookInstalled = true
            LogService.info("Hermes hooks installed", category: "HermesService")
        } catch {
            LogService.error("Failed to install Hermes hooks: \(error)", category: "HermesService")
        }
    }

    func uninstallHooks() {
        do {
            try HermesHookInstaller.uninstall()
            isHookInstalled = false
            LogService.info("Hermes hooks uninstalled", category: "HermesService")
        } catch {
            LogService.error("Failed to uninstall Hermes hooks: \(error)", category: "HermesService")
        }
    }

    // MARK: - Hook Event Handling

    func handleHookEvent(_ event: HookEvent) {
        guard let sessionID = event.sessionId, !sessionID.isEmpty else { return }

        let eventName = event.hookEventName
        LogService.debug("Hermes hook: \(eventName) session=\(sessionID)", category: "HermesService")

        switch eventName {
        case "on_session_start":
            let model = event.source ?? ""
            let workspace = event.cwd
            upsertAgent(
                id: sessionID,
                model: model,
                workspace: workspace,
                state: .working
            )

        case "pre_llm_call":
            upsertAgent(id: sessionID, state: .speaking)

        case "pre_tool_call":
            upsertAgent(
                id: sessionID,
                state: .toolCalling,
                currentTool: event.toolName
            )

        case "post_tool_call":
            upsertAgent(id: sessionID, state: .working)

        case "post_llm_call":
            removeAgent(id: sessionID)

        case "on_session_end":
            removeAgent(id: sessionID)

        default:
            break
        }
    }

    // MARK: - Agent State Management

    private func upsertAgent(
        id: String,
        model: String? = nil,
        workspace: String? = nil,
        state: AgentMonitorState,
        currentTool: String? = nil
    ) {
        var agent = agents[id] ?? MonitoredAgent(
            id: id,
            name: "Hermes",
            emoji: "",
            state: state,
            currentTool: currentTool,
            lastEventTime: Date()
        )
        if let model, !model.isEmpty, agent.name == "Hermes" {
            agent.name = "Hermes (\(model))"
        }
        agent.state = state
        if let currentTool { agent.currentTool = currentTool }
        if let workspace { agent.workspace = workspace }
        agent.lastEventTime = Date()
        agents[id] = agent
        updateActiveAgent()
    }

    private func removeAgent(id: String) {
        agents.removeValue(forKey: id)
        updateActiveAgent()
    }

    private func updateActiveAgent() {
        activeAgent = agents.values
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
            .first
    }
}
