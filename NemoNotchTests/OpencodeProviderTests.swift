import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct OpencodeProviderTests {
    private func event(_ json: String) -> HookEvent {
        // decode-or-die 测试夹具:坏 JSON 就该当场炸
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    @Test func lifecycleMovesThroughWorkingThenWaiting() {
        let store = AISessionStore()
        let provider = OpencodeProvider(store: store)
        let sid = "ses_a"

        provider
            .handleEvent(
                event(
                    #"{"hook_event_name":"UserPromptSubmit","session_id":"ses_a","cwd":"/tmp/proj","model":"anthropic/claude-sonnet-4-5","cli_source":"opencode"}"#
                )
            )
        #expect(store.get(sid)?.source == .opencode)
        #expect(store.get(sid)?.status == .working)
        #expect(store.get(sid)?.cwd == "/tmp/proj")
        #expect(store.get(sid)?.model == "anthropic/claude-sonnet-4-5")

        provider
            .handleEvent(
                event(
                    #"{"hook_event_name":"PreToolUse","session_id":"ses_a","tool_name":"bash","tool_use_id":"c1","cli_source":"opencode"}"#
                )
            )
        #expect(store.get(sid)?.currentTool == "bash")
        #expect(store.get(sid)?.status == .working)

        provider
            .handleEvent(
                event(
                    #"{"hook_event_name":"PostToolUse","session_id":"ses_a","tool_name":"bash","tool_use_id":"c1","cli_source":"opencode"}"#
                )
            )
        #expect(store.get(sid)?.currentTool == nil)

        provider.handleEvent(event(#"{"hook_event_name":"Stop","session_id":"ses_a","cli_source":"opencode"}"#))
        #expect(store.get(sid)?.status == .waiting)
    }

    @Test func notificationMovesToWaitingForApproval() {
        let store = AISessionStore()
        let provider = OpencodeProvider(store: store)
        let sid = "ses_b"
        provider
            .handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_b","cli_source":"opencode"}"#))
        provider
            .handleEvent(
                event(
                    #"{"hook_event_name":"Notification","session_id":"ses_b","tool_name":"bash","tool_use_id":"p1","message":"rm -rf x","cli_source":"opencode"}"#
                )
            )
        #expect(store.get(sid)?.phase.isWaitingForApproval == true)
        #expect(store.get(sid)?.phase.approvalToolName == "bash")
    }

    @Test func ignoresEventsWithoutSessionId() {
        let store = AISessionStore()
        let provider = OpencodeProvider(store: store)
        provider.handleEvent(event(#"{"hook_event_name":"Stop","cli_source":"opencode"}"#))
        #expect(store.sortedSessions.isEmpty)
    }
}

extension OpencodeProviderTests {
    @Test func permissionRequestEventMovesToWaitingForApproval() {
        let store = AISessionStore()
        let provider = OpencodeProvider(store: store)
        provider.handleEvent(
            event(
                #"{"hook_event_name":"PermissionRequest","session_id":"ses_pr","tool_name":"bash","tool_use_id":"perm-1","message":"allow rm?","cli_source":"opencode"}"#
            )
        )
        guard case let .waitingForApproval(ctx) = store.get("ses_pr")?.phase else {
            Issue.record("expected waitingForApproval, got \(String(describing: store.get("ses_pr")?.phase))")
            return
        }
        #expect(ctx.toolUseId == "perm-1")
        #expect(ctx.toolName == "bash")
    }

    @Test func respondToPermissionAdvancesPhaseToProcessing() {
        let store = AISessionStore()
        let provider = OpencodeProvider(store: store)
        provider.handleEvent(
            event(
                #"{"hook_event_name":"PermissionRequest","session_id":"ses_ans","tool_name":"bash","tool_use_id":"perm-2","cli_source":"opencode"}"#
            )
        )
        // No HookServer attached (nil weak ref) — the write lands nowhere but
        // the phase must still advance, mirroring the Gemini provider.
        provider.respondToPermission(sessionId: "ses_ans", approved: true)
        guard case .processing = store.get("ses_ans")?.phase else {
            Issue.record("expected processing after answer")
            return
        }
    }
}
