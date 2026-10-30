import Foundation
import Network
import Security

/// Local hook server. Accepts HTTP POSTs from hook-sender.sh on TCP loopback.
///
/// Design follows masko-code/Sources/Services/LocalServer.swift — TCP rather
/// than AF_UNIX socket because, on this bundle id, macOS hides unix socket
/// inodes from any process other than NemoNotch itself even when bind()
/// succeeds. Regular files in the same directory remain visible, so the
/// filtering is socket-inode-specific. TCP loopback bypasses VFS entirely.
@MainActor
@Observable
final class HookServer {
    private(set) var isRunning = false
    private(set) var port: UInt16 = NotchConstants.hookServerDefaultPort

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var pendingPermissions: [String: NWConnection] = [:]
    @ObservationIgnored private var hasReadied = false

    /// POST /hook 的共享令牌,由 ~/.NemoNotch/hook-token(0600)持有;发送方脚本
    /// 运行时读同一文件并放进 X-NemoNotch-Token 头。回环 TCP 不区分调用者身份,
    /// 没有它任何本地进程都能伪造 hook 事件或抢答权限决策。
    @ObservationIgnored private var authToken: String?
    /// 回环端口对全部本地进程开放:并发连接、单请求体积、请求时长都需要上限,
    /// 否则慢速发送 + 超大 Content-Length 就能把内存拖垮(本地 DoS)。
    @ObservationIgnored private var activeConnections: Set<ObjectIdentifier> = []
    @ObservationIgnored private var connectionDeadlines: [ObjectIdentifier: DispatchWorkItem] = [:]
    /// 权限等待键的插入顺序:respondToPermission 只拿到 sessionId,应回应最早
    /// 插入的请求,而不是字典遍历顺序碰到的任意一个。
    @ObservationIgnored private var pendingOrder: [String] = []

    private static let maxRequestBytes = 2 << 20 // 2 MB
    private static let maxConcurrentConnections = 32
    private static let requestDeadlineSeconds: TimeInterval = 15

    private static var tokenFilePath: String {
        NSHomeDirectory() + "/.NemoNotch/hook-token"
    }

    var onEventReceived: ((HookEvent) -> Void)?
    var onReady: (() -> Void)?

    func start() {
        hasReadied = false
        authToken = loadOrCreateAuthToken()
        port = NotchConstants.hookServerDefaultPort
        attemptStart()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func attemptStart() {
        listener?.cancel()
        listener = nil

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            LogService.error("Invalid hook port \(port)", category: "HookServer")
            return
        }
        let params = Self.listenerParameters(port: nwPort)

        let newListener: NWListener
        do {
            // Port comes from `requiredLocalEndpoint`; passing it again via
            // `on:` would conflict with the pinned endpoint.
            newListener = try NWListener(using: params)
        } catch {
            LogService.warn("Failed to create NWListener on \(port): \(error)", category: "HookServer")
            tryNextPort()
            return
        }
        listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        newListener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }

        newListener.start(queue: .global(qos: .userInitiated))
    }

    /// Listener parameters for the hook port, bound to IPv4 loopback.
    /// `acceptLocalOnly` alone means "local link" (anyone on the same subnet),
    /// and without a required endpoint the listener took every interface
    /// (`*:45831`, reachable on the LAN IP). Every sender — hook-sender.sh,
    /// the Hermes script, the opencode plugin — targets 127.0.0.1.
    nonisolated static func listenerParameters(port: NWEndpoint.Port) -> NWParameters {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        params.includePeerToPeer = false
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        return params
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            hasReadied = true
            LogService.info("Hook server listening on 127.0.0.1:\(port)", category: "HookServer")
            // Persist the port and bring every sender script in line with it —
            // on the default port too, so a script left pointing elsewhere
            // heals on the next launch (the rewrite is a no-op when the
            // script's version and port already match). Only the user's real
            // app may do this: a test host / --uitest instance sits on the
            // next port and would redirect every CLI to it, then exit.
            if UITestMode.ownsSharedHookConfig {
                NotchConstants.setHookServerPort(port)
                try? HookInstaller.ensureScriptExists()
                if HermesHookInstaller.isInstalled {
                    try? HermesHookInstaller.refreshScript()
                }
                try? OpencodePluginInstaller.refreshScript()
            } else {
                LogService.info(
                    "Test/UI-test instance on \(port): shared hook config left alone",
                    category: "HookServer"
                )
            }
            onReady?()
        case let .failed(error):
            LogService.warn("Hook server failed on \(port): \(error)", category: "HookServer")
            isRunning = false
            listener?.cancel()
            listener = nil
            if !hasReadied {
                tryNextPort()
            }
        case let .waiting(error):
            // Port unavailable (already in use, etc.) — try next
            LogService.warn("Hook server waiting on \(port): \(error)", category: "HookServer")
            isRunning = false
            listener?.cancel()
            listener = nil
            if !hasReadied {
                tryNextPort()
            }
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func tryNextPort() {
        let base = NotchConstants.hookServerDefaultPort
        let max = base + NotchConstants.hookServerMaxPortAttempts
        let next = port + 1
        if next < max {
            port = next
            attemptStart()
        } else {
            LogService.error("Hook server exhausted ports \(base)..<\(max)", category: "HookServer")
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        // 并发上限:超出的连接直接断开,防止闲置连接堆积。
        let id = ObjectIdentifier(connection)
        guard activeConnections.count < Self.maxConcurrentConnections else {
            connection.cancel()
            LogService.warn("HookServer: rejected connection (over concurrent limit)", category: "HookServer")
            return
        }
        activeConnections.insert(id)
        armRequestDeadline(for: connection)
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection: connection, accumulated: Data())
    }

    /// 单连接请求截止:慢速发送、或只声明 Content-Length 永不补齐的连接,到期
    /// 直接断开,不能无限占用内存与连接槽。
    private func armRequestDeadline(for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, connectionDeadlines[id] != nil else { return }
                retireConnection(connection)
                connection.cancel()
                LogService.warn("HookServer: closed connection (request deadline)", category: "HookServer")
            }
        }
        connectionDeadlines[id] = item
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.requestDeadlineSeconds,
            execute: item
        )
    }

    private func retireConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connectionDeadlines.removeValue(forKey: id)?.cancel()
        activeConnections.remove(id)
    }

    /// Receive loop for one request. The accumulate/complete checks are pure
    /// and run WITHOUT hopping to the main actor: if every chunk waited for a
    /// MainActor turn, a busy main thread (long layout pass, dialog stall)
    /// would stop the server reading, the sender's socket buffer would fill,
    /// and a `--max-time`-capped curl (hook-sender.sh posts events with
    /// `--max-time 2`) would abort mid-body — the truncated event then failed
    /// to decode and was silently dropped (observed: a 65KB PostToolUse with
    /// a base64 tool_response died exactly this way). Only the FINAL
    /// processing needs the main actor.
    private nonisolated func receive(connection: NWConnection, accumulated: Data) {
        connection
            .receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data, _, isComplete, error in
                var buf = accumulated
                if let data {
                    buf.append(data)
                }
                // 请求体积硬上限:超限即断,不再继续累积。
                if buf.count > Self.maxRequestBytes {
                    Task { @MainActor [weak self] in
                        self?.retireConnection(connection)
                        self?.sendHTTP(connection, status: "413 Payload Too Large", body: #"{"status":"error"}"#)
                    }
                    return
                }
                if Self.hasCompleteHTTPRequest(buf) || isComplete || error != nil {
                    Task { @MainActor [weak self] in
                        self?.retireConnection(connection)
                        self?.processRequest(buf, connection: connection)
                    }
                } else {
                    self?.receive(connection: connection, accumulated: buf)
                }
            }
    }

    private nonisolated static func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8),
              let separator = str.range(of: "\r\n\r\n") else { return false }
        let headers = str[..<separator.lowerBound]
        let body = str[separator.upperBound...]
        if let clRange = headers.range(of: "Content-Length:", options: .caseInsensitive) {
            let after = headers[clRange.upperBound...]
            if let lineEnd = after.firstIndex(of: "\r") {
                let value = after[..<lineEnd].trimmingCharacters(in: .whitespaces)
                if let cl = Int(value) {
                    return body.utf8.count >= cl
                }
            }
        }
        return true
    }

    private func processRequest(_ data: Data, connection: NWConnection) {
        guard let httpString = String(data: data, encoding: .utf8) else {
            sendHTTP(connection, status: "400 Bad Request", body: "Bad Request")
            return
        }
        let firstLine = httpString.components(separatedBy: "\r\n").first ?? ""

        if firstLine.hasPrefix("GET /health") {
            sendHTTP(connection, status: "200 OK", body: "ok")
            return
        }

        if firstLine.hasPrefix("POST /hook") {
            // 回环 TCP 只限接口不限身份,凭共享令牌验明发送方;失败关闭。
            guard isAuthorized(httpString) else {
                LogService.warn("HookServer: rejected unauthenticated POST /hook", category: "HookServer")
                sendHTTP(connection, status: "401 Unauthorized", body: #"{"status":"unauthorized"}"#)
                return
            }
            guard let bodyRange = httpString.range(of: "\r\n\r\n") else {
                sendHTTP(connection, status: "400 Bad Request", body: "No body")
                return
            }
            let bodyString = String(httpString[bodyRange.upperBound...])
            guard let bodyData = bodyString.data(using: .utf8) else {
                sendHTTP(connection, status: "400 Bad Request", body: "Invalid body")
                return
            }
            LogService.debug("Received hook message: \(bodyData.count) bytes", category: "HookServer")

            let decoder = JSONDecoder()
            do {
                let event = try decoder.decode(HookEvent.self, from: bodyData)
                onEventReceived?(event)
                if event.hookEventName == "PermissionRequest" {
                    handlePermissionRequest(event, connection: connection)
                    return
                }
                sendJSON(connection, payload: .ack)
            } catch {
                // Log the decode ERROR itself (a typeMismatch names the JSON
                // path) plus the body size — a size below the request's
                // Content-Length means the sender aborted mid-body (e.g. the
                // hook script's --max-time), which is the signature of the
                // silently-dropped 65KB PostToolUse incident.
                let snippet = String(bodyString.prefix(500))
                LogService.error(
                    "Failed to decode HookEvent: \(error) — body \(bodyData.count)B, head: \(snippet)",
                    category: "HookServer"
                )
                sendJSON(connection, payload: .ack)
            }
            return
        }

        sendHTTP(connection, status: "404 Not Found", body: "Not Found")
    }

    private func handlePermissionRequest(_ event: HookEvent, connection: NWConnection) {
        guard let sessionId = event.sessionId else {
            sendJSON(connection, payload: .decision(.deny(reason: .noSessionId)))
            return
        }
        let waitKey = sessionId + ":" + (event.toolUseId ?? UUID().uuidString)
        if pendingPermissions[waitKey] == nil {
            pendingOrder.append(waitKey)
        }
        pendingPermissions[waitKey] = connection

        let timeout = Self.permissionHoldTimeout(cliSource: event.cliSource)
        let timeoutPayload = Self.timeoutPayload(cliSource: event.cliSource)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            if let conn = pendingPermissions.removeValue(forKey: waitKey) {
                pendingOrder.removeAll { $0 == waitKey }
                sendJSON(conn, payload: timeoutPayload)
            }
        }
    }

    /// How long a held permission connection waits for the user. Claude's hook
    /// waits with the CLI (short hold); the opencode plugin holds its bridge
    /// while opencode's own TUI dialog can stay up much longer.
    nonisolated static func permissionHoldTimeout(cliSource: String?) -> TimeInterval {
        cliSource == "opencode" ? 600 : 120
    }

    /// What a held permission connection gets when the user never answers.
    /// Claude fail-closes with a deny (an unanswered hook would block the CLI
    /// forever). The opencode bridge MUST answer with no decision (ack): its
    /// TUI dialog is still up and owns the call — a deny here would reject the
    /// user's tool out from under them.
    nonisolated static func timeoutPayload(cliSource: String?) -> HookResponse {
        cliSource == "opencode" ? .ack : .decision(.deny(reason: .timeout))
    }

    /// 取最早插入且仍存活的等待连接(字典遍历顺序不确定,不能当作"第一个")。
    private func takePendingConnection(matchingPrefix prefix: String) -> NWConnection? {
        for key in pendingOrder where key.hasPrefix(prefix) {
            pendingOrder.removeAll { $0 == key }
            if let conn = pendingPermissions.removeValue(forKey: key) {
                return conn
            }
        }
        pendingOrder.removeAll { pendingPermissions[$0] == nil }
        return nil
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        let decision: HookResponse.Decision = approved ? .allow : .deny(reason: nil)
        if let conn = takePendingConnection(matchingPrefix: sessionId + ":") {
            sendJSON(conn, payload: .decision(decision))
        }
    }

    /// An AskUserQuestion answered from the bar: allow with `updatedInput`
    /// carrying the original tool input plus the chosen answers.
    func respondToAsk(sessionId: String, originalInput: String, answers: [String: String]) {
        guard !answers.isEmpty else { return }
        if let conn = takePendingConnection(matchingPrefix: sessionId + ":") {
            sendJSON(conn, payload: .answer(originalInput: originalInput, answers: answers))
        }
    }

    func cancelPendingPermissions(sessionId: String) {
        let matching = pendingPermissions.keys.filter { $0.hasPrefix(sessionId + ":") }
        for key in matching {
            if let conn = pendingPermissions.removeValue(forKey: key) {
                sendJSON(conn, payload: .decision(.deny(reason: .sessionEnded)))
            }
        }
        pendingOrder.removeAll { pendingPermissions[$0] == nil }
    }

    /// Silently drop pending permission(s) for a session WITHOUT sending a
    /// decision. Used when a tool completes (PostToolUse): the request is moot
    /// because the tool already ran — approved here, approved directly in the
    /// terminal, or timed out — so a late allow/deny would be wrong. Closing the
    /// (usually already-dead) connection just releases the held socket.
    func clearPendingPermissions(sessionId: String) {
        let matching = pendingPermissions.keys.filter { $0.hasPrefix(sessionId + ":") }
        for key in matching {
            if let conn = pendingPermissions.removeValue(forKey: key) {
                conn.cancel()
                LogService.debug(
                    "Cleared pending permission \(key) on tool completion",
                    category: "HookServer"
                )
            }
        }
        pendingOrder.removeAll { pendingPermissions[$0] == nil }
    }

    // MARK: - Auth

    /// 首次访问时生成 32 字节随机令牌写入 0600 文件;发送方脚本运行时读取同一
    /// 文件。令牌缺失/不可写时返回 nil —— /hook 对未验明身份的请求失败关闭
    /// (此时脚本同样读不到令牌,hook 本来就发不进来)。
    private func loadOrCreateAuthToken() -> String? {
        let path = Self.tokenFilePath
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let token = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           token.count >= 32 {
            return token
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            LogService.error("HookServer: SecRandomCopyBytes failed", category: "HookServer")
            return nil
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return token
        } catch {
            LogService.error("HookServer: failed to write hook token: \(error)", category: "HookServer")
            return nil
        }
    }

    /// 从原始 HTTP 请求里取出 X-NemoNotch-Token 的值(头名大小写不敏感)。
    /// 纯函数,便于单测。注意:Swift 把 "\r\n" 视作单个 Character,不能用
    /// `firstIndex(of: "\r")` 找行尾——必须按换行符集合切分。
    nonisolated static func headerToken(_ request: String) -> String? {
        guard let range = request.range(of: "X-NemoNotch-Token:", options: .caseInsensitive) else {
            return nil
        }
        let after = String(request[range.upperBound...])
        let line = after.components(separatedBy: .newlines).first ?? ""
        let value = line.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func isAuthorized(_ httpString: String) -> Bool {
        guard let token = authToken, !token.isEmpty,
              let provided = Self.headerToken(httpString) else { return false }
        return provided == token
    }

    private func sendJSON(
        _ connection: NWConnection,
        status: String = "200 OK",
        payload: HookResponse
    ) {
        do {
            let data = try payload.jsonData() // deterministic wire format
            let bodyString = String(data: data, encoding: .utf8) ?? "{}"
            sendHTTP(connection, status: status, body: bodyString)
        } catch {
            LogService.error(
                "HookServer: failed to encode response \(payload): \(error)",
                category: "HookServer"
            )
            sendHTTP(connection, status: "500 Internal Server Error", body: #"{"status":"error"}"#)
        }
    }

    private func sendHTTP(_ connection: NWConnection, status: String, body: String) {
        let bodyBytes = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(bodyBytes.count)\r\n" +
            "Connection: close\r\n\r\n"
        var response = header.data(using: .utf8) ?? Data()
        response.append(bodyBytes)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    deinit {
        listener?.cancel()
    }
}
