import Foundation

/// Response sent from HookServer back to the hook-sender.sh shell script,
/// which echoes it to stdout for the CLI to parse. Wire format is JSON over
/// HTTP/1.1. Claude Code (>= 2.x) reads the permission decision from
/// `hookSpecificOutput.decision.behavior`; the legacy flat `{"decision":"allow"}`
/// shape is silently ignored, leaving the CLI blocked at its terminal prompt.
enum HookResponse: Codable, Equatable {
    case ack
    case decision(Decision)

    enum Decision: Codable, Equatable {
        case allow
        case deny(reason: DenyReason?)
    }

    /// Stable string values consumed by hook-sender.sh — do not rename without
    /// updating the shell script in lockstep.
    enum DenyReason: String, Codable {
        case timeout
        case sessionEnded = "session ended"
        case noSessionId = "no session id"
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .ack:
            var container = encoder.container(keyedBy: AckKeys.self)
            try container.encode("ok", forKey: .status)
        case let .decision(decision):
            var root = encoder.container(keyedBy: RootKeys.self)
            var output = root.nestedContainer(
                keyedBy: HookSpecificOutputKeys.self,
                forKey: .hookSpecificOutput
            )
            try output.encode("PermissionRequest", forKey: .hookEventName)
            var decisionContainer = output.nestedContainer(
                keyedBy: DecisionKeys.self,
                forKey: .decision
            )
            switch decision {
            case .allow:
                try decisionContainer.encode("allow", forKey: .behavior)
            case let .deny(reason):
                try decisionContainer.encode("deny", forKey: .behavior)
                if let reason {
                    try decisionContainer.encode(reason.rawValue, forKey: .message)
                }
            }
        }
    }

    init(from decoder: Decoder) throws {
        // Decoding is not exercised in this codebase — shell script only emits
        // requests, not responses. Provide a minimal stub so Codable compiles.
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "HookResponse is encode-only"
        ))
    }

    private enum AckKeys: String, CodingKey { case status }
    private enum RootKeys: String, CodingKey { case hookSpecificOutput }
    private enum HookSpecificOutputKeys: String, CodingKey { case hookEventName, decision }
    private enum DecisionKeys: String, CodingKey { case behavior, message }
}
