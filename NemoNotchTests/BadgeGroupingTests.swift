@testable import NemoNotch
import Testing

@Suite("Badge grouping")
struct BadgeGroupingTests {
    private func ai(
        _ status: ClaudeStatus = .working,
        _ source: AISource = .claude,
        approval: Bool = false,
        id: String
    ) -> BadgeItem {
        .ai(source: source, status: status, tool: nil, waitingApproval: approval, sessionID: id)
    }

    private func agent(_ emoji: String, id: String) -> BadgeItem {
        .agents(agentID: id, state: .working, emoji: emoji)
    }

    @Test("Single item → one group, count 1")
    func single() {
        let g = BadgeGrouping.group([ai(id: "s1")])
        #expect(g.count == 1)
        #expect(g[0].key == "ai:claude")
        #expect(g[0].count == 1)
    }

    @Test("Multiple same program → one group, count = members")
    func multipleSame() {
        let g = BadgeGrouping.group([ai(id: "s1"), ai(id: "s2"), ai(id: "s3")])
        #expect(g.count == 1)
        #expect(g[0].count == 3)
    }

    @Test("Multiple different programs → one group each, order preserved")
    func multipleDifferent() {
        let g = BadgeGrouping.group([ai(id: "s1"), .media, .calendar])
        #expect(g.map(\.key) == ["ai:claude", "media", "calendar"])
        #expect(g.allSatisfy { $0.count == 1 })
    }

    @Test("Mixed with duplicates → dup group carries count, others 1")
    func mixedWithDuplicates() {
        let g = BadgeGrouping.group([ai(id: "s1"), ai(id: "s2"), .media])
        #expect(g.count == 2)
        #expect(g[0].key == "ai:claude")
        #expect(g[0].count == 2)
        #expect(g[1].key == "media")
        #expect(g[1].count == 1)
    }

    @Test("Representative is the first (highest-priority) member")
    func representative() {
        // Caller passes already priority-sorted items; approval sorts ahead of working.
        let approval = ai(.waiting, approval: true, id: "s1")
        let working = ai(.working, id: "s2")
        let g = BadgeGrouping.group([approval, working])
        #expect(g.count == 1)
        #expect(g[0].representative == approval)
        #expect(g[0].count == 2)
    }

    @Test("Agents group by emoji icon identity")
    func agentsByEmoji() {
        let g = BadgeGrouping.group([agent("🤖", id: "a1"), agent("🤖", id: "a2"), agent("🦀", id: "a3")])
        #expect(g.count == 2)
        #expect(g.first { $0.key == "agents:🤖" }?.count == 2)
        #expect(g.first { $0.key == "agents:🦀" }?.count == 1)
    }

    @Test("Overflow beyond cap collapses remainder to +K")
    func overflow() {
        let items: [BadgeItem] = [
            ai(id: "s1"), .media, .calendar, .pomodoro(phase: .work), agent("🤖", id: "a1"),
        ]
        // 5 distinct groups, cap 4 → show first 3, overflow 2
        let c = BadgeGrouping.cluster(items, cap: 4)
        #expect(c.groups.count == 3)
        #expect(c.overflow == 2)
    }

    @Test("Under cap → no overflow")
    func underCap() {
        let c = BadgeGrouping.cluster([ai(id: "s1"), .media], cap: 4)
        #expect(c.groups.count == 2)
        #expect(c.overflow == 0)
    }
}
