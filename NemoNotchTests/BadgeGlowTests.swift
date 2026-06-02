@testable import NemoNotch
import Testing

@Suite("Badge activity glow")
struct BadgeGlowTests {
    private func ai(_ status: ClaudeStatus, approval: Bool = false) -> BadgeItem {
        .ai(source: .claude, status: status, tool: nil, waitingApproval: approval, sessionID: "s")
    }

    private func agent(_ state: AgentMonitorState = .working) -> BadgeItem {
        .agents(agentID: "a", state: state, emoji: "🤖")
    }

    @Test("Approval-waiting AI glows amber")
    func approvalIsAmber() {
        #expect(BadgeItem.glow(for: [ai(.waiting, approval: true)]) == .attention)
    }

    @Test("Working AI glows green")
    func workingIsGreen() {
        #expect(BadgeItem.glow(for: [ai(.working)]) == .running)
    }

    @Test("Active agent glows green")
    func agentIsGreen() {
        #expect(BadgeItem.glow(for: [agent()]) == .running)
    }

    @Test("Approval wins over concurrent working/agent")
    func approvalWins() {
        #expect(BadgeItem.glow(for: [ai(.working), ai(.waiting, approval: true)]) == .attention)
        #expect(BadgeItem.glow(for: [agent(), ai(.waiting, approval: true)]) == .attention)
    }

    @Test("Media or calendar alone does not glow")
    func mediaCalendarNone() {
        #expect(BadgeItem.glow(for: [.media]) == NotchGlow.none)
        #expect(BadgeItem.glow(for: [.calendar, .media]) == NotchGlow.none)
    }

    @Test("Idle AI without approval does not glow")
    func idleAINone() {
        #expect(BadgeItem.glow(for: [ai(.idle)]) == NotchGlow.none)
    }

    @Test("Empty set does not glow")
    func emptyNone() {
        #expect(BadgeItem.glow(for: []) == NotchGlow.none)
    }
}
