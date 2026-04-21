import Foundation

enum ConversationParser {

    struct ParseResult {
        var messages: [ChatMessage]
        var inputTokens: Int
        var outputTokens: Int
        var newOffset: UInt64
        var interrupted: Bool
        var cleared: Bool
    }

    static func conversationPath(sessionId: String, cwd: String) -> String? {
        let dir = claudeProjectsDir(for: cwd)
        let path = "\(dir)/\(sessionId).jsonl"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func conversationFiles(for cwd: String) -> [String] {
        let dir = claudeProjectsDir(for: cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".jsonl") }.map { "\(dir)/\($0)" }
    }

    static func parseIncremental(filePath: String, fromOffset: UInt64) -> ParseResult {
        var result = ParseResult(messages: [], inputTokens: 0, outputTokens: 0, newOffset: fromOffset, interrupted: false, cleared: false)

        guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else {
            return result
        }
        defer { try? fileHandle.close() }

        if fromOffset > 0 {
            try? fileHandle.seek(toOffset: fromOffset)
        }

        guard let data = try? fileHandle.readToEnd() else { return result }
        guard let text = String(data: data, encoding: .utf8) else { return result }

        result.newOffset = fromOffset + UInt64(data.count)

        var messageIndex = 0
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if isInterruptLine(json) {
                result.interrupted = true
                continue
            }

            if isClearLine(json) {
                result.cleared = true
                result.messages = []
                continue
            }

            if let usage = json["usage"] as? [String: Any] {
                result.inputTokens += usage["input_tokens"] as? Int ?? 0
                result.outputTokens += usage["output_tokens"] as? Int ?? 0
            }

            if let message = parseMessage(json, index: messageIndex) {
                result.messages.append(message)
                messageIndex += 1
            }
        }

        return result
    }

    static func parseFull(filePath: String) -> ParseResult {
        parseIncremental(filePath: filePath, fromOffset: 0)
    }

    // MARK: - Private

    private static func claudeProjectsDir(for cwd: String) -> String {
        let encoded = "-" + cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "-")
        return NSString(string: "~/.claude/projects/\(encoded)").expandingTildeInPath
    }

    private static func parseMessage(_ json: [String: Any], index: Int) -> ChatMessage? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "user": return parseUserMessage(json, index: index)
        case "assistant": return parseAssistantMessage(json, index: index)
        case "tool_result": return parseToolResult(json, index: index)
        default: return nil
        }
    }

    private static func parseUserMessage(_ json: [String: Any], index: Int) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        let text = extractText(from: message)
        guard !text.isEmpty else { return nil }
        return ChatMessage(id: "user-\(index)", role: .user, content: text, timestamp: parseTimestamp(json) ?? Date())
    }

    private static func parseAssistantMessage(_ json: [String: Any], index: Int) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        let text = extractText(from: message)

        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "tool_use",
                   let toolName = block["name"] as? String {
                    let input = block["input"]
                    let inputStr = input.flatMap { try? String(data: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8) }
                    return ChatMessage(
                        id: "tool-\(index)",
                        role: .tool,
                        content: text.isEmpty ? "Using \(toolName)" : text,
                        toolName: toolName,
                        toolInput: inputStr,
                        timestamp: parseTimestamp(json) ?? Date()
                    )
                }
            }
        }

        guard !text.isEmpty else { return nil }
        return ChatMessage(id: "assistant-\(index)", role: .assistant, content: text, timestamp: parseTimestamp(json) ?? Date())
    }

    private static func parseToolResult(_ json: [String: Any], index: Int) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        let content = message["content"]
        var text = ""
        if let str = content as? String { text = str }
        else if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text", let t = item["text"] as? String { text = t; break }
            }
        }
        guard !text.isEmpty else { return nil }
        return ChatMessage(
            id: "result-\(index)",
            role: .toolResult,
            content: String(text.prefix(500)),
            toolName: message["tool_use_id"] as? String,
            timestamp: parseTimestamp(json) ?? Date()
        )
    }

    private static func extractText(from message: [String: Any]) -> String {
        guard let content = message["content"] else { return "" }
        if let str = content as? String { return str }
        if let array = content as? [[String: Any]] {
            return array.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseTimestamp(_ json: [String: Any]) -> Date? {
        guard let ts = json["timestamp"] as? String else { return nil }
        return isoFormatter.date(from: ts)
    }

    private static let interruptPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user",
    ]

    private static func isInterruptLine(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any] else { return false }
        let text = extractText(from: message).lowercased()
        return interruptPatterns.contains { text.contains($0.lowercased()) }
    }

    private static func isClearLine(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return false }
            return text.contains("/clear") || text.contains("/compact")
        }
    }
}
