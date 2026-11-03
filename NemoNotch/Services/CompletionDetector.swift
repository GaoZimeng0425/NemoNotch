import Foundation

/// Which application/subsystem a completion came from — drives the leading
/// logo in the toast so the user can tell a Claude Code turn from a Gemini one.
enum CompletionSource: Equatable, Hashable {
    case ai(AISource) // Claude Code / Gemini / opencode
    case agent // OpenClaw / Hermes multi-agent monitors
    case calendar // Calendar event due
    case notification(bundleID: String) // Notification Center message (Mail / Slack / WeChat …)
    /// External app push (`POST /v1/toast`): the caller's SF Symbol name when
    /// it sent a valid `sf:<name>` icon, else nil for the generic mark.
    case external(iconSymbol: String?)
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
    /// "agent:<agentID>"). nil for sources with no session (calendar).
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
    /// Time/place and link lines for a calendar-due card (`.calendar` source only).
    var calendar: CalendarCard?
    /// Whole card face for an external-app push (`.external` source only).
    var external: ExternalCardContent?
    /// What happened in the lifecycle — drives the card's wording, ring and
    /// glow color. nil keeps the legacy multi-color ring for sources with no
    /// lifecycle (calendar / notification / external).
    var kind: ReminderKind?
    /// Attention cards never expire on their own: they leave with the wait
    /// they announced (answered / bridge timeout / answered in terminal).
    var sticky: Bool

    /// Convenience for callers that only have name + source (multi-item merges).
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
        calendar = nil
        external = nil
        kind = nil
        sticky = false
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
        calendar = nil
        external = nil
        kind = nil
        sticky = false
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
    /// The attention kind while parked on the user (a waiting-for-approval
    /// snapshot); nil otherwise. Feeds `AttentionDetector`.
    var attentionKind: ReminderKind?
    /// What a completion of this unit reports — turnDone by default; the
    /// snapshot labels a Stop-less demote/reap `sessionLost`.
    var completesAs: ReminderKind
    /// True while a multi-agent's state is `.error`: a completion that
    /// follows an error reports `agentError`, not a green turnDone.
    var wasError: Bool

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
        attentionKind = nil
        completesAs = .turnDone
        wasError = false
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
        attentionKind = nil
        completesAs = .turnDone
        wasError = false
    }
}

/// Detects active→idle transitions by diffing successive snapshots, and the
/// vanishings of units that were still working (no Stop ever came →
/// `sessionLost`). Pure value type — no actor isolation, no UI. The first
/// `step` only records a baseline, so units already active at startup never
/// false-fire.
struct CompletionDetector {
    /// What the detector remembers about one unit between snapshots.
    private struct PriorState {
        var active: Bool
        var error: Bool
        /// Identity for a disappearance card: the unit is gone, so the card
        /// can only speak in the skeleton it last showed.
        var skeleton: CompletionItem
    }

    private var prior: [String: PriorState] = [:]

    /// Returns the units that went active→idle since the last call, and the
    /// units that vanished while still active (`sessionLost`). A unit that
    /// was already idle and then disappears is dropped, not reported.
    mutating func step(_ candidates: [CompletionCandidate]) -> [CompletionItem] {
        var completed: [CompletionItem] = []
        var next: [String: PriorState] = [:]
        for candidate in candidates {
            next[candidate.key] = PriorState(
                active: candidate.isActive,
                error: candidate.wasError,
                skeleton: Self.skeleton(of: candidate)
            )
            guard let before = prior[candidate.key], before.active, !candidate.isActive else {
                continue
            }
            var item = Self.skeleton(of: candidate)
            // An agent that sat in `.error` before going quiet reports a
            // failure, not a green "done".
            item.kind = before.error ? .agentError : candidate.completesAs
            completed.append(item)
        }
        // Vanished while still working: report `sessionLost` in the last
        // skeleton. Sorted by key so the batch order is deterministic.
        for key in prior.keys.filter({ next[$0] == nil }).sorted()
            where prior[key]!.active {
            var lost = prior[key]!.skeleton
            lost.key = key
            lost.kind = .sessionLost
            completed.append(lost)
        }
        prior = next
        return completed
    }

    /// The identity fields a card can show without the unit being around
    /// anymore: everything else left with the unit.
    private static func skeleton(of candidate: CompletionCandidate) -> CompletionItem {
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
        return item
    }
}

/// Detects entries into and exits from "parked on the user"
/// (waiting-for-approval). An arrival fires once per wait — an approval
/// context changing must not replay the arrival gesture, the same
/// coarseness `RingKind` uses for the edge bar ring — and the wait ends by
/// the phase leaving OR the unit vanishing, both reported as a retraction.
/// Pure value type; the service turns arrivals/retractions into cards.
struct AttentionDetector {
    typealias Entry = (key: String, attention: ReminderKind?)

    private var waiting: [String: ReminderKind] = [:]

    mutating func step(_ entries: [Entry]) -> (arrived: [(key: String, kind: ReminderKind)], retracted: [String]) {
        var next: [String: ReminderKind] = [:]
        var arrived: [(key: String, kind: ReminderKind)] = []
        for entry in entries {
            guard let kind = entry.attention else { continue }
            if waiting[entry.key] == nil {
                arrived.append((entry.key, kind))
            }
            next[entry.key] = kind
        }
        // A wait ends by attention clearing OR the unit vanishing — both
        // leave the key absent from `next`. Sorted for determinism.
        let retracted = waiting.keys.filter { next[$0] == nil }.sorted()
        waiting = next
        return (arrived, retracted)
    }
}

extension CompletionItem {
    /// What makes two completions "the same card": the session/agent when
    /// known, else the name (session-less sources such as calendar).
    var toastKey: String {
        key ?? "name:\(name)"
    }

    /// The session id inside an `ai:` / `ask:` / `fail:` key — the three card
    /// identities one session can hold. nil for agent / calendar / external
    /// keys: a failure card must only ever displace its OWN session's cards.
    var sessionKey: String? {
        guard let key else { return nil }
        for prefix in ["ai:", "ask:", "fail:"] where key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return nil
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
    /// External items are the exception for `jump`: they replace it whole,
    /// so a keyed re-push without `jumpBundleId` / `jumpURL` clears the jump target.
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
                if case .external = item.source {
                    merged.jump = item.jump
                } else {
                    merged.jump = item.jump ?? older.jump
                }
                result[idx] = merged
            } else {
                result.append(item)
            }
        }
        return result
    }
}

/// Pure snapshot builder: store sessions and registry agents into detector
/// candidates. Extracted from `CompletionFlashService.currentCandidates` so
/// the misfire regression — "parked on the user is NOT a completion", twice
/// a live incident (2026-11-02: green flash on every PermissionRequest) —
/// has a testable seam.
enum ReminderSnapshot {
    static func aiCandidate(_ session: AISessionState, now: Date = Date()) -> CompletionCandidate {
        var candidate = CompletionCandidate(
            key: "ai:\(session.id)",
            name: session.projectFolder ?? session.displayTitle,
            // Active == the CLI is mid-conversation (processing / compacting
            // / waiting for an approval) — `SessionPhase.isActive`. A session
            // parked at its prompt is NOT active: the turn is over.
            isActive: session.phase.isActive,
            source: .ai(session.source),
            subtitle: session.lastUserMessage ?? session.displayTitle,
            tool: session.currentTool,
            model: session.displayModel,
            tokenDisplay: session.tokenDisplay,
            duration: now.timeIntervalSince(session.sessionStart),
            path: session.cwd,
            jump: CompletionJump.make(
                hostPID: session.launchingAppPID,
                hostBundleId: session.launchingAppBundleId,
                tabLink: session.tabLinkURL
            )
        )
        candidate.attentionKind = session.attentionKind
        // A Stop reports turnDone (apiError when the transcript's last
        // assistant entry is a terminal API error); anything else that
        // deactivates a session — demote, reap, record-gone — never saw a
        // Stop, so it reports sessionLost.
        candidate.completesAs = session.phase == .waitingForInput
            ? (session.hitApiError ? .apiError : .turnDone)
            : .sessionLost
        return candidate
    }

    static func agentCandidate(id: String, name: String, state: AgentMonitorState) -> CompletionCandidate {
        var candidate = CompletionCandidate(
            key: "agent:\(id)",
            name: name,
            isActive: state != .idle,
            source: .agent
        )
        candidate.wasError = state == .error
        return candidate
    }
}
