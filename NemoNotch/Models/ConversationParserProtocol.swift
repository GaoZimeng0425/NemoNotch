import Foundation

/// Common parsed conversation data produced by all AI providers.
struct ParsedConversation {
    let messages: [ChatMessage]
    let inputTokens: Int
    let outputTokens: Int
    let lastModel: String?

    init(messages: [ChatMessage] = [], inputTokens: Int = 0, outputTokens: Int = 0, lastModel: String? = nil) {
        self.messages = messages
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.lastModel = lastModel
    }
}

/// Contract for AI CLI conversation file parsers.
///
/// Each provider (Claude, Gemini, etc.) implements this protocol for its specific
/// file format and directory layout, while exposing a common interface for file
/// discovery and basic parsing. Provider-specific details (extra token types,
/// incremental parsing, interrupt detection) live in each parser's own result type.
protocol ConversationParserProtocol {
    /// Locate the conversation file for a session within a working directory.
    static func findSessionFile(sessionId: String, cwd: String) -> String?

    /// Parse the full conversation, returning common fields.
    static func parseFull(filePath: String) -> ParsedConversation
}
