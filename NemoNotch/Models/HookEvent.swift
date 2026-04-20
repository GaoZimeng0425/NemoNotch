import Foundation

struct HookEvent: Codable {
    let hookEventName: String
    let sessionId: String?
    let toolName: String?
    let message: String?
    let cwd: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case toolName = "tool_name"
        case message
        case cwd
        case source
    }
}
