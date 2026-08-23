import Foundation

enum ConversationParser: ConversationParserProtocol {
    struct ParseResult {
        var messages: [ChatMessage]
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var lastContextTokens: Int
        var lastModel: String?
        var newOffset: UInt64
        var interrupted: Bool
        var cleared: Bool

        var conversation: ParsedConversation {
            ParsedConversation(
                messages: messages,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                lastModel: lastModel
            )
        }
    }

    // MARK: - ConversationParserProtocol

    static func findSessionFile(sessionId: String, cwd: String) -> String? {
        let dir = claudeProjectsDir(for: cwd)
        let path = "\(dir)/\(sessionId).jsonl"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func parseFull(filePath: String) -> ParsedConversation {
        parseFullResult(filePath: filePath).conversation
    }

    // MARK: - Claude-Specific

    static func parseFullResult(filePath: String) -> ParseResult {
        parseIncremental(filePath: filePath, fromOffset: 0)
    }

    static func parseIncremental(filePath: String, fromOffset: UInt64) -> ParseResult {
        var result = ParseResult(
            messages: [],
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            lastContextTokens: 0,
            lastModel: nil,
            newOffset: fromOffset,
            interrupted: false,
            cleared: false
        )

        guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else {
            return result
        }
        defer { try? fileHandle.close() }

        if fromOffset > 0 {
            try? fileHandle.seek(toOffset: fromOffset)
        }

        guard let data = try? fileHandle.readToEnd() else { return result }

        let framing = JSONLFramer.frame(data)
        result.newOffset = fromOffset + UInt64(framing.consumedByteCount)

        if case let .surrendered(tail) = framing.tail {
            LogService.error(
                "Surrendered unparseable \(tail.count)-byte tail in \(filePath)",
                category: "ConversationParser"
            )
        }

        for lineData in framing.lines {
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                LogService.warn("Skipped malformed JSONL line in \(filePath)", category: "ConversationParser")
                continue
            }
            processLine(json, lineData: lineData, into: &result)
        }
        if case let .line(tailData) = framing.tail,
           let json = try? JSONSerialization.jsonObject(with: tailData) as? [String: Any] {
            processLine(json, lineData: tailData, into: &result)
        }

        return result
    }

    private static func processLine(_ json: [String: Any], lineData: Data, into result: inout ParseResult) {
        // 行级稳定 id:消息行的 uuid 优先;meta/summary 行没有 uuid,退到内容
        // 哈希。同一行重复解析得到同一 id,跨增量块的 id 也不会再撞。
        let lineID = (json["uuid"] as? String) ?? JSONLFramer.stableLineID(lineData)

        if isInterruptLine(json) {
            result.interrupted = true
            return
        }

        if isClearLine(json) {
            result.cleared = true
            result.messages = []
            return
        }

        if json["type"] as? String == "assistant",
           let message = json["message"] as? [String: Any] {
            if let usage = message["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
                result.inputTokens += input
                result.outputTokens += output
                result.cacheReadTokens += cacheRead
                result.cacheCreationTokens += cacheCreation
                result.lastContextTokens = input + cacheRead + cacheCreation
            }
            if let model = message["model"] as? String {
                result.lastModel = model
            }
        }

        if let message = parseMessage(json, lineID: lineID) {
            result.messages.append(message)
        }
    }

    // MARK: - Private

    private static func claudeProjectsDir(for cwd: String) -> String {
        let encoded = "-" + cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(
            of: "/",
            with: "-"
        )
        return NSString(string: "~/.claude/projects/\(encoded)").expandingTildeInPath
    }

    private static func parseMessage(_ json: [String: Any], lineID: String) -> ChatMessage? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "user": return parseUserMessage(json, lineID: lineID)
        case "assistant": return parseAssistantMessage(json, lineID: lineID)
        case "tool_result": return parseToolResult(json, lineID: lineID)
        default: return nil
        }
    }

    private static func parseUserMessage(_ json: [String: Any], lineID: String) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        let text = extractText(from: message)
        guard !text.isEmpty else { return nil }
        return ChatMessage(id: "user-\(lineID)", role: .user, content: text, timestamp: parseTimestamp(json) ?? Date())
    }

    private static func parseAssistantMessage(_ json: [String: Any], lineID: String) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        let text = extractText(from: message)

        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "tool_use",
                   let toolName = block["name"] as? String {
                    let input = block["input"]
                    let inputStr = input.flatMap { try? String(
                        data: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]),
                        encoding: .utf8
                    ) }
                    return ChatMessage(
                        id: "tool-\(lineID)",
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
        return ChatMessage(
            id: "assistant-\(lineID)",
            role: .assistant,
            content: text,
            timestamp: parseTimestamp(json) ?? Date()
        )
    }

    private static func parseToolResult(_ json: [String: Any], lineID: String) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        let content = message["content"]
        var text = ""
        if let str = content as? String { text = str }
        else if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text", let t = item["text"] as? String { text = t
                    break
                }
            }
        }
        guard !text.isEmpty else { return nil }
        return ChatMessage(
            id: "result-\(lineID)",
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
            return array.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return ""
    }

    private static func parseTimestamp(_ json: [String: Any]) -> Date? {
        guard let ts = json["timestamp"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: ts)
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
