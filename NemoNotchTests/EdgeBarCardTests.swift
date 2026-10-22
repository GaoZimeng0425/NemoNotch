import Foundation
@testable import NemoNotch
import Testing

@Suite("EdgeBar card data")
struct EdgeBarCardTests {
    // MARK: Hook payload → tool subject

    @Test func hookEventDecodesToolInputAndSubject() throws {
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash",
         "tool_input":{"command":"sed -n 1,12p a.sh; \\\\\\n  echo done\\nsecond line","timeout":5}}
        """
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.toolSubject == "sed -n 1,12p a.sh; echo done")
        let input = try #require(event.toolInput)
        #expect(input.contains(#""timeout":5"#))
    }

    @Test func subjectPrefersCommandThenPathThenQuestion() {
        #expect(ToolSubject.subject(of: ["file_path": "/a/b.swift", "description": "x"]) == "/a/b.swift")
        #expect(ToolSubject.subject(of: ["questions": [["question": "Which one?\nmore"]]]) == "Which one?")
        #expect(ToolSubject.subject(of: ["other": "x"]) == nil)
        let long = String(repeating: "a", count: 300)
        #expect(ToolSubject.subject(of: ["command": long])?.count == ToolSubject.limit)
    }

    @Test func toolInputIsOnlyDecodedWhereItIsUsed() throws {
        let json = #"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Write","tool_input":{"file_path":"/a"}}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.toolInput == nil)
        #expect(event.toolSubject == nil)
    }

    @Test func malformedToolInputKeepsTheEvent() throws {
        let json = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":"just text"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.toolName == "Bash")
        #expect(event.toolSubject == nil)
    }

    // MARK: Turn bookkeeping

    @Test func toolsAreCountedPerTurnAndTheLastIsKept() {
        var s = AISessionState(sessionId: "s", source: .claude)
        s.recordTool(HookEvent(hookEventName: "PreToolUse", toolName: "Bash", toolSubject: "ls"))
        s.recordTool(HookEvent(hookEventName: "PreToolUse", toolName: "Read", toolSubject: "/a"))
        #expect(s.turnToolCount == 2)
        #expect(s.lastToolName == "Read")
        #expect(s.lastToolSubject == "/a")
        s.beginTurn()
        #expect(s.turnToolCount == 0)
        #expect(s.lastToolName == nil)
    }

    // MARK: Card body / meta / button

    @Test func bodyPrefersApprovalThenReplyThenLastTool() {
        var s = AISessionState(sessionId: "s", source: .claude)
        #expect(EdgeBarCardModel.body(of: s) == .none)
        s.lastToolName = "Bash"
        s.lastToolSubject = "ls"
        s.phase = .processing
        #expect(EdgeBarCardModel.body(of: s) == .tool(name: "Bash", subject: "ls"))
        s.messages = [ChatMessage(id: "1", role: .assistant, content: "Done.\n\nAll  good")]
        s.phase = .waitingForInput
        #expect(EdgeBarCardModel.body(of: s) == .reply("Done. All good"))
        s.phase = .waitingForApproval(PermissionContext(
            toolUseId: "t", toolName: "Edit", toolInput: nil, receivedAt: Date()
        ))
        #expect(EdgeBarCardModel.body(of: s) == .approval(tool: "Edit", input: "", prompt: nil))
    }

    @Test func metaSaysToolsOnlyWhenThereAreAny() {
        #expect(!EdgeBarCardModel.meta(waited: 7 * 60, tools: 0).contains("·"))
        let many = EdgeBarCardModel.meta(waited: 7 * 60, tools: 41)
        #expect(many.contains("7") && many.contains("41"))
        #expect(EdgeBarCardModel.meta(waited: 10, tools: 1).contains("1"))
    }

    @Test func goTitleNamesTheHostApp() {
        #expect(EdgeBarCardModel.goTitle(host: "Zap").contains("Zap"))
        #expect(EdgeBarCardModel.goTitle(host: nil) == String(localized: "edge_bar.jump"))
    }

    // MARK: Git branch (from the transcript, never the repo)

    @Test func parserTakesTheBranchFromTranscriptLines() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lines = [
            #"{"type":"user","uuid":"1","gitBranch":"develop","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"user","uuid":"2","gitBranch":"feature/card","message":{"role":"user","content":"again"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let result = ConversationParser.parseIncremental(filePath: path, fromOffset: 0)
        #expect(result.lastGitBranch == "feature/card")
    }
}
