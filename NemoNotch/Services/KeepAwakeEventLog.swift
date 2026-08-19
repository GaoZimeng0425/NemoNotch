import Foundation

/// 合盖 / 防休眠事件的**长期**记录,独立于 `LogService` 的主日志。
///
/// 为什么要单独一份:主日志由 `DDFileLogger` 管理,`maximumNumberOfLogFiles = 7`
/// 且单文件 1MB 上限 —— 活跃使用时一天就能烧掉三四个文件,有效保留窗口不到
/// 两天。合盖是低频事件,想"过几周回头查一眼它到底有没有正常工作"的话,记录
/// 早就被高频日志冲掉了。
///
/// 这里只记合盖/开盖/开关切换这类**低频语义事件**,一天至多几行,不参与轮转。
/// 一行约 100 字节,跑一年也就几十 KB。
///
/// 事件同时也会写进主日志(`LogService.info`)—— 主日志用于结合上下文排查当下
/// 的问题,这份用于长期回溯。两者刻意重复。
enum KeepAwakeEventLog {
    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".NemoNotch")
            .appendingPathComponent("keep-awake.log")
    }

    /// 失控增长的兜底。正常使用远远够不到 —— 但万一 clamshell 消息风暴(驱动
    /// 异常、外接坞反复抖动),不设上限会把磁盘写满。超限时保留后半,丢最老的。
    private static let maxBytes = 1_024 * 1_024
    private static let trimToBytes = 512 * 1_024

    /// 串行化写入。事件来自 @MainActor(LidMonitor / KeepAwakeService),但
    /// `record` 本身是 nonisolated,不该依赖调用方的隔离域。
    private static let lock = NSLock()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // 与主日志一致的格式与**本地时区**。CocoaLumberjack 默认格式化器硬编码
        // UTC,LogService 已经改过;这里从一开始就用本地时间,免得两份日志对不上。
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss:SSS"
        formatter.timeZone = .current
        return formatter
    }()

    /// 追加一行事件。任何失败都只写主日志,绝不影响调用方的业务流程。
    nonisolated static func record(_ message: String, to url: URL? = nil) {
        let target = url ?? defaultURL
        let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fm.fileExists(atPath: target.path) {
                try data.write(to: target, options: .atomic)
                return
            }

            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            LogService.error(
                "keep-awake event log write failed: \(error.localizedDescription)",
                category: "KeepAwakeEventLog"
            )
            return
        }

        trimIfOversized(target)
    }

    /// 超过 `maxBytes` 时保留最后 `trimToBytes`,并从下一个完整行开始 —— 否则
    /// 文件会以半行开头。
    private nonisolated static func trimIfOversized(_ url: URL) {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > maxBytes else { return }

        do {
            let data = try Data(contentsOf: url)
            var tail = data.suffix(trimToBytes)
            // 丢掉开头那半行。
            if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
                tail = tail[tail.index(after: newline)...]
            }
            let notice = "--- 日志已截断,更早的记录被丢弃 ---\n"
            var rebuilt = Data(notice.utf8)
            rebuilt.append(contentsOf: tail)
            try rebuilt.write(to: url, options: .atomic)
            LogService.info("keep-awake event log trimmed (was \(size) bytes)", category: "KeepAwakeEventLog")
        } catch {
            LogService.error(
                "keep-awake event log trim failed: \(error.localizedDescription)",
                category: "KeepAwakeEventLog"
            )
        }
    }
}
