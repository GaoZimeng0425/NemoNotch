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
        DDLog.add(fileLogger)

        #if DEBUG
        dynamicLogLevel = .all
        #else
        dynamicLogLevel = .info
        #endif
    }

    var currentLogFile: String? {
        fileLogger.currentLogFileInfo?.filePath
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
