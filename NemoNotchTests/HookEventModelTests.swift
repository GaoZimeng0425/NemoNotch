import Foundation
@testable import NemoNotch
import Testing

struct HookEventModelTests {
    @Test func decodesModelField() throws {
        let json = #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","model":"anthropic/claude-sonnet-4-5","cli_source":"opencode"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.model == "anthropic/claude-sonnet-4-5")
    }

    @Test func modelIsNilWhenAbsent() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.model == nil)
    }
}
