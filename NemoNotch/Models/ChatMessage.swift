import Foundation

enum ChatMessageRole: String, Codable {
    case user
    case assistant
    case thought
    case tool
    case toolResult
    case system
}

struct ChatMessage: Identifiable {
    let id: String
    let role: ChatMessageRole
    let content: String
    let toolName: String?
    let toolInput: String?
    let timestamp: Date
    /// Claude Code's `isMeta`: a user-role line the user did not type (skill
    /// bodies, command expansions, caveats, image placeholders).
    var isMeta = false

    init(
        id: String,
        role: ChatMessageRole,
        content: String,
        toolName: String? = nil,
        toolInput: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolInput = toolInput
        self.timestamp = timestamp
    }
}
