import Foundation

enum SessionPhase: Equatable {
    case idle
    case processing
    case waitingForInput
    case waitingForApproval(PermissionContext)
    case compacting
    case ended

    var needsAttention: Bool {
        switch self {
        case .waitingForInput, .waitingForApproval: true
        default: false
        }
    }

    var isActive: Bool {
        switch self {
        case .processing, .compacting, .waitingForApproval: true
        default: false
        }
    }

    var isWaitingForApproval: Bool {
        if case .waitingForApproval = self { return true }
        return false
    }

    var approvalToolName: String? {
        if case .waitingForApproval(let ctx) = self { return ctx.toolName }
        return nil
    }

    func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        case (.idle, .processing), (.idle, .ended):
            return true
        case (.processing, .waitingForInput),
             (.processing, .waitingForApproval),
             (.processing, .compacting),
             (.processing, .idle),
             (.processing, .ended):
            return true
        case (.waitingForInput, .processing),
             (.waitingForInput, .ended):
            return true
        case (.waitingForApproval, .processing),
             (.waitingForApproval, .ended):
            return true
        case (.compacting, .processing),
             (.compacting, .ended):
            return true
        case (.ended, _):
            return false
        default:
            return false
        }
    }

    func transition(to next: SessionPhase) -> SessionPhase {
        guard canTransition(to: next) else {
            LogService.warn("Invalid phase transition: \(self) → \(next)", category: "SessionPhase")
            return self
        }
        return next
    }
}

struct PermissionContext: Equatable {
    let toolUseId: String
    let toolName: String
    let toolInput: String?
    let receivedAt: Date

    var displayInput: String {
        guard let input = toolInput, !input.isEmpty else { return "" }
        if input.count > 120 {
            return String(input.prefix(120)) + "..."
        }
        return input
    }

    static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        lhs.toolUseId == rhs.toolUseId
    }
}
