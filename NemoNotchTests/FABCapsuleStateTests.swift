@testable import NemoNotch
import Foundation
import Testing

@Suite("FABCapsuleState")
struct FABCapsuleStateTests {
    private func session(_ id: String, phase: SessionPhase) -> AISessionState {
        var s = AISessionState(sessionId: id, source: .claude)
        s.phase = phase
        return s
    }

    // MARK: - single-state aggregation

    @Test("processing maps to running with its count")
    func processingRunning() {
        let sessions = [
            session("a", phase: .processing),
            session("b", phase: .processing),
        ]
        #expect(FABCapsuleState.of(sessions) == .running(count: 2))
    }

    @Test("compacting counts as running")
    func compactingRunning() {
        #expect(FABCapsuleState.of([session("a", phase: .compacting)]) == .running(count: 1))
    }

    @Test("waitingForApproval and waitingForInput map to their own states")
    func waitingStates() {
        #expect(FABCapsuleState.of([session("a", phase: .waitingForApproval(.placeholder))]) == .waitingApproval(count: 1))
        #expect(FABCapsuleState.of([session("a", phase: .waitingForInput)]) == .waitingInput(count: 1))
    }

    @Test("all idle/ended or empty yields done")
    func quietDone() {
        #expect(FABCapsuleState.of([]) == .done)
        #expect(FABCapsuleState.of([session("a", phase: .idle)]) == .done)
        #expect(FABCapsuleState.of([session("a", phase: .idle), session("b", phase: .ended)]) == .done)
    }

    // MARK: - priority (approval > running > waiting input)

    @Test("approval outranks running")
    func approvalBeatsRunning() {
        let sessions = [
            session("a", phase: .processing),
            session("b", phase: .compacting),
            session("c", phase: .waitingForApproval(.placeholder)),
        ]
        #expect(FABCapsuleState.of(sessions) == .waitingApproval(count: 1))
    }

    @Test("running outranks waiting input")
    func runningBeatsInput() {
        let sessions = [
            session("a", phase: .waitingForInput),
            session("b", phase: .processing),
        ]
        #expect(FABCapsuleState.of(sessions) == .running(count: 1))
    }

    @Test("count reflects the winning state, not all engaged sessions")
    func countIsPerWinningState() {
        let sessions = [
            session("a", phase: .waitingForInput),
            session("b", phase: .waitingForInput),
            session("c", phase: .waitingForApproval(.placeholder)),
        ]
        #expect(FABCapsuleState.of(sessions) == .waitingApproval(count: 1))
    }

    // MARK: - visibility

    @Test("only done is invisible")
    func visibility() {
        #expect(FABCapsuleState.of([session("a", phase: .waitingForInput)]).isVisible)
        #expect(!FABCapsuleState.done.isVisible)
    }
}

/// Test fixture: `PermissionContext` only participates via its identity, never
/// its content, in capsule aggregation.
private extension PermissionContext {
    static var placeholder: PermissionContext {
        PermissionContext(toolUseId: "tu", toolName: "Bash", toolInput: nil, receivedAt: Date())
    }
}
