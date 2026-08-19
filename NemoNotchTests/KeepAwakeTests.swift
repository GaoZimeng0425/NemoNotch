import Foundation
import Testing

@testable import NemoNotch

// MARK: - 事件日志(长期保留的那份)

/// 每个用例一个临时文件,互不干扰。
private func makeTempLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("keepawake-test-\(UUID().uuidString)")
        .appendingPathComponent("keep-awake.log")
}

@Test func eventLogCreatesFileAndAppendsLines() throws {
    let url = makeTempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    KeepAwakeEventLog.record("盖子合上", to: url)
    KeepAwakeEventLog.record("盖子打开", to: url)

    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    #expect(lines[0].hasSuffix("盖子合上"))
    #expect(lines[1].hasSuffix("盖子打开"))
}

@Test func eventLogLinesCarryALocalTimestamp() throws {
    let url = makeTempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    KeepAwakeEventLog.record("事件", to: url)
    let line = try String(contentsOf: url, encoding: .utf8)

    // 与主日志同格式 `yyyy/MM/dd HH:mm:ss:SSS`,本地时区 —— 两份日志要能对得上。
    let pattern = #/^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}:\d{3} 事件$/#
    #expect(line.trimmingCharacters(in: .newlines).contains(pattern))
}

@Test func eventLogSurvivesAMissingParentDirectory() throws {
    // ~/.NemoNotch 在全新安装上可能还不存在,record 必须自己建出来。
    let url = makeTempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(!FileManager.default.fileExists(atPath: url.path))
    KeepAwakeEventLog.record("首次写入", to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test func eventLogTrimsWhenOversizedAndKeepsWholeLines() throws {
    let url = makeTempLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    // 预置一个超过 1MB 上限的文件,每行可识别。
    let filler = String(repeating: "x", count: 200)
    let oversized = (0 ..< 6_000).map { "line-\($0)-\(filler)" }.joined(separator: "\n") + "\n"
    try oversized.write(to: url, atomically: true, encoding: .utf8)
    #expect(try Data(contentsOf: url).count > 1_024 * 1_024)

    KeepAwakeEventLog.record("触发截断", to: url)

    let after = try String(contentsOf: url, encoding: .utf8)
    let bytes = Data(after.utf8).count
    // 截断到 512KB 左右,加上刚写入的那行 —— 总之必须显著小于上限。
    #expect(bytes < 1_024 * 1_024)
    // 最老的记录被丢弃,最新的必须还在。
    #expect(!after.contains("line-0-"))
    #expect(after.hasSuffix("触发截断\n"))
    // 关键:不能以半行开头,否则文件读起来是坏的。
    let firstLine = after.split(separator: "\n")[0]
    #expect(firstLine.contains("截断") || firstLine.hasPrefix("line-"))
}

// MARK: - pmset -g 解析

@Test func parsesSleepDisabledFromRealPmsetOutput() {
    // 真机 `pmset -g` 输出(macOS 26.5)。注意 `sleep 1 (sleep prevented by ...)`
    // 这一行——它含 "sleep" 且第二段也是数字,是最容易被粗糙解析器误匹配的干扰项。
    let output = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     disksleep            10
     sleep                1 (sleep prevented by Arc, coreaudiod, caffeinate)
     hibernatemode        3
     displaysleep         20 (display sleep prevented by Arc)
    """
    #expect(PMSet.parseSleepDisabled(output) == false)
}

@Test func parsesSleepDisabledWhenOn() {
    let output = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     sleep                1
    """
    #expect(PMSet.parseSleepDisabled(output) == true)
}

@Test func returnsNilWhenSleepDisabledLineIsAbsent() {
    // 部分机型/配置下整行缺席。这必须区别于 "存在且为 0" —— 前者是"读不到",
    // 后者是"确定没开"。
    let output = """
    Currently in use:
     standby              1
     sleep                1
    """
    #expect(PMSet.parseSleepDisabled(output) == nil)
}

@Test func returnsNilForUnexpectedValue() {
    #expect(PMSet.parseSleepDisabled(" SleepDisabled\t\tyes") == nil)
}

@Test func returnsNilForEmptyOutput() {
    #expect(PMSet.parseSleepDisabled("") == nil)
}

@Test func ignoresLinesThatMerelyContainTheToken() {
    // 只含子串、字段数不对的行不该被当成结果。
    let output = """
     note: SleepDisabled is managed by policy 1
     SleepDisabled\t\t1
    """
    #expect(PMSet.parseSleepDisabled(output) == true)
}

// MARK: - 用户取消授权的识别

@Test func detectsUserCancellationByAppleScriptErrorNumber() {
    let failure = PMSet.ShellFailure(
        command: "/usr/bin/osascript -e ...",
        status: 1,
        stderr: "execution error: User canceled. (-128)"
    )
    #expect(failure.isUserCancellation)
}

@Test func localizedCancellationTextStillDetected() {
    // 文案会跟随系统语言变化,所以匹配的是错误号而不是英文文本。
    let failure = PMSet.ShellFailure(
        command: "/usr/bin/osascript -e ...",
        status: 1,
        stderr: "execution error: 用户取消。 (-128)"
    )
    #expect(failure.isUserCancellation)
}

@Test func realFailureIsNotTreatedAsCancellation() {
    let failure = PMSet.ShellFailure(
        command: "/usr/bin/pmset -a disablesleep 1",
        status: 1,
        stderr: "pmset: must be run as root"
    )
    #expect(!failure.isUserCancellation)
}

// MARK: - 状态 / 标记对账

@Test func markerPlusEnabledMeansWeOwnIt() {
    let outcome = KeepAwakeReconciliation(systemSleepDisabled: true, hasMarker: true)
    #expect(outcome == KeepAwakeReconciliation(systemSleepDisabled: true, hasMarker: true))
    #expect(outcome.isEnabled)
    #expect(outcome.isOwned)
    #expect(!outcome.shouldDropMarker)
}

@Test func markerWithoutSystemFlagIsStaleAndDropped() {
    // 用户手动 `sudo pmset -a disablesleep 0` 关掉了,或系统重置过。
    let outcome = KeepAwakeReconciliation(systemSleepDisabled: false, hasMarker: true)
    #expect(!outcome.isEnabled)
    #expect(!outcome.isOwned)
    #expect(outcome.shouldDropMarker)
}

@Test func enabledWithoutMarkerIsNotOwned() {
    // 别人开的(用户自己跑的 pmset,或另一个 App)。如实显示,但退出时不还原。
    let outcome = KeepAwakeReconciliation(systemSleepDisabled: true, hasMarker: false)
    #expect(outcome.isEnabled)
    #expect(!outcome.isOwned)
    #expect(!outcome.shouldDropMarker)
}

@Test func cleanStateOwnsNothing() {
    let outcome = KeepAwakeReconciliation(systemSleepDisabled: false, hasMarker: false)
    #expect(!outcome.isEnabled)
    #expect(!outcome.isOwned)
    #expect(!outcome.shouldDropMarker)
}

@Test func unreadableSystemStateIsTreatedAsDisabledButKeepsTheMarker() {
    // 读不到时保守地当"没禁用" —— 宁可少显示一个开启态,也不要谎报。
    //
    // 但标记**必须保留**:`nil` 是"读不到"而非"已关闭"。若一次读取失败就删掉
    // 标记,我们会永久忘记那个 SleepDisabled=1 是自己开的,退出时不再还原,
    // 用户的 Mac 从此永远不睡且无从追溯。
    let outcome = KeepAwakeReconciliation(systemSleepDisabled: nil, hasMarker: true)
    #expect(!outcome.isEnabled)
    #expect(!outcome.isOwned)
    #expect(!outcome.shouldDropMarker)
}
