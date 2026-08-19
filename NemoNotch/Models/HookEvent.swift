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
    let model: String?
    /// PID of the CLI process that emitted the hook (bash's `$PPID` in
    /// hook-sender.sh). Used to walk up to the hosting terminal/IDE app so a
    /// session can jump back to it. Absent for plugin-based emitters
    /// (opencode's TS plugin has no shell parent to report).
    let cliPID: Int?

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
        model = try container.decodeIfPresent(String.self, forKey: .model)
        // Tolerant on purpose: a foreign emitter may send a non-numeric value
        // here, and one bad field must not drop the whole event.
        cliPID = (try? container.decodeIfPresent(Int.self, forKey: .cliPID)) ?? nil
    }

    init(
        hookEventName: String,
        sessionId: String? = nil,
        toolName: String? = nil,
        toolUseId: String? = nil,
        message: String? = nil,
        cwd: String? = nil,
        source: String? = nil,
        cliSource: String? = nil,
        model: String? = nil,
        cliPID: Int? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.message = message
        self.cwd = cwd
        self.source = source
        self.cliSource = cliSource
        self.model = model
        self.cliPID = cliPID
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
        case model
        case cliPID = "cli_pid"
    }
}
