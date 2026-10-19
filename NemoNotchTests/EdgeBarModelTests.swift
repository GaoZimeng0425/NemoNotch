import Foundation
@testable import NemoNotch
import Testing

@Suite("EdgeBarModel")
struct EdgeBarModelTests {
    private func session(
        _ id: String,
        phase: SessionPhase,
        name: String = "proj",
        at timeIntervalSince1970: TimeInterval = 100
    ) -> AISessionState {
        var s = AISessionState(sessionId: id, source: .zcode)
        s.phase = phase
        s.lastEventTime = Date(timeIntervalSince1970: timeIntervalSince1970)
        s.firstUserMessage = name
        s.cwd = "/code/\(name)"
        s.phaseChangedAt = Date(timeIntervalSince1970: timeIntervalSince1970 - 900)
        return s
    }

    @Test func engagedOnlyAttentionOrdered() {
        let content = EdgeBarModel.content(of: [
            session("in", phase: .waitingForInput),
            session("run", phase: .processing),
            session("ok", phase: .ended),
            session("appr", phase: .waitingForApproval(.placeholder)),
        ])
        #expect(content.rows.map(\.id) == ["appr", "run", "in"])
        #expect(content.overflow == 0)
    }

    @Test func samePhaseBreaksTiesByRecency() {
        let content = EdgeBarModel.content(of: [
            session("old", phase: .processing, at: 100),
            session("new", phase: .processing, at: 200),
        ])
        #expect(content.rows.map(\.id) == ["new", "old"])
    }

    @Test func closedBarFoldsPastTheSlotsIntoACount() {
        var sessions: [AISessionState] = [session("appr", phase: .waitingForApproval(.placeholder))]
        for i in 0 ..< 5 {
            sessions.append(session("in-\(i)", phase: .waitingForInput, at: TimeInterval(100 + i)))
        }
        let content = EdgeBarModel.content(of: sessions)
        // The open list keeps every session; the closed bar shows three rings
        // and gives the fourth slot to "+3".
        #expect(content.rows.count == 6)
        #expect(content.closedRows.map(\.id) == ["appr", "in-4", "in-3"])
        #expect(content.overflow == 3)
        #expect(content.closedSlots == 4)
    }

    @Test func exactlyFullBarNeedsNoCount() {
        let sessions = (0 ..< 4).map { session("s\($0)", phase: .processing, at: TimeInterval(100 + $0)) }
        let content = EdgeBarModel.content(of: sessions)
        #expect(content.closedRows.count == 4)
        #expect(content.overflow == 0)
        #expect(content.closedSlots == 4)
    }

    @Test func rowCarriesProjectFolderAndPhaseClock() {
        let content = EdgeBarModel.content(of: [session("a", phase: .processing, name: "shop-api", at: 1000)])
        #expect(content.rows.first?.name == "shop-api")
        #expect(content.rows.first?.since == Date(timeIntervalSince1970: 100))
    }

    @Test func openWidthStaysWithinBounds() {
        #expect(EdgeBarModel.openWidth(of: .empty) == EdgeBarMetrics.barWidth)
        let short = EdgeBarModel.content(of: [session("a", phase: .processing, name: "a")])
        #expect(EdgeBarModel.openWidth(of: short) >= EdgeBarMetrics.minOpenWidth)
        let long = EdgeBarModel.content(of: [
            session("b", phase: .processing, name: String(repeating: "very-long-project-name-", count: 6)),
        ])
        #expect(EdgeBarModel.openWidth(of: long) == EdgeBarMetrics.maxOpenWidth)
        #expect(EdgeBarModel.openWidth(of: short) < EdgeBarModel.openWidth(of: long))
    }

    @Test func emptyStoreGivesEmptyContent() {
        #expect(EdgeBarModel.content(of: []) == .empty)
        #expect(EdgeBarModel.content(of: [session("idle", phase: .idle)]).rows.isEmpty)
    }

    @Test func summaryCountsWaitingAndRunning() {
        let content = EdgeBarModel.content(of: [
            session("a", phase: .waitingForApproval(.placeholder)),
            session("b", phase: .processing),
            session("c", phase: .processing),
        ])
        // The exact localized string differs per language; assert the numbers
        // are embedded in order.
        #expect(content.summary.contains("3"))
        #expect(content.summary.contains("1"))
        #expect(content.summary.contains("2"))
    }

    @Test func statusLineFormatsWaitedTime() {
        let line = EdgeBarPalette.statusLine(.waitingForApproval(.placeholder), waited: 14 * 60 + 20)
        #expect(line.contains("14"))
        #expect(line.contains("waiting for approval") || line.contains("等待审批"))
    }

    @Test func paletteDistinguishesApprovalFromInput() {
        #expect(EdgeBarPalette.phase(.waitingForApproval(.placeholder)) != EdgeBarPalette.phase(.waitingForInput))
        #expect(EdgeBarPalette.phase(.processing) != EdgeBarPalette.phase(.idle))
    }
}

private extension PermissionContext {
    static var placeholder: PermissionContext {
        PermissionContext(toolUseId: "tu", toolName: "Bash", toolInput: nil, receivedAt: Date())
    }
}
