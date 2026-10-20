import Foundation
@testable import NemoNotch
import Testing

@MainActor
@Suite("AI tab console order")
struct ConsoleOrderTests {
    private typealias Item = AIChatTab.ConsoleItem

    private func session(
        _ id: String,
        _ phase: SessionPhase,
        stamp: TimeInterval = 0,
        settled: TimeInterval = 0
    ) -> Item {
        var s = AISessionState(sessionId: id, source: .claude)
        s.phase = phase
        s.lastEventTime = Date(timeIntervalSince1970: stamp)
        s.phaseChangedAt = Date(timeIntervalSince1970: settled)
        return .session(s)
    }

    private func agent(_ id: String, _ state: AgentMonitorState) -> Item {
        .agent(.init(
            agent: MonitoredAgent(id: id, state: state, lastEventTime: Date(timeIntervalSince1970: 5)),
            style: AgentMonitorSourceStyle(displayName: "OpenClaw", iconEmoji: "🦞", iconAssetName: nil),
            messages: nil
        ))
    }

    private func order(_ items: [Item]) -> [String] {
        items.sorted(by: Item.precedes).map(\.id)
    }

    @Test func runningItemsIgnoreTheirEventStamp() {
        // "b" just ran a tool: it must not overtake "a".
        #expect(order([session("b", .processing, stamp: 999), session("a", .processing, stamp: 1)]) == ["s-a", "s-b"])
    }

    @Test func layersThenSettledMomentNewestFirst() {
        let items = [
            session("idle", .idle, settled: 50),
            session("parked-old", .waitingForInput, settled: 10),
            agent("bot", .working),
            session("parked-new", .waitingForInput, settled: 20),
            session("run", .processing),
            agent("sleepy", .idle),
        ]
        #expect(order(items) == ["a-bot", "s-run", "s-parked-new", "s-parked-old", "s-idle", "a-sleepy"])
    }
}
