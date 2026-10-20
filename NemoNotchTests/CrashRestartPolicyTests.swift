@testable import NemoNotch
import Testing

/// CrashRestartPolicy 的循环保护算术 —— 信号 handler 在 async-signal-safe 约束
/// 下内联调用的就是这套决策,这里锁定窗口判定与放弃阈值的边界语义。
@Suite("Crash restart policy")
struct CrashRestartPolicyTests {
    @Test("首次崩溃(无上次重启记录)计数归 1")
    func firstCrash() {
        #expect(CrashRestartPolicy.nextCount(previousCount: 0, lastRestartUnix: nil, nowUnix: 1000) == 1)
    }

    @Test("窗口内再崩在前值上 +1")
    func insideWindowIncrements() {
        #expect(
            CrashRestartPolicy.nextCount(
                previousCount: 2,
                lastRestartUnix: 1000,
                nowUnix: 1000 + 599,
                window: 600
            ) == 3
        )
    }

    @Test("隔满一个窗口视为新循环,计数归 1(边界取严格小于)")
    func outsideWindowResets() {
        #expect(
            CrashRestartPolicy.nextCount(
                previousCount: 3,
                lastRestartUnix: 1000,
                nowUnix: 1000 + 600,
                window: 600
            ) == 1
        )
    }

    @Test("默认窗口常量同样满足边界语义")
    func defaultWindow() {
        let last: Int64 = 1000
        #expect(CrashRestartPolicy.nextCount(
            previousCount: 3,
            lastRestartUnix: last,
            nowUnix: last + Int64(CrashRestartPolicy.restartWindow) - 1
        ) == 4)
        #expect(CrashRestartPolicy.nextCount(
            previousCount: 3,
            lastRestartUnix: last,
            nowUnix: last + Int64(CrashRestartPolicy.restartWindow)
        ) == 1)
    }

    @Test("1...maxRestarts 各重启一次,之后放弃")
    func restartThreshold() {
        #expect(CrashRestartPolicy.shouldRestart(crashCount: 1))
        #expect(CrashRestartPolicy.shouldRestart(crashCount: CrashRestartPolicy.maxRestarts))
        #expect(!CrashRestartPolicy.shouldRestart(crashCount: CrashRestartPolicy.maxRestarts + 1))
        #expect(!CrashRestartPolicy.shouldRestart(crashCount: 10))
    }
}
