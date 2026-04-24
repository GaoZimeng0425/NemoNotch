import Foundation

final class AgentFileWatcher {
    private let filePath: String
    private let taskToolId: String
    private let onUpdate: ([SubagentToolCall]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.nemonotch.agentwatcher", qos: .utility)
    private var seenToolIds: Set<String> = []
    private var allTools: [SubagentToolCall] = []

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
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let text = String(data: data, encoding: .utf8) else { return }

        let completedIds = parseCompletedToolIds(text)

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "tool_use",
                       let toolId = block["id"] as? String,
                       let toolName = block["name"] as? String {
                        guard !seenToolIds.contains(toolId) else { continue }
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
                    }
                }
            }
        }

        // Update completion status for existing tools
        for i in allTools.indices {
            allTools[i].isCompleted = completedIds.contains(allTools[i].id)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onUpdate(self.allTools)
        }
    }

    private func parseCompletedToolIds(_ text: String) -> Set<String> {
        var ids: Set<String> = []
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "tool_result",
                   let toolUseId = block["tool_use_id"] as? String {
                    ids.insert(toolUseId)
                }
            }
        }
        return ids
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
        MainActor.assumeIsolated {
            stop()
        }
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
