import Foundation
@testable import NemoNotch
import Testing

/// Calibrated 2026-11-03 against real transcripts in ~/.claude/projects:
/// terminal API failures are synthetic assistant entries stamped
/// `isApiErrorMessage: true` with text "API Error: …" (e.g. "Stream ended
/// without receiving any events"); benign synthetics ("No response
/// requested.") carry `isApiErrorMessage: false` — only `true` counts.
@Suite("ApiErrorMarker")
struct ApiErrorMarkerTests {
    private func entry(
        type: String = "assistant",
        flag: Bool? = nil,
        text: String
    ) -> [String: Any] {
        var json: [String: Any] = [
            "type": type,
            "message": ["role": "assistant", "model": "<synthetic>", "content": [["type": "text", "text": text]]],
        ]
        if let flag {
            json["isApiErrorMessage"] = flag
        }
        return json
    }

    @Test("a flagged API-error assistant entry marks the turn")
    func flaggedEntryIsError() {
        let sample = entry(flag: true, text: "API Error: Stream ended without receiving any events")
        #expect(ApiErrorMarker.isApiError(sample))
    }

    @Test("a benign synthetic keeps its flag false")
    func benignSyntheticIsNotError() {
        #expect(!ApiErrorMarker.isApiError(entry(flag: false, text: "No response requested.")))
    }

    @Test("a normal assistant entry is not an error")
    func normalAssistantIsNotError() {
        #expect(!ApiErrorMarker.isApiError(entry(flag: nil, text: "Here is the fix.")))
    }

    @Test("non-assistant entries never mark")
    func nonAssistantNeverMarks() {
        #expect(!ApiErrorMarker.isApiError(entry(type: "user", flag: true, text: "API Error: 429")))
    }

    @Test("an API Error text prefix marks even without the flag")
    func textPrefixFallback() {
        #expect(ApiErrorMarker.isApiError(entry(text: "API Error: 429 rate limit exceeded")))
    }

    // MARK: - Parser wiring(最后一条非 sidechain assistant 定胜负)

    @Test("the latest main assistant entry owns the api-error state")
    func parserLatestAssistantWins() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apierr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.jsonl").path

        let lines = [
            entry(flag: true, text: "API Error: Stream ended without receiving any events"),
            // 重试成功:后续正常 assistant 把错误态清掉
            entry(text: "Recovered and finished the task."),
        ]
        try lines
            .map { try String(data: JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\n" }
            .joined()
            .write(toFile: path, atomically: true, encoding: .utf8)

        var result = ConversationParser.parseIncremental(filePath: path, fromOffset: 0)
        #expect(result.lastAssistantApiError == false)

        // 只含错误条目时为 true
        let errorLine = try #require(try String(
            data: JSONSerialization.data(withJSONObject: entry(
                flag: true, text: "API Error: You've hit your usage limit"
            )), encoding: .utf8
        )) + "\n"
        try errorLine.write(toFile: path, atomically: true, encoding: .utf8)
        result = ConversationParser.parseIncremental(filePath: path, fromOffset: 0)
        #expect(result.lastAssistantApiError == true)

        // 无 assistant 条目时为 nil(增量里没有新说法,保持会话原状)
        try "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        result = ConversationParser.parseIncremental(filePath: path, fromOffset: 0)
        #expect(result.lastAssistantApiError == nil)
    }
}
