import Foundation
@testable import NemoNotch
import Testing

/// `EdgeBarAlertCards`: when a quota alert brings its card up on its own —
/// only on arrival (a folded bar stays folded for alerts it already showed),
/// never over a held approval; a pending alert is reclaimed when nothing is up.
@Suite("EdgeBarAlertCards")
struct EdgeBarAlertCardsTests {
    private let a = "alert:claude:5h:exceeded"
    private let b = "alert:codex:300m:exceeded"

    @Test func anArrivalOpensTheClosedBar() {
        let decision = EdgeBarAlertCards.plan(
            previous: [],
            pending: [a],
            isOpen: false,
            selectedRow: nil,
            approvalSelected: false
        )
        #expect(decision == EdgeBarAlertCards.Decision(open: true, select: a))
    }

    @Test func anArrivalTakesTheCardOnAnOpenBar() {
        let decision = EdgeBarAlertCards.plan(
            previous: [a],
            pending: [a, b],
            isOpen: true,
            selectedRow: "session-1",
            approvalSelected: false
        )
        #expect(decision == EdgeBarAlertCards.Decision(open: false, select: b))
    }

    @Test func anArrivalWaitsBehindAHeldApproval() {
        let decision = EdgeBarAlertCards.plan(
            previous: [],
            pending: [a],
            isOpen: true,
            selectedRow: "session-1",
            approvalSelected: true
        )
        #expect(decision == EdgeBarAlertCards.Decision())
    }

    @Test func oldAlertsNeverReopenAFoldedBar() {
        let decision = EdgeBarAlertCards.plan(
            previous: [a],
            pending: [a],
            isOpen: false,
            selectedRow: nil,
            approvalSelected: false
        )
        #expect(decision == EdgeBarAlertCards.Decision())
    }

    @Test func aFreeCardOnAnOpenBarIsReclaimed() {
        let decision = EdgeBarAlertCards.plan(
            previous: [a, b],
            pending: [a, b],
            isOpen: true,
            selectedRow: nil,
            approvalSelected: false
        )
        #expect(decision == EdgeBarAlertCards.Decision(open: false, select: a))
    }

    @Test func aCardAlreadyUpIsLeftAlone() {
        let decision = EdgeBarAlertCards.plan(
            previous: [a, b],
            pending: [a, b],
            isOpen: true,
            selectedRow: b,
            approvalSelected: false
        )
        #expect(decision == EdgeBarAlertCards.Decision())
    }

    @Test func nothingPendingDecidesNothing() {
        #expect(EdgeBarAlertCards.plan(
            previous: [a],
            pending: [],
            isOpen: true,
            selectedRow: nil,
            approvalSelected: false
        ) == EdgeBarAlertCards.Decision())
    }

    @Test func reclaimPicksTheOldestUnlessOneIsUpOrAnApprovalIs() {
        #expect(EdgeBarAlertCards.reclaim(pending: [a, b], selectedRow: "session-1", approvalSelected: false) == a)
        #expect(EdgeBarAlertCards.reclaim(pending: [a, b], selectedRow: b, approvalSelected: false) == nil)
        #expect(EdgeBarAlertCards.reclaim(pending: [a, b], selectedRow: "session-1", approvalSelected: true) == nil)
        #expect(EdgeBarAlertCards.reclaim(pending: [], selectedRow: nil, approvalSelected: false) == nil)
    }

    @Test func cardIDsRoundTrip() {
        let alert = QuotaAlert(
            key: QuotaAlertKey(provider: .claude, window: .fiveHour),
            kind: .exceeded, utilization: 90, resetsAt: nil, threshold: 80,
            firedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(EdgeBarAlertCards.cardID(alert) == a)
        #expect(EdgeBarAlertCards.alertID(ofCardID: a) == "claude:5h:exceeded")
        #expect(EdgeBarAlertCards.alertID(ofCardID: "usage:claude") == nil)
        #expect(EdgeBarAlertCards.alertID(ofCardID: "abc123") == nil)
    }
}
