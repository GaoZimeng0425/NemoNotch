import Foundation
@testable import NemoNotch
import Testing

// MARK: - H05:跨增量块的稳定消息 id

struct ParserStableIDTests {
    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("stable-id-\(tag)-\(UUID().uuidString).jsonl")
    }

    @Test func claudeUUIDLineUsesUUIDAsID() throws {
        let url = tempURL("claude-uuid")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = "{\"type\":\"user\",\"uuid\":\"abc-123\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}\n"
        try Data(line.utf8).write(to: url)

        let r = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r.messages.first?.id == "user-abc-123")
    }

    @Test func claudeLinesWithoutUUIDGetStableHashIDs() throws {
        let url = tempURL("claude-hash")
        defer { try? FileManager.default.removeItem(at: url) }
        let lineA = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}\n"
        let lineB = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"world\"}}\n"
        try Data((lineA + lineB).utf8).write(to: url)

        let r = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r.messages.count == 2)
        #expect(r.messages[0].id != r.messages[1].id) // 不同行 id 不同
        #expect(r.messages[0].id != "user-0")        // 不再是块内序号

        // 同一批行重复解析 → id 一致(重解析幂等,可被 upsert 按 id 去重)
        let r2 = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r2.messages.map(\.id) == r.messages.map(\.id))
    }

    @Test func geminiLinesWithoutIDKeepStableIDAcrossReparses() throws {
        let url = tempURL("gemini-hash")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = "{\"type\":\"user\",\"content\":\"hi\"}\n" // 无 id 字段
        try Data(line.utf8).write(to: url)

        let r1 = GeminiConversationParser.parseIncrementalJSONL(filePath: url.path, fromOffset: 0)
        let r2 = GeminiConversationParser.parseIncrementalJSONL(filePath: url.path, fromOffset: 0)
        // 原实现的兜底是随机 UUID:重复解析同一行会被当成新消息追加
        #expect(r1.common.messages.first?.id == r2.common.messages.first?.id)
        #expect(r1.common.messages.first?.id.hasPrefix("h-") == true)
    }

    @Test func upsertDedupsByID() {
        var session = AISessionState(sessionId: "dedup", source: .claude)
        let msg = ChatMessage(id: "user-x", role: .user, content: "hello", timestamp: Date())
        session.upsertMessage(msg)
        session.upsertMessage(msg)
        #expect(session.messages.count == 1)
    }
}

// MARK: - H07:/clear、/compact 后 token 计数随 offset 一起归零

@MainActor
struct HandleClearTokenResetTests {
    private func seededSession(_ id: String, source: AISource) -> AISessionState {
        var session = AISessionState(sessionId: id, source: source)
        session.messages = [ChatMessage(id: "user-1", role: .user, content: "hi", timestamp: Date())]
        session.inputTokens = 100
        session.outputTokens = 50
        session.thoughtTokens = 10
        session.cacheReadTokens = 200
        session.cacheCreationTokens = 20
        session.lastContextTokens = 320
        session.lastParsedOffset = 1234
        return session
    }

    @Test func claudeClearResetsTokensAndOffset() {
        let store = AISessionStore()
        let provider = ClaudeProvider(store: store)
        store.upsert(seededSession("claude-clear", source: .claude))

        provider.handleClear(sessionId: "claude-clear")

        let s = store.get("claude-clear")
        #expect(s?.messages.isEmpty == true)
        #expect(s?.lastParsedOffset == 0)
        #expect(s?.inputTokens == 0)
        #expect(s?.outputTokens == 0)
        #expect(s?.thoughtTokens == 0)
        #expect(s?.cacheReadTokens == 0)
        #expect(s?.cacheCreationTokens == 0)
        #expect(s?.lastContextTokens == 0)
    }

    @Test func geminiClearResetsTokensAndOffset() {
        let store = AISessionStore()
        let provider = GeminiProvider(store: store)
        store.upsert(seededSession("gemini-clear", source: .gemini))

        provider.handleClear(sessionId: "gemini-clear")

        let s = store.get("gemini-clear")
        #expect(s?.messages.isEmpty == true)
        #expect(s?.lastParsedOffset == 0)
        #expect(s?.inputTokens == 0)
        #expect(s?.lastContextTokens == 0)
    }
}
