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
}
