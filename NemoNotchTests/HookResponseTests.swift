import Foundation
@testable import NemoNotch
import Testing

@Suite("HookResponse encoding")
struct HookResponseTests {
    private static func encode(_ value: HookResponse) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test("Ack encodes to {\"status\":\"ok\"}")
    func ack() throws {
        #expect(try Self.encode(.ack) == #"{"status":"ok"}"#)
    }

    // Claude Code (>= 2.x) parses the permission decision from
    // hookSpecificOutput.decision.behavior. The legacy flat {"decision":"allow"}
    // shape is silently ignored, leaving the CLI blocked at its terminal prompt.

    @Test("Allow decision nests behavior under hookSpecificOutput")
    func allow() throws {
        #expect(try Self.encode(.decision(.allow)) ==
            #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
    }

    @Test("Deny decision encodes reason as message")
    func denyTimeout() throws {
        #expect(try Self.encode(.decision(.deny(reason: .timeout))) ==
            #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"timeout"},"hookEventName":"PermissionRequest"}}"#)
    }

    @Test("Deny with sessionEnded reason")
    func denySessionEnded() throws {
        #expect(try Self.encode(.decision(.deny(reason: .sessionEnded))) ==
            #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"session ended"},"hookEventName":"PermissionRequest"}}"#)
    }

    @Test("Deny with noSessionId reason")
    func denyNoSessionId() throws {
        #expect(try Self.encode(.decision(.deny(reason: .noSessionId))) ==
            #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"no session id"},"hookEventName":"PermissionRequest"}}"#)
    }

    @Test("Deny without explicit reason omits message field")
    func denyNoReason() throws {
        #expect(try Self.encode(.decision(.deny(reason: nil))) ==
            #"{"hookSpecificOutput":{"decision":{"behavior":"deny"},"hookEventName":"PermissionRequest"}}"#)
    }
}
