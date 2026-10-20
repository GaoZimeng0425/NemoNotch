import Darwin
import Foundation

// MARK: - 循环保护决策(纯函数,单测覆盖)

/// 崩溃重启的计数与阈值决策。状态文件记录 "count lastRestartUnixSec",
/// handler 在 async-signal-safe 约束下只能做标量运算,决策逻辑集中在这里以便测试。
enum CrashRestartPolicy {
    /// 连续崩溃判定窗口:上次自动重启后 10 分钟内再崩,计入同一循环。
    static let restartWindow: TimeInterval = 600
    /// 窗口内最多自动重启次数;第 maxRestarts + 1 次崩溃放弃,等用户手动拉起。
    static let maxRestarts = 3
    /// 稳定运行多久后清零计数(小于它的存活不信任 —— 崩溃循环里每次重启都活不满)。
    static let stableUptime: TimeInterval = 120

    /// 计算本次崩溃后的连续计数。窗口外(或首次,`lastRestartUnix == nil`)归 1,
    /// 窗口内在前值上 +1。边界取严格小于:恰好隔一个完整窗口视为新循环。
    static func nextCount(
        previousCount: Int,
        lastRestartUnix: Int64?,
        nowUnix: Int64,
        window: TimeInterval = restartWindow
    ) -> Int {
        guard let lastRestartUnix else { return 1 }
        guard nowUnix - lastRestartUnix < Int64(window) else { return 1 }
        return previousCount + 1
    }

    /// 是否允许本次自动重启:崩溃序号 1...maxRestarts 各重启一次,之后放弃。
    static func shouldRestart(crashCount: Int, maxRestarts: Int = maxRestarts) -> Bool {
        crashCount <= maxRestarts
    }
}

// MARK: - 信号处理自愈

/// 致命信号自愈。崩溃族背景(2026-08-19 / 10-12 / 10-13 三次 .ips):主线程在
/// AppKit 屏幕重配派发栈内过度释放窗口对象,autoreleasepool 排干时对僵尸对象
/// objc_release → SIGSEGV,栈内无应用帧。L1(重配回调推迟窗口重建)移除已知
/// 根因;本类型是兜底 —— 任何残余崩溃发生时几秒内自动拉起新实例,且通过恢复
/// 默认处置后重发信号,让系统照常生成 .ips 崩溃报告(诊断证据不丢)。
///
/// **async-signal-safe 是硬约束**:handler 内只允许 open/read/write/lseek/close/
/// time/posix_spawn/signal/sigprocmask/raise 与纯标量运算。绝不构造 String/Array
/// (malloc —— 崩溃线程可能正持有 malloc 锁,重入即死锁)。所有缓冲在 install()
/// 里一次性分配并显式触碰 —— Swift 的 static var 是懒初始化的,懒初始化本身要
/// 拿锁/分配,绝不能发生在 handler 里;指针进程生命周期内永不释放。
///
/// 路线取舍(勿重选):不用 SMAppService —— ad-hoc 签名下 register() 返回成功但
/// 守护进程不会被拉起(KeepAwake 探针实测,status 说谎);不用 LaunchAgent
/// KeepAlive —— 表达不了"循环保护后放弃",且给用户装常驻系统状态属于过度。
/// 信号处理只对我们点名的致命信号动作,force-quit(SIGKILL 不可捕获)后保持死透。
enum CrashGuard {
    /// handler 专用预分配缓冲。install() 注册信号之前全部完成分配与初始化,
    /// handler 安装后不存在并发窗口。
    private nonisolated(unsafe) static var statePath: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var logPath: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var shPath: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    private nonisolated(unsafe) static var envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    private nonisolated(unsafe) static var readBuf: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var stateBuf: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var lineBuf: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var handling = false

    /// 状态文件定长记录 "NNNN TTTTTTTTTT\n"(16 字节,零填充)—— 定长意味着原地
    /// 覆写永不截断(ftruncate 不是 async-signal-safe,避开)。
    private static let stateRecordLength = 16
    private static let lineCapacity = 128

    static func install() {
        // 测试宿主崩溃会拉起新实例干扰测试连接;--uitest 截图模式自 terminate,
        // 同样不该有复活行为。
        guard !UITestMode.isTestHost, !UITestMode.isActive else {
            LogService.info("CrashGuard skipped (test host / uitest mode)", category: "CrashGuard")
            return
        }
        // 逃生开关:`defaults write com.nemo.BrightnessApp.NemoNotch crashGuardEnabled -bool false`
        if (UserDefaults.standard.object(forKey: "crashGuardEnabled") as? Bool) == false {
            LogService.info("CrashGuard disabled by crashGuardEnabled default", category: "CrashGuard")
            return
        }

        let dir = NSHomeDirectory() + "/.NemoNotch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // 重启子进程脚本(在崩溃进程的孤儿 shell 里跑,普通 shell 语义):
        // 1) 先捕获 P=$PPID 再轮询 kill -0 —— 等垂死进程真正退出(pid 释放)再
        //    open,避免 open 只是激活垂死旧实例;P 必须先捕获,进程死后 shell 被
        //    重挂到 launchd($PPID 变 1),那之后读就永远活着了。上限 100×0.2s=20s。
        // 2) open 重试 3 次:实测崩溃上下文里 open 偶发静默失败(3 次端到端验证
        //    1 次未拉起,机制本身在最小 env 下正常),失败时把 rc 落进审计日志,
        //    绝不无声消失。
        let bundlePath = Bundle.main.bundleURL.path
        let auditPath = dir + "/crash-restart.log"
        guard !bundlePath.contains("'"), !auditPath.contains("'") else {
            LogService.error(
                "CrashGuard not installed: path contains a quote: \(bundlePath) / \(auditPath)",
                category: "CrashGuard"
            )
            return
        }
        let command = "P=$PPID; n=0; while kill -0 $P 2>/dev/null && [ $n -lt 100 ]; do sleep 0.2; n=$((n+1)); done; "
            + "m=0; while [ $m -lt 3 ]; do /usr/bin/open -a '\(bundlePath)' && exit 0; "
            + "echo \"epoch=$(date +%s) sig=0 count=0 action=open-failed rc=$?\" >> '\(auditPath)'; "
            + "sleep 2; m=$((m+1)); done"

        shPath = copyC("/bin/sh")
        statePath = copyC(dir + "/crash-restart.state")
        logPath = copyC(dir + "/crash-restart.log")
        readBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        stateBuf = UnsafeMutablePointer<CChar>.allocate(capacity: stateRecordLength)
        stateBuf?.initialize(repeating: 0, count: stateRecordLength)
        lineBuf = UnsafeMutablePointer<CChar>.allocate(capacity: lineCapacity)
        handling = false

        let a = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 4)
        a[0] = shPath
        a[1] = copyC("-c")
        a[2] = copyC(command)
        a[3] = nil
        argv = a

        let e = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 3)
        e[0] = copyC("PATH=/usr/bin:/bin")
        e[1] = copyC("HOME=" + NSHomeDirectory())
        e[2] = nil
        envp = e

        // 懒初始化规避(本文件头的硬约束):handler 路径经默认参数读取的策略常量,
        // 首次触碰必须发生在注册信号之前 —— 默认参数在每个调用点求值,handler 里
        // 的首次触碰要走 swift_once 拿锁分配。
        _ = CrashRestartPolicy.restartWindow
        _ = CrashRestartPolicy.maxRestarts

        let signals = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP]
        for sig in signals {
            signal(sig, crashGuardSignalC)
        }
        LogService.info(
            "CrashGuard installed — fatal signals \(signals.map(String.init).joined(separator: ",")) "
                +
                "→ relaunch after parent exit ≤20s (loop guard: \(CrashRestartPolicy.maxRestarts)x/\(Int(CrashRestartPolicy.restartWindow))s)",
            category: "CrashGuard"
        )
        scheduleCounterReset()
    }

    /// 稳定运行 stableUptime 后把计数清零。崩溃循环里每次重启都活不满这个时长,
    /// 所以计数能跨重启累积到放弃;正常运行则不该让几小时前的旧崩溃占用配额。
    /// (普通代码路径,无 async-signal-safe 约束。与 handler 对状态文件的写无锁 ——
    /// 120s 整点恰好撞上崩溃的窗口极窄,最坏后果是清零覆盖一次自增、多放行一次
    /// 重启,温和,不为此上锁。)
    static func scheduleCounterReset(after seconds: TimeInterval = CrashRestartPolicy.stableUptime) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard let statePath else { return }
            let record = String(format: "%04d %ld\n", 0, Int64(Date().timeIntervalSince1970))
            let fd = open(statePath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            if fd >= 0 {
                record.withCString { bytes in
                    _ = write(fd, bytes, record.utf8.count)
                }
                close(fd)
            }
            LogService.info("CrashGuard: stable uptime \(Int(seconds))s — crash counter reset", category: "CrashGuard")
        }
    }

    // MARK: - 信号处理(async-signal-safe;只碰预分配缓冲与标量)

    fileprivate static func handleSignal(_ sig: Int32) {
        // 只处理第一个致命信号;后续信号恢复默认处置直接死。注意:若第二个信号与
        // 第一个不同(如 SIGSEGV 后 Swift runtime 补 SIGTRAP),重发的是第二个 ——
        // .ips 记录的崩溃类型可能掩盖首发信号。崩溃上下文内的取舍,接受。
        if handling {
            signal(sig, SIG_DFL)
            raise(sig)
            return
        }
        handling = true

        let nowSec = Int64(time(nil))
        var newCount = 1
        var allowed = true
        if let statePath, let readBuf, let stateBuf {
            let fd = open(statePath, O_RDWR | O_CREAT, 0o600)
            if fd >= 0 {
                let n = read(fd, readBuf, 63)
                let parsed = n > 0 ? parseTwoIntegers(readBuf, Int(n)) : (0, 0)
                let lastRestart = parsed.1 == 0 ? nil : parsed.1
                newCount = CrashRestartPolicy.nextCount(
                    previousCount: Int(parsed.0),
                    lastRestartUnix: lastRestart,
                    nowUnix: nowSec
                )
                allowed = CrashRestartPolicy.shouldRestart(crashCount: newCount)

                lseek(fd, 0, SEEK_SET)
                var pos = 0
                appendNumber(Int64(newCount), minWidth: 4, stateBuf, stateRecordLength, &pos)
                stateBuf[pos] = 32 // " "
                pos += 1
                appendNumber(nowSec, minWidth: 10, stateBuf, stateRecordLength, &pos)
                stateBuf[pos] = 10 // "\n" —— 凑满定长 16 字节,覆写无残留
                _ = write(fd, stateBuf, stateRecordLength)
                close(fd)
            }
            appendAuditLine(sig: sig, count: newCount, epoch: nowSec, restarted: allowed)
        }

        if allowed, let shPath, let argv, let envp {
            var child: pid_t = 0
            _ = posix_spawn(&child, shPath, nil, nil, argv, envp)
        }

        // 恢复默认处置后重发信号:系统按未处理致命信号走 EXC_CRASH →
        // ReportCrash 照常写 .ips(诊断证据保留),进程真正死亡。
        signal(sig, SIG_DFL)
        var set = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, sig)
        sigprocmask(SIG_UNBLOCK, &set, nil)
        raise(sig)
        _exit(1) // 不可达保险
    }

    /// 往 ~/.NemoNotch/crash-restart.log 追加一行审计记录(KeepAwakeEventLog 的
    /// 保留思路:主日志 1MB×7 文件两天就滚没,自愈决策要数周后仍可审计)。
    /// 只写 epoch 秒 —— localtime 不是 async-signal-safe,换算交给阅读的人。
    private nonisolated static func appendAuditLine(sig: Int32, count: Int, epoch: Int64, restarted: Bool) {
        guard let logPath, let lineBuf else { return }
        let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        var pos = 0
        append("epoch=", lineBuf, &pos)
        appendNumber(epoch, minWidth: 1, lineBuf, lineCapacity, &pos)
        append(" sig=", lineBuf, &pos)
        appendNumber(Int64(sig), minWidth: 1, lineBuf, lineCapacity, &pos)
        append(" count=", lineBuf, &pos)
        appendNumber(Int64(count), minWidth: 1, lineBuf, lineCapacity, &pos)
        if restarted {
            append(" action=restart\n", lineBuf, &pos)
        } else {
            append(" action=giveup\n", lineBuf, &pos)
        }
        _ = write(fd, lineBuf, pos)
        close(fd)
    }

    /// 解析前两个十进制非负整数("NNNN TTTT\n" → (NNNN, TTTT));手工扫描,
    /// 无 sscanf(非 async-signal-safe)。
    private nonisolated static func parseTwoIntegers(
        _ buf: UnsafeMutablePointer<CChar>,
        _ len: Int
    ) -> (Int64, Int64) {
        var first: Int64 = 0
        var second: Int64 = 0
        var which = 0
        var current: Int64 = 0
        var inNumber = false
        for i in 0 ..< len {
            let c = buf[i]
            if c >= 48, c <= 57 {
                // 防算术溢出 trap(handler 内 trap = 重入 = 不重启不审计):超长
                // 数字段(状态文件被手工改坏)直接截断不累计。
                if current < 999_999_999_999_999_999 {
                    current = current * 10 + Int64(c - 48)
                }
                inNumber = true
            } else if inNumber {
                if which == 0 {
                    first = current
                } else {
                    second = current
                    return (first, second)
                }
                which += 1
                current = 0
                inNumber = false
            }
        }
        if inNumber {
            if which == 0 {
                first = current
            } else {
                second = current
            }
        }
        return (first, second)
    }

    /// 手工十进制写入,零填充到 minWidth。纯标量运算,无分配、无 String。
    private nonisolated static func appendNumber(
        _ value: Int64,
        minWidth: Int,
        _ out: UnsafeMutablePointer<CChar>,
        _ cap: Int,
        _ pos: inout Int
    ) {
        var digitCount = 1
        var rest = value
        while rest >= 10 {
            digitCount += 1
            rest /= 10
        }
        let width = max(digitCount, minWidth)
        guard pos + width < cap else { return }
        var n = value
        var p = pos + width
        while p > pos {
            p -= 1
            out[p] = CChar(48 + n % 10)
            n /= 10
        }
        pos += width
    }

    /// 字符串字面量的字节是编译期常量(StaticString),拷贝安全。
    private nonisolated static func append(
        _ literal: StaticString,
        _ out: UnsafeMutablePointer<CChar>,
        _ pos: inout Int
    ) {
        let count = Int(literal.utf8CodeUnitCount)
        let cap = lineCapacity
        guard pos + count < cap else { return }
        for i in 0 ..< count {
            out[pos + i] = CChar(bitPattern: literal.utf8Start[i])
        }
        pos += count
    }

    /// 拷贝为 C 字符串,进程生命周期内永不释放(信号 handler 引用)。
    private static func copyC(_ string: String) -> UnsafeMutablePointer<CChar> {
        let units = string.utf8CString
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: units.count)
        units.withUnsafeBufferPointer { buffer in
            pointer.update(from: buffer.baseAddress!, count: buffer.count)
        }
        return pointer
    }
}

/// 信号 trampoline:顶层函数引用才能转 `@convention(c)` —— Swift 6 同时拒绝
/// 静态方法引用与"捕获上下文"的闭包字面量。只做一次透传,handler 本体在
/// `CrashGuard.handleSignal`。
private func crashGuardSignalC(_ sig: Int32) {
    CrashGuard.handleSignal(sig)
}
