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
    private var pollTimer: Timer?

    init() {
        hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        isInstalled = FileManager.default.fileExists(atPath: hermesDir)
        isHookInstalled = HermesHookInstaller.isInstalled
        isOnline = isHookInstalled
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
        isOnline = false
        LogService.info("Disconnected from Hermes monitoring", category: "HermesService")
    }

    // MARK: - Session File Polling

    private func refreshSessions() {
        let files = HermesConversationParser.findAllSessionFiles()

        var currentSessionIds: Set<String> = []
        for file in files {
            currentSessionIds.insert(file.sessionId)

            guard let count = HermesConversationParser.readMessageCount(filePath: file.path) else { continue }
            let lastCount = lastMessageCounts[file.sessionId] ?? 0

            if count > lastCount {
                let parsed = HermesConversationParser.parseFull(filePath: file.path)
                let recent = Array(parsed.messages.suffix(20))
                sessionMessages[file.sessionId] = recent
                lastMessageCounts[file.sessionId] = count

                // Update lastMessage on the agent if it exists
                if let lastMsg = recent.last?.content {
                    updateAgentLastMessage(sessionId: file.sessionId, message: lastMsg)
                }

                if !recent.isEmpty {
                    LogService.debug(
                        "Parsed \(recent.count) messages for session \(file.sessionId)",
                        category: "HermesService"
                    )
                }
            }
        }

        // Clean up disappeared sessions
        let stale = lastMessageCounts.keys.filter { !currentSessionIds.contains($0) }
        for id in stale {
            lastMessageCounts.removeValue(forKey: id)
            sessionMessages.removeValue(forKey: id)
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
            isOnline = true
            LogService.info("Hermes hooks installed", category: "HermesService")
        } catch {
            LogService.error("Failed to install Hermes hooks: \(error)", category: "HermesService")
        }
    }

    func uninstallHooks() {
        do {
            try HermesHookInstaller.uninstall()
            isHookInstalled = false
            isOnline = false
            agents = [:]
            activeAgent = nil
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
