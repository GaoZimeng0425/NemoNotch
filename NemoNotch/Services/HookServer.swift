import Foundation

@Observable
final class HookServer {
    private(set) var isRunning = false
    nonisolated(unsafe) private var socketFd: Int32 = -1
    nonisolated(unsafe) private var acceptSource: DispatchSourceRead?
    private let socketQueue = DispatchQueue(label: "com.nemonotch.hookserver", qos: .userInitiated)

    nonisolated(unsafe) private var responseWaiters: [String: (String) -> Void] = [:]

    var onEventReceived: ((HookEvent) -> Void)?
    var onReady: (() -> Void)?

    func start() {
        let socketPath = NotchConstants.hookSocketPath
        socketQueue.async { [weak self] in
            self?.doStart(socketPath: socketPath)
        }
    }

    nonisolated private func doStart(socketPath: String) {
        unlink(socketPath)

        socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFd >= 0 else {
            LogService.error("Failed to create socket: \(String(cString: strerror(errno)))", category: "HookServer")
            return
        }

        var optval: Int32 = 1
        setsockopt(socketFd, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout.size(ofValue: optval)))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { ptr in
            strncpy(&addr.sun_path.0, ptr, 103)
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }
        guard bind(socketFd, bindResult, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 else {
            LogService.error("Failed to bind socket: \(String(cString: strerror(errno)))", category: "HookServer")
            close(socketFd)
            socketFd = -1
            return
        }

        guard listen(socketFd, 10) == 0 else {
            LogService.error("Failed to listen on socket: \(String(cString: strerror(errno)))", category: "HookServer")
            close(socketFd)
            socketFd = -1
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isRunning = true
            self?.onReady?()
        }

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: socketFd, queue: socketQueue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.resume()

        LogService.info("Hook server listening on \(socketPath)", category: "HookServer")
    }

    nonisolated private func acceptConnection() {
        var addr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebased in
                accept(socketFd, rebased, &addrLen)
            }
        }
        guard clientFd >= 0 else { return }
        readRequest(fd: clientFd)
    }

    nonisolated private func readRequest(fd: Int32) {
        var buffer = Data()
        var tempBuf = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(fd, &tempBuf, tempBuf.count)
            if bytesRead > 0 {
                buffer.append(tempBuf, count: bytesRead)
                if let str = String(data: buffer, encoding: .utf8), str.hasSuffix("\n") {
                    break
                }
            } else {
                break
            }
        }

        guard let message = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            close(fd)
            return
        }

        LogService.debug("Raw message received: \(message)", category: "HookServer")

        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LogService.error("Failed to parse JSON from message", category: "HookServer")
            sendResponse(fd: fd, response: #"{"error":"invalid json"}"#)
            return
        }

        if json["type"] as? String == "health" {
            sendResponse(fd: fd, response: #"{"status":"ok"}"#)
            return
        }

        let decoder = JSONDecoder()
        if let event = try? decoder.decode(HookEvent.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                self?.onEventReceived?(event)
            }

            if event.hookEventName == "PermissionRequest" {
                handlePermissionRequest(event, fd: fd)
                return
            }

            sendResponse(fd: fd, response: #"{"status":"ok"}"#)
        } else {
            sendResponse(fd: fd, response: #"{"status":"ok"}"#)
        }
    }

    nonisolated private func handlePermissionRequest(_ event: HookEvent, fd: Int32) {
        guard let sessionId = event.sessionId else {
            sendResponse(fd: fd, response: #"{"decision":"deny","reason":"no session id"}"#)
            return
        }

        let waitKey = sessionId + ":" + (event.toolUseId ?? UUID().uuidString)
        responseWaiters[waitKey] = { [weak self] response in
            self?.sendResponse(fd: fd, response: response)
        }

        socketQueue.asyncAfter(deadline: .now() + 120) { [weak self] in
            if let waiter = self?.responseWaiters.removeValue(forKey: waitKey) {
                waiter(#"{"decision":"deny","reason":"timeout"}"#)
            }
        }
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        let response = #"{"decision":"\#(approved ? "allow" : "deny")"}"#
        socketQueue.async { [weak self] in
            guard let self else { return }
            if let key = self.responseWaiters.keys.first(where: { $0.hasPrefix(sessionId + ":") }) {
                self.responseWaiters.removeValue(forKey: key)?(response)
            }
        }
    }

    func cancelPendingPermissions(sessionId: String) {
        socketQueue.async { [weak self] in
            guard let self else { return }
            let matching = self.responseWaiters.keys.filter { $0.hasPrefix(sessionId + ":") }
            for key in matching {
                self.responseWaiters.removeValue(forKey: key)?(#"{"decision":"deny","reason":"session ended"}"#)
            }
        }
    }

    nonisolated private func sendResponse(fd: Int32, response: String) {
        let data = (response + "\n").data(using: .utf8) ?? Data()
        _ = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, data.count)
        }
        close(fd)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
        unlink(NotchConstants.hookSocketPath)
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
    }

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }
}
