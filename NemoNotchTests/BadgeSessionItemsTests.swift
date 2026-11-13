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
        let shown = BadgeItem.sessionItems(all, edgeBarShown: false)
        #expect(shown.map(\.id).sorted() == [
            "ai:appr:claude:waiting:Bash:true",
            "ai:compact:claude:working:nil:false",
            "ai:run:claude:working:nil:false",
        ])
        #expect(BadgeItem.sessionItems(all, edgeBarShown: true).isEmpty)
    }

    @Test("A source's sessions render whatever the store holds — the gate is upstream")
    func allStoreSessionsRender() {
        // The per-source UI filter is gone: disabled sources have no sessions
        // in the store at all (service-layer gate), so any session present
        // here must badge, gemini included.
        let mixed = [
            session("c", .processing),
            session("g", .processing, source: .gemini),
            approval("ga", source: .gemini),
        ]
        let items = BadgeItem.sessionItems(mixed, edgeBarShown: false)
        #expect(items.map(\.id).sorted() == [
            "ai:c:claude:working:nil:false",
            "ai:g:gemini:working:nil:false",
            "ai:ga:gemini:waiting:Bash:true",
        ])
    }
}
