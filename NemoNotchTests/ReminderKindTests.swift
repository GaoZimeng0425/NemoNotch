@testable import NemoNotch
import Testing

struct ReminderKindTests {
    @Test func toneMappingMatchesSpec() {
        #expect(ReminderKind.turnDone.tone == .green)
        #expect(ReminderKind.needsDecision.tone == .amber)
        #expect(ReminderKind.needsPlanApproval.tone == .amber)
        #expect(ReminderKind.needsApproval.tone == .blue)
        #expect(ReminderKind.agentError.tone == .red)
        #expect(ReminderKind.apiError.tone == .red)
        #expect(ReminderKind.sessionLost.tone == .red)
    }

    @Test func attentionKindByToolName() {
        #expect(ReminderKind.attentionKind(forToolName: "AskUserQuestion") == .needsDecision)
        #expect(ReminderKind.attentionKind(forToolName: "ask_user_question") == .needsDecision)
        #expect(ReminderKind.attentionKind(forToolName: "AskUser") == .needsDecision)
        #expect(ReminderKind.attentionKind(forToolName: "ExitPlanMode") == .needsPlanApproval)
        #expect(ReminderKind.attentionKind(forToolName: "exit_plan_mode") == .needsPlanApproval)
        #expect(ReminderKind.attentionKind(forToolName: "Bash") == .needsApproval)
        #expect(ReminderKind.attentionKind(forToolName: nil) == .needsApproval)
    }

    @Test func pickTakesHighestPriority() {
        #expect(ReminderTone.pick([.green, .red]) == .red)
        #expect(ReminderTone.pick([.amber, .blue]) == .amber)
        #expect(ReminderTone.pick([.blue]) == .blue)
        #expect(ReminderTone.pick([]) == nil)
    }

    @Test func ringGradientsCloseTheLoop() {
        for tone in ReminderTone.allCases {
            #expect(tone.ring.count == 4, "\(tone) ring must be main/light/deep/main")
            #expect(tone.ring.first == tone.ring.last, "\(tone) conic stops must close")
        }
    }

    @Test func tonesHaveDistinctColors() {
        let mains = ReminderTone.allCases.map(\.main)
        #expect(Set(mains.map(String.init(describing:))).count == mains.count)
    }
}
