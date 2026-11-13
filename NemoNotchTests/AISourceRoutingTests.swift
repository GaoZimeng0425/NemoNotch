import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct AISourceRoutingTests {
    private func event(_ json: String) -> HookEvent {
        // decode-or-die 测试夹具:坏 JSON 就该当场炸
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    /// Attribution tests are orthogonal to the toggle: force every source on
    /// so a locally-disabled CLI (shared UserDefaults) can't skew them.
    private func openService() -> AICLIMonitorService {
        let service = AICLIMonitorService()
        service.sourceGate = { _ in true }
        return service
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
        let service = openService()
        let sid = "ses_routingtest_abc"
        // No cli_source — mimics the foreign untagged emitter that arrives first.
        service.hookServer.onEventReceived?(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        #expect(service.store.get(sid)?.source == .opencode)
    }

    /// zcode: an explicit cli_source routes to zcode.
    @Test func taggedZcodeEventRoutesToZcode() {
        let service = openService()
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
        let service = openService()
        let sid = "sess_zc_untagged"
        service.hookServer.onEventReceived?(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        #expect(service.store.get(sid)?.source == .zcode)
    }
}

// MARK: - Per-source monitoring gate (Settings toggle)

/// The Settings toggle is a service-layer gate, not a UI filter: with a source
/// disabled, its events (tagged, prefix-attributed, or Claude-fallback) must
/// never reach the store.
@MainActor
struct AISourceGateTests {
    private func event(_ json: String) -> HookEvent {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    private func gatedService(off: AISource...) -> AICLIMonitorService {
        let service = AICLIMonitorService()
        service.sourceGate = { !off.contains($0) }
        return service
    }

    /// Tagged claude events are dropped when claude is toggled off — the exact
    /// path that used to keep minting sessions after the hook was uninstalled.
    @Test func disabledClaudeDropsTaggedEvents() {
        let service = gatedService(off: .claude)
        let sid = "gate-claude-tagged"
        service.hookServer.onEventReceived?(
            event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cli_source":"claude"}"#)
        )
        #expect(service.store.get(sid) == nil)
    }

    /// Untagged, unprefixed events fall back to Claude — the fallback inherits
    /// the claude gate, so a disabled claude swallows the whole legacy line.
    @Test func disabledClaudeDropsUntaggedFallback() {
        let service = gatedService(off: .claude)
        let sid = "diag-fallback-xyz"
        service.hookServer.onEventReceived?(
            event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#)
        )
        #expect(service.store.get(sid) == nil)

        // Re-enabling lets the same shape through again.
        service.sourceGate = { _ in true }
        service.hookServer.onEventReceived?(
            event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#)
        )
        #expect(service.store.get(sid)?.source == .claude)
    }

    /// Disabling one source leaves the other attribution paths intact: zcode
    /// off drops `sess_`, opencode's `ses_` still gets through.
    @Test func disabledZcodeDropsSessButNotSes() {
        let service = gatedService(off: .zcode)
        service.hookServer.onEventReceived?(
            event(#"{"hook_event_name":"UserPromptSubmit","session_id":"sess_gate_zc"}"#)
        )
        #expect(service.store.get("sess_gate_zc") == nil)

        service.hookServer.onEventReceived?(
            event(#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_gate_oc"}"#)
        )
        #expect(service.store.get("ses_gate_oc")?.source == .opencode)
    }

    /// The store-owner fallback routes by the existing session's source — that
    /// source's gate applies too (a disabled claude session stays untouched).
    @Test func disabledSourceDropsEventsForExistingSession() {
        let service = gatedService(off: .claude)
        let sid = "gate-existing"
        service.store.mutateOrCreate(sid, source: .claude) { $0.phase = .idle }
        service.hookServer.onEventReceived?(
            event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#)
        )
        #expect(service.store.get(sid)?.phase == .idle)
    }
}
