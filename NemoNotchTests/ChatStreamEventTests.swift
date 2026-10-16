import Foundation
@testable import NemoNotch
import Testing

struct ChatStreamEventTests {
    private func decode(_ json: String) -> ChatStreamEvent? {
        ChatStreamEvent.decode(Data(json.utf8))
    }

    @Test func initLineYieldsSessionStarted() {
        guard case let .sessionStarted(id) = decode(
            #"{"type":"system","subtype":"init","session_id":"abc-123","model":"claude"}"#
        ) else {
            Issue.record("expected sessionStarted")
            return
        }
        #expect(id == "abc-123")
    }

    @Test func textDeltaExtractedFromStreamEvent() {
        guard case let .textDelta(text) = decode(
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}},"session_id":"s1"}"#
        ) else {
            Issue.record("expected textDelta")
            return
        }
        #expect(text == "你好")
    }

    @Test func nonTextDeltasAreIgnored() {
        #expect(decode(
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}}"#
        ) == nil)
    }

    @Test func assistantToolUseYieldsToolStarted() {
        guard case let .toolStarted(name) = decode(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"…"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]},"session_id":"s1"}"#
        ) else {
            Issue.record("expected toolStarted")
            return
        }
        #expect(name == "Bash")
    }

    @Test func resultYieldsTurnCompleted() {
        guard case let .turnCompleted(result, isError) = decode(
            #"{"type":"result","subtype":"success","result":"done","is_error":false,"session_id":"s1"}"#
        ) else {
            Issue.record("expected turnCompleted")
            return
        }
        #expect(result == "done")
        #expect(!isError)

        guard case let .turnCompleted(errorResult, errorFlag) = decode(
            #"{"type":"result","subtype":"error_during_execution","result":"boom","is_error":true,"session_id":"s1"}"#
        ) else {
            Issue.record("expected error turnCompleted")
            return
        }
        #expect(errorResult == "boom")
        #expect(errorFlag)
    }

    @Test func unknownTypesAndGarbageAreIgnored() {
        #expect(decode(#"{"type":"user","message":{}}"#) == nil)
        #expect(decode("not json at all") == nil)
        #expect(decode(#"{"type":"system","subtype":"other"}"#) == nil)
    }

    @Test func userMessageEncodesStreamJSONInput() {
        let data = ChatStreamEvent.userMessage("跑个测试")
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "user")
        let message = object?["message"] as? [String: Any]
        #expect(message?["role"] as? String == "user")
        let content = message?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "跑个测试")
    }

    @Test func locateClaudeFindsTheInstalledBinary() {
        // On this machine claude is at ~/.bun/bin/claude; wherever it is, the
        // locator must find A executable when one of the known paths exists.
        if FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.bun/bin/claude") {
            #expect(ChatTurnRunner.locateClaude()?.path.hasPrefix(NSHomeDirectory()) == true)
        }
    }
}
