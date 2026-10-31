import Foundation
@testable import NemoNotch
import Testing

/// Shapes copied from a real Claude Code transcript in this project: the
/// injected lines below are user-role text the user never typed.
struct UserPromptTests {
    private func user(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .user, content: text)
    }

    @Test(arguments: [
        "<task-notification>\n<task-id>aafc01c1f2761359a</task-id>\n<tool-use-id>",
        "This session is being continued from a previous conversation that ran out of context.",
        "[Image: original 2304x120, displayed at 2000x104.]",
        "[Request interrupted by user]",
        "<command-name>/compact</command-name>",
        "<local-command-stdout>ok</local-command-stdout>",
        "   ",
    ])
    func injectedTextIsNotAPrompt(_ text: String) {
        #expect(UserPrompt.isTyped(text) == false)
    }

    @Test func typedTextIsAPrompt() {
        #expect(UserPrompt.isTyped("toast 里显示的 name 是怎么来的?"))
    }

    @Test func lastSkipsTrailingInjectedLines() {
        let messages = [
            user("查看一下胶囊组件"),
            user("可以, 开个 feat 修一下"),
            user("<task-notification>\n<task-id>aabb</task-id>"),
        ]
        #expect(UserPrompt.last(in: messages) == "可以, 开个 feat 修一下")
    }

    @Test func firstSkipsLeadingContinuationSummary() {
        let messages = [
            user("This session is being continued from a previous conversation that ran out of context."),
            user("推送到远端吧"),
        ]
        #expect(UserPrompt.first(in: messages) == "推送到远端吧")
    }

    @Test func onlyInjectedLinesGiveNil() {
        #expect(UserPrompt.last(in: [user("<task-notification>x</task-notification>")]) == nil)
    }

    // MARK: - Transcript-level (isMeta)

    /// Writes JSONL lines to a temp transcript and returns the parsed messages.
    private func parse(_ lines: [[String: Any]]) throws -> [ChatMessage] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = try lines
            .map { try String(bytes: JSONSerialization.data(withJSONObject: $0), encoding: .utf8) ?? "" }
        try (body.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return ConversationParser.parseFullResult(filePath: url.path).messages
    }

    private func userLine(_ text: String, meta: Bool = false) -> [String: Any] {
        var line: [String: Any] = [
            "type": "user",
            "uuid": UUID().uuidString,
            "timestamp": "2026-10-31T10:00:00.000Z",
            "message": ["role": "user", "content": text],
        ]
        if meta {
            line["isMeta"] = true
        }
        return line
    }

    @Test func metaLinesAfterThePromptAreNotTheTitle() throws {
        // A skill loading after the prompt injects an isMeta user line.
        let messages = try parse([
            userLine("帮我审查一下胶囊组件"),
            userLine("Base directory for this skill: /Users/me/.claude/skills/review\n\n# Review", meta: true),
        ])
        #expect(UserPrompt.last(in: messages) == "帮我审查一下胶囊组件")
    }

    @Test func pastedImagePromptIsTyped() {
        // A prompt with a pasted image is recorded as "[Image #1] …" and is the user's own text.
        #expect(UserPrompt.isTyped("[Image #1] 看看这里为什么歪了"))
    }

    @Test func injectedImagePlaceholderIsNot() {
        #expect(UserPrompt.isTyped("[Image: original 2304x120, displayed at 2000x104.]") == false)
    }
}
