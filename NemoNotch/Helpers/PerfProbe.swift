import AppKit
import Darwin
import Foundation
import Synchronization

/// 运行时性能探针：统计热点调用频率/耗时，并采样进程与线程级 CPU，用于定位
/// “谁在烧 CPU”。
///
/// **默认关闭**，禁用时 `hit` / `begin` / `end` 只做一次静态 `Bool` 读取，
/// 可以安全留在热路径上。开启方式（任一，需重启 App）：
///
/// ```
/// # 1. 环境变量（Xcode scheme → Run → Arguments → Environment Variables）
/// NEMONOTCH_PERF=1
///
/// # 2. 命令行启动已安装的 Release 版本
/// NEMONOTCH_PERF=1 /Applications/NemoNotch.app/Contents/MacOS/NemoNotch
///
/// # 3. UserDefaults（对 GUI 双击启动也生效）
/// defaults write com.gaozimeng.NemoNotch perfProbe -bool true
/// ```
///
/// 报告每 `reportInterval` 秒（默认 5，可用 `NEMONOTCH_PERF_INTERVAL` 覆盖）
/// 以 `.info` 级别写入日志，category `PerfProbe`，因此 Release 构建同样可见：
///
/// ```
/// tail -f ~/.NemoNotch/logs/*.log | grep PerfProbe
/// ```
enum PerfProbe {
    private static let category = "PerfProbe"

    // MARK: - 开关

    /// 探针总开关，进程生命周期内只求值一次。
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["NEMONOTCH_PERF"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "perfProbe")
    }()

    /// 报告窗口长度（秒）。
    private static let reportInterval: Double = {
        guard let raw = ProcessInfo.processInfo.environment["NEMONOTCH_PERF_INTERVAL"],
              let value = Double(raw), value > 0
        else { return 5 }
        return value
    }()

    /// 单次报告最多列出多少个热点，防止日志被刷爆。
    private static let topN = 25

    // MARK: - 状态

    private struct Window {
        var hits: [String: Int] = [:]
        var nanos: [String: UInt64] = [:]
    }

    private static let window = Mutex(Window())
    private static let cpuBaseline = Mutex<CPUSample?>(nil)

    /// 主线程的 mach port，用来把线程 CPU 拆成“主线程 vs 其他”。
    /// `pthread_main_thread_np` 是 C 宏、Swift 不可见，所以改由 `start()`
    /// 在主线程上用 `pthread_self()` 填入。不转移所有权，无需 deallocate。
    private static let mainThreadPort = Mutex<mach_port_t>(0)

    /// `TH_USAGE_SCALE` / `TH_FLAGS_IDLE` 都是 C 宏，Swift 里取不到，按定义写死。
    private static let threadUsageScale = 1000.0
    private static let threadFlagIdle: Int32 = 0x2

    // MARK: - 插桩 API

    /// 记一次命中。
    @inline(__always)
    static func hit(_ label: String, count: Int = 1) {
        guard enabled else { return }
        window.withLock { $0.hits[label, default: 0] += count }
    }

    /// 开始一段计时，返回交给 `end(_:_:)` 的令牌。禁用时返回 0。
    @inline(__always)
    static func begin() -> UInt64 {
        enabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    /// 结束一段计时：累计耗时并记一次命中。
    ///
    /// 用于无法包进闭包的场景（例如 `Canvas` 的 renderer 拿到的是 `inout` 上下文，
    /// 闭包捕获不了）。
    @inline(__always)
    static func end(_ label: String, _ token: UInt64) {
        guard enabled, token != 0 else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- token
        window.withLock {
            $0.hits[label, default: 0] += 1
            $0.nanos[label, default: 0] += elapsed
        }
    }

    /// 直接登记一次“耗时已知”的命中，用于拿不到 begin 令牌的场景
    /// （例如 runloop observer 自己已经算过这一轮的时长）。
    @inline(__always)
    static func record(_ label: String, nanos: UInt64) {
        guard enabled else { return }
        window.withLock {
            $0.hits[label, default: 0] += 1
            $0.nanos[label, default: 0] += nanos
        }
    }

    /// 计时一段同步工作，并记一次命中。
    @inline(__always)
    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let token = DispatchTime.now().uptimeNanoseconds
        defer { end(label, token) }
        return try body()
    }

    // MARK: - 生命周期

    /// 启动周期性报告。**必须在主线程调用**（靠这一点捕获主线程的 mach port），
    /// 在 App 启动时调用一次；未开启时立即返回。
    static func start() {
        guard enabled else { return }
        mainThreadPort.withLock { $0 = pthread_mach_thread_np(pthread_self()) }
        cpuBaseline.withLock { $0 = sampleProcessCPU() }
        LogService.info(
            "探针已启用：每 \(fmt(reportInterval))s 输出一次报告（NEMONOTCH_PERF_INTERVAL 可调）",
            category: category
        )
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(reportInterval))
                } catch {
                    break // 被取消：退出循环，不要空转
                }
                report()
            }
        }
    }

    // MARK: - 报告

    /// 立即输出一份报告并重置窗口。
    static func report() {
        guard enabled else { return }

        let snapshot = window.withLock { current -> Window in
            let copy = current
            current = Window()
            return copy
        }

        let cpu = advanceProcessCPU()
        let threads = sampleThreadCPU()
        let windowSeconds = cpu?.seconds ?? reportInterval

        var lines: [String] = []
        lines.append("──────── 窗口 \(fmt(windowSeconds))s ────────")

        if let cpu {
            lines.append(
                "进程 CPU \(fmt(cpu.totalPercent))%（user \(fmt(cpu.userPercent))% / sys \(fmt(cpu.systemPercent))%）"
            )
        } else {
            lines.append("进程 CPU 采样失败")
        }

        if let threads {
            lines.append(
                "线程 \(threads.count) 个，瞬时占用合计 \(fmt(threads.total))%"
                    + "（主线程 \(fmt(threads.main))% / 其他 \(fmt(threads.total - threads.main))%）"
            )
        }

        // 有计时数据的热点：按窗口内总耗时降序 —— 这才是真正花掉的 CPU。
        let timed = snapshot.nanos
            .map { label, nanos -> (String, Int, UInt64) in (label, snapshot.hits[label] ?? 0, nanos) }
            .sorted { $0.2 > $1.2 }
        if !timed.isEmpty {
            lines.append("耗时热点（按窗口内总耗时降序）：")
            for (label, hits, nanos) in timed.prefix(topN) {
                let totalMs = Double(nanos) / 1_000_000
                let avgUs = hits > 0 ? Double(nanos) / 1000 / Double(hits) : 0
                let cpuShare = windowSeconds > 0 ? totalMs / 10 / windowSeconds : 0
                lines.append(
                    "  \(fmt(cpuShare))% cpu | \(fmt(totalMs))ms 共 | \(hits) 次"
                        + " | 均 \(fmt(avgUs))µs | \(fmt(Double(hits) / windowSeconds))/s | \(label)"
                )
            }
            if timed.count > topN { lines.append("  …另有 \(timed.count - topN) 项未列出") }
        }

        // 纯计数热点：按频率降序。频率异常高本身就是信号。
        let counted = snapshot.hits
            .filter { snapshot.nanos[$0.key] == nil }
            .sorted { $0.value > $1.value }
        if !counted.isEmpty {
            lines.append("调用频率（无计时）：")
            for (label, hits) in counted.prefix(topN) {
                lines.append("  \(fmt(Double(hits) / windowSeconds))/s | \(hits) 次 | \(label)")
            }
            if counted.count > topN { lines.append("  …另有 \(counted.count - topN) 项未列出") }
        }

        if timed.isEmpty, counted.isEmpty {
            lines.append("窗口内无插桩命中 —— CPU 若仍偏高，说明消耗在未插桩的路径上")
        }

        LogService.info("\n" + lines.joined(separator: "\n"), category: category)
        reportVisibleWindows()
    }

    /// 每份报告附带一次可见窗口快照。常驻可见的全屏透明覆盖层会一直参与窗口
    /// 合成（尤其带 `.blendMode` / `.blur` 时会强制离屏渲染），属于典型的
    /// “屏幕上看不见、CPU 却一直在烧”。合计像素数越大越可疑。
    private static func reportVisibleWindows() {
        Task { @MainActor in
            let visible = (NSApp?.windows ?? []).filter(\.isVisible)
            guard !visible.isEmpty else { return }
            let rows = visible.map { window -> String in
                let size = window.frame.size
                let megapixels = size.width * size.height / 1_000_000
                return "  \(type(of: window)) \(Int(size.width))x\(Int(size.height))"
                    + " \(fmt(megapixels))MP alpha=\(fmt(Double(window.alphaValue)))"
            }
            let totalMP = visible.reduce(0.0) { $0 + $1.frame.width * $1.frame.height / 1_000_000 }
            LogService.info(
                "可见窗口 \(visible.count) 个，合计 \(fmt(totalMP))MP 参与合成：\n"
                    + rows.joined(separator: "\n"),
                category: category
            )
        }
    }

    // MARK: - 进程 CPU 采样

    private struct CPUSample {
        let wall: UInt64
        let user: UInt64
        let system: UInt64
    }

    private struct CPUDelta {
        let seconds: Double
        let userPercent: Double
        let systemPercent: Double
        var totalPercent: Double { userPercent + systemPercent }
    }

    /// 读取本进程累计的 user/system CPU 时间（纳秒）。
    ///
    /// 用 POSIX `getrusage` 而不是 `proc_pid_rusage`：后者在当前 SDK 上，
    /// `rusage_info_current` 的结构体版本与内核写回的长度不一致，会栈越界后
    /// SIGABRT（已实测）。`getrusage` 只给 user/system 时间，正是这里要的。
    private static func sampleProcessCPU() -> CPUSample? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func nanos(_ time: timeval) -> UInt64 {
            UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_usec) * 1000
        }
        return CPUSample(
            wall: DispatchTime.now().uptimeNanoseconds,
            user: nanos(usage.ru_utime),
            system: nanos(usage.ru_stime)
        )
    }

    /// 与上次采样求差，得出这段窗口的真实 CPU 占用，并把基线推进。
    private static func advanceProcessCPU() -> CPUDelta? {
        guard let now = sampleProcessCPU() else { return nil }
        let previous = cpuBaseline.withLock { baseline -> CPUSample? in
            let old = baseline
            baseline = now
            return old
        }
        guard let previous, now.wall > previous.wall else { return nil }

        let elapsed = Double(now.wall - previous.wall)
        guard elapsed > 0 else { return nil }
        return CPUDelta(
            seconds: elapsed / 1_000_000_000,
            userPercent: Double(now.user &- previous.user) / elapsed * 100,
            systemPercent: Double(now.system &- previous.system) / elapsed * 100
        )
    }

    // MARK: - 线程 CPU 采样

    /// 瞬时线程占用（`thread_basic_info.cpu_usage` 是最近调度窗口的采样，
    /// 不是窗口平均值，只用于判断“主线程 vs 后台线程”的分布）。
    private static func sampleThreadCPU() -> (total: Double, main: Double, count: Int)? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        defer {
            for index in 0 ..< Int(count) {
                mach_port_deallocate(mach_task_self_, list[index])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.size)
            )
        }

        let infoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.stride / MemoryLayout<natural_t>.stride
        )
        let mainPort = mainThreadPort.withLock { $0 }

        var total = 0.0
        var main = 0.0
        for index in 0 ..< Int(count) {
            var info = thread_basic_info()
            var size = infoCount
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { rebound in
                    thread_info(list[index], thread_flavor_t(THREAD_BASIC_INFO), rebound, &size)
                }
            }
            guard result == KERN_SUCCESS, info.flags & threadFlagIdle == 0 else { continue }
            let percent = Double(info.cpu_usage) / threadUsageScale * 100
            total += percent
            if list[index] == mainPort { main = percent }
        }
        return (total, main, Int(count))
    }

    // MARK: - 格式化

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
