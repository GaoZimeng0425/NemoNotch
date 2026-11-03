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

    @Test("stale demotion spares open tools, waiting approvals and records")
    func staleDemotionExemptions() {
        // 开着的工具:CLI 还在跑,降级=假完成/假中断(2026-11-01 zcode 实案)
        #expect(!StaleDemotion.shouldDemote(phase: .processing, isPreToolUse: true))
        // record 在管的会话由 record 纠正 phase(Claude 专属)
        #expect(!StaleDemotion.shouldDemote(phase: .processing, isPreToolUse: false, recordStatusKnown: true))
        // 等审批:审批桥自带超时(Claude 120s / opencode 600s)会挪 phase
        #expect(!StaleDemotion.shouldDemote(phase: .waitingForApproval(ctx), isPreToolUse: false))
        #expect(!StaleDemotion.shouldDemote(phase: .idle, isPreToolUse: false))
        #expect(!StaleDemotion.shouldDemote(phase: .ended, isPreToolUse: false))
        // 其余静默 5 分钟的活跃/停泊态都降
        #expect(StaleDemotion.shouldDemote(phase: .processing, isPreToolUse: false))
        #expect(StaleDemotion.shouldDemote(phase: .waitingForInput, isPreToolUse: false))
        #expect(StaleDemotion.shouldDemote(phase: .compacting, isPreToolUse: false))
    }
}
