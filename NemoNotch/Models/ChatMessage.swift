import Foundation

enum ChatMessageRole: String, Codable {
    case user
    case assistant
    case tool
    case toolResult
    case system
}

struct ChatMessage: Identifiable, Sendable {
    let id: String
    let role: ChatMessageRole
    let content: String
    let toolName: String?
    let toolInput: String?
    let timestamp: Date

    init(id: String, role: ChatMessageRole, content: String, toolName: String? = nil, toolInput: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolInput = toolInput
        self.timestamp = timestamp
    }
}
