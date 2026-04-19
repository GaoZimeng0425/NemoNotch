import Foundation

@Observable
final class OpenClawService {
    var agents: [String: AgentInfo] = [:]
    var activeAgent: AgentInfo?
    var gatewayOnline = false
    var isInstalled = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTimer: Timer?
    private var ttlTimer: Timer?
    private let gatewayURL: URL
    private let token: String?

    init() {
        let expanded = NSString(string: "~/.openclaw/openclaw.json").expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let gateway = json["gateway"] as? [String: Any]
            let auth = gateway?["auth"] as? [String: Any]
            self.token = auth?["token"] as? String
            let port = gateway?["port"] as? Int ?? 18789
            self.gatewayURL = URL(string: "ws://localhost:\(port)/gateway-ws")!
            self.isInstalled = true
        } else {
            self.gatewayURL = URL(string: "ws://localhost:18789/gateway-ws")!
            self.token = nil
            self.isInstalled = false
        }
    }

    func connect() {
        guard isInstalled else { return }
        disconnect()

        var request = URLRequest(url: gatewayURL)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        receiveMessage()
        gatewayOnline = true
        startTTLTimer()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        gatewayOnline = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        ttlTimer?.invalidate()
        ttlTimer = nil
    }

    // MARK: - WebSocket Messages

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()
            case .failure(let error):
                print("[OpenClaw] WebSocket error: \(error)")
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else { return }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? json["event"] as? String ?? ""

        switch type {
        case "agent":
            handleAgentEvent(json)
        case "health":
            gatewayOnline = true
        case "heartbeat":
            gatewayOnline = true
        case "presence":
            break
        default:
            break
        }
    }

    private func handleAgentEvent(_ json: [String: Any]) {
        guard let agentId = json["agentId"] as? String ?? json["id"] as? String else { return }
        let rawState = json["state"] as? String ?? json["status"] as? String ?? "idle"
        let state = AgentState.normalize(rawState)

        let name = json["name"] as? String ?? json["agentName"] as? String ?? "Agent \(agentId.prefix(4))"
        let tool = json["tool"] as? String ?? json["toolName"] as? String
        let message = json["message"] as? String ?? json["detail"] as? String
        let workspace = json["workspace"] as? String ?? json["cwd"] as? String

        if agents[agentId] == nil {
            agents[agentId] = AgentInfo(id: agentId, name: name, state: state)
        }

        agents[agentId]?.state = state
        agents[agentId]?.name = name
        if let tool { agents[agentId]?.currentTool = tool }
        if let message { agents[agentId]?.lastMessage = message }
        if let workspace { agents[agentId]?.workspace = workspace }
        agents[agentId]?.lastEventTime = Date()

        updateActiveAgent()
    }

    private func updateActiveAgent() {
        activeAgent = agents.values
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
            .first
    }

    // MARK: - TTL

    private func startTTLTimer() {
        ttlTimer?.invalidate()
        ttlTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupStaleAgents()
        }
    }

    private func cleanupStaleAgents() {
        let idleThreshold = Date().addingTimeInterval(-300)
        for (id, agent) in agents {
            if agent.lastEventTime < idleThreshold, agent.state != .idle {
                agents[id]?.state = .idle
                agents[id]?.currentTool = nil
            }
        }
        let removeThreshold = Date().addingTimeInterval(-1800)
        agents = agents.filter { $0.value.lastEventTime >= removeThreshold }
        updateActiveAgent()
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        gatewayOnline = false
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }
}
