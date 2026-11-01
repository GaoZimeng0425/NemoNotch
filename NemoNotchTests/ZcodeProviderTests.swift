import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct ZcodeProviderTests {
    private func event(_ json: String) -> HookEvent {
        // decode-or-die 测试夹具:坏 JSON 就该当场炸
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    @Test func sessionStartThenPromptThenStopTransitions() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_abc123"

        provider.handleEvent(event(#"{"hook_event_name":"SessionStart","session_id":"\#(sid)","cwd":"/tmp/proj"}"#))
        #expect(store.get(sid)?.source == .zcode)
        #expect(store.get(sid)?.phase == .idle)

        provider.handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        #expect(store.get(sid)?.status == .working)

        provider.handleEvent(event(#"{"hook_event_name":"Stop","session_id":"\#(sid)"}"#))
        #expect(store.get(sid)?.status == .waiting)
    }

    @Test func postToolUseFailureReturnsToProcessingAndClearsTool() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_fail"
        provider.handleEvent(event(#"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","tool_name":"Bash"}"#))
        #expect(store.get(sid)?.currentTool == "Bash")
        provider
            .handleEvent(event(#"{"hook_event_name":"PostToolUseFailure","session_id":"\#(sid)","tool_name":"Bash"}"#))
        #expect(store.get(sid)?.currentTool == nil)
        #expect(store.get(sid)?.status == .working)
    }

    /// zcode emits neither Notification nor SessionEnd — such events must be
    /// ignored (no phantom state change, no removal), leaving cleanup to timeout.
    @Test func unsupportedEventsAreIgnored() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_unsupported"
        provider.handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        #expect(store.get(sid)?.status == .working)
        provider.handleEvent(event(#"{"hook_event_name":"Notification","session_id":"\#(sid)"}"#))
        #expect(store.get(sid)?.status == .working) // unchanged — Notification not handled
        provider.handleEvent(event(#"{"hook_event_name":"SessionEnd","session_id":"\#(sid)"}"#))
        #expect(store.get(sid) != nil) // still present — SessionEnd not handled
    }

    @Test func preToolUseRecordsTool() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_tool"
        provider.handleEvent(event(#"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","tool_name":"Bash"}"#))
        #expect(store.get(sid)?.currentTool == "Bash")
        #expect(store.get(sid)?.status == .working)
    }

    /// An open tool call (PreToolUse seen, its PostToolUse not yet back) must
    /// NOT be demoted by the 5-min silence sweep: builds, test runs and
    /// subagents run past it with zero hook events in between (subagents fire
    /// no hooks at all — 2026-11-01 probe), and demoting there fires a false
    /// "completed" toast mid-execution.
    @Test func openToolCallIsNotDemotedBySilence() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_open_tool"
        provider.handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        provider.handleEvent(event(#"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","tool_name":"Bash"}"#))

        // 400s after the last event — past the 300s silent-demote threshold.
        provider.cleanupStaleSessions(now: Date().addingTimeInterval(400))

        #expect(store.get(sid)?.status == .working)
        #expect(store.get(sid)?.currentTool == "Bash")
    }

    /// The closed-tool counterpart still demotes on schedule — that sweep is
    /// the only completion signal for zcode sessions whose Stop never arrives.
    @Test func closedToolSessionStillDemotesAfterSilence() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_closed_tool"
        provider.handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        provider.handleEvent(event(#"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","tool_name":"Bash"}"#))
        provider.handleEvent(event(#"{"hook_event_name":"PostToolUse","session_id":"\#(sid)","tool_name":"Bash"}"#))

        provider.cleanupStaleSessions(now: Date().addingTimeInterval(400))

        #expect(store.get(sid)?.status == .idle)
        #expect(store.get(sid)?.currentTool == nil)
    }

    /// Symmetric guard: a failed tool call also closes the tool, so silence
    /// after it still demotes on schedule — protects the failure path that
    /// keeps the open-tool guard honest.
    @Test func failedToolThenSilenceStillDemotes() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_failed_tool"
        provider.handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        provider.handleEvent(event(#"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","tool_name":"Bash"}"#))
        provider
            .handleEvent(event(#"{"hook_event_name":"PostToolUseFailure","session_id":"\#(sid)","tool_name":"Bash"}"#))

        provider.cleanupStaleSessions(now: Date().addingTimeInterval(400))

        #expect(store.get(sid)?.status == .idle)
        #expect(store.get(sid)?.currentTool == nil)
    }
}
