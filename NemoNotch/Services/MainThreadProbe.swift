import Foundation
import AppKit

/// 主线程卡顿探针:挂一个 CFRunLoopObserver,测每轮主 runloop 耗时。
/// 单轮超过阈值(默认 50ms)即抓主线程调用栈 + 窗口快照,写进 LogService。
///
/// 设计约束:
/// - Release 也常驻(用户机器复现也能拿到日志)。
/// - 平时零开销:只在超阈值时才做 `Thread.callStackSymbols` / 遍历窗口,
///   `mach_absolute_time` 是纳秒级、无分配。
/// - 不改变 app 行为:不做 layout、不触发 redraw,只读。
///
/// 用途:诊断 NemoNotch 被 watchdog 因 CPU 超标杀掉
/// (cpu_resource 报告显示主线程卡在 `NSView _layoutSubtreeWithOldSize:` 递归,
/// 由 `CA::Transaction::flush` 每帧驱动)。采样栈抓不到业务层符号,这个探针补上
/// "卡住那一轮主线程到底停在哪个业务函数 / 哪个窗口在疯布局"。
///
/// 整个类 `@MainActor`:install 在主线程的 applicationDidFinishLaunching,
/// CF observer 挂在 main runloop,回调也都在主线程跑。
@MainActor
final class MainThreadProbe {
    static let shared = MainThreadProbe()

    /// 单轮主 runloop 超过这个毫秒数即记录。50ms ≈ 丢 3 帧。
    private let thresholdMs: Double = 50
    /// 两次记录之间的最小间隔,防刷屏。
    private let cooldownSeconds: Double = 1.0

    private var observer: CFRunLoopObserver?
    private var lastWake: UInt64 = 0
    private var lastLogTime: Double = 0

    private init() {}

    /// 在主线程、应用启动后调用一次。
    func install() {
        guard observer == nil else { return }

        // activities:
        // - afterWaiting:主线程被唤醒(一轮活跃期开始)—— 记起点。
        // - beforeWaiting:即将休眠(一轮活跃期结束)—— 算这段活跃工作耗时。
        //   真实卡顿(某个 source/timer 回调霸占主线程)发生在这两个回调之间。
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let context = UnsafeMutablePointer<RunLoopProbeContext>.allocate(capacity: 1)
        context.initialize(to: RunLoopProbeContext(probe: self))

        var ctx = CFRunLoopObserverContext(
            version: 0,
            info: UnsafeMutableRawPointer(context),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let obs = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            activities.rawValue,
            true,  // repeats
            0,     // order: 最早
            { _, activity, info in
                guard let info else { return }
                let ctx = info.assumingMemoryBound(to: RunLoopProbeContext.self).pointee
                // CF 回调是 @convention(c),不能直接调 @MainActor 方法。
                // 但这个回调只会在 main runloop 上触发,所以安全地假设在 main actor 上。
                MainActor.assumeIsolated {
                    ctx.probe.handle(activity: activity)
                }
            },
            &ctx
        ) else {
            context.deinitialize(count: 1)
            context.deallocate()
            return
        }

        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
        LogService.info("installed (threshold=\(thresholdMs)ms)", category: "MainThreadProbe")
    }

    // CF 回调入口。绝对不能在这里做重活 —— 只读时间、必要时切回主线程采样。
    private func handle(activity: CFRunLoopActivity) {
        // 主线程被唤醒(一轮活跃期开始):记起点。
        if activity.contains(.afterWaiting) {
            lastWake = mach_absolute_time()
            return
        }
        // 即将休眠(活跃期结束):算这段活跃工作耗时。
        guard activity.contains(.beforeWaiting) else { return }
        guard lastWake != 0 else { return }
        let elapsedNs = machTimeNs(since: lastWake)
        lastWake = 0
        let elapsedMs = Double(elapsedNs) / 1_000_000.0
        guard elapsedMs >= thresholdMs else { return }

        // 冷却检查。
        let now = Date().timeIntervalSince1970
        if now - lastLogTime < cooldownSeconds { return }
        lastLogTime = now

        // 已在主线程(beforeWaiting 阶段,主线程即将休眠)。直接采样 —— 下一轮 runloop 会
        // 把日志写入也跑掉。无需 async 切换(那反而引入 Swift 6 sendable 问题)。
        recordSlowRunloop(elapsedMs: elapsedMs)
    }

    private func recordSlowRunloop(elapsedMs: Double) {
        // 抓当前主线程调用栈。这是整个探针里唯一有点开销的地方,且只在超阈值时触发。
        let stack = Thread.callStackSymbols.dropFirst(2) // 去掉本帧 + 系统帧
        let stackText = stack.joined(separator: "\n  ")

        // 窗口快照:看哪个窗口在疯布局。
        let windows = NSApp?.windows ?? []
        let windowSnap = windows.map { win -> String in
            let cv = win.contentView
            let cvSize = cv.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "nil"
            return "\(type(of: win)) title=\"\(win.title)\" frame=\(Int(win.frame.width))x\(Int(win.frame.height)) contentView=\(cvSize) visible=\(win.isVisible)"
        }.joined(separator: "\n  ")

        LogService.warn(
            """
            slow main runloop: \(String(format: "%.1f", elapsedMs))ms
            stack:
              \(stackText)
            windows (\(windows.count)):
              \(windowSnap)
            """,
            category: "MainThreadProbe"
        )
    }

    private func machTimeNs(since start: UInt64) -> UInt64 {
        let now = mach_absolute_time()
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let delta = now > start ? now - start : 0
        return delta * UInt64(info.numer) / UInt64(info.denom)
    }
}

/// 传给 CFRunLoopObserverContext 的桥接结构,持有对探针的引用。
/// `@unchecked Sendable`:探针本身是 @MainActor,但 CF 回调只在 main runloop 触发,
/// 实际不会跨线程;context 指针只是 C 侧的传递载体。
private struct RunLoopProbeContext: @unchecked Sendable {
    let probe: MainThreadProbe
}
