import Foundation

/// Response sent from HookServer back to the hook-sender.sh shell script.
/// Wire format is JSON over HTTP/1.1; shapes must stay byte-stable so the
/// shell-side parser (jq-based) continues to work.
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
            var container = encoder.container(keyedBy: DecisionKeys.self)
            switch decision {
            case .allow:
                try container.encode("allow", forKey: .decision)
            case let .deny(reason):
                try container.encode("deny", forKey: .decision)
                if let reason {
                    try container.encode(reason.rawValue, forKey: .reason)
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
    private enum DecisionKeys: String, CodingKey { case decision, reason }
}
