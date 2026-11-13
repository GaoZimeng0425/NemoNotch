import Foundation
@testable import NemoNotch
import Testing

/// 真实形状来自 2026-11-13 本机探针(`IOPMCopyAssertionsByProcess` 运行时字典,
/// 字段集头文件未记载,见 AGENTS.md 防休眠节):
/// - ZCode:`AssertType=NoIdleSleepAssertion` + `AssertionTrueType=PreventUserIdleSystemSleep`
/// - 带超时条目:`AssertTimeoutTimeLeft`(数字秒)+ `AssertTimeoutUpdateTime`(Date)
/// - 归因:`AssertionOnBehalfOfPID`(NSNumber)
struct ExternalSleepAssertionsTests {
    private let now = Date(timeIntervalSince1970: 1_794_580_000)

    // MARK: - fixture

    private func entry(
        pid: Int32,
        process: String? = "App",
        name: String = "some assertion",
        type: String = "PreventUserIdleSystemSleep",
        trueType: String? = "PreventUserIdleSystemSleep",
        start: Date? = nil,
        timeoutLeft: Double? = nil,
        timeoutUpdate: Date? = nil,
        onBehalf: Int32? = nil
    ) -> [String: Any] {
        var a: [String: Any] = [
            "AssertPID": pid,
            "AssertType": type,
            "AssertName": name,
        ]
        if let process {
            a["Process Name"] = process
        }
        if let start {
            a["AssertStartWhen"] = start
        }
        if let trueType {
            a["AssertionTrueType"] = trueType
        }
        if let timeoutLeft {
            a["AssertTimeoutTimeLeft"] = timeoutLeft
        }
        if let timeoutUpdate {
            a["AssertTimeoutUpdateTime"] = timeoutUpdate
        }
        if let onBehalf {
            a["AssertionOnBehalfOfPID"] = onBehalf
        }
        return a
    }

    private func group(pid: Int32, _ entries: [[String: Any]]) -> [AnyHashable: Any] {
        [AnyHashable(NSNumber(value: pid)): entries]
    }

    // MARK: - parse:归族与过滤

    @Test func trueTypeWinsOverLegacyAssertType() {
        // ZCode 实测形状:AssertType 是旧名字,归族必须按 TrueType。
        let out = ExternalSleepAssertions.parse(
            byPID: group(
                pid: 39735,
                [entry(
                    pid: 39735,
                    process: "ZCode",
                    type: "NoIdleSleepAssertion",
                    trueType: "PreventUserIdleSystemSleep"
                )]
            ),
            now: now, ownPID: 1
        )
        #expect(out.count == 1)
        #expect(out[0].trueType == "PreventUserIdleSystemSleep")
        #expect(out[0].processName == "ZCode")
    }

    @Test func legacyTypeAloneNormalizesIntoFamily() {
        // 没有 TrueType 的老形状:NoIdleSleepAssertion 是 PreventUserIdleSystemSleep 的旧名。
        let out = ExternalSleepAssertions.parse(
            byPID: group(pid: 99, [entry(pid: 99, type: "NoIdleSleepAssertion", trueType: nil)]),
            now: now, ownPID: 1
        )
        #expect(out.count == 1)
    }

    @Test func nonFamilyTypeExcluded() {
        // WindowServer 的 UserIsActive 不属于「系统不睡」族。
        let out = ExternalSleepAssertions.parse(
            byPID: group(
                pid: 410,
                [entry(pid: 410, process: "WindowServer", type: "UserIsActive", trueType: "UserIsActive")]
            ),
            now: now, ownPID: 1
        )
        #expect(out.isEmpty)
    }

    @Test func noiseProcessesFiltered() {
        // 四个系统常驻守护即使持有族内类型也不列(列了等于没列)。
        let raw: [AnyHashable: Any] = [
            AnyHashable(NSNumber(value: 352)): [entry(
                pid: 352,
                process: "powerd",
                name: "Powerd - Prevent sleep while display is on"
            )],
            AnyHashable(NSNumber(value: 403)): [entry(pid: 403, process: "bluetoothd")],
            AnyHashable(NSNumber(value: 414)): [entry(pid: 414, process: "runningboardd")],
            AnyHashable(NSNumber(value: 410)): [entry(pid: 410, process: "WindowServer")],
        ]
        #expect(ExternalSleepAssertions.parse(byPID: raw, now: now, ownPID: 1).isEmpty)
    }

    @Test func ownPidAssertionsFiltered() {
        // 自家两份断言(第二层 + A 开关)同 pid,都不得进面板。
        let raw = group(pid: 7, [
            entry(
                pid: 7,
                process: "NemoNotch",
                name: "NemoNotch Keep Awake",
                type: "PreventSystemSleep",
                trueType: "PreventSystemSleep"
            ),
            entry(pid: 7, process: "NemoNotch", name: "NemoNotch Idle Keep Awake"),
        ])
        #expect(ExternalSleepAssertions.parse(byPID: raw, now: now, ownPID: 7).isEmpty)
    }

    // MARK: - parse:字段语义

    @Test func timeoutRemainingComputedFromUpdateTime() throws {
        // TimeLeft 是 UpdateTime 那一刻的余量,要减去之后的流逝。
        let out = ExternalSleepAssertions.parse(
            byPID: group(
                pid: 4844,
                [entry(pid: 4844, process: "caffeinate", timeoutLeft: 100, timeoutUpdate: now.addingTimeInterval(-40))]
            ),
            now: now, ownPID: 1
        )
        #expect(out.count == 1)
        #expect(try abs(#require(out[0].timeoutRemaining) - 60) < 0.001)
    }

    @Test func expiredTimeoutClampedToZero() {
        let out = ExternalSleepAssertions.parse(
            byPID: group(
                pid: 4844,
                [entry(pid: 4844, process: "caffeinate", timeoutLeft: 10, timeoutUpdate: now.addingTimeInterval(-100))]
            ),
            now: now, ownPID: 1
        )
        #expect(out[0].timeoutRemaining == 0)
    }

    @Test func missingTimeoutKeysGiveNil() {
        let out = ExternalSleepAssertions.parse(
            byPID: group(pid: 39735, [entry(pid: 39735, process: "ZCode")]),
            now: now, ownPID: 1
        )
        #expect(out[0].timeoutRemaining == nil)
    }

    @Test func onBehalfPidPassedThrough() {
        // coreaudiod 挂给 octok 的形状:归因 pid 透传,由展示层解析名字。
        let out = ExternalSleepAssertions.parse(
            byPID: group(pid: 591, [entry(pid: 591, process: "coreaudiod", onBehalf: 57602)]),
            now: now, ownPID: 1
        )
        #expect(out[0].onBehalfOfPID == 57602)
    }

    @Test func malformedEntriesSkippedNotCrashed() {
        // 缺 AssertPID 的条目、非字典元素、空顶层数字典:跳过,不崩,不误报。
        let raw: [AnyHashable: Any] = [
            AnyHashable(NSNumber(value: 100)): [
                ["AssertType": "PreventUserIdleSystemSleep", "Process Name": "NoPid"],
                entry(pid: 101, process: "Good"),
                "not a dictionary",
            ],
        ]
        let out = ExternalSleepAssertions.parse(byPID: raw, now: now, ownPID: 1)
        #expect(out.count == 1)
        #expect(out[0].processName == "Good")
        #expect(ExternalSleepAssertions.parse(byPID: [:], now: now, ownPID: 1).isEmpty)
    }

    @Test func processNameAndStartFallbacks() {
        let out = ExternalSleepAssertions.parse(
            byPID: group(pid: 123, [entry(pid: 123, process: nil, start: nil)]),
            now: now, ownPID: 1
        )
        #expect(out[0].processName == "pid 123")
        #expect(out[0].startedAt == now)
    }

    // MARK: - summarize

    @Test func summarizeGroupsSortsAndAggregates() {
        let t1 = now.addingTimeInterval(-7200)
        let t2 = now.addingTimeInterval(-60)
        let t0 = now.addingTimeInterval(-10000)
        let parsed = [
            ExternalSleepAssertion(
                pid: 100,
                processName: "ZCode",
                name: "a",
                trueType: "PreventUserIdleSystemSleep",
                startedAt: t1,
                timeoutRemaining: 300,
                onBehalfOfPID: nil
            ),
            ExternalSleepAssertion(
                pid: 100,
                processName: "ZCode",
                name: "b",
                trueType: "PreventUserIdleSystemSleep",
                startedAt: t2,
                timeoutRemaining: 100,
                onBehalfOfPID: 55
            ),
            ExternalSleepAssertion(
                pid: 200,
                processName: "octok-daemon",
                name: "c",
                trueType: "PreventUserIdleSystemSleep",
                startedAt: t0,
                timeoutRemaining: nil,
                onBehalfOfPID: nil
            ),
        ]
        let s = ExternalSleepAssertions.summarize(parsed)
        #expect(s.count == 2)
        // 最老的组排前面:octok(10000s 前)> ZCode(7200s 前)
        #expect(s[0].pid == 200)
        #expect(s[0].timeoutRemaining == nil)
        #expect(s[1].pid == 100)
        #expect(s[1].count == 2)
        #expect(s[1].oldestStartedAt == t1)
        #expect(s[1].timeoutRemaining == 100) // 组内最小(最先到期)
        #expect(s[1].onBehalfOfPID == 55)
    }

    // MARK: - 时间分量

    @Test func ageComponentsMath() {
        #expect(ExternalSleepAssertions.ageComponents(startedAt: now.addingTimeInterval(-11.5 * 3600), now: now) == (
            hours: 11,
            minutes: 30
        ))
        #expect(ExternalSleepAssertions.ageComponents(startedAt: now.addingTimeInterval(-59 * 60), now: now) == (
            hours: 0,
            minutes: 59
        ))
        #expect(ExternalSleepAssertions.ageComponents(startedAt: now.addingTimeInterval(30), now: now) == (
            hours: 0,
            minutes: 0
        ))
    }

    @Test func remainingMinutesMath() {
        #expect(ExternalSleepAssertions.remainingMinutes(122) == 2)
        #expect(ExternalSleepAssertions.remainingMinutes(59) == 0)
        #expect(ExternalSleepAssertions.remainingMinutes(0.4) == 0)
        #expect(ExternalSleepAssertions.remainingMinutes(nil) == nil)
    }
}
