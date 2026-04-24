import Foundation

struct HookEvent: Codable, Sendable {
    let hookEventName: String
    let sessionId: String?
    let toolName: String?
    let toolUseId: String?
    let message: String?
    let cwd: String?
    let source: String?
    let cliSource: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hookEventName = try container.decode(String.self, forKey: .hookEventName)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        cliSource = try container.decodeIfPresent(String.self, forKey: .cliSource)
    }

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
