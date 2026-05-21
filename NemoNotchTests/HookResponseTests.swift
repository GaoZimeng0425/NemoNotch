import Foundation
@testable import NemoNotch
import Testing

@Suite("HookResponse encoding")
struct HookResponseTests {
    @Test("Ack encodes to {\"status\":\"ok\"}")
    func ack() throws {
        let data = try JSONEncoder().encode(HookResponse.ack)
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"status":"ok"}"#)
    }

    @Test("Allow decision encodes without reason field")
    func allow() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.allow))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"allow"}"#)
    }

    @Test("Deny decision encodes with reason field")
    func denyTimeout() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.deny(reason: .timeout)))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"deny","reason":"timeout"}"#)
    }

    @Test("Deny with sessionEnded reason")
    func denySessionEnded() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.deny(reason: .sessionEnded)))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"deny","reason":"session ended"}"#)
    }

    @Test("Deny with noSessionId reason")
    func denyNoSessionId() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.deny(reason: .noSessionId)))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"deny","reason":"no session id"}"#)
    }

    @Test("Deny without explicit reason omits reason field")
    func denyNoReason() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.deny(reason: nil)))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"deny"}"#)
    }
}
