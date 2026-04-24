import Foundation

enum AISource: String, Codable, CaseIterable {
    case claude
    case gemini
}

protocol AIProvider: AnyObject, Observable {
    var source: AISource { get }
    var sessions: [String: AISessionState] { get set }
    var activeSession: AISessionState? { get set }
    var isHookInstalled: Bool { get set }
    func handleEvent(_ event: HookEvent)
    func installHooks()
    func uninstallHooks()
    func respondToPermission(sessionId: String, approved: Bool)
}

struct AISessionState: Identifiable {
    let id: String
    let source: AISource
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

    init(sessionId: String, source: AISource) {
        self.id = sessionId
        self.source = source
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

    var displayModel: String? {
        guard let model, !model.isEmpty else { return nil }
        switch source {
        case .claude:
            return formatClaudeModel(model)
        case .gemini:
            return formatGeminiModel(model)
        }
    }

    private func formatClaudeModel(_ model: String) -> String {
        var cleaned = model
        if cleaned.hasPrefix("claude-") { cleaned = String(cleaned.dropFirst(6)) }
        if let range = cleaned.range(of: "-\\d{8,}$", options: .regularExpression) {
            cleaned = String(cleaned[..<range.lowerBound])
        }
        let parts = cleaned.split(separator: "-")
        if parts.count == 3, Int(parts[1]) != nil, Int(parts[2]) != nil {
            return "\(parts[0].capitalized) \(parts[1]).\(parts[2])"
        }
        if parts.count >= 3, Int(parts[0]) != nil {
            return "\(parts[0]).\(parts[1]) \(parts[2].capitalized)"
        }
        return cleaned
    }

    private func formatGeminiModel(_ model: String) -> String {
        var cleaned = model
        if cleaned.hasPrefix("gemini-") { cleaned = String(cleaned.dropFirst(6)) }
        if let range = cleaned.range(of: "-\\d{8,}$", options: .regularExpression) {
            cleaned = String(cleaned[..<range.lowerBound])
        }
        return cleaned
            .replacingOccurrences(of: "-preview", with: "")
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

enum ClaudeStatus: Equatable {
    case idle
    case working
    case waiting
}
