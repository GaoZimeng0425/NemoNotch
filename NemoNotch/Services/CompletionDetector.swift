import Foundation

/// Which application/subsystem a completion came from — drives the leading
/// logo in the toast so the user can tell a Claude Code turn from a Gemini one.
enum CompletionSource: Equatable, Hashable {
    case ai(AISource) // Claude Code / Gemini / opencode
    case agent // OpenClaw / Hermes multi-agent monitors
    case pomodoro // Pomodoro phase end
}

/// A finished unit of work: the name shown in the toast plus its source logo.
struct CompletionItem: Equatable {
    let name: String
    let source: CompletionSource
}

/// One observed unit of work (an AI session or an agent) at a point in time.
struct CompletionCandidate: Equatable {
    /// Namespaced unique id, e.g. "ai:<sessionID>" or "agent:<agentID>".
    let key: String
    /// Human-facing name shown in the toast (project folder / agent name).
    let name: String
    /// True while the unit is doing work.
    let isActive: Bool
    /// Source application/subsystem — carried through to the toast logo.
    let source: CompletionSource
}

/// Detects active→idle transitions by diffing successive snapshots.
/// Pure value type — no actor isolation, no UI. The first `step` only
/// records a baseline, so units already active at startup never false-fire.
struct CompletionDetector {
    private var prior: [String: Bool] = [:]

    /// Returns the units that went active→idle since the last call.
    /// A unit that disappears (e.g. session removed) is dropped, not reported.
    mutating func step(_ candidates: [CompletionCandidate]) -> [CompletionItem] {
        var completed: [CompletionItem] = []
        var next: [String: Bool] = [:]
        for candidate in candidates {
            next[candidate.key] = candidate.isActive
            if prior[candidate.key] == true, !candidate.isActive {
                completed.append(CompletionItem(name: candidate.name, source: candidate.source))
            }
        }
        prior = next
        return completed
    }
}

/// Item-list helpers for the toast.
enum CompletionFlashNames {
    /// Append `new` items to `existing`, skipping duplicate names, preserving order.
    static func merge(existing: [CompletionItem], new: [CompletionItem]) -> [CompletionItem] {
        var result = existing
        for item in new where !result.contains(where: { $0.name == item.name }) {
            result.append(item)
        }
        return result
    }
}
