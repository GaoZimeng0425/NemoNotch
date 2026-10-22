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
        if case .waitingForApproval = self {
            return true
        }
        return false
    }

    /// Phases the AI-status capsule tracks: any state where the CLI is still
    /// mid-conversation — running, or parked at a prompt / permission choice.
    /// Wider than `isActive` (which excludes `waitingForInput`) because a
    /// session waiting for the next prompt still deserves the status light.
    var isEngaged: Bool {
        switch self {
        case .processing, .compacting, .waitingForApproval, .waitingForInput: true
        case .idle, .ended: false
        }
    }

    var approvalToolName: String? {
        if case let .waitingForApproval(ctx) = self {
            return ctx.toolName
        }
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
        if kind == next.kind {
            return true
        }

        switch (self, next) {
        case (.idle, .processing), (.idle, .ended), (.idle, .waitingForInput), (.idle, .waitingForApproval):
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

/// An AskUserQuestion-shaped ask: the questions and the choices each
/// offers, answered from the bar (`AskAnswer` builds the reply).
struct InteractivePrompt: Equatable {
    struct Question: Equatable {
        let text: String
        let choices: [Choice]
        let multiSelect: Bool

        init(text: String, choices: [Choice], multiSelect: Bool = false) {
            self.text = text
            self.choices = choices
            self.multiSelect = multiSelect
        }
    }

    struct Choice: Equatable {
        let label: String
        let detail: String?
    }

    let questions: [Question]

    /// "Which framework? → React / Vue", the questions run together — the
    /// one-line form for the status row and the notch tab.
    var summary: String {
        questions
            .map { question in
                question.choices.isEmpty
                    ? question.text
                    : "\(question.text) → \(question.choices.map(\.label).joined(separator: " / "))"
            }
            .joined(separator: "; ")
    }

    /// Claude Code's AskUserQuestion: `{"questions": [{question, options:
    /// [{label, description}]}]}` (1–4 questions, 2–4 options each). An
    /// older shape puts one `{question, options}` at the top level — accept
    /// both. Nil when there is nothing to ask — and when two questions share
    /// a text: the answer is keyed by that text, and a duplicate would
    /// answer the wrong one (evlat's rule).
    static func parse(_ json: [String: Any]) -> InteractivePrompt? {
        var raw = json["questions"] as? [[String: Any]] ?? []
        if raw.isEmpty, json["question"] != nil {
            raw = [json]
        }
        var seenTexts: Set<String> = []
        var questions: [Question] = []
        for entry in raw {
            // An entry that cannot be answered by key refuses the whole ask,
            // not just itself: an empty text has no key, and a duplicate
            // text would have one answer land on the wrong question.
            guard let text = (entry["question"] as? String), !text.isEmpty,
                  seenTexts.insert(text).inserted
            else { return nil }
            let choices = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> Choice? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return Choice(label: label, detail: option["description"] as? String)
            }
            questions.append(Question(
                text: text, choices: choices, multiSelect: entry["multiSelect"] as? Bool ?? false
            ))
        }
        return questions.isEmpty ? nil : InteractivePrompt(questions: questions)
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
            if isInteractiveTool, let prompt = InteractivePrompt.parse(json) {
                return truncate(prompt.summary, limit: 160)
            }
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

    /// The parsed ask of an AskUserQuestion-shaped tool; nil for everything
    /// else (and for an interactive tool whose input did not parse).
    var interactivePrompt: InteractivePrompt? {
        guard isInteractiveTool,
              let input = toolInput,
              let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return InteractivePrompt.parse(json)
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

/// The bar's side of answering an `InteractivePrompt`: which press answers
/// at once, when the Send button is live, and the `answers` object the
/// response carries (question text → answer; a multi-select is its labels
/// joined by ", " in the options' own order). Pure, unit-tested.
enum AskAnswer {
    /// A press on one option of one question: the whole reply when one
    /// press is the whole answer — a single single-select question. Nil
    /// when the press only picks (something to tick, or more questions
    /// than one to answer together).
    static func immediateReply(question: Int, option: Int, prompt: InteractivePrompt) -> [String: String]? {
        guard prompt.questions.count == 1, question == 0, option >= 0,
              !prompt.questions[0].multiSelect,
              option < prompt.questions[0].choices.count
        else { return nil }
        let q = prompt.questions[0]
        return [q.text: q.choices[option].label]
    }

    /// Send is live only with every question answered — a question missing
    /// from `answers` reaches Claude unanswered, so a draft never goes.
    static func isComplete(picks: [Int: Set<Int>], prompt: InteractivePrompt) -> Bool {
        answers(picks: picks, prompt: prompt) != nil
    }

    /// The `answers` object for what is picked, or nil while any question
    /// has nothing picked. Multi-select labels keep the options' order.
    static func answers(picks: [Int: Set<Int>], prompt: InteractivePrompt) -> [String: String]? {
        var answers: [String: String] = [:]
        for (index, question) in prompt.questions.enumerated() {
            guard let picked = picks[index], !picked.isEmpty else { return nil }
            let labels = question.choices.enumerated()
                .filter { picked.contains($0.offset) }
                .map(\.element.label)
            guard !labels.isEmpty else { return nil }
            answers[question.text] = labels.joined(separator: ", ")
        }
        return answers
    }
}
