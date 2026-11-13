import Foundation

/// 一条外部进程持有的「阻止空闲休眠」断言(`IOPMCopyAssertionsByProcess` 条目的解析产物)。
///
/// 字段集来自 2026-11-13 本机探针——头文件只记载了 `Type`/`Level`,运行时字典实际
/// 还有 `Process Name`/`AssertStartWhen`/超时键/归因键,**别按头文件下「不存在」的
/// 结论**(见 AGENTS.md 防休眠节)。
struct ExternalSleepAssertion: Equatable {
    let pid: Int32
    let processName: String
    let name: String
    let trueType: String
    let startedAt: Date
    /// 到期剩余秒数(按 `AssertTimeoutUpdateTime` 折算到 `now`,过期钳 0);无超时为 nil。
    let timeoutRemaining: TimeInterval?
    /// 归因 pid(`AssertionOnBehalfOfPID`,如 coreaudiod 挂给录音 app);无归因为 nil。
    let onBehalfOfPID: Int32?
}

/// 按 pid 聚合的展示行:一个进程可能持有多条断言。
struct ExternalSleepAssertionSummary: Equatable {
    let pid: Int32
    let processName: String
    let count: Int
    let oldestStartedAt: Date
    /// 组内最先到期的剩余秒数;全组无超时为 nil。
    let timeoutRemaining: TimeInterval?
    let onBehalfOfPID: Int32?
}

/// 外部休眠断言的纯解析/过滤/聚合层(IOKit 调用在服务层,不进此文件)。
enum ExternalSleepAssertions {
    /// 系统常驻守护,即使持有族内断言也不列 —— 常驻噪音,列出来等于没列。
    /// 实测样本:powerd「屏幕亮着就不睡」、bluetoothd HID、runningboardd osservice、WindowServer。
    static let noiseProcessNames: Set<String> = ["powerd", "WindowServer", "runningboardd", "bluetoothd"]

    /// 只列「系统不睡」族;display 保活族(NoDisplaySleepAssertion)语义是「屏幕不灭」,不混进来。
    static let systemSleepFamilyTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep"]

    /// 旧类型名 → 族内真名(条目缺 `AssertionTrueType` 时按此归族)。
    private static let legacyTypeMap: [String: String] = [
        "NoIdleSleepAssertion": "PreventUserIdleSystemSleep",
    ]

    /// 解析 `IOPMCopyAssertionsByProcess` 的顶层数字典(键为 pid,值为断言字典数组)。
    ///
    /// 过滤三连:缺 `AssertPID` 或非字典的条目跳过(不崩);自家 pid 跳过(两份自家
    /// 断言都不进面板);类型按 `AssertionTrueType`(缺失用 `AssertType` + 旧名映射)
    /// 归族,族外跳过。
    static func parse(byPID raw: [AnyHashable: Any], now: Date, ownPID: Int32) -> [ExternalSleepAssertion] {
        var out: [ExternalSleepAssertion] = []
        for value in raw.values {
            guard let entries = value as? [Any] else { continue }
            for element in entries {
                // 非字典元素(实测未见过,但按容错跳过)不崩不计数。
                guard let entry = element as? [String: Any] else { continue }
                if let parsed = parseEntry(entry, now: now, ownPID: ownPID) {
                    out.append(parsed)
                }
            }
        }
        return out
    }

    private static func parseEntry(
        _ entry: [String: Any],
        now: Date,
        ownPID: Int32
    ) -> ExternalSleepAssertion? {
        guard let pid = (entry["AssertPID"] as? NSNumber)?.int32Value, pid != ownPID else { return nil }
        let processName = entry["Process Name"] as? String ?? "pid \(pid)"
        guard !noiseProcessNames.contains(processName) else { return nil }

        let rawType = (entry["AssertionTrueType"] as? String) ?? (entry["AssertType"] as? String)
        guard let rawType else { return nil }
        let trueType = legacyTypeMap[rawType] ?? rawType
        guard systemSleepFamilyTypes.contains(trueType) else { return nil }

        // `AssertTimeoutTimeLeft` 是 `AssertTimeoutUpdateTime` 那一刻的余量(Date,
        // 实测桥接为 __NSTaggedDate),要减去之后的流逝;任一键缺失视为无超时。
        let timeoutRemaining: TimeInterval? = if let left = (entry["AssertTimeoutTimeLeft"] as? NSNumber)?.doubleValue,
                                                 let update = entry["AssertTimeoutUpdateTime"] as? Date {
            max(0, left - now.timeIntervalSince(update))
        } else {
            nil
        }

        return ExternalSleepAssertion(
            pid: pid,
            processName: processName,
            name: entry["AssertName"] as? String ?? "",
            trueType: trueType,
            startedAt: entry["AssertStartWhen"] as? Date ?? now,
            timeoutRemaining: timeoutRemaining,
            onBehalfOfPID: (entry["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
        )
    }

    /// 按 pid 聚合;组内取最早 `startedAt`、最小(最先到期)的超时余量、首个非 nil 归因;
    /// 组间按最老断言排前面(日期升序 —— 挂得最久的排最上面)。
    static func summarize(_ assertions: [ExternalSleepAssertion]) -> [ExternalSleepAssertionSummary] {
        Dictionary(grouping: assertions, by: \.pid)
            .map { pid, items in
                ExternalSleepAssertionSummary(
                    pid: pid,
                    processName: items[0].processName,
                    count: items.count,
                    oldestStartedAt: items.map(\.startedAt).min()!,
                    timeoutRemaining: items.compactMap(\.timeoutRemaining).min(),
                    onBehalfOfPID: items.compactMap(\.onBehalfOfPID).first
                )
            }
            .sorted { $0.oldestStartedAt < $1.oldestStartedAt }
    }

    /// 归因 pid 去重列表(保序)。多条断言可挂同一归因(如 coreaudiod 替同一
    /// app 的两个音频流各挂一条)——拿未去重的 (pid, name) 对直接构造
    /// `Dictionary(uniqueKeysWithValues:)` 会因重复 key trap(评审 P1)。
    static func uniqueOnBehalfPIDs(_ assertions: [ExternalSleepAssertion]) -> [Int32] {
        var seen = Set<Int32>()
        var out: [Int32] = []
        for pid in assertions.compactMap(\.onBehalfOfPID) where seen.insert(pid).inserted {
            out.append(pid)
        }
        return out
    }

    /// 剩余分钟(向下取整);nil 透传,负数钳 0。
    static func remainingMinutes(_ remaining: TimeInterval?) -> Int? {
        guard let remaining else { return nil }
        return max(0, Int(remaining / 60))
    }
}
