import Foundation

struct HookEvent: Codable {
    let hookEventName: String
    let sessionId: String?
    let toolName: String?
    let toolUseId: String?
    let message: String?
    let cwd: String?
    let source: String?
    let cliSource: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case toolName = "tool_name"
        case toolUseId = "tool_use_id"
        case message
        case cwd
        case source
        case cliSource = "cli_source"
    }
}
