import Foundation
@testable import NemoNotch
import Testing

struct SessionPhaseTests {
    private let ctx = PermissionContext(
        toolUseId: "t", toolName: "Bash", toolInput: nil, receivedAt: Date()
    )

    @Test func compactingCanLeaveTowardEveryRestingState() {
        // opencode PreCompact 后直接 Stop/审批/静默降级都不许再被拒——
        // 死胡同曾让徽章空转 30min、完成卡永不弹(spec「捎带修复 2」)。
        #expect(SessionPhase.compacting.canTransition(to: .waitingForInput))
        #expect(SessionPhase.compacting.canTransition(to: .waitingForApproval(ctx)))
        #expect(SessionPhase.compacting.canTransition(to: .idle))
        // 既有出边保持
        #expect(SessionPhase.compacting.canTransition(to: .processing))
        #expect(SessionPhase.compacting.canTransition(to: .ended))
    }

    @Test func compactingTransitionActuallyMoves() {
        #expect(SessionPhase.compacting.transition(to: .waitingForInput) == .waitingForInput)
        #expect(SessionPhase.compacting.transition(to: .idle) == .idle)
    }
}
