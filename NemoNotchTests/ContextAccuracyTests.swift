import Foundation
@testable import NemoNotch
import Testing

/// The context a session shows is its latest model call's prompt — never a
/// sub-agent's, never a synthetic note's, never cached tokens counted twice.
struct ContextAccuracyTests {
    private func write(_ lines: [String], tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-\(tag)-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func claudeAssistant(
        model: String,
        input: Int,
        cacheRead: Int,
        cacheCreation: Int,
        sidechain: Bool = false
    ) -> String {
        """
        {"type":"assistant","isSidechain":\(sidechain),"uuid":"\(UUID().uuidString)",\
        "message":{"id":"msg_\(UUID().uuidString)","model":"\(model)","role":"assistant",\
        "content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\(input),\
        "cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation),\
        "output_tokens":10}}}
        """
    }

    @Test func claudeContextIsLatestMainCall() throws {
        let url = try write([
            claudeAssistant(model: "claude-opus-5-5", input: 2, cacheRead: 150_000, cacheCreation: 3000),
        ], tag: "claude-main")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r.lastContextTokens == 153_002)
        #expect(r.lastModel == "claude-opus-5-5")
    }

    @Test func claudeSidechainCallDoesNotMoveContextOrModel() throws {
        let url = try write([
            claudeAssistant(model: "claude-opus-5-5", input: 2, cacheRead: 150_000, cacheCreation: 3000),
            claudeAssistant(model: "claude-haiku-4-5", input: 5, cacheRead: 9000, cacheCreation: 0, sidechain: true),
        ], tag: "claude-sidechain")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r.lastContextTokens == 153_002)
        #expect(r.lastModel == "claude-opus-5-5")
    }

    @Test func claudeSidechainCallStillCountsTowardTotals() throws {
        let url = try write([
            claudeAssistant(model: "claude-opus-5-5", input: 2, cacheRead: 150_000, cacheCreation: 3000),
            claudeAssistant(model: "claude-haiku-4-5", input: 5, cacheRead: 9000, cacheCreation: 0, sidechain: true),
        ], tag: "claude-sidechain-totals")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r.inputTokens == 7)
        #expect(r.cacheReadTokens == 159_000)
    }

    @Test func claudeSyntheticNoteDoesNotMoveContextOrModel() throws {
        let url = try write([
            claudeAssistant(model: "claude-opus-5-5", input: 2, cacheRead: 150_000, cacheCreation: 3000),
            claudeAssistant(model: "<synthetic>", input: 0, cacheRead: 0, cacheCreation: 0),
        ], tag: "claude-synthetic")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r.lastContextTokens == 153_002)
        #expect(r.lastModel == "claude-opus-5-5")
    }

    @Test func geminiContextIsPromptCountWithoutAddingCached() throws {
        let line = """
        {"id":"g1","type":"gemini","content":"hi","model":"gemini-3-pro",\
        "tokens":{"input":120000,"output":50,"cached":100000,"thoughts":0,"tool":0,"total":120050}}
        """
        let url = try write([line], tag: "gemini")
        defer { try? FileManager.default.removeItem(at: url) }
        let r = GeminiConversationParser.parseIncrementalJSONL(filePath: url.path, fromOffset: 0)
        #expect(r.lastContextTokens == 120_000)
    }

    @Test func sessionLimitUpgradesClaudeSeenPast200K() {
        var session = AISessionState(sessionId: "ctx", source: .claude)
        session.model = "claude-sonnet-4-5-20250929"
        session.lastContextTokens = 100_000
        #expect(session.contextLimit == 200_000)
        #expect(session.contextPercent == 0.5)
        session.lastContextTokens = 250_000
        #expect(session.contextLimit == 1_000_000)
        #expect(session.contextPercent == 0.25)
    }

    @Test func oneMillionIsRememberedAfterTheContextFalls() {
        var session = AISessionState(sessionId: "ctx", source: .claude)
        session.model = "claude-sonnet-4-5-20250929"
        session.lastContextTokens = 300_000
        // `/compact`: the prompt shrinks, the window does not.
        session.lastContextTokens = 150_000
        #expect(session.contextLimit == 1_000_000)
    }

    @Test func rememberedWindowIsPerModel() {
        var session = AISessionState(sessionId: "ctx", source: .claude)
        session.model = "claude-sonnet-4-5-20250929"
        session.lastContextTokens = 300_000
        // The next call, in the providers' write order: tokens, then model.
        session.lastContextTokens = 50000
        session.model = "claude-haiku-4-5-20251001"
        #expect(session.contextLimit == 200_000)
    }
}
