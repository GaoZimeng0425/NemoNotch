@testable import NemoNotch
import Foundation
import Testing

@Suite("LockScreenAIPanelModel")
struct LockScreenAIPanelModelTests {
    /// Helper: a session in the given phase, started `age` seconds before
    /// `now` so ordering tests can control recency.
    private func session(
        _ id: String,
        source: AISource = .claude,
        phase: SessionPhase,
        age: TimeInterval,
        cwd: String? = nil,
        now: Date
    ) -> AISessionState {
        var s = AISessionState(sessionId: id, source: source)
        s.phase = phase
        s.cwd = cwd
        s.sessionStart = now.addingTimeInterval(-age)
        s.lastEventTime = now.addingTimeInterval(-age / 2)
        return s
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - shouldShow

    @Test("shows only when locked, enabled, and something is active")
    func shouldShowTruthTable() {
        let working = [AISessionState]()

        #expect(!LockScreenAIPanelModel.shouldShow(sessions: working, isLocked: false, enabled: true))
        #expect(!LockScreenAIPanelModel.shouldShow(sessions: working, isLocked: true, enabled: true))
        #expect(!LockScreenAIPanelModel.shouldShow(sessions: working, isLocked: true, enabled: false))
    }

    @Test("waitingForInput does not count as an active process")
    func waitingForInputNotActive() {
        let sessions = [self.session("a", phase: .waitingForInput, age: 60, now: now)]
        #expect(!LockScreenAIPanelModel.shouldShow(sessions: sessions, isLocked: true, enabled: true))
        #expect(LockScreenAIPanelModel.makeItems(from: sessions, now: now).isEmpty)
    }

    // MARK: - makeItems filtering

    @Test("keeps running, compacting, and awaiting-approval; drops idle and ended")
    func filtersPhases() {
        let sessions = [
            self.session("idle", phase: .idle, age: 10, now: now),
            self.session("ended", phase: .ended, age: 20, now: now),
            self.session("run", phase: .processing, age: 30, now: now),
            self.session("comp", phase: .compacting, age: 40, now: now),
            self.session(
                "appr",
                phase: .waitingForApproval(
                    PermissionContext(toolUseId: "t1", toolName: "Bash", toolInput: nil, receivedAt: now)
                ),
                age: 50,
                now: now
            ),
        ]

        let items = LockScreenAIPanelModel.makeItems(from: sessions, now: now)
        #expect(items.map(\.id) == ["appr", "comp", "run"])
        #expect(items.map(\.status) == [.awaitingApproval, .compacting, .running])
    }

    // MARK: - makeItems ordering

    @Test("awaiting approval sorts ahead of longer-running sessions")
    func approvalFirst() {
        let sessions = [
            self.session("long", phase: .processing, age: 3600, now: now),
            self.session(
                "appr",
                phase: .waitingForApproval(
                    PermissionContext(toolUseId: "t2", toolName: "Edit", toolInput: nil, receivedAt: now)
                ),
                age: 30,
                now: now
            ),
        ]

        let items = LockScreenAIPanelModel.makeItems(from: sessions, now: now)
        #expect(items.first?.id == "appr")
    }

    @Test("ties break by longer runtime")
    func ordersByRuntime() {
        let sessions = [
            self.session("short", phase: .processing, age: 60, now: now),
            self.session("long", phase: .processing, age: 600, now: now),
        ]

        #expect(LockScreenAIPanelModel.makeItems(from: sessions, now: now).map(\.id) == ["long", "short"])
    }

    // MARK: - makeItems capping

    @Test("caps at maxRows")
    func capsRows() {
        let sessions = (0..<9).map {
            self.session("s\($0)", phase: .processing, age: TimeInterval($0 + 1), now: now)
        }

        let items = LockScreenAIPanelModel.makeItems(from: sessions, now: now)
        #expect(items.count == LockScreenAIPanelModel.maxRows)
        // Longest-running five survive the cap.
        #expect(items.map(\.id) == ["s8", "s7", "s6", "s5", "s4"])
    }

    // MARK: - display title

    @Test("title prefers the project folder and truncates fallbacks")
    func displayTitle() {
        let foldered = session("a", phase: .processing, age: 1, cwd: "/Users/x/Code/NemoNotch", now: now)
        #expect(LockScreenAIPanelModel.displayTitle(for: foldered) == "NemoNotch")

        var noFolder = session("b", phase: .processing, age: 1, now: now)
        noFolder.firstUserMessage = String(repeating: "很长的消息", count: 20)
        let truncated = LockScreenAIPanelModel.displayTitle(for: noFolder)
        #expect(truncated.count <= 29)
        #expect(truncated.hasSuffix("…"))
    }

    // MARK: - elapsed text

    @Test("elapsed text uses compact units")
    func elapsedText() {
        #expect(LockScreenAIPanelModel.elapsedText(0) == "0s")
        #expect(LockScreenAIPanelModel.elapsedText(45) == "45s")
        #expect(LockScreenAIPanelModel.elapsedText(60) == "1m")
        #expect(LockScreenAIPanelModel.elapsedText(754) == "12m")
        #expect(LockScreenAIPanelModel.elapsedText(11_520) == "3.2h")
    }

    // MARK: - running seconds

    @Test("running seconds never go negative")
    func nonNegativeRunningSeconds() {
        let s = session("a", phase: .processing, age: -30, now: now) // starts in the future
        let items = LockScreenAIPanelModel.makeItems(from: [s], now: now)
        #expect(items.first?.runningSeconds == 0)
    }
}
