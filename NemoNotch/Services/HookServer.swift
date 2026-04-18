import Foundation
import Network

@Observable
final class HookServer {
    private var listener: NWListener?
    private(set) var isRunning = false
    private(set) var port: UInt16 = 49200
    private var stopped = false

    var onEventReceived: ((HookEvent) -> Void)?

    private static let maxPortAttempts: UInt16 = 10

    func start() throws {
        stopped = false
        listener?.cancel()
        listener = nil

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        listener = try NWListener(using: params, on: nwPort)

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    print("[NemoNotch] Hook server listening on port \(self.port)")
                case .failed(let error):
                    self.isRunning = false
                    self.listener?.cancel()
                    self.listener = nil
                    self.tryNextPort(error: error)
                case .waiting(let error):
                    self.isRunning = false
                    self.listener?.cancel()
                    self.listener = nil
                    self.tryNextPort(error: error)
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    private func tryNextPort(error: NWError) {
        guard !stopped else { return }
        let nextPort = port + 1
        let basePort: UInt16 = 49200
        if nextPort < basePort + Self.maxPortAttempts {
            port = nextPort
            try? start()
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var receivedData = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data { receivedData.append(data) }

                if self?.hasCompleteHTTPRequest(receivedData) == true || isComplete == true || error != nil {
                    self?.processRequest(receivedData, connection: connection)
                } else {
                    readMore()
                }
            }
        }

        readMore()
    }

    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8) else { return false }
        if str.hasPrefix("GET ") { return str.contains("\r\n\r\n") }

        guard let separatorRange = str.range(of: "\r\n\r\n") else { return false }
        let headers = str[str.startIndex..<separatorRange.lowerBound]
        let body = str[separatorRange.upperBound...]

        if let clRange = headers.range(of: "Content-Length: ", options: .caseInsensitive) {
            let afterCL = headers[clRange.upperBound...]
            if let lineEnd = afterCL.firstIndex(of: "\r"),
               let contentLength = Int(afterCL[afterCL.startIndex..<lineEnd]) {
                return body.utf8.count >= contentLength
            }
        }
        return true
    }

    private func processRequest(_ data: Data, connection: NWConnection) {
        guard let httpString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Bad Request")
            return
        }

        let firstLine = httpString.components(separatedBy: "\r\n").first ?? ""

        if firstLine.contains("GET /health") {
            sendResponse(connection: connection, status: "200 OK", body: "ok")
            return
        }

        guard let bodyRange = httpString.range(of: "\r\n\r\n") else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "No body")
            return
        }
        let bodyString = String(httpString[bodyRange.upperBound...])
        guard let bodyData = bodyString.data(using: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid body")
            return
        }

        if firstLine.contains("POST /hook") {
            let decoder = JSONDecoder()
            if let event = try? decoder.decode(HookEvent.self, from: bodyData) {
                DispatchQueue.main.async { [weak self] in
                    self?.onEventReceived?(event)
                }
            }
            sendResponse(connection: connection, status: "200 OK", body: "OK")
            return
        }

        sendResponse(connection: connection, status: "404 Not Found", body: "Not Found")
    }

    private func sendResponse(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    deinit {
        listener?.cancel()
    }
}

struct HookEvent: Codable {
    let hookEventName: String
    let sessionId: String?
    let toolName: String?
    let message: String?
    let cwd: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case toolName = "tool_name"
        case message
        case cwd
        case source
    }
}
