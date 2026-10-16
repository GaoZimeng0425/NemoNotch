import Foundation
@testable import NemoNotch
import Testing

@Suite("FABSessionStrip")
struct FABSessionStripTests {
    private func session(
        _ id: String,
        phase: SessionPhase,
        at timeIntervalSince1970: TimeInterval = 100,
        source: AISource = .claude,
        hostPID: Int32? = nil
    ) -> AISessionState {
        var s = AISessionState(sessionId: id, source: source)
        s.phase = phase
        s.lastEventTime = Date(timeIntervalSince1970: timeIntervalSince1970)
        s.launchingAppPID = hostPID
        return s
    }

    // MARK: - filtering

    @Test("idle and ended sessions produce no chips")
    func filtersNonEngaged() {
        let strip = FABSessionStrip.of([
            session("a", phase: .idle),
            session("b", phase: .ended),
        ], cap: 6)
        #expect(strip.chips.isEmpty)
        #expect(strip.overflow == 0)
    }

    @Test("empty input yields an empty strip")
    func emptyInput() {
        #expect(FABSessionStrip.of([], cap: 6) == FABSessionStrip())
    }

    // MARK: - attention order (approval > running > input, ties by recency)

    @Test("chips are attention-ordered regardless of input order")
    func attentionOrder() {
        let strip = FABSessionStrip.of([
            session("input", phase: .waitingForInput),
            session("running", phase: .processing),
            session("approval", phase: .waitingForApproval(.placeholder)),
        ], cap: 6)
        #expect(strip.chips.map(\.id) == ["approval", "running", "input"])
    }

    @Test("same-rank chips break ties by most recent event")
    func recencyTiebreak() {
        let strip = FABSessionStrip.of([
            session("older", phase: .processing, at: 100),
            session("newer", phase: .processing, at: 200),
        ], cap: 6)
        #expect(strip.chips.map(\.id) == ["newer", "older"])
    }

    // MARK: - cap + overflow

    @Test("cap keeps the most attention-needing chips and folds the rest")
    func capFoldsLowestPriority() {
        let strip = FABSessionStrip.of([
            session("input-1", phase: .waitingForInput, at: 100),
            session("running-old", phase: .processing, at: 100),
            session("approval", phase: .waitingForApproval(.placeholder), at: 100),
            session("running-new", phase: .processing, at: 200),
        ], cap: 2)
        #expect(strip.chips.map(\.id) == ["approval", "running-new"])
        #expect(strip.overflow == 2)
    }

    @Test("strip under the cap has no overflow")
    func underCap() {
        let strip = FABSessionStrip.of([
            session("a", phase: .processing),
            session("b", phase: .waitingForInput),
        ], cap: 6)
        #expect(strip.chips.count == 2)
        #expect(strip.overflow == 0)
    }

    // MARK: - chip payload

    @Test("hasHost mirrors launchingAppPID and source is preserved")
    func chipPayload() {
        let strip = FABSessionStrip.of([
            session("hosted", phase: .processing, source: .zcode, hostPID: 42),
            session("orphan", phase: .processing, source: .opencode, hostPID: nil),
        ], cap: 6)
        #expect(strip.chips.first { $0.id == "hosted" }?.hasHost == true)
        #expect(strip.chips.first { $0.id == "orphan" }?.hasHost == false)
        #expect(strip.chips.first { $0.id == "hosted" }?.source == .zcode)
        #expect(strip.chips.first { $0.id == "orphan" }?.source == .opencode)
        #expect(strip.chips.allSatisfy { $0.phase == .processing })
    }
}

/// Test fixture: `PermissionContext` only participates via its identity, never
/// its content, in strip ordering.
private extension PermissionContext {
    static var placeholder: PermissionContext {
        PermissionContext(toolUseId: "tu", toolName: "Bash", toolInput: nil, receivedAt: Date())
    }
}
