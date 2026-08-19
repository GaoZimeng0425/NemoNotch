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

    @Test func decodesCliPID() throws {
        let json = #"{"hook_event_name":"SessionStart","session_id":"s1","cli_source":"claude","cli_pid":4242}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.cliPID == 4242)
    }

    @Test func cliPIDIsNilWhenAbsent() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.cliPID == nil)
    }

    @Test func cliPIDIsTolerantlyNilWhenNotNumeric() throws {
        // A foreign emitter sending a garbage value must not drop the event
        // (nor its other fields).
        let json = #"{"hook_event_name":"Stop","session_id":"s1","cli_source":"claude","cli_pid":"not-a-number"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.cliPID == nil)
        #expect(event.cliSource == "claude")
        #expect(event.sessionId == "s1")
    }
}
