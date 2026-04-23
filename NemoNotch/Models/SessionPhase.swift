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

    private var kind: String {
        switch self {
        case .idle: return "idle"
        case .processing: return "processing"
        case .waitingForInput: return "waitingForInput"
        case .waitingForApproval: return "waitingForApproval"
        case .compacting: return "compacting"
        case .ended: return "ended"
        }
    }

    func canTransition(to next: SessionPhase) -> Bool {
        // Treat repeated same-kind updates as idempotent (e.g. processing -> processing).
        if kind == next.kind { return true }

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
             (.waitingForInput, .ended),
             (.waitingForInput, .idle):
            return true
        case (.waitingForApproval, .processing),
             (.waitingForApproval, .waitingForInput),
             (.waitingForApproval, .idle),
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

        // Try to parse as JSON for tool-specific formatting
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return formattedToolInput(toolName: toolName, json: json)
        }

        // Fallback: plain string
        if input.count > 120 {
            return String(input.prefix(120)) + "..."
        }
        return input
    }

    var isInteractiveTool: Bool {
        let normalized = toolName.replacingOccurrences(of: "_", with: "").lowercased()
        return normalized == "askuserquestion" || normalized == "askuser"
    }

    private func formattedToolInput(toolName: String, json: [String: Any]) -> String {
        // Bash: show command
        if toolName == "Bash", let cmd = json["command"] as? String {
            return truncate(cmd, limit: 100)
        }
        // Write/Edit/Read: show file path
        if ["Write", "Edit", "Read"].contains(toolName), let path = json["file_path"] as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        // Grep: show pattern
        if toolName == "Grep", let pattern = json["pattern"] as? String {
            return "pattern: \(truncate(pattern, limit: 80))"
        }
        // Glob: show pattern
        if toolName == "Glob", let pattern = json["pattern"] as? String {
            return truncate(pattern, limit: 80)
        }
        // Web: show url
        if toolName.hasPrefix("Web"), let url = json["url"] as? String {
            return truncate(url, limit: 100)
        }
        // Default: show first meaningful value
        let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = json[key] as? String, !value.isEmpty {
                return truncate(value, limit: 100)
            }
        }
        return ""
    }

    private func truncate(_ str: String, limit: Int) -> String {
        str.count > limit ? String(str.prefix(limit)) + "..." : str
    }

    static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        lhs.toolUseId == rhs.toolUseId
    }
}
