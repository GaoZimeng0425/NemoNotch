import Foundation
@testable import NemoNotch
import Testing

/// `EdgeBarAutoCard`: when the bar shows a card on its own. Approval opens
/// the closed bar; a parked prompt only takes a free card on an open bar.
@Suite("EdgeBarAutoCard")
struct EdgeBarAutoCardTests {
    private func approval(_ key: String) -> SessionPhase {
        .waitingForApproval(PermissionContext(toolUseId: key, toolName: "Bash", toolInput: nil, receivedAt: Date()))
    }

    private func row(_ id: String, _ phase: SessionPhase) -> EdgeBarAutoCard.Candidate {
        EdgeBarAutoCard.Candidate(id: id, phase: phase)
    }

    @Test func approvalOpensTheClosedBar() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", .processing)],
            next: [row("a", approval("a1"))],
            isOpen: false,
            selectedRow: nil
        )
        #expect(decision.open)
        #expect(decision.select == "a")
    }

    @Test func aRowAppearingAlreadyWaitingCountsAsAnEdge() {
        // The permission request is often the first event that lands.
        let decision = EdgeBarAutoCard.plan(
            previous: [],
            next: [row("a", approval("a1"))],
            isOpen: false,
            selectedRow: nil
        )
        #expect(decision.open)
        #expect(decision.select == "a")
    }

    @Test func approvalSelectsOnAnOpenBar() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", .processing)],
            next: [row("a", approval("a1"))],
            isOpen: true,
            selectedRow: nil
        )
        #expect(!decision.open)
        #expect(decision.select == "a")
    }

    @Test func approvalTakesTheCardFromANonApprovalCard() {
        // The user is reading a parked row's reply when an approval lands:
        // the held request outranks reading.
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", .processing), row("b", .waitingForInput)],
            next: [row("a", approval("a1")), row("b", .waitingForInput)],
            isOpen: true,
            selectedRow: "b"
        )
        #expect(!decision.open)
        #expect(decision.select == "a")
    }

    @Test func anApprovalHoldingTheCardIsNotYankedByAnother() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", approval("a1")), row("b", .processing)],
            next: [row("a", approval("a1")), row("b", approval("b1"))],
            isOpen: true,
            selectedRow: "a"
        )
        #expect(decision == EdgeBarAutoCard.Decision())
    }

    @Test func aParkedPromptNeverOpensTheBar() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", .processing)],
            next: [row("a", .waitingForInput)],
            isOpen: false,
            selectedRow: nil
        )
        #expect(decision == EdgeBarAutoCard.Decision())
    }

    @Test func aParkedPromptTakesAFreeCardOnAnOpenBar() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", .processing)],
            next: [row("a", .waitingForInput)],
            isOpen: true,
            selectedRow: nil
        )
        #expect(!decision.open)
        #expect(decision.select == "a")
    }

    @Test func aParkedPromptNeverTakesACardFromAnotherRow() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", .processing), row("b", .processing)],
            next: [row("a", .waitingForInput), row("b", .processing)],
            isOpen: true,
            selectedRow: "b"
        )
        #expect(decision == EdgeBarAutoCard.Decision())
    }

    @Test func approvalOutranksAParkedPrompt() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", .processing), row("b", .processing)],
            next: [row("a", .waitingForInput), row("b", approval("b1"))],
            isOpen: false,
            selectedRow: nil
        )
        #expect(decision.open)
        #expect(decision.select == "b")
    }

    @Test func noPhaseChangeMeansNoCard() {
        // A held approval refreshed (another event on the same phase) must
        // not re-open or re-select anything.
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", approval("a1"))],
            next: [row("a", approval("a1"))],
            isOpen: false,
            selectedRow: nil
        )
        #expect(decision == EdgeBarAutoCard.Decision())
    }

    @Test func answeredApprovalMeansNoCard() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", approval("a1"))],
            next: [row("a", .processing)],
            isOpen: false,
            selectedRow: nil
        )
        #expect(decision == EdgeBarAutoCard.Decision())
    }

    @Test func simultaneousApprovalsPickTheFirstInListOrder() {
        let decision = EdgeBarAutoCard.plan(
            previous: [row("a", .processing), row("b", .processing)],
            next: [row("a", approval("a1")), row("b", approval("b1"))],
            isOpen: false,
            selectedRow: nil
        )
        #expect(decision.open)
        #expect(decision.select == "a")
    }

    // EdgeBarAutoCard.closePlan: the auto-opened bar folds itself only when
    // nothing is left to show, the cursor is off the bar, and no card is still
    // on its way out — the acknowledge flow folds after the card, not with it.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func closePlanClosesWhenNothingLeftAndCursorOff() {
        #expect(EdgeBarAutoCard.closePlan(
            autoOpened: true, approvalWaiting: false, alertsPending: false,
            pointerOnBar: false, cardGoneBy: nil, now: now
        ) == .close)
    }

    @Test func closePlanStandsDownWhileThereIsSomethingToShowOrACursorOn() {
        #expect(EdgeBarAutoCard.closePlan(
            autoOpened: false,
            approvalWaiting: false,
            alertsPending: false,
            pointerOnBar: false,
            cardGoneBy: nil,
            now: now
        ) == .standDown)
        #expect(EdgeBarAutoCard.closePlan(
            autoOpened: true,
            approvalWaiting: true,
            alertsPending: false,
            pointerOnBar: false,
            cardGoneBy: nil,
            now: now
        ) == .standDown)
        #expect(EdgeBarAutoCard.closePlan(
            autoOpened: true,
            approvalWaiting: false,
            alertsPending: true,
            pointerOnBar: false,
            cardGoneBy: nil,
            now: now
        ) == .standDown)
        #expect(EdgeBarAutoCard.closePlan(
            autoOpened: true,
            approvalWaiting: false,
            alertsPending: false,
            pointerOnBar: true,
            cardGoneBy: now.addingTimeInterval(0.2),
            now: now
        ) == .standDown)
    }

    @Test func closePlanWaitsForTheCardToLeave() {
        // TimeInterval equality at the Date arithmetic boundary is off by one
        // ulp (~5e-8), so the wait is asserted within a tolerance.
        let plan = EdgeBarAutoCard.closePlan(
            autoOpened: true, approvalWaiting: false, alertsPending: false,
            pointerOnBar: false, cardGoneBy: now.addingTimeInterval(0.2), now: now
        )
        guard case let .waitForCard(wait) = plan else {
            Issue.record("expected waitForCard, got \(plan)")
            return
        }
        #expect(abs(wait - 0.2) < 0.001)
    }

    @Test func closePlanClosesOnceTheCardIsGone() {
        #expect(EdgeBarAutoCard.closePlan(
            autoOpened: true, approvalWaiting: false, alertsPending: false,
            pointerOnBar: false, cardGoneBy: now.addingTimeInterval(-0.01), now: now
        ) == .close)
    }
}
