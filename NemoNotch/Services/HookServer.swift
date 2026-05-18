import Foundation
import Network

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

    var onEventReceived: ((HookEvent) -> Void)?
    var onReady: (() -> Void)?

    func start() {
        hasReadied = false
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

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        params.includePeerToPeer = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            LogService.error("Invalid hook port \(port)", category: "HookServer")
            return
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: nwPort)
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

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            hasReadied = true
            LogService.info("Hook server listening on 127.0.0.1:\(port)", category: "HookServer")
            // If we landed on a non-default port, persist it and rewrite the
            // hook script so external callers find the right port.
            if port != NotchConstants.hookServerDefaultPort {
                NotchConstants.setHookServerPort(port)
                try? HookInstaller.ensureScriptExists()
                try? HermesHookInstaller.refreshScript()
            } else {
                NotchConstants.setHookServerPort(port)
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
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection: connection, accumulated: Data())
    }

    private func receive(connection: NWConnection, accumulated: Data) {
        connection
            .receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data, _, isComplete, error in
                var buf = accumulated
                if let data { buf.append(data) }
                if Self.hasCompleteHTTPRequest(buf) || isComplete || error != nil {
                    Task { @MainActor in
                        self?.processRequest(buf, connection: connection)
                    }
                } else {
                    Task { @MainActor in
                        self?.receive(connection: connection, accumulated: buf)
                    }
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
            if let event = try? decoder.decode(HookEvent.self, from: bodyData) {
                onEventReceived?(event)
                if event.hookEventName == "PermissionRequest" {
                    handlePermissionRequest(event, connection: connection)
                    return
                }
                sendHTTP(connection, status: "200 OK", body: #"{"status":"ok"}"#)
            } else {
                LogService.error("Failed to decode HookEvent", category: "HookServer")
                sendHTTP(connection, status: "200 OK", body: #"{"status":"ok"}"#)
            }
            return
        }

        sendHTTP(connection, status: "404 Not Found", body: "Not Found")
    }

    private func handlePermissionRequest(_ event: HookEvent, connection: NWConnection) {
        guard let sessionId = event.sessionId else {
            sendHTTP(connection, status: "200 OK", body: #"{"decision":"deny","reason":"no session id"}"#)
            return
        }
        let waitKey = sessionId + ":" + (event.toolUseId ?? UUID().uuidString)
        pendingPermissions[waitKey] = connection

        // Timeout fallback: deny after 120s of no user response.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self else { return }
            if let conn = pendingPermissions.removeValue(forKey: waitKey) {
                sendHTTP(conn, status: "200 OK", body: #"{"decision":"deny","reason":"timeout"}"#)
            }
        }
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        let body = #"{"decision":"\#(approved ? "allow" : "deny")"}"#
        if let key = pendingPermissions.keys.first(where: { $0.hasPrefix(sessionId + ":") }),
           let conn = pendingPermissions.removeValue(forKey: key) {
            sendHTTP(conn, status: "200 OK", body: body)
        }
    }

    func cancelPendingPermissions(sessionId: String) {
        let matching = pendingPermissions.keys.filter { $0.hasPrefix(sessionId + ":") }
        for key in matching {
            if let conn = pendingPermissions.removeValue(forKey: key) {
                sendHTTP(conn, status: "200 OK", body: #"{"decision":"deny","reason":"session ended"}"#)
            }
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
