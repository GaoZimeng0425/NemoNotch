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

    private var all: [AISessionState] {
        [
            session("appr", .waitingForApproval(
                PermissionContext(toolUseId: "tu", toolName: "Bash", toolInput: nil, receivedAt: Date())
            )),
            session("run", .processing),
            session("input", .waitingForInput),
            session("idle", .idle),
        ]
    }

    @Test("Without the edge bar, approval and working sessions get badges")
    func badgesWithoutEdgeBar() {
        let items = BadgeItem.sessionItems(all, edgeBarShown: false) { _ in true }
        #expect(items.map(\.id).sorted() == [
            "ai:appr:claude:waiting:Bash:true",
            "ai:run:claude:working:nil:false",
        ])
    }

    @Test("With the edge bar shown, the notch repeats none of them")
    func noneWithEdgeBar() {
        #expect(BadgeItem.sessionItems(all, edgeBarShown: true) { _ in true }.isEmpty)
    }

    @Test("A disabled provider's sessions get no badge")
    func disabledProviderSkipped() {
        let mixed = [session("c", .processing), session("g", .processing, source: .gemini)]
        let items = BadgeItem.sessionItems(mixed, edgeBarShown: false) { $0 != .gemini }
        #expect(items.map(\.id) == ["ai:c:claude:working:nil:false"])
    }
}
