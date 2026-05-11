import Foundation

final class AgentFileWatcher: @unchecked Sendable {
    private let filePath: String
    private let taskToolId: String
    private let onUpdate: ([SubagentToolCall]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.nemonotch.agentwatcher", qos: .utility)
    private var seenToolIds: Set<String> = []
    private var completedIds: Set<String> = []
    private var allTools: [SubagentToolCall] = []
    private var readOffset: UInt64 = 0
    private var pendingTail = Data()

    init(filePath: String, taskToolId: String, onUpdate: @escaping ([SubagentToolCall]) -> Void) {
        self.filePath = filePath
        self.taskToolId = taskToolId
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            self?.doStart()
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func doStart() {
        guard FileManager.default.fileExists(atPath: filePath) else {
            retryStart(attempt: 0)
            return
        }
        beginWatching()
    }

    private func retryStart(attempt: Int) {
        guard attempt < 10 else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.filePath) {
                self.beginWatching()
            } else {
                self.retryStart(attempt: attempt + 1)
            }
        }
    }

    private func beginWatching() {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return }
        self.fileHandle = handle

        let fd = handle.fileDescriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            self?.parseFile()
        }

        parseFile()
        source?.resume()
    }

    private func parseFile() {
        guard let handle = fileHandle else { return }

        // Read only the bytes appended since last invocation.
        do {
            try handle.seek(toOffset: readOffset)
        } catch {
            return
        }
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }
        readOffset += UInt64(chunk.count)

        var buffer = pendingTail
        buffer.append(chunk)
        pendingTail.removeAll(keepingCapacity: true)

        let newline = UInt8(ascii: "\n")
        var lineStart = buffer.startIndex
        var didChange = false

        for i in buffer.indices {
            if buffer[i] == newline {
                let lineRange = lineStart..<i
                if !lineRange.isEmpty {
                    if processLine(buffer.subdata(in: lineRange)) { didChange = true }
                }
                lineStart = buffer.index(after: i)
            }
        }

        // Preserve the trailing partial line for next time.
        if lineStart < buffer.endIndex {
            pendingTail = buffer.subdata(in: lineStart..<buffer.endIndex)
        }

        guard didChange else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onUpdate(self.allTools)
        }
    }

    /// Parse a single JSONL line, mutate `seenToolIds` / `completedIds` /
    /// `allTools` accordingly. Returns true if state changed.
    private func processLine(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }

        var changed = false
        for block in content {
            let type = block["type"] as? String
            if type == "tool_use",
               let toolId = block["id"] as? String,
               let toolName = block["name"] as? String,
               !seenToolIds.contains(toolId) {
                seenToolIds.insert(toolId)
                let input = block["input"].flatMap {
                    try? String(data: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8)
                } ?? ""
                allTools.append(SubagentToolCall(
                    id: toolId,
                    name: toolName,
                    input: input,
                    isCompleted: completedIds.contains(toolId),
                    timestamp: parseTimestamp(json) ?? Date()
                ))
                changed = true
            } else if type == "tool_result",
                      let toolUseId = block["tool_use_id"] as? String,
                      !completedIds.contains(toolUseId) {
                completedIds.insert(toolUseId)
                if let idx = allTools.firstIndex(where: { $0.id == toolUseId }) {
                    allTools[idx].isCompleted = true
                }
                changed = true
            }
        }
        return changed
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseTimestamp(_ json: [String: Any]) -> Date? {
        guard let ts = json["timestamp"] as? String else { return nil }
        return isoFormatter.date(from: ts)
    }

    deinit {
        stop()
    }
}

final class AgentFileWatcherManager {
    private var watchers: [String: AgentFileWatcher] = [:]

    func startWatching(sessionId: String, taskToolId: String, agentFilePath: String, onUpdate: @escaping ([SubagentToolCall]) -> Void) {
        let key = "\(sessionId):\(taskToolId)"
        let watcher = AgentFileWatcher(filePath: agentFilePath, taskToolId: taskToolId, onUpdate: onUpdate)
        watchers[key] = watcher
        watcher.start()
    }

    func stopWatching(sessionId: String, taskToolId: String) {
        let key = "\(sessionId):\(taskToolId)"
        watchers.removeValue(forKey: key)?.stop()
    }

    func stopAll(sessionId: String) {
        let prefix = "\(sessionId):"
        let matching = watchers.keys.filter { $0.hasPrefix(prefix) }
        for key in matching {
            watchers.removeValue(forKey: key)?.stop()
        }
    }
}
