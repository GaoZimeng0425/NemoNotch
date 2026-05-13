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
    let iconEmoji = "🐦"

    private let hermesDir: String

    /// sessionId → recently parsed messages (max 20)
    var sessionMessages: [String: [ChatMessage]] = [:]
    private var lastMessageCounts: [String: Int] = [:]
    private var lastModDates: [String: Date] = [:]
    private var pollTimer: Timer?

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
        LogService.info("Starting Hermes monitoring (hook + session polling)", category: "HermesService")
        refreshSessions()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSessions()
            }
        }
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionMessages = [:]
        lastMessageCounts = [:]
        lastModDates = [:]
        isOnline = false
        LogService.info("Disconnected from Hermes monitoring", category: "HermesService")
    }

    // MARK: - Session File Polling

    private func refreshSessions() {
        Task.detached { [weak self] in
            let files = HermesConversationParser.findAllSessionFiles()
            let now = Date()
            let activeThreshold: TimeInterval = 600 // 10 minutes
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
                        // File unchanged but still active — keep existing data
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

    /// Ensure a MonitoredAgent exists for a session discovered via file polling.
    private func ensureAgentExists(sessionId: String) {
        if agents[sessionId] == nil {
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
            emoji: "🐦",
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
