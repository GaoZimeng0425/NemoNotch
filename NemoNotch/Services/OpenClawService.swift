import CryptoKit
import Foundation

@MainActor
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
    private var pendingConnectId: String?
    private var agentProfiles: [String: (name: String, emoji: String)] = [:]

    // Ed25519 device identity
    private let signingKey: Curve25519.Signing.PrivateKey
    private let deviceId: String

    init() {
        let configPath = NSString(string: "~/.openclaw/openclaw.json").expandingTildeInPath

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.gatewayURL = URL(string: "ws://127.0.0.1:18789/gateway-ws")!
            self.token = nil
            self.isInstalled = false
            // dummy values for init
            self.signingKey = Curve25519.Signing.PrivateKey()
            self.deviceId = ""
            return
        }

        let gateway = json["gateway"] as? [String: Any]
        let auth = gateway?["auth"] as? [String: Any]
        let rawToken = auth?["token"] as? String
        let port = gateway?["port"] as? Int ?? 18789

        self.token = Self.resolveEnvVar(rawToken)
        self.gatewayURL = URL(string: "ws://127.0.0.1:\(port)/gateway-ws")!
        self.isInstalled = true

        // Load or generate device identity
        let (key, id) = Self.loadOrCreateDeviceIdentity()
        self.signingKey = key
        self.deviceId = id

        // Load agent profiles from config + IDENTITY.md
        if let agentsConfig = json["agents"] as? [String: Any],
           let list = agentsConfig["list"] as? [[String: Any]] {
            for agent in list {
                let agentId = agent["id"] as? String ?? ""
                let displayName = agent["name"] as? String ?? agentId
                let workspace = agent["workspace"] as? String ?? ""
                let emoji = Self.parseEmojiFromIdentity(workspace: workspace)
                agentProfiles[agentId] = (name: displayName, emoji: emoji)
            }
        }

        LogService.info("Installed: port=\(port), hasToken=\(token != nil), deviceId=\(id.prefix(8))...", category: "OpenClaw")
    }

    // MARK: - Device Identity

    private static func loadOrCreateDeviceIdentity() -> (Curve25519.Signing.PrivateKey, String) {
        let keychainKey = "ai.openclaw.nemonotch.device-key"

        // Try to load existing key from Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let keyData = result as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            let pubKeyData = key.publicKey.rawRepresentation
            let fingerprint = SHA256.hash(data: pubKeyData)
            let deviceId = fingerprint.compactMap { String(format: "%02x", $0) }.joined()
            return (key, deviceId)
        }

        // Generate new key
        let key = Curve25519.Signing.PrivateKey()
        let pubKeyData = key.publicKey.rawRepresentation
        let fingerprint = SHA256.hash(data: pubKeyData)
        let deviceId = fingerprint.compactMap { String(format: "%02x", $0) }.joined()

        // Save to Keychain
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: key.rawRepresentation,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)

        return (key, deviceId)
    }

    private static func parseEmojiFromIdentity(workspace: String) -> String {
        let identityPath = (workspace as NSString).appendingPathComponent("IDENTITY.md")
        guard let content = try? String(contentsOfFile: identityPath, encoding: .utf8) else { return "🦞" }
        for line in content.components(separatedBy: "\n") {
            guard line.localizedCaseInsensitiveContains("emoji") else { continue }
            // "- **Emoji:** 🔥" → strip markdown and label, extract emoji
            let cleaned = line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "Emoji:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Find first emoji character (Unicode scalar with emoji property)
            for scalar in cleaned.unicodeScalars {
                if scalar.properties.isEmoji && !scalar.properties.isEmojiPresentation {
                    continue // skip emoji modifiers
                }
                if scalar.properties.isEmojiPresentation || scalar.properties.isEmoji {
                    return String(scalar)
                }
            }
            // Fallback: first non-whitespace, non-punctuation, non-letter/digit
            if let ch = cleaned.first(where: { !$0.isWhitespace && !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "*" }) {
                return String(ch)
            }
        }
        return "🦞"
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
        guard isInstalled else {
            LogService.warn("Not installed, skipping connect", category: "OpenClaw")
            return
        }
        disconnect()

        let port = gatewayURL.port ?? 18789
        Task.detached { [weak self] in
            guard Self.checkPort(host: "127.0.0.1", port: port) else {
                await self?.scheduleReconnect()
                return
            }
            await self?.openWebSocket()
        }
    }

    private func openWebSocket() {
        LogService.info("Connecting to \(gatewayURL)...", category: "OpenClaw")
        let session = URLSession(configuration: .default)
        urlSession = session

        var request = URLRequest(url: gatewayURL)
        request.setValue("http://127.0.0.1:\(gatewayURL.port ?? 18789)", forHTTPHeaderField: "Origin")
        webSocketTask = session.webSocketTask(with: request)
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

    private nonisolated static func checkPort(host: String, port: Int) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST

        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &res) == 0, let addr = res else { return false }
        defer { freeaddrinfo(res) }

        let sock = Darwin.socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let rc = Darwin.connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 1000) > 0 else { return false }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    // MARK: - WebSocket Messages

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveMessage()
                case .failure(let error):
                    if (error as? URLError)?.code == .cannotConnectToHost {
                        LogService.debug("WebSocket not reachable: \(error)", category: "OpenClaw")
                    } else {
                        LogService.error("WebSocket error: \(error)", category: "OpenClaw")
                    }
                    self.scheduleReconnect()
                }
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
        if event != "agent" && event != "heartbeat" && event != "tick" && event != "chat" {
            LogService.debug("Event: \(event)", category: "OpenClaw")
        }

        switch event {
        case "connect.challenge":
            handleChallenge(json)
        case "agent":
            handleAgentEvent(json)
        case "chat":
            handleChatEvent(json)
        case "health":
            gatewayOnline = true
        case "heartbeat", "tick":
            gatewayOnline = true
        default:
            LogService.warn("Unknown event: \(event), keys: \(json.keys)", category: "OpenClaw")
        }
    }

    // MARK: - Challenge-Response Auth

    private func handleChallenge(_ json: [String: Any]) {
        guard let payload = json["payload"] as? [String: Any],
              let nonce = payload["nonce"] as? String else { return }

        LogService.debug("Challenge received, nonce=\(nonce)", category: "OpenClaw")
        let requestId = UUID().uuidString.lowercased()
        pendingConnectId = requestId

        let signedAt = Int(Date().timeIntervalSince1970 * 1000)
        let clientId = "openclaw-control-ui"
        let clientMode = "ui"
        let role = "operator"
        let scopes = "operator.admin,operator.read"

        // Sign: v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce
        let signPayload = "v2|\(deviceId)|\(clientId)|\(clientMode)|\(role)|\(scopes)|\(signedAt)|\(token ?? "")|\(nonce)"
        guard let signData = signPayload.data(using: .utf8) else { return }
        let signature = try? signingKey.signature(for: signData)

        let pubKeyBase64 = signingKey.publicKey.rawRepresentation.base64EncodedString()
        let sigBase64 = signature?.base64EncodedString() ?? ""

        let connectFrame: [String: Any] = [
            "type": "req",
            "id": requestId,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "role": role,
                "client": [
                    "id": clientId,
                    "version": "0.1.0",
                    "platform": "macos",
                    "mode": clientMode
                ],
                "caps": ["tool-events"],
                "scopes": ["operator.admin", "operator.read"],
                "auth": ["token": token ?? ""],
                "device": [
                    "id": deviceId,
                    "publicKey": pubKeyBase64,
                    "signature": sigBase64,
                    "signedAt": signedAt,
                    "nonce": nonce
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: connectFrame),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error {
                LogService.error("Auth send error: \(error)", category: "OpenClaw")
            } else {
                LogService.info("Auth sent with device identity, waiting for response...", category: "OpenClaw")
            }
        }
    }

    private func handleResponse(_ json: [String: Any]) {
        let id = json["id"] as? String ?? ""
        let ok = json["ok"] as? Bool ?? false
        LogService.debug("Response: id=\(id), ok=\(ok)", category: "OpenClaw")

        if id == pendingConnectId {
            pendingConnectId = nil
            if ok {
                LogService.info("Auth successful!", category: "OpenClaw")
                gatewayOnline = true
                startTTLTimer()
                // Parse initial snapshot from hello-ok result
                if let result = json["result"] as? [String: Any] {
                    LogService.debug("Snapshot keys: \(result.keys)", category: "OpenClaw")
                    if let agents = result["agents"] as? [[String: Any]] {
                        LogService.info("Initial agents: \(agents.count)", category: "OpenClaw")
                        for a in agents { handleAgentEvent(["payload": a]) }
                    }
                    if let sessions = result["sessions"] as? [[String: Any]] {
                        LogService.info("Initial sessions: \(sessions.count)", category: "OpenClaw")
                        for s in sessions { handleAgentEvent(["payload": s]) }
                    }
                }
            } else {
                LogService.error("Auth failed: \(json["error"] ?? "unknown")", category: "OpenClaw")
                scheduleReconnect()
            }
        }
    }

    // MARK: - Chat Events

    private func handleChatEvent(_ json: [String: Any]) {
        let payload = json["payload"] as? [String: Any] ?? [:]

        // Find the agent by sessionKey or sender
        let sessionKey = payload["sessionKey"] as? String ?? ""
        let role = payload["role"] as? String ?? ""

        // Detect tool use from content blocks
        if let parts = payload["content"] as? [[String: Any]] {
            let toolNames = parts.compactMap { block -> String? in
                let type = block["type"] as? String ?? ""
                if type == "tool_use" || type == "tool_call" {
                    return block["name"] as? String ?? "tool"
                }
                return nil
            }
            if !toolNames.isEmpty {
                let key = sessionKey.isEmpty ? nil : sessionKey
                let targetKey = key ?? agents.filter({ $0.value.state != .idle })
                    .sorted(by: { $0.value.lastEventTime > $1.value.lastEventTime }).first?.key
                if let targetKey, agents[targetKey] != nil {
                    agents[targetKey]?.state = .toolCalling
                    agents[targetKey]?.currentTool = toolNames.first
                    agents[targetKey]?.lastEventTime = Date()
                    updateActiveAgent()
                }
                return
            }
        }

        // Also check top-level tool fields
        if let toolName = payload["tool"] as? String ?? payload["toolName"] as? String ?? payload["name"] as? String {
            let roleLC = role.lowercased()
            if roleLC.contains("tool") || roleLC.contains("assistant") {
                let key = sessionKey.isEmpty ? nil : sessionKey
                let targetKey = key ?? agents.filter({ $0.value.state != .idle })
                    .sorted(by: { $0.value.lastEventTime > $1.value.lastEventTime }).first?.key
                if let targetKey, agents[targetKey] != nil {
                    agents[targetKey]?.state = .toolCalling
                    agents[targetKey]?.currentTool = toolName
                    agents[targetKey]?.lastEventTime = Date()
                    updateActiveAgent()
                }
                return
            }
        }

        // Extract text content
        let text: String?
        if let content = payload["content"] as? String {
            text = content
        } else if let parts = payload["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        } else if let delta = payload["delta"] as? String {
            text = delta
        } else {
            text = payload["text"] as? String
        }

        guard let message = text, !message.isEmpty else { return }

        // Update the matching agent's last message
        let targetKey = sessionKey.isEmpty ? nil : sessionKey
        if let key = targetKey, agents[key] != nil {
            agents[key]?.lastMessage = String(message.prefix(120))
            agents[key]?.lastEventTime = Date()
        } else {
            // Try to match by updating the most recent active agent
            if let activeKey = agents.filter({ $0.value.state != .idle })
                .sorted(by: { $0.value.lastEventTime > $1.value.lastEventTime }).first?.key {
                agents[activeKey]?.lastMessage = String(message.prefix(120))
                agents[activeKey]?.lastEventTime = Date()
            }
        }
    }

    // MARK: - Agent Events

    private func handleAgentEvent(_ json: [String: Any]) {
        let payload = json["payload"] as? [String: Any] ?? json

        let stream = payload["stream"] as? String ?? ""
        let data = payload["data"] as? [String: Any] ?? [:]
        let phase = data["phase"] as? String ?? ""

        // sessionKey format: "agent:<name>:<session>"
        guard let sessionKey = payload["sessionKey"] as? String else { return }
        let parts = sessionKey.split(separator: ":", maxSplits: 2)
        guard parts.count >= 2 else { return }
        let agentKey = String(parts[1])
        let agentId = sessionKey

        // Look up profile (emoji, display name)
        let profile = agentProfiles[agentKey]
        let displayName = profile?.name ?? agentKey
        let emoji = profile?.emoji ?? "🦞"

        // Determine state from stream + phase (already extracted above for logging)
        let kind = data["kind"] as? String ?? ""
        let state: AgentState
        if stream == "item" && kind == "tool" {
            // Tool call item events: stream=item, kind=tool, phase=start|end
            switch phase {
            case "start": state = .toolCalling
            case "end":
                // Tool completed — keep speaking if assistant is still streaming,
                // otherwise stay working (lifecycle will set idle when run ends)
                state = agents[agentId]?.state == .speaking ? .speaking : .working
            default: state = .toolCalling
            }
        } else if stream == "lifecycle" {
            switch phase {
            case "start": state = .working
            case "end", "stop", "done": state = .idle
            case "error": state = .error
            default: state = .working
            }
        } else if stream == "assistant" {
            state = .speaking
        } else {
            switch phase {
            case "tool_call", "tool_use": state = .toolCalling
            case "speaking", "chat": state = .speaking
            case "error": state = .error
            default:
                if stream == "tool" { state = .toolCalling }
                else if stream == "chat" || stream == "message" { state = .speaking }
                else { state = .working }
            }
        }

        let tool = data["name"] as? String ?? data["tool"] as? String ?? data["toolName"] as? String
        let message = data["title"] as? String ?? data["message"] as? String ?? data["detail"] as? String ?? data["text"] as? String
        let workspace = data["workspace"] as? String ?? data["cwd"] as? String

        if agents[agentId] == nil {
            agents[agentId] = AgentInfo(id: agentId, name: displayName, emoji: emoji, state: state)
        }

        let prevState = agents[agentId]?.state
        agents[agentId]?.state = state
        agents[agentId]?.name = displayName
        agents[agentId]?.emoji = emoji
        if let tool { agents[agentId]?.currentTool = tool }
        if let message { agents[agentId]?.lastMessage = message }
        if let workspace { agents[agentId]?.workspace = workspace }
        agents[agentId]?.lastEventTime = Date()

        if state != prevState {
            LogService.info("Agent \(displayName): \(String(describing: prevState)) -> \(state), stream=\(stream) phase=\(phase)", category: "OpenClaw")
        }
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
        ttlTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupStaleAgents()
            }
        }
    }

    private func cleanupStaleAgents() {
        let idleThreshold = Date().addingTimeInterval(-15)
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
            Task { @MainActor [weak self] in
                self?.connect()
            }
        }
    }
}
