import Foundation

enum HermesConversationParser: ConversationParserProtocol {
    // MARK: - ConversationParserProtocol

    static func findSessionFile(sessionId: String, cwd: String) -> String? {
        let hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        let fm = FileManager.default

        // Default profile
        let defaultPath = "\(hermesDir)/sessions/session_\(sessionId).json"
        if fm.fileExists(atPath: defaultPath) { return defaultPath }

        // Named profiles
        let profilesDir = "\(hermesDir)/profiles"
        guard let profiles = try? fm.contentsOfDirectory(atPath: profilesDir) else { return nil }
        for name in profiles {
            let path = "\(profilesDir)/\(name)/sessions/session_\(sessionId).json"
            if fm.fileExists(atPath: path) { return path }
        }

        return nil
    }

    static func parseFull(filePath: String) -> ParsedConversation {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedConversation()
        }

        guard let rawMessages = json["messages"] as? [[String: Any]] else {
            return ParsedConversation(lastModel: json["model"] as? String)
        }

        var messages: [ChatMessage] = []
        for (index, msg) in rawMessages.enumerated() {
            guard let role = msg["role"] as? String else { continue }
            switch role {
            case "user":
                if let m = parseUserMessage(msg, index: index) { messages.append(m) }
            case "assistant":
                if let m = parseAssistantMessage(msg, index: index) { messages.append(m) }
            case "tool":
                if let m = parseToolMessage(msg, index: index) { messages.append(m) }
            default:
                break
            }
        }

        return ParsedConversation(
            messages: messages,
            lastModel: json["model"] as? String
        )
    }

    // MARK: - Session Discovery

    /// Scan all profile directories for session files, returning (path, sessionId) pairs.
    static func findAllSessionFiles() -> [(path: String, sessionId: String)] {
        let hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        let fm = FileManager.default
        var results: [(path: String, sessionId: String)] = []

        func scanDirectory(_ dir: String) {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for file in files where file.hasPrefix("session_") && file.hasSuffix(".json") {
                let sessionId = String(file.dropFirst("session_".count).dropLast(".json".count))
                results.append((path: "\(dir)/\(file)", sessionId: sessionId))
            }
        }

        // Default profile
        scanDirectory("\(hermesDir)/sessions")

        // Named profiles
        let profilesDir = "\(hermesDir)/profiles"
        if let profiles = try? fm.contentsOfDirectory(atPath: profilesDir) {
            for name in profiles {
                scanDirectory("\(profilesDir)/\(name)/sessions")
            }
        }

        return results
    }

    /// Quick-read the message_count from a session file without full parsing.
    static func readMessageCount(filePath: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["message_count"] as? Int
    }

    // MARK: - Private Parsing

    private static func parseUserMessage(_ msg: [String: Any], index: Int) -> ChatMessage? {
        guard let content = msg["content"] as? String, !content.isEmpty else { return nil }
        return ChatMessage(
            id: "hermes-user-\(index)",
            role: .user,
            content: content,
            timestamp: parseTimestamp(msg) ?? Date()
        )
    }

    private static func parseAssistantMessage(_ msg: [String: Any], index: Int) -> ChatMessage? {
        let content = msg["content"] as? String ?? ""
        let reasoning = msg["reasoning"] as? String
        let finishReason = msg["finish_reason"] as? String
        let toolCalls = msg["tool_calls"] as? [[String: Any]]

        // Has tool calls
        if finishReason == "tool_calls", let firstTool = toolCalls?.first,
           let function = firstTool["function"] as? [String: Any],
           let toolName = function["name"] as? String {
            let toolInput = function["arguments"] as? String
            return ChatMessage(
                id: "hermes-tool-\(index)",
                role: .assistant,
                content: content.isEmpty ? "Using \(toolName)" : content,
                toolName: toolName,
                toolInput: toolInput,
                timestamp: parseTimestamp(msg) ?? Date()
            )
        }

        // Regular assistant message
        var displayContent = content
        if let reasoning, !reasoning.isEmpty {
            displayContent = "> \(reasoning.prefix(200))\n\(content)"
        }
        guard !displayContent.isEmpty else { return nil }
        return ChatMessage(
            id: "hermes-assistant-\(index)",
            role: .assistant,
            content: displayContent,
            timestamp: parseTimestamp(msg) ?? Date()
        )
    }

    private static func parseToolMessage(_ msg: [String: Any], index: Int) -> ChatMessage? {
        guard let content = msg["content"] as? String else { return nil }

        // Try to extract a summary from JSON content
        let summary = summarizeToolContent(content)

        return ChatMessage(
            id: "hermes-result-\(index)",
            role: .toolResult,
            content: String(summary.prefix(500)),
            timestamp: parseTimestamp(msg) ?? Date()
        )
    }

    /// Extract key fields from tool result JSON string for display.
    private static func summarizeToolContent(_ content: String) -> String {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return content
        }

        // Check for success/error pattern
        if let success = json["success"] as? Bool {
            if success {
                if let results = json["results"] {
                    return "success - \(results)"
                }
                return "success"
            } else {
                return "error: \(json["error"] as? String ?? content)"
            }
        }

        // Fallback: compact JSON
        if let compact = try? String(
            data: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
            encoding: .utf8
        ) {
            return String(compact.prefix(200))
        }

        return content
    }

    private static func parseTimestamp(_ msg: [String: Any]) -> Date? {
        guard let ts = msg["timestamp"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: ts)
    }
}
