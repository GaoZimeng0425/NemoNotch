import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct ZcodeProviderTests {
    private func event(_ json: String) -> HookEvent {
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

    @Test func preToolUseRecordsTool() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_tool"
        provider.handleEvent(event(#"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","tool_name":"Bash"}"#))
        #expect(store.get(sid)?.currentTool == "Bash")
        #expect(store.get(sid)?.status == .working)
    }
}
