import Foundation

/// Decodes any JSON value and stringifies it — used for `message`, which
/// emitters disagree on (string vs object/array).
private struct FlexibleString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let n = try? container.decode(Double.self) {
            value = n == n.rounded() ? String(Int(n)) : String(n)
        } else if let b = try? container.decode(Bool.self) {
            value = String(b)
        } else if let arr = try? container.decode([FlexibleString].self) {
            value = arr.compactMap(\.value).joined(separator: "\n")
        } else if let obj = try? container.decode([String: FlexibleString].self) {
            value = obj.sorted(by: { $0.key < $1.key })
                .compactMap { "\($0.key): \($0.value.value ?? "")" }
                .joined(separator: "\n")
        } else {
            value = nil
        }
    }
}

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
        // Claude/zcode deliver `message` as a plain string, but some emitters
        // (zcode's Stop) send the assistant message as a JSON object — keep the
        // event alive by stringifying whatever shape arrives.
        message = (try? container.decodeIfPresent(FlexibleString.self, forKey: .message))?.value
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
