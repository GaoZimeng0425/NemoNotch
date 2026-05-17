import Foundation

enum GeminiConversationParser: ConversationParserProtocol {
    struct ParseResult {
        let common: ParsedConversation
        let cachedTokens: Int
        let thoughtTokens: Int
        let lastContextTokens: Int
        let toolTokens: Int
        let totalTokens: Int
    }

    private struct GeminiSession: Codable {
        let sessionId: String?
        let messages: [GeminiMessage]?
    }

    private struct GeminiMessage: Codable {
        let id: String?
        let type: String?
        let content: ContentWrapper?
        let thoughts: [GeminiThought]?
        let toolCalls: [GeminiToolCall]?
        let tokens: GeminiTokens?
        let model: String?
    }

    private struct GeminiThought: Codable {
        let subject: String?
        let description: String?
    }

    private struct GeminiTokens: Codable {
        let input: Int?
        let output: Int?
        let cached: Int?
        let thoughts: Int?
        let tool: Int?
        let total: Int?
    }

    private struct GeminiToolCall: Codable {
        let id: String?
        let name: String?
        let result: [FunctionResponseWrapper]?
        let status: String?
        let displayName: String?
    }

    private struct FunctionResponseWrapper: Codable {
        let functionResponse: FunctionResponse?
    }

    private struct FunctionResponse: Codable {
        let response: FunctionResponseBody?
    }

    private struct FunctionResponseBody: Codable {
        let output: String?
    }

    private enum ContentWrapper: Codable {
        case string(String)
        case array([ContentItem])

        var text: String? {
            switch self {
            case let .string(s): return s
            case let .array(items): return items.first?.text
            }
        }

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                self = .string(s)
            } else if let arr = try? decoder.singleValueContainer().decode([ContentItem].self) {
                self = .array(arr)
            } else {
                self = .string("")
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .string(s): try s.encode(to: encoder)
            case let .array(items): try items.encode(to: encoder)
            }
        }
    }

    private struct ContentItem: Codable {
        let text: String?
    }

    // MARK: - ConversationParserProtocol

    static func findSessionFile(sessionId: String, cwd: String) -> String? {
        guard let projectName = projectName(for: cwd) else { return nil }
        let chatsDir = NSHomeDirectory() + "/.gemini/tmp/\(projectName)/chats"
        let shortId = String(sessionId.prefix(8))

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: chatsDir) else { return nil }
        // Prefer .jsonl if it exists, fallback to .json
        if let jsonlMatch = files
            .first(where: { $0.localizedCaseInsensitiveContains(shortId) && $0.hasSuffix(".jsonl") }) {
            return chatsDir + "/" + jsonlMatch
        }
        let jsonMatch = files.first { $0.localizedCaseInsensitiveContains(shortId) && $0.hasSuffix(".json") }
        return jsonMatch.map { chatsDir + "/" + $0 }
    }

    static func parseFull(filePath: String) -> ParsedConversation {
        if filePath.hasSuffix(".jsonl") {
            return parseIncrementalJSONL(filePath: filePath, fromOffset: 0).common
        }
        return parseDetailed(filePath: filePath)?.common ?? ParsedConversation()
    }

    // MARK: - Gemini-Specific

    struct IncrementalResult {
        var common: ParsedConversation
        var cachedTokens: Int
        var thoughtTokens: Int
        var lastContextTokens: Int
        var newOffset: UInt64
        var cleared: Bool
    }

    static func parseIncrementalJSONL(filePath: String, fromOffset: UInt64) -> IncrementalResult {
        var result = IncrementalResult(
            common: ParsedConversation(messages: [], inputTokens: 0, outputTokens: 0, lastModel: nil),
            cachedTokens: 0,
            thoughtTokens: 0,
            lastContextTokens: 0,
            newOffset: fromOffset,
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
        guard let text = String(data: data, encoding: .utf8) else { return result }

        result.newOffset = fromOffset + UInt64(data.count)

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            // Detect clear/compact
            if isClearLine(json) {
                result.cleared = true
                result.common.messages = []
                continue
            }

            if let type = json["type"] as? String {
                switch type {
                case "user":
                    if let msg = parseUserMessageLine(json) {
                        mergeOrAppend(msg, into: &result.common.messages)
                    }
                case "gemini":
                    // Parse thoughts first
                    if let thoughts = json["thoughts"] as? [[String: Any]] {
                        for (idx, thought) in thoughts.enumerated() {
                            let content = thought["description"] as? String ?? thought["subject"] as? String ?? ""
                            if !content.isEmpty {
                                let tId = (json["id"] as? String ?? UUID().uuidString) + "-thought-\(idx)"
                                let tMsg = ChatMessage(id: tId, role: .thought, content: content)
                                mergeOrAppend(tMsg, into: &result.common.messages)
                            }
                        }
                    }

                    if let msg = parseGeminiMessageLine(json, result: &result) {
                        mergeOrAppend(msg, into: &result.common.messages)
                    }
                case "info":
                    if let msg = parseInfoMessageLine(json) {
                        mergeOrAppend(msg, into: &result.common.messages)
                    }
                default: break
                }
            }
        }

        return result
    }

    private static func mergeOrAppend(_ message: ChatMessage, into messages: inout [ChatMessage]) {
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            // Merge: For now just replace with latest snapshot
            messages[idx] = message
        } else {
            messages.append(message)
        }
    }

    private static func parseUserMessageLine(_ json: [String: Any]) -> ChatMessage? {
        let content = extractTextFromLine(json)
        guard !content.isEmpty else { return nil }
        return ChatMessage(
            id: json["id"] as? String ?? UUID().uuidString,
            role: .user,
            content: content,
            timestamp: parseTimestampFromLine(json) ?? Date()
        )
    }

    private static func parseGeminiMessageLine(_ json: [String: Any], result: inout IncrementalResult) -> ChatMessage? {
        let content = extractTextFromLine(json)

        if let tokens = json["tokens"] as? [String: Any] {
            let input = tokens["input"] as? Int ?? 0
            let output = tokens["output"] as? Int ?? 0
            let cached = tokens["cached"] as? Int ?? 0
            let thoughts = tokens["thoughts"] as? Int ?? 0

            result.common.inputTokens += input
            result.common.outputTokens += output
            result.cachedTokens += cached
            result.thoughtTokens += thoughts

            // Current context size for progress bar
            result.lastContextTokens = input + cached
        }
        if let model = json["model"] as? String {
            result.common.lastModel = model
        }

        // Handle tool calls in JSONL
        if let toolCalls = json["toolCalls"] as? [[String: Any]] {
            for tc in toolCalls {
                let toolName = tc["name"] as? String
                let toolId = tc["id"] as? String ?? UUID().uuidString

                // Extract tool input
                let input = tc["input"].flatMap {
                    try? String(
                        data: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]),
                        encoding: .utf8
                    )
                }

                mergeOrAppend(ChatMessage(
                    id: toolId,
                    role: .tool,
                    content: tc["displayName"] as? String ?? toolName ?? "",
                    toolName: toolName,
                    toolInput: input,
                    timestamp: parseTimestampFromLine(json) ?? Date()
                ), into: &result.common.messages)

                if let results = tc["result"] as? [[String: Any]] {
                    let output = results.compactMap { res -> String? in
                        let funcRes = res["functionResponse"] as? [String: Any]
                        let response = funcRes?["response"] as? [String: Any]
                        return response?["output"] as? String
                    }.joined(separator: "\n")

                    if !output.isEmpty {
                        mergeOrAppend(ChatMessage(
                            id: toolId + "-result",
                            role: .toolResult,
                            content: String(output.prefix(500)),
                            toolName: toolName,
                            timestamp: parseTimestampFromLine(json) ?? Date()
                        ), into: &result.common.messages)
                    }
                }
            }
        }

        guard !content.isEmpty else { return nil }
        return ChatMessage(
            id: json["id"] as? String ?? UUID().uuidString,
            role: .assistant,
            content: content,
            timestamp: parseTimestampFromLine(json) ?? Date()
        )
    }

    private static func parseInfoMessageLine(_ json: [String: Any]) -> ChatMessage? {
        let content = extractTextFromLine(json)
        guard !content.isEmpty else { return nil }
        return ChatMessage(
            id: json["id"] as? String ?? UUID().uuidString,
            role: .system,
            content: content,
            timestamp: parseTimestampFromLine(json) ?? Date()
        )
    }

    private static func extractTextFromLine(_ json: [String: Any]) -> String {
        if let contentStr = json["content"] as? String { return contentStr }
        if let contentArr = json["content"] as? [[String: Any]] {
            return contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static func parseTimestampFromLine(_ json: [String: Any]) -> Date? {
        guard let ts = json["timestamp"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: ts)
    }

    private static func isClearLine(_ json: [String: Any]) -> Bool {
        if let type = json["type"] as? String, type == "user" {
            let text = extractTextFromLine(json)
            return text.contains("/clear") || text.contains("/compact")
        }
        return false
    }

    static func parseDetailed(filePath: String) -> ParseResult? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let session = try? JSONDecoder().decode(GeminiSession.self, from: data),
              let rawMessages = session.messages else {
            return nil
        }

        var messages: [ChatMessage] = []
        var inputTokens = 0, outputTokens = 0, cachedTokens = 0, thoughtTokens = 0, lastContextTokens = 0,
            toolTokens = 0, totalTokens = 0
        var lastModel: String?

        for msg in rawMessages {
            guard let type = msg.type else { continue }
            let msgId = msg.id ?? UUID().uuidString

            switch type {
            case "user":
                let text = msg.content?.text ?? ""
                mergeOrAppend(ChatMessage(
                    id: msgId,
                    role: .user,
                    content: text,
                    timestamp: Date()
                ), into: &messages)

            case "gemini":
                // Parse thoughts
                if let thoughts = msg.thoughts {
                    for (idx, thought) in thoughts.enumerated() {
                        let content = thought.description ?? thought.subject ?? ""
                        if !content.isEmpty {
                            let tId = msgId + "-thought-\(idx)"
                            mergeOrAppend(ChatMessage(id: tId, role: .thought, content: content), into: &messages)
                        }
                    }
                }

                let text = msg.content?.text ?? ""
                mergeOrAppend(ChatMessage(
                    id: msgId,
                    role: .assistant,
                    content: text,
                    timestamp: Date()
                ), into: &messages)

                if let tokens = msg.tokens {
                    let input = tokens.input ?? 0
                    let output = tokens.output ?? 0
                    let cached = tokens.cached ?? 0
                    let thoughts = tokens.thoughts ?? 0
                    let tool = tokens.tool ?? 0
                    let total = tokens.total ?? 0

                    inputTokens += input
                    outputTokens += output
                    cachedTokens += cached
                    thoughtTokens += thoughts
                    toolTokens += tool
                    totalTokens += total

                    lastContextTokens = input + cached
                }

                if let model = msg.model { lastModel = model }

                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        let toolId = tc.id ?? UUID().uuidString
                        mergeOrAppend(ChatMessage(
                            id: toolId,
                            role: .tool,
                            content: tc.displayName ?? tc.name ?? "",
                            toolName: tc.name,
                            timestamp: Date()
                        ), into: &messages)

                        let output = tc.result?
                            .compactMap { $0.functionResponse?.response?.output }
                            .joined(separator: "\n") ?? ""
                        if !output.isEmpty {
                            mergeOrAppend(ChatMessage(
                                id: toolId + "-result",
                                role: .toolResult,
                                content: String(output.prefix(500)),
                                toolName: tc.name,
                                timestamp: Date()
                            ), into: &messages)
                        }
                    }
                }

            case "info":
                let text = msg.content?.text ?? ""
                mergeOrAppend(ChatMessage(
                    id: msgId,
                    role: .system,
                    content: text,
                    timestamp: Date()
                ), into: &messages)

            default:
                break
            }
        }

        return ParseResult(
            common: ParsedConversation(
                messages: messages,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                lastModel: lastModel
            ),
            cachedTokens: cachedTokens,
            thoughtTokens: thoughtTokens,
            lastContextTokens: lastContextTokens,
            toolTokens: toolTokens,
            totalTokens: totalTokens
        )
    }

    // MARK: - Internal Helper

    static func projectName(for cwd: String) -> String? {
        let path = NSHomeDirectory() + "/.gemini/projects.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: String] else {
            return nil
        }
        return projects[cwd]
    }
}
