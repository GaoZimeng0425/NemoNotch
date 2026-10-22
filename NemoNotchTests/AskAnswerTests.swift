import Foundation
@testable import NemoNotch
import Testing

/// Answering a multi-choice ask from the bar: which press answers at once,
/// when Send is live, and the `answers` object the response carries.
@Suite("Ask answer")
struct AskAnswerTests {
    private let single = InteractivePrompt(questions: [
        InteractivePrompt.Question(
            text: "Which?",
            choices: [
                InteractivePrompt.Choice(label: "A", detail: nil),
                InteractivePrompt.Choice(label: "B", detail: nil),
            ]
        ),
    ])

    private let multiSelect = InteractivePrompt(questions: [
        InteractivePrompt.Question(
            text: "Pick any",
            choices: [.init(label: "x", detail: nil), .init(label: "y", detail: nil), .init(label: "z", detail: nil)],
            multiSelect: true
        ),
    ])

    private let twoQuestions = InteractivePrompt(questions: [
        InteractivePrompt.Question(text: "Q1?", choices: [.init(label: "a", detail: nil)]),
        InteractivePrompt.Question(text: "Q2?", choices: [.init(label: "b", detail: nil)]),
    ])

    @Test func oneSingleSelectQuestionAnswersWithThePress() {
        #expect(AskAnswer.immediateReply(question: 0, option: 1, prompt: single) == ["Which?": "B"])
        #expect(AskAnswer.immediateReply(question: 5, option: 9, prompt: single) == nil)
    }

    @Test func ticksAndSeveralQuestionsOnlyPick() {
        #expect(AskAnswer.immediateReply(question: 0, option: 0, prompt: multiSelect) == nil)
        #expect(AskAnswer.immediateReply(question: 0, option: 0, prompt: twoQuestions) == nil)
    }

    @Test func sendIsLiveOnlyWhenEveryQuestionIsAnswered() {
        #expect(!AskAnswer.isComplete(picks: [:], prompt: multiSelect))
        #expect(!AskAnswer.isComplete(picks: [0: [0]], prompt: twoQuestions))
        #expect(AskAnswer.isComplete(picks: [0: [0], 1: [0]], prompt: twoQuestions))
        // An index out of the question's options answers nothing.
        #expect(!AskAnswer.isComplete(picks: [0: [7]], prompt: multiSelect))
    }

    @Test func multiSelectJoinsInOptionOrderNotSetOrder() {
        let answers = AskAnswer.answers(picks: [0: [2, 0]], prompt: multiSelect)
        #expect(answers == ["Pick any": "x, z"])
    }

    @Test func wireFormatCarriesOriginalInputAndAnswers() throws {
        let original = #"{"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}]}],"header":"x"}"#
        let data = try HookResponse.answer(originalInput: original, answers: ["Which?": "A"]).jsonData()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try #require(json["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(output["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedInput"] as? [String: Any])
        // The original input rides along whole — updatedInput REPLACES it.
        #expect((updated["header"] as? String) == "x")
        #expect(updated["questions"] != nil)
        #expect((updated["answers"] as? [String: String]) == ["Which?": "A"])
    }

    @Test func unparseableOriginalInputStillCarriesTheAnswers() throws {
        let data = try HookResponse.answer(originalInput: "not json", answers: ["Q": "yes"]).jsonData()
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decision = try #require(
            ((json["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        )
        let updated = try #require(decision["updatedInput"] as? [String: Any])
        #expect((updated["answers"] as? [String: String]) == ["Q": "yes"])
    }

    @Test func parsesMultiSelectFlag() throws {
        let input = """
        {"questions":[{"question":"Pick?","multiSelect":true,
         "options":[{"label":"a","description":"1"},{"label":"b","description":"2"}]}]}
        """
        let json = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let prompt = try #require(InteractivePrompt.parse(json))
        #expect(prompt.questions[0].multiSelect)
        #expect(!single.questions[0].multiSelect)
    }
}
