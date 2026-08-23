import Foundation
@testable import NemoNotch
import Testing

// MARK: - 分帧器单元测试

struct JSONLFramerTests {
    private func d(_ s: String) -> Data { Data(s.utf8) }

    private func tailKind(_ t: JSONLFramer.Framing.Tail) -> String {
        switch t {
        case .none: return "none"
        case .line: return "line"
        case .pending: return "pending"
        case .surrendered: return "surrendered"
        }
    }

    @Test func completeLinesAreAllConsumed() {
        let input = d("{\"a\":1}\n{\"b\":2}\n")
        let f = JSONLFramer.frame(input)
        #expect(f.lines.count == 2)
        #expect(tailKind(f.tail) == "none")
        #expect(f.consumedByteCount == input.count)
    }

    @Test func trailingHalfLineIsNotConsumed() {
        let f = JSONLFramer.frame(d("{\"a\":1}\n{\"b\":2"))
        #expect(f.lines.count == 1)
        #expect(tailKind(f.tail) == "pending")
        #expect(f.consumedByteCount == 8) // 停在第一行的 \n 之后
    }

    @Test func unterminatedObjectTailIsConsumedAsLine() {
        // 写完但没补 \n 的最后一行:能解析出完整 object 即消费
        let input = d("{\"a\":1}\n{\"b\":25}")
        let f = JSONLFramer.frame(input)
        #expect(f.lines.count == 1)
        #expect(tailKind(f.tail) == "line")
        #expect(f.consumedByteCount == input.count)
    }

    @Test func objectTailWithTrailingWhitespaceIsConsumed() {
        let f = JSONLFramer.frame(d("{\"a\":1}\n{\"b\":2}  "))
        #expect(tailKind(f.tail) == "line")
    }

    @Test func scalarTailIsNeverConsumedAsLine() {
        // 截断的数字前缀(如 "12")本身是合法 JSON 标量;只有 object 才算完整行
        let f = JSONLFramer.frame(d("{\"a\":1}\n12"))
        #expect(tailKind(f.tail) == "pending")
    }

    @Test func emptyLinesAreOmitted() {
        let input = d("{\"a\":1}\n\n{\"b\":2}\n")
        let f = JSONLFramer.frame(input)
        #expect(f.lines.count == 2)
        #expect(f.consumedByteCount == input.count)
    }

    @Test func oversizeGarbageTailIsSurrendered() {
        // 放弃但推进 offset,避免每次触发都重读同一段永久垃圾
        let input = d("{\"a\":1}\nAAAAAAABBBB")
        let f = JSONLFramer.frame(input, maxTailBytes: 4)
        #expect(f.lines.count == 1)
        #expect(tailKind(f.tail) == "surrendered")
        #expect(f.consumedByteCount == input.count)
    }

    @Test func emptyInputConsumesNothing() {
        let f = JSONLFramer.frame(Data())
        #expect(f.lines.isEmpty)
        #expect(tailKind(f.tail) == "none")
        #expect(f.consumedByteCount == 0)
    }
}

// MARK: - Claude 解析器集成测试

struct ConversationParserHalfLineTests {
    private let line1 = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}\n"
    private let line2Full = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"world\"}}\n"
    private let line2Half = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"wor"

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("framer-claude-\(UUID().uuidString).jsonl")
    }

    @Test func halfLineIsReReadAfterCompletion() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((line1 + line2Half).utf8).write(to: url)

        let r1 = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r1.messages.count == 1)
        #expect(r1.messages.first?.content == "hello")
        #expect(r1.newOffset == UInt64(line1.utf8.count)) // 半行未消费

        // 模拟写方补完后半行
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line2Full.dropFirst(line2Half.count).utf8))
        try handle.close()

        let r2 = ConversationParser.parseIncremental(filePath: url.path, fromOffset: r1.newOffset)
        #expect(r2.messages.count == 1)
        #expect(r2.messages.first?.content == "world")
        #expect(r2.newOffset == UInt64((line1 + line2Full).utf8.count))
    }

    @Test func unterminatedFinalLineIsParsed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(String(line2Full.dropLast()).utf8).write(to: url) // 完整行但无 \n

        let r = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r.messages.count == 1)
        #expect(r.messages.first?.content == "world")
        #expect(r.newOffset == UInt64(line2Full.utf8.count - 1)) // 没有换行也消费到 EOF
    }

    @Test func corruptCompleteLineIsSkipped() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let input = "not json\n" + line1
        try Data(input.utf8).write(to: url)

        let r = ConversationParser.parseIncremental(filePath: url.path, fromOffset: 0)
        #expect(r.messages.count == 1)
        #expect(r.newOffset == UInt64(input.utf8.count)) // 损坏行跳过但推进
    }
}

// MARK: - Gemini 解析器集成测试

struct GeminiParserHalfLineTests {
    private let userLine = "{\"type\":\"user\",\"id\":\"g1\",\"content\":\"hi\"}\n"
    private let geminiLine = "{\"type\":\"gemini\",\"id\":\"g2\",\"content\":\"yo\",\"tokens\":{\"input\":5,\"output\":2}}\n"

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("framer-gemini-\(UUID().uuidString).jsonl")
    }

    @Test func halfLineIsReReadAfterCompletion() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let half = String(geminiLine.prefix(30)) // 截断在 content 键中间
        try Data((userLine + half).utf8).write(to: url)

        let r1 = GeminiConversationParser.parseIncrementalJSONL(filePath: url.path, fromOffset: 0)
        #expect(r1.common.messages.count == 1)
        #expect(r1.newOffset == UInt64(userLine.utf8.count))

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(geminiLine.dropFirst(half.count).utf8))
        try handle.close()

        let r2 = GeminiConversationParser.parseIncrementalJSONL(filePath: url.path, fromOffset: r1.newOffset)
        #expect(r2.common.messages.count == 1)
        #expect(r2.common.messages.first?.content == "yo")
        #expect(r2.common.inputTokens == 5)
        #expect(r2.newOffset == UInt64((userLine + geminiLine).utf8.count))
    }

    @Test func unterminatedFinalLineIsParsed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(String(geminiLine.dropLast()).utf8).write(to: url)

        let r = GeminiConversationParser.parseIncrementalJSONL(filePath: url.path, fromOffset: 0)
        #expect(r.common.messages.count == 1)
        #expect(r.common.messages.first?.content == "yo")
        #expect(r.newOffset == UInt64(geminiLine.utf8.count - 1))
    }
}
