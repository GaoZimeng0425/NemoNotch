import Foundation
@testable import NemoNotch
import Testing

@Suite("ClaudeProvider event handling")
@MainActor
struct ClaudeProviderTests {
    private static func event(_ name: String, sessionId: String, tool: String? = nil) throws -> HookEvent {
        var fields = ["\"hook_event_name\":\"\(name)\"", "\"session_id\":\"\(sessionId)\""]
        if let tool { fields.append("\"tool_name\":\"\(tool)\"") }
        let json = "{\(fields.joined(separator: ","))}"
        return try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    private static func waitingSession(_ id: String) -> AISessionState {
        var session = AISessionState(sessionId: id, source: .claude)
        session.phase = .waitingForApproval(PermissionContext(
            toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: Date()
        ))
        return session
    }

    @Test("PostToolUse resolves a stale waitingForApproval into processing")
    func postToolUseClearsStaleApproval() throws {
        let store = AISessionStore()
        let provider = ClaudeProvider(store: store)
        store.upsert(Self.waitingSession("post-clears-approval"))

        try provider.handleEvent(Self.event("PostToolUse", sessionId: "post-clears-approval", tool: "Bash"))

        #expect(store.get("post-clears-approval")?.phase.isWaitingForApproval == false)
    }
}
