import Foundation

/// `pmset` 命令封装。
///
/// 读 (`pmset -g`) 不需要 root，写 (`pmset -a disablesleep`) 需要。写路径通过
/// `osascript ... with administrator privileges` 提权 —— 见 `KeepAwakeService`
/// 里对路线选择的说明。
enum PMSet {
    /// `pmset` 的绝对路径。写死是有意的:提权执行的命令绝不能受 `PATH` 影响。
    private static let executable = "/usr/bin/pmset"

    // MARK: - 纯逻辑(可测)

    /// 从 `pmset -g` 输出里取 `SleepDisabled` 标志。
    ///
    /// 输出形如:
    /// ```
    /// System-wide power settings:
    ///  SleepDisabled		0
    /// Currently in use:
    ///  standby              1
    /// ```
    /// 该行在部分机型/配置下**整行缺席**,此时返回 `nil`(区别于"存在且为 0")。
    static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // 必须是恰好两段的 `SleepDisabled <0|1>`，避免匹配到
            // `sleep 1 (sleep prevented by ...)` 这类含相同子串的行。
            guard fields.count == 2, fields[0] == "SleepDisabled" else { continue }
            switch fields[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    // MARK: - 读

    /// 读系统当前的 `SleepDisabled`。无法确定时返回 `nil`。
    ///
    /// **这是唯一的状态真相源。** 内存里的开关值随时可能失真 —— 用户手动跑过
    /// `pmset`、别的 App 改过、App 上次非正常退出,都会让两者不一致。
    nonisolated static func readSleepDisabled() async -> Bool? {
        do {
            let output = try run(executable, ["-g"])
            let value = parseSleepDisabled(output)
            LogService.debug("pmset -g → SleepDisabled=\(value.map(String.init) ?? "absent")", category: "PMSet")
            return value
        } catch {
            LogService.error("pmset -g failed: \(error.localizedDescription)", category: "PMSet")
            return nil
        }
    }

    // MARK: - 写(需要 root)

    /// 通过系统授权框把 `SleepDisabled` 写成 `on`。
    ///
    /// 每次调用弹一次密码框。用户点取消时抛 `.userCancelled` —— 调用方应当
    /// 静默回滚 UI,而不是当成错误弹提示。
    nonisolated static func writeSleepDisabled(_ on: Bool) async throws(KeepAwakeError) {
        // 命令全部硬编码,不拼接任何外部输入 —— 提权执行的字符串必须如此。
        let command = "\(executable) -a disablesleep \(on ? "1" : "0")"
        let script = "do shell script \"\(command)\" with administrator privileges"

        LogService.info("requesting admin authorization for: \(command)", category: "PMSet")
        do {
            _ = try run("/usr/bin/osascript", ["-e", script])
            LogService.info("pmset -a disablesleep \(on ? "1" : "0") succeeded", category: "PMSet")
        } catch let failure as ShellFailure {
            if failure.isUserCancellation {
                LogService.info("admin authorization cancelled by user", category: "PMSet")
                throw .userCancelled
            }
            LogService.error("pmset write failed: \(failure.localizedDescription)", category: "PMSet")
            throw .commandFailed(failure.stderr.isEmpty ? failure.localizedDescription : failure.stderr)
        } catch {
            LogService.error("pmset write failed: \(error.localizedDescription)", category: "PMSet")
            throw .commandFailed(error.localizedDescription)
        }
    }

    /// 立刻熄屏。**不需要 root** —— 合盖后主动熄屏的策略因此可以留在无特权侧。
    nonisolated static func displaySleepNow() {
        do {
            _ = try run(executable, ["displaysleepnow"])
            LogService.info("pmset displaysleepnow issued", category: "PMSet")
        } catch {
            LogService.error("pmset displaysleepnow failed: \(error.localizedDescription)", category: "PMSet")
        }
    }

    // MARK: - Process

    private nonisolated static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        // 输出量极小(几百字节),管道不会写满,先 wait 再读是安全的。
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ShellFailure(
                command: ([executable] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct ShellFailure: LocalizedError {
        let command: String
        let status: Int32
        let stderr: String

        /// `osascript` 在用户点掉授权框时以 1 退出,stderr 带 AppleScript
        /// 错误号 `-128`(User canceled)。文案会本地化,所以匹配错误号而非文本。
        var isUserCancellation: Bool {
            stderr.contains("-128")
        }

        var errorDescription: String? {
            stderr.isEmpty ? "\(command) exited with status \(status)"
                : "\(command) exited with status \(status): \(stderr)"
        }
    }
}

/// 防休眠开关的失败原因。
enum KeepAwakeError: LocalizedError, Equatable {
    /// 用户在系统授权框上点了取消。属于正常操作,调用方应静默回滚。
    case userCancelled
    /// `pmset` 真的失败了。
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .userCancelled: String(localized: "keepawake.error.cancelled")
        case let .commandFailed(detail): detail
        }
    }
}
