@testable import NemoNotch
import Testing

/// The held-permission timeout semantics per CLI source: Claude fail-closes
/// (an unanswered hook would block the CLI forever), the opencode bridge must
/// stay decision-free because opencode's own TUI dialog is still up and owns
/// the call.
struct HookServerPermissionHoldTests {
    @Test func opencodeTimeoutAnswersWithNoDecision() {
        let payload = HookServer.timeoutPayload(cliSource: "opencode")
        guard case .ack = payload else {
            Issue.record("opencode timeout must ack (no decision), got \(payload)")
            return
        }
    }

    @Test func claudeAndUnknownTimeoutsFailClosed() {
        for source in [nil, "claude", "gemini", "zcode", ""] {
            let payload = HookServer.timeoutPayload(cliSource: source)
            guard case let .decision(.deny(reason)) = payload else {
                Issue.record("\(source ?? "nil") timeout must deny, got \(payload)")
                return
            }
            #expect(reason == .timeout)
        }
    }

    @Test func opencodeBridgeHoldsLongerThanClaude() {
        #expect(HookServer.permissionHoldTimeout(cliSource: "opencode") == 600)
        #expect(HookServer.permissionHoldTimeout(cliSource: "claude") == 120)
        #expect(HookServer.permissionHoldTimeout(cliSource: nil) == 120)
    }
}
