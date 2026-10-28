import Foundation

/// Which application/subsystem a completion came from — drives the leading
/// logo in the toast so the user can tell a Claude Code turn from a Gemini one.
enum CompletionSource: Equatable, Hashable {
    case ai(AISource) // Claude Code / Gemini / opencode
    case agent // OpenClaw / Hermes multi-agent monitors
    case pomodoro // Pomodoro phase end
    case calendar // Calendar event due
}

/// A finished unit of work: the name shown in the toast plus its source logo,
/// and optional rich detail (task title, last tool, model, tokens, duration)
/// carried through from the AI session that completed.
struct CompletionItem: Equatable {
    let name: String
    let source: CompletionSource
    var subtitle: String?
    var tool: String?
    var model: String?
    var tokenDisplay: String?
    var duration: TimeInterval?
    /// Working directory the session ran in (AI sessions only).
    var path: String?

    /// Convenience for callers that only have name + source (Pomodoro, multi-item merges).
    init(name: String, source: CompletionSource) {
        self.name = name
        self.source = source
        subtitle = nil
        tool = nil
        model = nil
        tokenDisplay = nil
        duration = nil
        path = nil
    }

    init(
        name: String,
        source: CompletionSource,
        subtitle: String?,
        tool: String?,
        model: String?,
        tokenDisplay: String?,
        duration: TimeInterval?,
        path: String? = nil
    ) {
        self.name = name
        self.source = source
        self.subtitle = subtitle
        self.tool = tool
        self.model = model
        self.tokenDisplay = tokenDisplay
        self.duration = duration
        self.path = path
    }
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
    /// Optional rich detail snapshot at the moment of completion.
    var subtitle: String?
    var tool: String?
    var model: String?
    var tokenDisplay: String?
    var duration: TimeInterval?
    /// Working directory the session ran in (AI sessions only).
    var path: String?

    /// Convenience for callers that only have the identity fields.
    init(key: String, name: String, isActive: Bool, source: CompletionSource) {
        self.key = key
        self.name = name
        self.isActive = isActive
        self.source = source
        subtitle = nil
        tool = nil
        model = nil
        tokenDisplay = nil
        duration = nil
        path = nil
    }

    init(
        key: String,
        name: String,
        isActive: Bool,
        source: CompletionSource,
        subtitle: String?,
        tool: String?,
        model: String?,
        tokenDisplay: String?,
        duration: TimeInterval?,
        path: String? = nil
    ) {
        self.key = key
        self.name = name
        self.isActive = isActive
        self.source = source
        self.subtitle = subtitle
        self.tool = tool
        self.model = model
        self.tokenDisplay = tokenDisplay
        self.duration = duration
        self.path = path
    }
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
                completed.append(CompletionItem(
                    name: candidate.name,
                    source: candidate.source,
                    subtitle: candidate.subtitle,
                    tool: candidate.tool,
                    model: candidate.model,
                    tokenDisplay: candidate.tokenDisplay,
                    duration: candidate.duration,
                    path: candidate.path
                ))
            }
        }
        prior = next
        return completed
    }
}

/// How a completion's working directory reads on the toast card.
enum CompletionPath {
    /// `path` with the home directory folded to `~`; nil for empty paths.
    static func display(_ path: String?, home: String = NSHomeDirectory()) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if !trimmedHome.isEmpty, path == trimmedHome || path.hasPrefix(trimmedHome + "/") {
            return "~" + path.dropFirst(trimmedHome.count)
        }
        return path
    }
}

/// Item-list helpers for the toast.
enum CompletionFlashNames {
    /// Append `new` items to `existing`, skipping duplicate names, preserving order.
    /// When a `new` item matches an existing name, its non-nil rich fields overwrite
    /// the existing item's fields (newer data wins); nil fields leave existing values.
    static func merge(existing: [CompletionItem], new: [CompletionItem]) -> [CompletionItem] {
        var result = existing
        for item in new {
            if let idx = result.firstIndex(where: { $0.name == item.name }) {
                // Field-level merge: newer non-nil values win.
                if let v = item.subtitle {
                    result[idx].subtitle = v
                }
                if let v = item.tool {
                    result[idx].tool = v
                }
                if let v = item.model {
                    result[idx].model = v
                }
                if let v = item.tokenDisplay {
                    result[idx].tokenDisplay = v
                }
                if let v = item.duration {
                    result[idx].duration = v
                }
                if let v = item.path {
                    result[idx].path = v
                }
            } else {
                result.append(item)
            }
        }
        return result
    }
}
