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
}
