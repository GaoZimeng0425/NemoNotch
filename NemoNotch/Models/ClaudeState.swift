import Foundation

struct ClaudeState: Identifiable {
    let id: String
    var phase: SessionPhase = .idle
    var currentTool: String?
    var cwd: String?
    var lastMessage: String?
    var lastEventName: String?
    var isPreToolUse = false
    var sessionStart: Date
    var lastEventTime: Date
    var firstUserMessage: String?
    var lastUserMessage: String?
    var messages: [ChatMessage] = []
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var lastParsedOffset: UInt64 = 0

    init(sessionId: String) {
        self.id = sessionId
        self.sessionStart = Date()
        self.lastEventTime = Date()
    }

    var projectFolder: String? {
        guard let cwd else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var displayTitle: String {
        if let msg = firstUserMessage, !msg.isEmpty { return msg }
        if let folder = projectFolder { return folder }
        return "Session \(id.prefix(8))"
    }

    /// Derived status for backward compatibility with CompactBadge and ClaudeTab
    var status: ClaudeStatus {
        switch phase {
        case .idle, .ended: return .idle
        case .processing, .compacting: return .working
        case .waitingForInput: return .waiting
        case .waitingForApproval: return .waiting
        }
    }

    var totalTokens: Int { inputTokens + outputTokens }

    var tokenDisplay: String {
        let total = totalTokens
        if total >= 1000 {
            return String(format: "%.1fk", Double(total) / 1000.0)
        }
        return "\(total)"
    }
}

/// Legacy status enum kept for UI compatibility
enum ClaudeStatus: Equatable {
    case idle
    case working
    case waiting
}
