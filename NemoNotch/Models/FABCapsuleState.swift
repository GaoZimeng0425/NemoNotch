import Foundation

/// The AI-status capsule's aggregate state, derived from all AI sessions.
/// Traffic-light semantics (borrowed from herdr): yellow = running, red =
/// needs a choice, solid green = waiting for input, hollow green = finished.
///
/// When sessions sit in mixed states the most attention-needing one wins the
/// dot — the same priority order `AISessionStore.activeSession` uses:
/// waitingForApproval > processing/compacting > waitingForInput. `.done` is
/// not a session phase: it is the transient "everything went quiet" state the
/// capsule shows during the hide-delay window before the window fades out.
enum FABCapsuleState: Hashable {
    /// At least one session is processing or compacting.
    case running(count: Int)
    /// At least one session is waiting for a tool-permission choice.
    case waitingApproval(count: Int)
    /// At least one session is waiting for the user's next prompt.
    case waitingInput(count: Int)
    /// No engaged session (all idle/ended, or none exist).
    case done

    /// Whether any session still needs the capsule on screen. `.done` returns
    /// false — the controller schedules the fade; the view keeps rendering the
    /// hollow-green dot until the window actually fades out.
    var isVisible: Bool { self != .done }

    /// `running` carries a count, so it can't be compared with `== .running`.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Fold every session's phase into one capsule state by attention
    /// priority. Pure; unit-tested without any store or UI.
    static func of(_ sessions: [AISessionState]) -> FABCapsuleState {
        FABStatusCounts.of(sessions).groups.first?.state ?? .done
    }
}

/// Per-status session counts behind the capsule. The capsule renders every
/// non-zero group side by side (red approvals · yellow running · green awaiting
/// input) instead of only the winning one, so a mixed workload is legible at a
/// glance. `FABCapsuleState` is still the single-winner fold used for the
/// window's visibility and the expanded header. Pure; unit-tested.
struct FABStatusCounts: Equatable {
    var approvals = 0
    var running = 0
    var inputs = 0

    var total: Int { approvals + running + inputs }
    var isEmpty: Bool { total == 0 }

    static func of(_ sessions: [AISessionState]) -> FABStatusCounts {
        var counts = FABStatusCounts()
        for session in sessions {
            switch session.phase {
            case .processing, .compacting: counts.running += 1
            case .waitingForApproval: counts.approvals += 1
            case .waitingForInput: counts.inputs += 1
            case .idle, .ended: break
            }
        }
        return counts
    }

    /// The groups to draw, in attention order (approval > running > input),
    /// skipping empty ones. Matches `FABCapsuleState`'s priority so the capsule's
    /// leading group is always the one the header names.
    var groups: [FABStatusGroup] {
        var out: [FABStatusGroup] = []
        if approvals > 0 { out.append(FABStatusGroup(state: .waitingApproval(count: approvals), count: approvals)) }
        if running > 0 { out.append(FABStatusGroup(state: .running(count: running), count: running)) }
        if inputs > 0 { out.append(FABStatusGroup(state: .waitingInput(count: inputs), count: inputs)) }
        return out
    }
}


/// One capsule chip: a status and how many sessions are in it. A struct (not a
/// tuple) because SwiftUI's `ForEach(_:id:)` needs a key path, which tuples
/// can't provide.
struct FABStatusGroup: Hashable, Identifiable {
    let state: FABCapsuleState
    let count: Int

    var id: FABCapsuleState { state }
}
