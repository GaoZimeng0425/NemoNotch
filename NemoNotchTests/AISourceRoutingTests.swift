import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct AISourceRoutingTests {
    private func event(_ json: String) -> HookEvent {
        try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    /// Fix 1 — source authority: an explicit cli_source must win even when the
    /// session was already created by another provider (the bug: an untagged
    /// event minted a `.claude` phantom for an opencode session, and the later
    /// opencode-tagged event left the stale source in place).
    @Test func mutateOrCreateReassignsSourceForExistingSession() {
        let store = AISessionStore()
        store.mutateOrCreate("ses_x", source: .claude) { $0.phase = .processing }
        #expect(store.get("ses_x")?.source == .claude)

        store.mutateOrCreate("ses_x", source: .opencode) { $0.phase = .processing }
        #expect(store.get("ses_x")?.source == .opencode)
    }

    /// Fix 2 — routeEvent: an untagged event for an opencode-format session id
    /// (`ses_` prefix) must route to opencode, not fall through to Claude.
    @Test func untaggedOpencodeSessionRoutesToOpencode() {
        let service = AICLIMonitorService()
        let sid = "ses_routingtest_abc"
        // No cli_source — mimics the foreign untagged emitter that arrives first.
        service.hookServer.onEventReceived?(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        #expect(service.store.get(sid)?.source == .opencode)
    }

    /// zcode: an explicit cli_source routes to zcode.
    @Test func taggedZcodeEventRoutesToZcode() {
        let service = AICLIMonitorService()
        let sid = "sess_zc_tagged"
        service.hookServer
            .onEventReceived?(
                event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cli_source":"zcode"}"#)
            )
        #expect(service.store.get(sid)?.source == .zcode)
    }

    /// zcode: an untagged event for a `sess_`-prefixed session routes to zcode,
    /// not Claude. (`sess_` is distinct from opencode's `ses_`.)
    @Test func untaggedZcodeSessionRoutesToZcode() {
        let service = AICLIMonitorService()
        let sid = "sess_zc_untagged"
        service.hookServer.onEventReceived?(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        #expect(service.store.get(sid)?.source == .zcode)
    }
}
