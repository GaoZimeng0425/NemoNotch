import Foundation

@Observable
final class OpenClawService {
    var agents: [String: AgentInfo] = [:]
    var activeAgent: AgentInfo?
    var gatewayOnline = false
    var isInstalled = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var ttlTimer: Timer?
    private let gatewayURL: URL
    private let token: String?

    init() {
        let configPath = NSString(string: "~/.openclaw/openclaw.json").expandingTildeInPath

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.gatewayURL = URL(string: "ws://127.0.0.1:18789/gateway-ws")!
            self.token = nil
            self.isInstalled = false
            return
        }

        let gateway = json["gateway"] as? [String: Any]
        let auth = gateway?["auth"] as? [String: Any]
        let rawToken = auth?["token"] as? String
        let port = gateway?["port"] as? Int ?? 18789

        self.token = Self.resolveEnvVar(rawToken)
        self.gatewayURL = URL(string: "ws://127.0.0.1:\(port)/gateway-ws")!
        self.isInstalled = true
    }

    // MARK: - Env Var Resolution

    private static func resolveEnvVar(_ value: String?) -> String? {
        guard let value, value.hasPrefix("${"), value.hasSuffix("}") else { return value }
        let varName = String(value.dropFirst(2).dropLast(1))
        return loadEnvFile()[varName] ?? ProcessInfo.processInfo.environment[varName]
    }

    private static func loadEnvFile() -> [String: String] {
        let envPath = NSString(string: "~/.openclaw/.env").expandingTildeInPath
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = String(parts[1])
        }
        return result
    }

    // MARK: - Connection

    func connect() {
        guard isInstalled else { return }
        disconnect()

        let session = URLSession(configuration: .default)
        urlSession = session
        webSocketTask = session.webSocketTask(with: gatewayURL)
        webSocketTask?.resume()

        receiveMessage()
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

        let type = json["type"] as? String ?? ""

        switch type {
        case "event":
            handleEvent(json)
        case "res":
            handleResponse(json)
        default:
            break
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        let event = json["event"] as? String ?? ""

        switch event {
        case "connect.challenge":
            handleChallenge(json)
        case "agent":
            handleAgentEvent(json)
        case "health":
            gatewayOnline = true
        case "heartbeat":
            gatewayOnline = true
        default:
            break
        }
    }

    // MARK: - Challenge-Response Auth

    private func handleChallenge(_ json: [String: Any]) {
        guard let payload = json["payload"] as? [String: Any],
              let nonce = payload["nonce"] as? String else { return }

        let requestId = UUID().uuidString.lowercased()
        let connectFrame: [String: Any] = [
            "type": "req",
            "id": requestId,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "role": "observer",
                "client": [
                    "id": "nemonotch",
                    "version": "1.0.0",
                    "platform": "macos",
                    "mode": "ui"
                ],
                "scopes": ["operator.read"],
                "auth": ["token": token ?? ""]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: connectFrame),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error {
                print("[OpenClaw] Auth send error: \(error)")
            }
        }
    }

    private func handleResponse(_ json: [String: Any]) {
        let method = json["method"] as? String ?? ""
        if method == "connect" {
            let hasError = json["error"] != nil
            if hasError {
                print("[OpenClaw] Auth failed: \(json["error"] ?? "unknown")")
                scheduleReconnect()
            } else {
                gatewayOnline = true
                startTTLTimer()
            }
        }
    }

    // MARK: - Agent Events

    private func handleAgentEvent(_ json: [String: Any]) {
        let payload = json["payload"] as? [String: Any] ?? json
        guard let agentId = payload["agentId"] as? String ?? payload["id"] as? String else { return }
        let rawState = payload["state"] as? String ?? payload["status"] as? String ?? "idle"
        let state = AgentState.normalize(rawState)

        let name = payload["name"] as? String ?? payload["agentName"] as? String ?? "Agent \(agentId.prefix(4))"
        let tool = payload["tool"] as? String ?? payload["toolName"] as? String
        let message = payload["message"] as? String ?? payload["detail"] as? String
        let workspace = payload["workspace"] as? String ?? payload["cwd"] as? String

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
