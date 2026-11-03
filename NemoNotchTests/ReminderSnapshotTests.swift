import Foundation
@testable import NemoNotch
import Testing

/// The misfire guard at the snapshot boundary: a session parked on the user
/// is NOT a completion. This exact shape fired a green "done" flash on every
/// PermissionRequest for months (2026-11-02 log evidence, 24 hits / 2 days).
@Suite("ReminderSnapshot")
struct ReminderSnapshotTests {
    private func session(_ phase: SessionPhase, hitApiError: Bool = false) -> AISessionState {
        var s = AISessionState(sessionId: "s1", source: .claude)
        s.phase = phase
        s.hitApiError = hitApiError
        return s
    }

    private let askCtx = PermissionContext(
        toolUseId: "t", toolName: "AskUserQuestion", toolInput: nil, receivedAt: Date()
    )
    private let bashCtx = PermissionContext(
        toolUseId: "t", toolName: "Bash", toolInput: nil, receivedAt: Date()
    )

    @Test("waiting for approval is still active — no completion fires")
    func waitingForApprovalIsActive() {
        let candidate = ReminderSnapshot.aiCandidate(session(.waitingForApproval(askCtx)))
        #expect(candidate.isActive)
        #expect(candidate.attentionKind == .needsDecision)
    }

    @Test("attention kind follows the tool shape")
    func attentionKindByTool() {
        #expect(ReminderSnapshot.aiCandidate(session(.waitingForApproval(bashCtx))).attentionKind == .needsApproval)
    }

    @Test("processing is active; a parked prompt is not")
    func activityByPhase() {
        #expect(ReminderSnapshot.aiCandidate(session(.processing)).isActive)
        #expect(ReminderSnapshot.aiCandidate(session(.compacting)).isActive)
        #expect(!ReminderSnapshot.aiCandidate(session(.waitingForInput)).isActive)
        #expect(!ReminderSnapshot.aiCandidate(session(.idle)).isActive)
    }

    @Test("a Stop reports turnDone — apiError when the transcript ended on one")
    func completesAsAtStop() {
        #expect(ReminderSnapshot.aiCandidate(session(.waitingForInput)).completesAs == .turnDone)
        #expect(ReminderSnapshot.aiCandidate(session(.waitingForInput, hitApiError: true)).completesAs == .apiError)
        #expect(ReminderSnapshot.aiCandidate(session(.idle)).completesAs == .sessionLost)
        #expect(ReminderSnapshot.aiCandidate(session(.ended)).completesAs == .sessionLost)
    }

    @Test("an agent in error carries the flag for its completion")
    func agentErrorFlag() {
        #expect(ReminderSnapshot.agentCandidate(id: "x", name: "Hermes", state: .error).wasError)
        #expect(!ReminderSnapshot.agentCandidate(id: "x", name: "Hermes", state: .working).wasError)
        #expect(!ReminderSnapshot.agentCandidate(id: "x", name: "Hermes", state: .idle).wasError)
    }
}
