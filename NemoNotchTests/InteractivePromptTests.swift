import Foundation
@testable import NemoNotch
import Testing

/// The multi-choice ask: AskUserQuestion's questions and choices, parsed for
/// display (the hook protocol cannot answer them), and the card body that
/// carries them.
@Suite("Interactive prompt")
struct InteractivePromptTests {
    private func askContext(_ toolInput: String) -> PermissionContext {
        PermissionContext(
            toolUseId: "t",
            toolName: "AskUserQuestion",
            toolInput: toolInput,
            receivedAt: Date()
        )
    }

    @Test func parsesClaudeShapeQuestionsArray() throws {
        let input = """
        {"questions":[{"question":"Which framework?","header":"Framework","multiSelect":false,
         "options":[{"label":"React","description":"React with Vite"},
                    {"label":"Vue","description":"Vue 3"}]}]}
        """
        let json = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let prompt = try #require(InteractivePrompt.parse(json))
        #expect(prompt.questions.count == 1)
        #expect(prompt.questions[0].text == "Which framework?")
        #expect(prompt.questions[0].choices.map(\.label) == ["React", "Vue"])
        #expect(prompt.questions[0].choices[1].detail == "Vue 3")
        #expect(prompt.summary == "Which framework? → React / Vue")
    }

    @Test func parsesSeveralQuestionsAndTheOldTopLevelShape() throws {
        let twoQuestions = """
        {"questions":[{"question":"A?","options":[{"label":"a1","description":"x"},{"label":"a2","description":"y"}]},
                      {"question":"B?","options":[{"label":"b1","description":null},{"label":"b2","description":"z"}]}]}
        """
        let twoJson = try #require(JSONSerialization.jsonObject(with: Data(twoQuestions.utf8)) as? [String: Any])
        let prompt = try #require(InteractivePrompt.parse(twoJson))
        #expect(prompt.questions.map(\.text) == ["A?", "B?"])
        #expect(prompt.questions[1].choices[0].detail == nil)
        #expect(prompt.summary == "A? → a1 / a2; B? → b1 / b2")

        let topLevel = """
        {"question":"Ship it?","options":[{"label":"yes","description":"go"},{"label":"no","description":"stop"}]}
        """
        let topJson = try #require(JSONSerialization.jsonObject(with: Data(topLevel.utf8)) as? [String: Any])
        let single = try #require(InteractivePrompt.parse(topJson))
        #expect(single.questions.count == 1)
        #expect(single.questions[0].choices.map(\.label) == ["yes", "no"])
    }

    @Test func garbageMeansNoPrompt() {
        for json in [["other": "x"], ["questions": []], ["questions": [["options": []]]]] {
            #expect(InteractivePrompt.parse(json) == nil)
        }
        #expect(askContext("not json").interactivePrompt == nil)
        #expect(askContext(#"{"questions":"oops"}"#).interactivePrompt == nil)
    }

    @Test func onlyInteractiveToolsGetAPrompt() {
        let bash = PermissionContext(
            toolUseId: "t", toolName: "Bash",
            toolInput: #"{"questions":[{"question":"Q?","options":[{"label":"a","description":""}]}]}"#,
            receivedAt: Date()
        )
        #expect(bash.interactivePrompt == nil)
        #expect(askContext(#"{"questions":[{"question":"Q?","options":[{"label":"a","description":""}]}]}"#)
            .interactivePrompt != nil)
    }

    @Test func displayInputSummarizesTheAsk() {
        let context =
            askContext(
                #"{"questions":[{"question":"Which?","options":[{"label":"A","description":"x"},{"label":"B","description":"y"}]}]}"#
            )
        #expect(context.displayInput == "Which? → A / B")
    }

    @Test func cardBodyCarriesThePrompt() {
        var s = AISessionState(sessionId: "s", source: .claude)
        let context =
            askContext(
                #"{"questions":[{"question":"Which?","options":[{"label":"A","description":"x"},{"label":"B","description":"y"}]}]}"#
            )
        s.phase = .waitingForApproval(context)
        let body = EdgeBarCardModel.body(of: s)
        #expect(body.asksToChoose)
        #expect(body == .approval(tool: "AskUserQuestion", input: "Which? → A / B", prompt: context.interactivePrompt))

        s.phase = .waitingForApproval(PermissionContext(
            toolUseId: "t", toolName: "Bash", toolInput: #"{"command":"ls"}"#, receivedAt: Date()
        ))
        let binary = EdgeBarCardModel.body(of: s)
        #expect(!binary.asksToChoose)
        #expect(binary == .approval(tool: "Bash", input: "ls", prompt: nil))

        #expect(!EdgeBarCardModel.Body.reply("hi").asksToChoose)

        // A parsed ask with no choice anywhere falls back to the binary card.
        s.phase = .waitingForApproval(askContext(#"{"questions":[{"question":"Only a question?","options":[]}]}"#))
        #expect(!EdgeBarCardModel.body(of: s).asksToChoose)
    }
}
