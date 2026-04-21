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
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var lastContextTokens: Int = 0
    var model: String?
    var lastParsedOffset: UInt64 = 0
    var subagentState = SubagentState()

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

    var contextTokens: Int { cacheReadTokens + cacheCreationTokens }

    /// Latest request's context usage as fraction of 200K window
    var contextPercent: Double {
        guard lastContextTokens > 0 else { return 0 }
        return min(Double(lastContextTokens) / 200_000.0, 1.0)
    }

    var tokenDisplay: String {
        let total = totalTokens
        if total >= 1000 {
            return String(format: "%.1fk", Double(total) / 1000.0)
        }
        return "\(total)"
    }

    var contextDisplay: String {
        let ctx = contextTokens
        if ctx >= 1_000_000 {
            return String(format: "%.1fM", Double(ctx) / 1_000_000)
        }
        if ctx >= 1000 {
            return String(format: "%.1fk", Double(ctx) / 1000.0)
        }
        return "\(ctx)"
    }

    var contextTokenDisplay: String {
        let t = lastContextTokens
        if t >= 1_000_000 {
            return String(format: "%.1fM", Double(t) / 1_000_000)
        }
        if t >= 1000 {
            return String(format: "%.1fK", Double(t) / 1000.0)
        }
        return "\(t)"
    }

    /// Human-readable model name (e.g. "Sonnet 4.6")
    var displayModel: String? {
        guard let model, !model.isEmpty else { return nil }
        var cleaned = model
        if cleaned.hasPrefix("claude-") { cleaned = String(cleaned.dropFirst(6)) }
        // Strip date suffix like -20241022
        if let range = cleaned.range(of: "-\\d{8,}$", options: .regularExpression) {
            cleaned = String(cleaned[..<range.lowerBound])
        }
        let parts = cleaned.split(separator: "-")
        // New format: sonnet-4-6, opus-4-7, haiku-4-5
        if parts.count == 3, Int(parts[1]) != nil, Int(parts[2]) != nil {
            return "\(parts[0].capitalized) \(parts[1]).\(parts[2])"
        }
        // Old format: 3-5-sonnet
        if parts.count >= 3, Int(parts[0]) != nil {
            return "\(parts[0]).\(parts[1]) \(parts[2].capitalized)"
        }
        return cleaned
    }
}

/// Legacy status enum kept for UI compatibility
enum ClaudeStatus: Equatable {
    case idle
    case working
    case waiting
}
