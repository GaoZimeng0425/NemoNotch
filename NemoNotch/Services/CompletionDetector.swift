import Foundation

/// Which application/subsystem a completion came from — drives the leading
/// logo in the toast so the user can tell a Claude Code turn from a Gemini one.
enum CompletionSource: Equatable, Hashable {
    case ai(AISource) // Claude Code / Gemini / opencode
    case agent // OpenClaw / Hermes multi-agent monitors
    case pomodoro // Pomodoro phase end
    case calendar // Calendar event due
    case notification(bundleID: String) // Notification Center message (Mail / Slack / WeChat …)
}

/// The session's host app as `AppActivator.activate` takes it: tab link →
/// pid → bundle id, each optional.
struct CompletionJump: Equatable {
    let hostPID: Int32?
    let hostBundleId: String?
    let tabLink: String?

    /// nil when there is nothing to jump to.
    static func make(hostPID: Int32?, hostBundleId: String?, tabLink: String?) -> CompletionJump? {
        guard hostPID != nil || hostBundleId != nil || tabLink != nil else { return nil }
        return CompletionJump(hostPID: hostPID, hostBundleId: hostBundleId, tabLink: tabLink)
    }
}

/// A finished unit of work: the name shown in the toast plus its source logo,
/// and optional rich detail (task title, last tool, model, tokens, duration)
/// carried through from the AI session that completed.
struct CompletionItem: Equatable {
    /// The unit that finished — the candidate key ("ai:<sessionID>" /
    /// "agent:<agentID>"). nil for sources with no session (Pomodoro, calendar).
    var key: String?
    let name: String
    let source: CompletionSource
    var subtitle: String?
    var tool: String?
    var model: String?
    var tokenDisplay: String?
    var duration: TimeInterval?
    /// Working directory the session ran in (AI sessions only).
    var path: String?
    /// Where a click on the card jumps (AI sessions only), snapshotted at
    /// completion so it still works after the session itself is reaped.
    var jump: CompletionJump?
    /// Card text for a Notification Center card (`.notification` source only).
    var notice: NotificationCard?

    /// Convenience for callers that only have name + source (Pomodoro, multi-item merges).
    init(name: String, source: CompletionSource) {
        key = nil
        self.name = name
        self.source = source
        subtitle = nil
        tool = nil
        model = nil
        tokenDisplay = nil
        duration = nil
        path = nil
        jump = nil
        notice = nil
    }

    init(
        name: String,
        source: CompletionSource,
        subtitle: String?,
        tool: String?,
        model: String?,
        tokenDisplay: String?,
        duration: TimeInterval?,
        path: String? = nil,
        jump: CompletionJump? = nil
    ) {
        key = nil
        self.name = name
        self.source = source
        self.subtitle = subtitle
        self.tool = tool
        self.model = model
        self.tokenDisplay = tokenDisplay
        self.duration = duration
        self.path = path
        self.jump = jump
        notice = nil
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
    /// Where a click on the card jumps (AI sessions only), snapshotted at
    /// completion so it still works after the session itself is reaped.
    var jump: CompletionJump?

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
        jump = nil
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
        path: String? = nil,
        jump: CompletionJump? = nil
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
        self.jump = jump
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
                var item = CompletionItem(
                    name: candidate.name,
                    source: candidate.source,
                    subtitle: candidate.subtitle,
                    tool: candidate.tool,
                    model: candidate.model,
                    tokenDisplay: candidate.tokenDisplay,
                    duration: candidate.duration,
                    path: candidate.path,
                    jump: candidate.jump
                )
                item.key = candidate.key
                completed.append(item)
            }
        }
        prior = next
        return completed
    }
}

extension CompletionItem {
    /// What makes two completions "the same card": the session/agent when
    /// known, else the name (session-less sources such as Pomodoro).
    var toastKey: String {
        key ?? "name:\(name)"
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
    /// Append `new` items to `existing`, one per `toastKey` (session/agent,
    /// else name), preserving order. When a `new` item matches an existing
    /// key it replaces it — name included, since a session's folder or title
    /// can change between turns — but a nil rich field keeps the older value.
    static func merge(existing: [CompletionItem], new: [CompletionItem]) -> [CompletionItem] {
        var result = existing
        for item in new {
            if let idx = result.firstIndex(where: { $0.toastKey == item.toastKey }) {
                var merged = item
                let older = result[idx]
                merged.subtitle = item.subtitle ?? older.subtitle
                merged.tool = item.tool ?? older.tool
                merged.model = item.model ?? older.model
                merged.tokenDisplay = item.tokenDisplay ?? older.tokenDisplay
                merged.duration = item.duration ?? older.duration
                merged.path = item.path ?? older.path
                merged.jump = item.jump ?? older.jump
                result[idx] = merged
            } else {
                result.append(item)
            }
        }
        return result
    }
}
