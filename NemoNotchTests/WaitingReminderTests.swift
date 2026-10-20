import Foundation
@testable import NemoNotch
import Testing

@Suite("WaitingReminder")
struct WaitingReminderTests {
    private func candidate(
        _ id: String,
        waiting: Bool,
        waited: TimeInterval
    ) -> WaitingReminder.Candidate {
        WaitingReminder.Candidate(id: id, isWaiting: waiting, waited: waited)
    }

    @Test func waitingPastThresholdIsRemindedOnce() {
        let plan = WaitingReminder.plan(
            sessions: [candidate("a", waiting: true, waited: 301)],
            enabled: true,
            authorized: true,
            threshold: 300,
            alreadyReminded: []
        )
        #expect(plan.remind == ["a"])
        #expect(plan.retract.isEmpty)
    }

    @Test func waitingUnderThresholdIsNotReminded() {
        let plan = WaitingReminder.plan(
            sessions: [candidate("a", waiting: true, waited: 299)],
            enabled: true,
            authorized: true,
            threshold: 300,
            alreadyReminded: []
        )
        #expect(plan.remind.isEmpty)
    }

    @Test func alreadyRemindedIsNotRemindedAgain() {
        let plan = WaitingReminder.plan(
            sessions: [candidate("a", waiting: true, waited: 6000)],
            enabled: true,
            authorized: true,
            threshold: 300,
            alreadyReminded: ["a"]
        )
        #expect(plan.remind.isEmpty)
        #expect(plan.retract.isEmpty) // still waiting → notification stays
    }

    @Test func leavingWaitingRetractsTheNotification() {
        let plan = WaitingReminder.plan(
            sessions: [candidate("a", waiting: false, waited: 0)],
            enabled: true,
            authorized: true,
            threshold: 300,
            alreadyReminded: ["a", "b"]
        )
        #expect(plan.remind.isEmpty)
        #expect(plan.retract == ["a", "b"])
    }

    @Test func disabledOrUnauthorizedRetractsEverything() {
        for enabled in [false, true] {
            for authorized in [false, true] where !(enabled && authorized) {
                let plan = WaitingReminder.plan(
                    sessions: [candidate("a", waiting: true, waited: 9999)],
                    enabled: enabled,
                    authorized: authorized,
                    threshold: 300,
                    alreadyReminded: ["a", "gone"]
                )
                #expect(plan.remind.isEmpty)
                #expect(plan.retract == ["a", "gone"])
            }
        }
    }

    @Test func thresholdClampsToOneMinute() {
        #expect(WaitingReminder.threshold(minutes: 0) == 60)
        #expect(WaitingReminder.threshold(minutes: -5) == 60)
        #expect(WaitingReminder.threshold(minutes: 5) == 300)
    }
}

@MainActor
@Suite("WaitingReminder Phase Stamp")
struct PhaseStampTests {
    @Test func phaseChangeStampsPhaseChangedAt() {
        let store = AISessionStore()
        #expect(store.get("s1") == nil)
        store.mutateOrCreate("s1", source: .claude) { $0.phase = $0.phase.transition(to: .processing) }
        let stamped = store.get("s1")?.phaseChangedAt
        #expect(stamped != nil)

        // A mutation that does NOT move the phase keeps the original stamp.
        let before = store.get("s1")?.phaseChangedAt
        store.mutate("s1") { $0.currentTool = "Bash" }
        #expect(store.get("s1")?.phaseChangedAt == before)

        // Moving the phase re-stamps.
        Thread.sleep(forTimeInterval: 0.02)
        store.mutate("s1") { $0.phase = $0.phase.transition(to: .waitingForApproval(.init(
            toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: Date()
        ))) }
        let after = store.get("s1")?.phaseChangedAt
        #expect(after != nil && after != before)
    }

    @Test func createdWithoutPhaseChangeHasNoStamp() {
        let store = AISessionStore()
        store.mutateOrCreate("s2", source: .zcode) { _ in } // stays idle
        #expect(store.get("s2")?.phaseChangedAt == nil)
    }
}
