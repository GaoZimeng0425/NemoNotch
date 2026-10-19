import Foundation
@testable import NemoNotch
import Testing

@Suite("Collapsed-notch AI session badges")
struct BadgeSessionItemsTests {
    private func session(_ id: String, _ phase: SessionPhase, source: AISource = .claude) -> AISessionState {
        var s = AISessionState(sessionId: id, source: source)
        s.phase = phase
        return s
    }

    private func approval(_ id: String, source: AISource = .claude) -> AISessionState {
        session(id, .waitingForApproval(
            PermissionContext(toolUseId: "tu", toolName: "Bash", toolInput: nil, receivedAt: Date())
        ), source: source)
    }

    private var all: [AISessionState] {
        [
            approval("appr"),
            session("run", .processing),
            session("compact", .compacting),
            session("input", .waitingForInput),
            session("idle", .idle),
            session("ended", .ended),
        ]
    }

    @Test("Approval and working sessions get badges — unless the edge bar is on")
    func badgesStepAsideForTheEdgeBar() {
        let shown = BadgeItem.sessionItems(all, edgeBarShown: false) { _ in true }
        #expect(shown.map(\.id).sorted() == [
            "ai:appr:claude:waiting:Bash:true",
            "ai:compact:claude:working:nil:false",
            "ai:run:claude:working:nil:false",
        ])
        #expect(BadgeItem.sessionItems(all, edgeBarShown: true) { _ in true }.isEmpty)
    }

    @Test("A disabled provider's sessions get no badge, approvals included")
    func disabledProviderSkipped() {
        let mixed = [
            session("c", .processing),
            session("g", .processing, source: .gemini),
            approval("ga", source: .gemini),
        ]
        let items = BadgeItem.sessionItems(mixed, edgeBarShown: false) { $0 != .gemini }
        #expect(items.map(\.id) == ["ai:c:claude:working:nil:false"])
    }
}
