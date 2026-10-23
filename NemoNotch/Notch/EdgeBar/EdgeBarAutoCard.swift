import Foundation

/// Decides when the bar shows a card on its own — no cursor involved.
///
/// A session that just began waiting for approval owns the screen for a
/// moment: the bar opens (if closed) with that row's card up, Deny/Allow
/// ready — the CLI is held at its hook until someone answers, so there is
/// nothing to wait out and no threshold. A session that parked at the
/// prompt (`waitingForInput`) only brings its card up on an ALREADY open
/// bar, and never takes a card from another row: turn ends are frequent
/// (the completion flash already announces them), and a bar that flapped
/// open on every one would be noise, not signal.
///
/// Pure and unit-tested: `EdgeBarController.refresh` feeds it the rows'
/// phases before and after a store change and performs what it says.
enum EdgeBarAutoCard {
    struct Candidate: Equatable {
        let id: String
        let phase: SessionPhase
    }

    struct Decision: Equatable {
        /// Open the closed bar for the approval.
        var open = false
        /// The row whose card to show (after opening, when `open`).
        var select: String?
    }

    static func plan(
        previous: [Candidate],
        next: [Candidate],
        isOpen: Bool,
        selectedRow: String?
    ) -> Decision {
        func before(_ id: String) -> SessionPhase? {
            previous.first(where: { $0.id == id })?.phase
        }
        // A row's arrival counts as an edge: a first event that is already
        // the permission request must still bring the card up.
        let approvals = next.filter { row in
            row.phase.isWaitingForApproval && !(before(row.id)?.isWaitingForApproval ?? false)
        }
        let parked = next.filter { row in
            row.phase == .waitingForInput && before(row.id) != .waitingForInput
        }

        // Approval first; among approvals, the list's order (attention:
        // approval rows ahead) picks the one the card speaks for.
        if let held = approvals.first {
            guard isOpen else { return Decision(open: true, select: held.id) }
            // On an open bar the card only moves to the approval when no
            // approval already holds it — first come, first served; the
            // other row's ring reads amber either way.
            let selectedHoldsApproval = selectedRow
                .flatMap { id in next.first(where: { $0.id == id })?.phase.isWaitingForApproval }
                ?? false
            if selectedRow == nil || selectedRow == held.id || !selectedHoldsApproval {
                return Decision(open: false, select: held.id)
            }
            return Decision()
        }
        if let idle = parked.first, isOpen, selectedRow == nil {
            return Decision(open: false, select: idle.id)
        }
        return Decision()
    }

    /// The auto-opened bar folding itself: only with nothing left to show, the
    /// cursor off the bar — and no card still on its way out. An acknowledged
    /// alert deselects its card while the bar stays open (unlike an answered
    /// approval, whose row keeps its card); folding at once ran the bar's fold
    /// and the card's fade in the same breath. Pure and unit-tested.
    enum ClosePlan: Equatable {
        case close
        /// A card is still leaving; re-decide this long from now.
        case waitForCard(TimeInterval)
        case standDown
    }

    static func closePlan(
        autoOpened: Bool,
        approvalWaiting: Bool,
        alertsPending: Bool,
        pointerOnBar: Bool,
        cardGoneBy: Date?,
        now: Date
    ) -> ClosePlan {
        guard autoOpened, !approvalWaiting, !alertsPending, !pointerOnBar else { return .standDown }
        if let gone = cardGoneBy, now < gone {
            return .waitForCard(gone.timeIntervalSince(now))
        }
        return .close
    }
}
