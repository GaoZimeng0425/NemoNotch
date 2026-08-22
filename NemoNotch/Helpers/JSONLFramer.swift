import Foundation

/// JSONL 增量读取的分帧器。
///
/// 核心不变量:**offset 只允许跨过"已确定消费"的字节** —— 即所有以 `\n` 终结的
/// 完整行,加上(若存在)一条写完但没补换行、且整体解析为合法 JSON object 的尾
/// 巴。尾部半行(写方还在写)的字节不消费,留给下一次增量重读;否则写方补完后
/// 半行后,读方已从行中间开始,该行永久丢失。
///
/// 尾巴"写完"的判据是"能解析出完整 object"而不是 `\n` 本身:JSON 序列化器只会
/// 在一个完整值之后另起新行,截断的前缀几乎不可能恰好是合法 JSON;反之只认
/// `\n` 会把"写完但永远没补换行的最后一行"无限期挂起。
enum JSONLFramer {
    struct Framing {
        enum Tail {
            /// 没有未终结的尾巴
            case none
            /// 尾巴是"写完但没补 `\n`"的完整行:已消费,按普通行处理
            case line(Data)
            /// 尾巴是半行:未消费,下次增量从这些字节之前重读
            case pending(Data)
            /// 尾巴超过 `maxTailBytes` 仍解析不出:已消费并放弃(调用方应记日志)
            case surrendered(Data)
        }

        /// 按文件顺序的完整行(以 `\n` 终结,空行已省略)。其中可能含无法解析的
        /// 损坏行 —— 调用方解析失败时跳过即可。
        let lines: [Data]
        let tail: Tail
        /// 本次可安全推进的字节数(完整行 + 已消费的尾巴)。
        let consumedByteCount: Int
    }

    /// 单条 JSONL 的防御上限:超过它仍解析不出的尾巴按永久垃圾放弃。
    static let defaultMaxTailBytes = 8 << 20

    static func frame(_ data: Data, maxTailBytes: Int = defaultMaxTailBytes) -> Framing {
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = []
        var lineStart = data.startIndex
        var completeEnd = data.startIndex

        for i in data.indices where data[i] == newline {
            if i > lineStart {
                lines.append(data.subdata(in: lineStart..<i))
            }
            lineStart = data.index(after: i)
            completeEnd = lineStart
        }

        guard lineStart < data.endIndex else {
            return Framing(
                lines: lines,
                tail: .none,
                consumedByteCount: data.distance(from: data.startIndex, to: completeEnd)
            )
        }

        let tail = data.subdata(in: lineStart..<data.endIndex)

        if tailEndsLikeObject(tail),
           let parsed = try? JSONSerialization.jsonObject(with: tail),
           parsed is [String: Any] {
            return Framing(lines: lines, tail: .line(tail), consumedByteCount: data.count)
        }

        if tail.count > maxTailBytes {
            return Framing(lines: lines, tail: .surrendered(tail), consumedByteCount: data.count)
        }

        return Framing(
            lines: lines,
            tail: .pending(tail),
            consumedByteCount: data.distance(from: data.startIndex, to: completeEnd)
        )
    }

    /// 廉价闸门:合法 object 的序列化结尾(忽略尾随空白)必是 `}`。不以 `}` 结尾
    /// 的尾巴一定是半行,省掉对大尾巴(流式写入的 base64/长文本)的整段解析尝试。
    private static func tailEndsLikeObject(_ tail: Data) -> Bool {
        guard let last = tail.lastIndex(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else {
            return false
        }
        return tail[last] == UInt8(ascii: "}")
    }
}
