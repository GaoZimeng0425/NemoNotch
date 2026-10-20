import Foundation

/// What the detail card says, decided apart from the drawing (evlat's card):
/// the status line's trailing facts and which body section shows.
enum EdgeBarCardModel {
    enum Body: Equatable {
        /// A held permission: the tool and its input, with Deny/Allow.
        case approval(tool: String, input: String)
        /// The last reply of a turn that ended (parked at the prompt).
        case reply(String)
        /// The turn's last tool and what it was about.
        case tool(name: String, subject: String?)
        case none
    }

    /// Approval first; then a finished turn's reply; then the turn's last
    /// tool (kept after it finished). A turn still thinking says nothing.
    static func body(of session: AISessionState) -> Body {
        if case let .waitingForApproval(context) = session.phase {
            return .approval(tool: context.toolName, input: context.displayInput)
        }
        if session.phase == .waitingForInput, let reply = lastReply(of: session) {
            return .reply(reply)
        }
        if let name = session.lastToolName {
            return .tool(name: name, subject: session.lastToolSubject)
        }
        return .none
    }

    /// The newest assistant text, its paragraphs run together, capped.
    static func lastReply(of session: AISessionState, limit: Int = 400) -> String? {
        guard let text = session.messages.last(where: { $0.role == .assistant })?.content else { return nil }
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > limit ? String(words.prefix(limit - 1)) + "…" : words
    }

    /// "7 min · 41 tools" after the status word. No tools yet says nothing
    /// about tools ("0 tools" under a first approval is noise).
    static func meta(waited: TimeInterval, tools: Int) -> String {
        let minutes = Int(waited / 60)
        var parts = [
            minutes >= 1
                ? String(format: String(localized: "edge_bar.min_fmt"), minutes)
                : String(localized: "edge_bar.moments"),
        ]
        if tools == 1 {
            parts.append(String(localized: "edge_bar.tools_one"))
        } else if tools > 1 {
            parts.append(String(format: String(localized: "edge_bar.tools_fmt"), tools))
        }
        return parts.joined(separator: " · ")
    }

    /// The go button's title: where it goes, named by the app.
    static func goTitle(host: String?) -> String {
        guard let host else { return String(localized: "edge_bar.jump") }
        return String(format: String(localized: "edge_bar.open_in_fmt"), host)
    }
}
