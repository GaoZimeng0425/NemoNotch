import Foundation

enum GeminiConversationParser: ConversationParserProtocol {

    struct ParseResult {
        let common: ParsedConversation
        let cachedTokens: Int
        let thoughtTokens: Int
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
        let toolCalls: [GeminiToolCall]?
        let tokens: GeminiTokens?
        let model: String?
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
            case .string(let s): return s
            case .array(let items): return items.first?.text
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
            case .string(let s): try s.encode(to: encoder)
            case .array(let items): try items.encode(to: encoder)
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
        let match = files.first { $0.localizedCaseInsensitiveContains(shortId) && $0.hasSuffix(".json") }
        return match.map { chatsDir + "/" + $0 }
    }

    static func parseFull(filePath: String) -> ParsedConversation {
        parseDetailed(filePath: filePath)?.common ?? ParsedConversation()
    }

    // MARK: - Gemini-Specific

    static func parseDetailed(filePath: String) -> ParseResult? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let session = try? JSONDecoder().decode(GeminiSession.self, from: data),
              let rawMessages = session.messages else {
            return nil
        }

        var messages: [ChatMessage] = []
        var inputTokens = 0, outputTokens = 0, cachedTokens = 0, thoughtTokens = 0, toolTokens = 0, totalTokens = 0
        var lastModel: String?

        for msg in rawMessages {
            guard let type = msg.type else { continue }

            switch type {
            case "user":
                let text = msg.content?.text ?? ""
                messages.append(ChatMessage(
                    id: msg.id ?? UUID().uuidString,
                    role: .user,
                    content: text,
                    toolName: nil,
                    toolInput: nil,
                    timestamp: Date()
                ))

            case "gemini":
                let text = msg.content?.text ?? ""
                messages.append(ChatMessage(
                    id: msg.id ?? UUID().uuidString,
                    role: .assistant,
                    content: text,
                    toolName: nil,
                    toolInput: nil,
                    timestamp: Date()
                ))

                if let tokens = msg.tokens {
                    inputTokens += tokens.input ?? 0
                    outputTokens += tokens.output ?? 0
                    cachedTokens += tokens.cached ?? 0
                    thoughtTokens += tokens.thoughts ?? 0
                    toolTokens += tokens.tool ?? 0
                    totalTokens += tokens.total ?? 0
                }

                if let model = msg.model { lastModel = model }

                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        messages.append(ChatMessage(
                            id: tc.id ?? UUID().uuidString,
                            role: .tool,
                            content: tc.displayName ?? tc.name ?? "",
                            toolName: tc.name,
                            toolInput: nil,
                            timestamp: Date()
                        ))

                        let output = tc.result?
                            .compactMap { $0.functionResponse?.response?.output }
                            .joined(separator: "\n") ?? ""
                        messages.append(ChatMessage(
                            id: (tc.id ?? UUID().uuidString) + "-result",
                            role: .toolResult,
                            content: String(output.prefix(500)),
                            toolName: tc.name,
                            toolInput: nil,
                            timestamp: Date()
                        ))
                    }
                }

            case "info":
                let text: String
                if let wrapper = msg.content {
                    text = wrapper.text ?? ""
                } else {
                    text = ""
                }
                messages.append(ChatMessage(
                    id: msg.id ?? UUID().uuidString,
                    role: .system,
                    content: text,
                    toolName: nil,
                    toolInput: nil,
                    timestamp: Date()
                ))

            default:
                break
            }
        }

        return ParseResult(
            common: ParsedConversation(messages: messages, inputTokens: inputTokens, outputTokens: outputTokens, lastModel: lastModel),
            cachedTokens: cachedTokens,
            thoughtTokens: thoughtTokens,
            toolTokens: toolTokens,
            totalTokens: totalTokens
        )
    }

    // MARK: - Private

    private static func projectName(for cwd: String) -> String? {
        let path = NSHomeDirectory() + "/.gemini/projects.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: String] else {
            return nil
        }
        return projects[cwd]
    }
}
