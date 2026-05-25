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

    @Test("Allow decision encodes without reason field")
    func allow() throws {
        #expect(try Self.encode(.decision(.allow)) == #"{"decision":"allow"}"#)
    }

    @Test("Deny decision encodes with reason field")
    func denyTimeout() throws {
        #expect(try Self.encode(.decision(.deny(reason: .timeout))) == #"{"decision":"deny","reason":"timeout"}"#)
    }

    @Test("Deny with sessionEnded reason")
    func denySessionEnded() throws {
        #expect(try Self
            .encode(.decision(.deny(reason: .sessionEnded))) == #"{"decision":"deny","reason":"session ended"}"#)
    }

    @Test("Deny with noSessionId reason")
    func denyNoSessionId() throws {
        #expect(try Self
            .encode(.decision(.deny(reason: .noSessionId))) == #"{"decision":"deny","reason":"no session id"}"#)
    }

    @Test("Deny without explicit reason omits reason field")
    func denyNoReason() throws {
        #expect(try Self.encode(.decision(.deny(reason: nil))) == #"{"decision":"deny"}"#)
    }
}
