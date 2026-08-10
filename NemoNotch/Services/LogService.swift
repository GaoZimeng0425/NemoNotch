import CocoaLumberjackSwift

final class LogService {
    nonisolated(unsafe) static let shared = LogService()
    private let fileLogger: DDFileLogger

    private init() {
        let logDir = NSHomeDirectory() + "/.NemoNotch/logs"

        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        DDLog.add(DDOSLogger.sharedInstance)

        let logFileManager = DDLogFileManagerDefault(logsDirectory: logDir)
        logFileManager.maximumNumberOfLogFiles = 7
        fileLogger = DDFileLogger(logFileManager: logFileManager)
        fileLogger.rollingFrequency = 60 * 60 * 24
        // CocoaLumberjack 的默认文件格式化器把时区**硬编码为 UTC**，于是日志
        // 时间比崩溃报告 / ps / Console 的本地时间早 8 小时（CST）。排查时极易
        // 把"刚写的日志"误读成"进程几小时前就停了"。这里换成本地时区，格式与
        // 默认实现保持一致，历史日志的排版不变。
        let localTimestamp = DateFormatter()
        localTimestamp.dateFormat = "yyyy/MM/dd HH:mm:ss:SSS"
        localTimestamp.timeZone = .current
        fileLogger.logFormatter = DDLogFileFormatterDefault(dateFormatter: localTimestamp)
        DDLog.add(fileLogger)

        #if DEBUG
            dynamicLogLevel = .all
        #else
            dynamicLogLevel = .info
        #endif
    }
}

extension LogService {
    nonisolated static func debug(_ message: String, category: String = "App") {
        DDLogDebug("[\(category)] \(message)")
    }

    nonisolated static func info(_ message: String, category: String = "App") {
        DDLogInfo("[\(category)] \(message)")
    }

    nonisolated static func warn(_ message: String, category: String = "App") {
        DDLogWarn("[\(category)] \(message)")
    }

    nonisolated static func error(_ message: String, category: String = "App") {
        DDLogError("[\(category)] \(message)")
    }
}
