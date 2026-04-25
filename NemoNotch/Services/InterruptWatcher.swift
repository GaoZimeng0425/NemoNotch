@preconcurrency import Foundation

final class InterruptWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private let filePath: String
    private let sessionId: String
    private var lastOffset: UInt64 = 0
    private let queue = DispatchQueue(label: "com.nemonotch.interruptwatcher", qos: .utility)

    var onInterrupt: ((String) -> Void)?
    var onClear: ((String) -> Void)?

    init(sessionId: String, filePath: String) {
        self.sessionId = sessionId
        self.filePath = filePath
    }

    func start() {
        guard FileManager.default.fileExists(atPath: filePath) else { return }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return }
        self.fileHandle = handle

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? UInt64) ?? 0
        lastOffset = fileSize

        let fd = handle.fileDescriptor
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source?.setEventHandler { [weak self] in self?.checkForChanges() }
        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func checkForChanges() {
        guard let handle = fileHandle else { return }
        let currentSize = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? UInt64) ?? 0
        guard currentSize > lastOffset else { return }

        try? handle.seek(toOffset: lastOffset)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            lastOffset = currentSize
            return
        }
        lastOffset = currentSize

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if isInterruptLine(json) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onInterrupt?(self.sessionId)
                }
            }
            if isClearLine(json) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onClear?(self.sessionId)
                }
            }
        }
    }

    private static let interruptPatterns = [
        "interrupted by user",
        "user doesn't want to proceed",
        "[request interrupted by user",
    ]

    private func isInterruptLine(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any] else { return false }
        let content = message["content"]
        var text = ""
        if let str = content as? String { text = str }
        else if let arr = content as? [[String: Any]] {
            for item in arr { if item["type"] as? String == "text", let t = item["text"] as? String { text += t } }
        }
        let lower = text.lowercased()
        return Self.interruptPatterns.contains { lower.contains($0) }
    }

    private func isClearLine(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return false }
            return text.contains("/clear") || text.contains("/compact")
        }
    }
}

final class InterruptWatcherManager {
    private var watchers: [String: InterruptWatcher] = [:]
    var onInterrupt: ((String) -> Void)?
    var onClear: ((String) -> Void)?

    func startWatching(sessionId: String, cwd: String) {
        guard let filePath = ConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd) else { return }
        guard watchers[sessionId] == nil else { return }
        let watcher = InterruptWatcher(sessionId: sessionId, filePath: filePath)
        watcher.onInterrupt = { [weak self] sessionId in self?.onInterrupt?(sessionId) }
        watcher.onClear = { [weak self] sessionId in self?.onClear?(sessionId) }
        watchers[sessionId] = watcher
        watcher.start()
    }

    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
    }

    func stopAll() {
        for (_, watcher) in watchers { watcher.stop() }
        watchers.removeAll()
    }
}
