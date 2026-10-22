import Foundation

/// Response sent from HookServer back to the hook-sender.sh shell script,
/// which echoes it to stdout for the CLI to parse. Wire format is JSON over
/// HTTP/1.1. Claude Code (>= 2.x) reads the permission decision from
/// `hookSpecificOutput.decision.behavior`; the legacy flat `{"decision":"allow"}`
/// shape is silently ignored, leaving the CLI blocked at its terminal prompt.
enum HookResponse: Codable, Equatable {
    case ack
    case decision(Decision)
    /// An AskUserQuestion answered: `allow` with `updatedInput` — the tool's
    /// input as it came plus an `answers` object (question text → answer).
    /// `updatedInput` replaces the whole input, so the original rides along
    /// in full; measured behavior in evlat's AskQuestion.swift (Claude Code
    /// 2.1.285): the terminal's dialog closes, free text passes through, a
    /// multi-select is labels joined by ", ", a question missing from
    /// `answers` reaches Claude unanswered.
    case answer(originalInput: String, answers: [String: String])

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

    /// The wire bytes. The answer case carries the caller's tool input as
    /// arbitrary JSON, which Codable cannot hold — it goes through
    /// JSONSerialization whole; every other case through Codable as before.
    func jsonData() throws -> Data {
        switch self {
        case .ack, .decision:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        case let .answer(originalInput, answers):
            var updated = (try? JSONSerialization.jsonObject(with: Data(originalInput.utf8))) as? [String: Any] ?? [:]
            updated["answers"] = answers
            let body: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": ["behavior": "allow", "updatedInput": updated],
                ],
            ]
            return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .answer:
            // The answer's payload holds the caller's arbitrary tool input;
            // it can only be encoded by `jsonData()`, which everything that
            // sends a response goes through.
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "HookResponse.answer goes through jsonData(), not Codable"
            ))
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
