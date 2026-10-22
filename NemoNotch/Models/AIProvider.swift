import Foundation

enum AISource: String, Codable, CaseIterable {
    case claude
    case gemini
    case opencode
    case zcode
}

@MainActor
protocol AIProvider: AnyObject, Observable {
    var source: AISource { get }
    var isHookInstalled: Bool { get set }
    func handleEvent(_ event: HookEvent)
    func installHooks()
    func uninstallHooks()
    func respondToPermission(sessionId: String, approved: Bool)
}

extension AIProvider {
    /// Answering an AskUserQuestion from the notch: only Claude's
    /// PermissionRequest protocol carries it (allow + updatedInput).
    func respondToAsk(sessionId: String, originalInput: String, answers: [String: String]) {}
}

struct AISessionState: Identifiable {
    let id: String
    /// Mutable so an explicit per-event `cli_source` can correct a session that
    /// was first created by another provider (e.g. an untagged event minting a
    /// `.claude` phantom before the opencode-tagged event arrives). See
    /// `AISessionStore.mutateOrCreate`.
    var source: AISource
    var phase: SessionPhase = .idle
    /// When `phase` last changed — stamped by `AISessionStore` on every
    /// mutation that moves the phase. Time-in-phase readers (waiting
    /// reminder) key off this; nil means the session never left its initial
    /// phase.
    var phaseChangedAt: Date?
    var currentTool: String?
    /// The turn's last tool and its one-line subject (`ToolSubject`) —
    /// kept after the tool finishes, cleared by the next prompt, so the
    /// edge bar's card can say what the session last did.
    var lastToolName: String?
    var lastToolSubject: String?
    /// Tools run this turn (`PreToolUse`s since the last prompt).
    var turnToolCount: Int = 0
    /// The git branch the session works on (Claude: from its transcript).
    var gitBranch: String?
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
    var thoughtTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var lastContextTokens: Int = 0 {
        didSet { noteContextWindow() }
    }

    var model: String? {
        didSet { noteContextWindow() }
    }

    /// The model this session was seen running with more than its listed
    /// window (so with 1M). Kept after its context falls back — a `/compact`
    /// shrinks the prompt, not the window.
    private(set) var upgradedContextModel: String?
    /// Host terminal/IDE app of the session, resolved from the hook's
    /// `cli_pid` by walking the process tree up to the first GUI app
    /// (`AppActivator.recordHost`). Bundle id is cached alongside to detect
    /// PID reuse after the host quits. Both nil for plugin-based emitters
    /// (opencode) and CLI runs with no GUI ancestor (tmux/ssh).
    var launchingAppPID: Int32?
    /// Set when the session is backed by a live Claude Code record
    /// (`ClaudeSessionRecords`): its process, and the name Claude gave it.
    /// Such a session lives exactly as long as that process.
    var recordPID: Int32?
    var recordName: String?
    /// The record carries a busy/idle status — then it, not the silence
    /// timer, corrects a stale phase.
    var recordStatusKnown = false
    var launchingAppBundleId: String?
    /// Tab-reveal URL captured from the CLI's inherited environment at event
    /// time (`TabLink`): terminals that publish one (iTerm2, Warp, …) let a
    /// jump land on the exact tab, not just the app. Never changes for the
    /// process's lifetime, so it stays valid after the CLI exits.
    var tabLinkURL: String?
    var lastParsedOffset: UInt64 = 0
    var subagentState = SubagentState()

    init(sessionId: String, source: AISource) {
        id = sessionId
        self.source = source
        sessionStart = Date()
        lastEventTime = Date()
    }

    mutating func upsertMessage(_ message: ChatMessage) {
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx] = message
        } else {
            messages.append(message)
        }
    }

    var projectFolder: String? {
        guard let cwd else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var displayTitle: String {
        if let msg = firstUserMessage, !msg.isEmpty {
            return msg
        }
        if let folder = projectFolder {
            return folder
        }
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

    var totalTokens: Int {
        inputTokens + outputTokens + thoughtTokens
    }

    var contextTokens: Int {
        cacheReadTokens + cacheCreationTokens
    }

    /// The window the latest call ran in (a Claude session seen past its
    /// listed window ran with 1M).
    var contextLimit: Int {
        let model = model ?? ""
        if upgradedContextModel == model {
            return max(ModelContextWindow.limit(for: model), ModelContextWindow.claudeOneMillion)
        }
        return ModelContextWindow.limit(for: model, observed: lastContextTokens)
    }

    private mutating func noteContextWindow() {
        let model = model ?? ""
        if ModelContextWindow.limit(for: model, observed: lastContextTokens) > ModelContextWindow.limit(for: model) {
            upgradedContextModel = model
        }
    }

    var contextPercent: Double {
        guard lastContextTokens > 0 else { return 0 }
        return min(Double(lastContextTokens) / Double(contextLimit), 1.0)
    }

    var contextLimitDisplay: String {
        let limit = contextLimit
        if limit >= 1_000_000 {
            return String(format: "%.0fM", Double(limit) / 1_000_000)
        }
        return String(format: "%.0fK", Double(limit) / 1000)
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
        case .opencode:
            return formatOpencodeModel(model)
        case .zcode:
            return formatZcodeModel(model)
        }
    }

    private func formatClaudeModel(_ model: String) -> String {
        var cleaned = model
        if cleaned.hasPrefix("claude-") {
            cleaned = String(cleaned.dropFirst(6))
        }
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
        if cleaned.hasPrefix("gemini-") {
            cleaned = String(cleaned.dropFirst(6))
        }
        if let range = cleaned.range(of: "-\\d{8,}$", options: .regularExpression) {
            cleaned = String(cleaned[..<range.lowerBound])
        }
        return cleaned
            .replacingOccurrences(of: "-preview", with: "")
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func formatOpencodeModel(_ model: String) -> String {
        // opencode model ids are "vendor/model" (e.g. "anthropic/claude-sonnet-4-5").
        let bare = model.split(separator: "/").last.map(String.init) ?? model
        return bare
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func formatZcodeModel(_ model: String) -> String {
        // zcode runs GLM models, e.g. "glm-4.6" → "GLM 4.6".
        model
            .split(separator: "-")
            .map { $0.lowercased() == "glm" ? "GLM" : String($0) }
            .joined(separator: " ")
    }
}

enum ClaudeStatus: Equatable {
    case idle
    case working
    case waiting
}

extension AISessionState {
    /// A new prompt starts a turn: its tools are counted afresh.
    mutating func beginTurn() {
        turnToolCount = 0
        lastToolName = nil
        lastToolSubject = nil
    }

    /// A `PreToolUse`: the turn's newest tool, and one more counted.
    mutating func recordTool(_ event: HookEvent) {
        guard let name = event.toolName else { return }
        lastToolName = name
        lastToolSubject = event.toolSubject
        turnToolCount += 1
    }
}
