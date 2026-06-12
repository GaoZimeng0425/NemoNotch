import Foundation

/// One observed unit of work (an AI session or an agent) at a point in time.
struct CompletionCandidate: Equatable {
    /// Namespaced unique id, e.g. "ai:<sessionID>" or "agent:<agentID>".
    let key: String
    /// Human-facing name shown in the toast (project folder / agent name).
    let name: String
    /// True while the unit is doing work.
    let isActive: Bool
}

/// Detects active→idle transitions by diffing successive snapshots.
/// Pure value type — no actor isolation, no UI. The first `step` only
/// records a baseline, so units already active at startup never false-fire.
struct CompletionDetector {
    private var prior: [String: Bool] = [:]

    /// Returns the names of units that went active→idle since the last call.
    /// A unit that disappears (e.g. session removed) is dropped, not reported.
    mutating func step(_ candidates: [CompletionCandidate]) -> [String] {
        var completed: [String] = []
        var next: [String: Bool] = [:]
        for candidate in candidates {
            next[candidate.key] = candidate.isActive
            if prior[candidate.key] == true, !candidate.isActive {
                completed.append(candidate.name)
            }
        }
        prior = next
        return completed
    }
}

/// Name-list helpers for the toast.
enum CompletionFlashNames {
    /// Append `new` names to `existing`, skipping duplicates, preserving order.
    static func merge(existing: [String], new: [String]) -> [String] {
        var result = existing
        for name in new where !result.contains(name) {
            result.append(name)
        }
        return result
    }
}
