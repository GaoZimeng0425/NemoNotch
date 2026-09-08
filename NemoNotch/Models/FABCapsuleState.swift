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
enum FABCapsuleState: Equatable {
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
        var running = 0
        var approvals = 0
        var inputs = 0
        for session in sessions {
            switch session.phase {
            case .processing, .compacting:
                running += 1
            case .waitingForApproval:
                approvals += 1
            case .waitingForInput:
                inputs += 1
            case .idle, .ended:
                break
            }
        }
        if approvals > 0 { return .waitingApproval(count: approvals) }
        if running > 0 { return .running(count: running) }
        if inputs > 0 { return .waitingInput(count: inputs) }
        return .done
    }
}
