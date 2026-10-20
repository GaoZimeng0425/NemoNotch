import Foundation
import IOKit.pwr_mgt

/// 系统真实状态与落盘标记的对账结果。
///
/// 抽成纯结构体是因为这是整个功能最容易出错的地方 —— `SleepDisabled` 是全局
/// 持久设置,进程外的任何人都可能改它,而标记只代表"上次是我们开的"。两者的
/// 四种组合各有不同的正确处理,值得单独测。
struct KeepAwakeReconciliation: Equatable {
    /// 系统当前是否禁用了休眠。读不到时按"没禁用"处理。
    let isEnabled: Bool
    /// 这份状态是否由本 App 开启(标记在 **且** 系统确实开着)。
    let isOwned: Bool
    /// 标记已经失去意义,应当删除。
    let shouldDropMarker: Bool

    init(systemSleepDisabled: Bool?, hasMarker: Bool) {
        let enabled = systemSleepDisabled ?? false
        isEnabled = enabled
        isOwned = hasMarker && enabled
        // 只有**确知**系统已经不禁休眠时才清标记(用户手动关的,或系统重置过)。
        //
        // 关键:`nil` 是"读不到",不是"已关闭"。一次 pmset 读取失败若就把标记
        // 删掉,我们会永久忘记那个 SleepDisabled=1 是自己开的 —— 退出时不再
        // 还原,用户的 Mac 从此永远不睡。所以 nil 时标记原样保留。
        shouldDropMarker = hasMarker && systemSleepDisabled == false
    }
}

/// 关闭防休眠后,是否应当立刻让机器睡下去(纯决策,可测)。
///
/// 背景:清掉 `disablesleep` 并不会让**已经合着盖**的机器自己睡 —— 它会睁着
/// 眼继续跑,放进包里就是持续发热,所以要补一脚 `pmset sleepnow`。
///
/// 三个条件缺一不可:
/// - 系统确实还处于"不禁休眠"(复核时用户没有又把开关拨回来);
/// - 盖子合着(`AppleClamshellState`);
/// - 内核判断合盖**会**导致睡眠(`AppleClamshellCausesSleep` —— 接着外接
///   显示器的 clamshell 工作模式下它是 No,那时合盖是用户要的工作状态)。
///
/// 任何一项读不到(`nil`)都不睡 —— 宁可不睡,也不要把用户正在用的机器睡黑。
struct KeepAwakeSleepNowDecision: Equatable {
    let shouldSleepNow: Bool

    init(systemSleepDisabled: Bool?, lidClosed: Bool?, clamshellCausesSleep: Bool?) {
        shouldSleepNow = systemSleepDisabled == false
            && lidClosed == true
            && clamshellCausesSleep == true
    }
}

/// 这次对账是谁触发的 —— 决定"状态发生变化"要不要按外部改动记入长期日志。
enum KeepAwakeRefreshReason {
    /// 我们自己的动作:启动、开关切换、设置页打开。
    case local
    /// prefschange 通知或周期轮询 —— 系统设置可能被外部程序改动了。
    case external
}

/// 合盖不休眠。
///
/// ## 为什么必须提权
///
/// 合盖走的是内核 clamshell sleep 路径,**无视所有 IOPMAssertion** ——
/// `caffeinate` / `IOPMAssertionCreateWithName` 那一套只能挡空闲休眠。唯一的
/// 口子是 `IOPMrootDomain` 的 `SleepDisabled` 标志,即 `pmset -a disablesleep`,
/// 而它需要 root。
///
/// ## 为什么用 osascript 而不是 SMAppService + LaunchDaemon
///
/// LaunchDaemon 路线一次批准后永久静默,体验更好,但**要求稳定的 Apple 签名**。
/// 本机实测(同一 bundle、同一 `/Applications` 路径、同一个已批准的 bundle id,
/// 只改签名):
///
/// | | ad-hoc | Apple Development |
/// |---|---|---|
/// | `register()` / `status` | 都报成功 | 都报成功 |
/// | launchd 拉起 helper | **不拉起** | 拉起 (uid=0) |
///
/// 也就是说 ad-hoc 下 `register()` 返回 OK、`status` 报 `.enabled`,**全都在
/// 撒谎**,直到发 XPC 才发现 helper 根本没起来。NemoNotch 的 Release 产物是
/// ad-hoc 签名的(`build.sh`),所以那条路对下载 DMG 的用户直接不可用。
///
/// 这里改用 `osascript ... with administrator privileges`:不依赖任何签名,
/// ad-hoc 构建照样能用。代价是开、关各弹一次系统授权框。
///
/// ## 状态真相源
///
/// `isEnabled` 永远来自 `pmset -g`,不是内存变量。`SleepDisabled` 是**跨重启
/// 持久的全局系统设置**,用户手动跑过 `pmset`、别的 App 改过、本 App 上次被
/// `kill -9`,都会让内存值失真。
@MainActor
@Observable
final class KeepAwakeService {
    /// 系统当前是否禁用了休眠。真相源是 `pmset -g`。
    private(set) var isEnabled = false

    /// 这个状态是否由 NemoNotch 开启的(落盘标记还在)。
    ///
    /// 用来区分"我们开的"和"用户自己 `sudo pmset` 开的" —— 后者退出时不该
    /// 被我们擅自还原。
    private(set) var isOwned = false

    /// 正在等待用户在系统授权框上操作。
    private(set) var isBusy = false

    /// 最近一次失败原因。用户取消授权不算失败,不写这里。
    private(set) var lastError: String?

    private let lidMonitor = LidMonitor()
    private weak var settings: AppSettings?

    /// 开启期间持有的 `PreventSystemSleep` 断言(0 = 未持有)。见
    /// `holdIdleSleepAssertion(_:)` 的说明。
    private var idleSleepAssertion: IOPMAssertionID = 0

    /// 断言创建失败的日志已记过(持续失败只记第一次,防轮询刷屏)。
    private var idleSleepAssertionFailureLogged = false

    /// 周期对账任务 —— 兜底发现外部对 `SleepDisabled` 的改动(通知可能漏发)。
    private var pollTask: Task<Void, Never>?

    /// Darwin 通知观察者指针(`CFNotificationCenterAddObserver` 的 observer
    /// 参数即回调上下文),注销时要用。
    private var prefsChangeObserver: UnsafeMutableRawPointer?

    /// 对账轮询间隔。直读注册表开销可忽略,10s 的检测延迟足够 —— 通知路径
    /// (`prefschange`)本来就是快速通道,轮询只是漏发时的兜底。
    private static let pollInterval: TimeInterval = 10

    /// 关闭防休眠后到复核"盖子是否合着"的等待。给设置落到内核的时间,也给
    /// "刚关掉又反悔拨回来"留窗口。
    private static let lidSettleDelay: TimeInterval = 2

    /// 落盘标记:存在 == 我们改过系统设置且还没还原。
    ///
    /// 跟着项目惯例放 `~/.NemoNotch/`。它的意义完全在于跨进程存活 —— App 被
    /// 强杀时内存状态全丢,只有这个文件还能告诉下次启动的我们"这是我们开的"。
    private let markerURL: URL

    static var defaultMarkerURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".NemoNotch")
            .appendingPathComponent("keep-awake.enabled")
    }

    init(settings: AppSettings? = nil, markerURL: URL? = nil) {
        self.settings = settings
        self.markerURL = markerURL ?? Self.defaultMarkerURL
        LogService.info("KeepAwakeService init", category: "KeepAwake")
    }

    /// `isolated deinit` —— 要触碰 MainActor 隔离的轮询任务 / 断言句柄 /
    /// 观察者指针,普通 nonisolated deinit 碰不到它们。断言随进程退出也会被
    /// 系统回收,这里显式释放只是不留悬念。
    isolated deinit {
        if let prefsChangeObserver {
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), prefsChangeObserver
            )
        }
        pollTask?.cancel()
        if idleSleepAssertion != 0 {
            IOPMAssertionRelease(idleSleepAssertion)
        }
        LogService.info("KeepAwakeService deinit", category: "KeepAwake")
    }

    /// 订阅合盖事件并做一次首轮对账。
    ///
    /// 刻意不放在 `init` 里 —— 测试会构造裸实例,它们不该去跑 `pmset` 和
    /// 订阅 IOKit。只有 `AppDelegate` 持有的那一个会被 `start()`。
    func start() {
        do {
            try lidMonitor.start()
        } catch {
            // 台式机没有 clamshell,或 IOKit 不给订阅 —— 防休眠本身仍然可用,
            // 只是少了合盖自动熄屏。不阻断。
            LogService.warn("LidMonitor unavailable: \(error.localizedDescription)", category: "KeepAwake")
        }
        lidMonitor.autoDisplayOff = settings?.keepAwakeLidDisplayOff ?? true
        registerPrefsChangeObserver()
        startStatePolling()

        Task {
            await refresh()
            // 启动时如果防休眠已经开着,留一条痕。可能是上次退出没还原(崩溃 /
            // 强杀 / 用户取消了授权),也可能是用户主动关掉了"退出时还原"。
            // 两种都值得在长期日志里可见 —— 这正是"Mac 为什么一直不睡"的答案。
            if isEnabled {
                KeepAwakeEventLog.record(
                    "启动时防休眠已处于开启状态 [\(isOwned ? "本 App 开启" : "非本 App 开启")]"
                )
            }
        }
    }

    // MARK: - 对账

    /// 重新从系统读状态并与落盘标记对账。
    ///
    /// 四种组合:
    /// - 标记在 + 系统开 → 我们开的,还持有着 (`isOwned = true`)
    /// - 标记在 + 系统关 → 用户手动关掉了(或系统重置),清标记
    /// - 标记无 + 系统开 → 别人开的,如实显示但不认领,退出时不动它
    /// - 标记无 + 系统关 → 干净状态
    ///
    /// 注意这里**不会**自动还原"标记在 + 系统开"的残留 —— 还原要弹授权框,
    /// 启动即弹密码框是无法接受的。取而代之的是如实显示状态,菜单栏和设置页
    /// 都能一眼看到"防休眠开启中",用户可随时一键关闭。
    ///
    /// 状态真相源优先直读 IOPMrootDomain 注册表(零开销,轮询才做得起),
    /// 读不到时回退到 `pmset -g` 解析。
    func refresh(reason: KeepAwakeRefreshReason = .local) async {
        let wasEnabled = isEnabled
        // `??` 的右操作数是 autoclosure,放不下 await,展开成显式回退。
        let system: Bool? = if let live = PMSet.readSleepDisabledLive() {
            live
        } else {
            await PMSet.readSleepDisabled()
        }
        let hasMarker = FileManager.default.fileExists(atPath: markerURL.path)
        let outcome = KeepAwakeReconciliation(systemSleepDisabled: system, hasMarker: hasMarker)

        if isEnabled != outcome.isEnabled {
            LogService.info(
                "keep-awake state \(isEnabled) → \(outcome.isEnabled) (marker=\(hasMarker), reason=\(reason))",
                category: "KeepAwake"
            )
            // 我们自己的写路径也会触发 prefschange 通知,但那期间 `isBusy`
            // 为真,外部复查被整体跳过,不会把自己误记成外部改动。
            if reason == .external {
                KeepAwakeEventLog.record(
                    "防休眠设置被外部程序改动:现在\(outcome.isEnabled ? "开启" : "关闭")"
                        + " [\(outcome.isOwned ? "本 App 开启" : "非本 App 开启")]"
                )
            }
        }
        // 只在有变化时写回 —— @Observable 的写通知不区分值是否相同,轮询每
        // 10s 无条件赋值会让菜单栏/设置页跟着每轮重算。
        if isEnabled != outcome.isEnabled {
            isEnabled = outcome.isEnabled
        }
        if isOwned != outcome.isOwned {
            isOwned = outcome.isOwned
        }

        if outcome.shouldDropMarker {
            LogService.info("stale marker with sleep re-enabled → dropping marker", category: "KeepAwake")
            removeMarker()
        }

        holdIdleSleepAssertion(outcome.isEnabled)

        lidMonitor.setEnabled(isEnabled)
        // 只在上升沿补熄屏:轮询引入后 refresh 会周期性跑,不能每轮都对一个
        // 已经合着的盖子再发一次 displaysleepnow。
        if isEnabled, !wasEnabled {
            lidMonitor.turnDisplayOffIfNeeded()
        }
    }

    // MARK: - 开关

    /// 切换防休眠。会弹一次系统授权框。
    ///
    /// 用户取消授权时静默回滚,不写 `lastError` —— 取消是正常操作,不是错误。
    func setEnabled(_ on: Bool) async {
        guard !isBusy else {
            LogService.debug("setEnabled(\(on)) ignored — authorization already in flight", category: "KeepAwake")
            return
        }
        guard on != isEnabled else {
            LogService.debug("setEnabled(\(on)) is a no-op — already in that state", category: "KeepAwake")
            return
        }

        isBusy = true
        lastError = nil
        defer { isBusy = false }

        // 顺序很重要:先写标记再改设置。若改完设置就崩溃,标记已在,下次启动
        // 能认出这是我们的残留。反过来则会留下一个无主的 SleepDisabled=1。
        if on {
            writeMarker()
        }

        do {
            try await PMSet.writeSleepDisabled(on)
        } catch .userCancelled {
            if on {
                removeMarker()
            }
            LogService.info("keep-awake toggle cancelled by user", category: "KeepAwake")
            KeepAwakeEventLog.record("切换防休眠 → \(on ? "开" : "关")失败:用户取消授权")
            await refresh()
            return
        } catch {
            if on {
                removeMarker()
            }
            lastError = error.localizedDescription
            LogService.error("keep-awake toggle failed: \(error.localizedDescription)", category: "KeepAwake")
            KeepAwakeEventLog.record("切换防休眠 → \(on ? "开" : "关")失败:\(error.localizedDescription)")
            await refresh()
            return
        }

        if !on {
            removeMarker()
        }
        KeepAwakeEventLog.record("防休眠已\(on ? "开启" : "关闭")")
        await refresh()

        if !on {
            // 关闭后若盖子已合着,延迟复核并补一脚 sleepnow。不 await —— 开关
            // 本身已经完成,不该为了这个收尾把 `isBusy` 多攥 2 秒。
            Task { await sleepNowIfLidClosedAfterDisabling(settleDelay: Self.lidSettleDelay) }
        }
    }

    // MARK: - 退出还原

    /// 退出时是否需要还原。只认领我们自己开的那份。
    var needsRestoreOnQuit: Bool {
        isEnabled && isOwned && (settings?.keepAwakeRestoreOnQuit ?? true)
    }

    /// 退出前还原系统设置。返回是否还原成功。
    ///
    /// 失败(含用户取消授权)时**保留落盘标记**,这样下次启动仍能认出这份残留
    /// 并在 UI 上如实显示,而不是变成一个无人认领的"Mac 永远不睡"。
    func restoreForQuit() async -> Bool {
        guard needsRestoreOnQuit else { return true }

        LogService.info("restoring normal sleep before quit", category: "KeepAwake")
        do {
            try await PMSet.writeSleepDisabled(false)
            removeMarker()
            isEnabled = false
            isOwned = false
            holdIdleSleepAssertion(false)
            LogService.info("normal sleep restored", category: "KeepAwake")
            KeepAwakeEventLog.record("退出前已还原休眠设置")
            // 退出路径不做延迟复核 —— 返回后 App 就要退出,等 2 秒的任务活不到
            // 那时候;写已经成功返回,直接按当前盖子状态决定。
            await sleepNowIfLidClosedAfterDisabling(settleDelay: nil)
            return true
        } catch {
            LogService.warn(
                "could not restore normal sleep on quit: \(error.localizedDescription) — marker kept",
                category: "KeepAwake"
            )
            // 这是最需要长期留痕的一条:系统被留在"永不休眠"状态退出了。
            KeepAwakeEventLog.record(
                "⚠️ 退出时还原失败,系统仍处于合盖不休眠状态:\(error.localizedDescription)"
            )
            return false
        }
    }

    // MARK: - 设置联动

    func applyLidDisplayOffSetting(_ enabled: Bool) {
        LogService.info("autoDisplayOff → \(enabled)", category: "KeepAwake")
        lidMonitor.autoDisplayOff = enabled
    }

    // MARK: - 外部改动感知

    /// 订阅系统电源设置变更的 Darwin 通知。
    ///
    /// 远程桌面 / 清理类软件改写电源设置时会顺带清掉 `SleepDisabled`(实测有
    /// 机器每 10 分钟被清一次)。收到通知即安排延迟复查 —— 注意通知到达时
    /// **新值还没写进内核**,所以要在多个时间点各对一次账,而不是只查一次。
    ///
    /// 用 `CFNotificationCenter` 的 Darwin 中心而不是 `notify_register_dispatch`,
    /// 是因为它的回调带 observer 上下文指针 —— 和 `LidMonitor` 的 refcon 一个
    /// 模式,不需要把非 Sendable 的 self 捕获进 C 回调。
    private func registerPrefsChangeObserver() {
        // 重入保护:重复注册会产生双份回调,每次通知的复查任务翻倍。
        guard prefsChangeObserver == nil else { return }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        prefsChangeObserver = observer
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let service = Unmanaged<KeepAwakeService>.fromOpaque(observer).takeUnretainedValue()
                // Darwin 通知的回调线程不确定;通知本身不带载荷,跳回主 actor
                // 安排复查即可。
                Task { @MainActor in service.scheduleExternalRecheck() }
            },
            "com.apple.system.powermanagement.prefschange" as CFString,
            nil,
            .deliverImmediately
        )
        LogService.info("watching power-management prefs changes", category: "KeepAwake")
    }

    /// 兜底轮询:万一通知漏发(比如睡眠期间被改动),周期对账也能发现。
    private func startStatePolling() {
        // 重入保护(镜像 LidMonitor.start 的自守卫):重复 start() 会覆盖
        // pollTask,孤儿任务永不取消,变成一个不死的 10s 循环。
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard let self, !self.isBusy else { continue }
                await refresh(reason: .external)
            }
        }
    }

    /// 我们自己的写路径同样会触发 prefschange —— `isBusy` 期间整体跳过,
    /// 避免把自己的开关动作记成"被外部改动"。
    private func scheduleExternalRecheck() {
        guard !isBusy else { return }
        // 照 MacMiniMode 实测的节奏:通知先到、内核后写,四个时间点各查一次。
        for delay in [0.0, 0.2, 1.0, 2.5] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !self.isBusy else { return }
                await refresh(reason: .external)
            }
        }
    }

    // MARK: - 第二道保险断言

    /// 开启期间持有 `PreventSystemSleep` 断言 —— **不需要 root**。
    ///
    /// `disablesleep` 本身已把整条睡眠路径禁掉,正常情况下断言是冗余的。它补
    /// 的是被篡改的窗口期:别的程序清掉 `SleepDisabled` 之后、我们发现之前,
    /// 机器不会因为没人操作而空闲睡死。它**挡不住合盖睡眠**(没有任何断言能
    /// 挡)—— 合盖那条路仍然只靠 `disablesleep`。断言跟随系统真相源
    /// (`isEnabled`)而非用户意图:发现被清掉后如实放开,由用户决定是否重开。
    ///
    /// 断言随进程退出自动被系统回收,被强杀也不会泄漏。
    private func holdIdleSleepAssertion(_ on: Bool) {
        // 测试宿主不持断言 —— 单测一跑几分钟,别把跑测试的机器摁着不让睡。
        guard !UITestMode.isTestHost else { return }
        if on, idleSleepAssertion == 0 {
            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                "PreventSystemSleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NemoNotch Keep Awake" as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                idleSleepAssertion = assertionID
                idleSleepAssertionFailureLogged = false
                LogService.info("idle-sleep assertion held", category: "KeepAwake")
            } else if !idleSleepAssertionFailureLogged {
                // 创建失败每个轮询周期都会重试,但日志只记第一次 —— 持续失败
                // 也不能刷屏(高频循环只记状态转移的规则)。
                idleSleepAssertionFailureLogged = true
                LogService.warn(
                    "could not hold idle-sleep assertion: 0x\(String(result, radix: 16))",
                    category: "KeepAwake"
                )
            }
        } else if !on, idleSleepAssertion != 0 {
            IOPMAssertionRelease(idleSleepAssertion)
            idleSleepAssertion = 0
            LogService.info("idle-sleep assertion released", category: "KeepAwake")
        }
    }

    // MARK: - 关闭后已合盖 → 补一脚睡眠

    /// 关闭防休眠后,若盖子已经合着且合盖本会导致睡眠,执行 `pmset sleepnow`。
    ///
    /// 清掉 `disablesleep` 不会让已合盖的机器自己睡下去 —— 不补这一脚,它会
    /// 睁着眼继续跑,放进包里持续发热(见 `KeepAwakeSleepNowDecision`)。
    private func sleepNowIfLidClosedAfterDisabling(settleDelay: TimeInterval?) async {
        if let settleDelay {
            try? await Task.sleep(for: .seconds(settleDelay))
        }
        // 结算窗口内用户可能又开始重新开启(授权框还弹着、写尚未落地)—— 此时
        // live 读到的仍是旧值,千万别把机器睡下去。
        guard !isBusy, !isEnabled else { return }
        let decision = KeepAwakeSleepNowDecision(
            systemSleepDisabled: PMSet.readSleepDisabledLive(),
            lidClosed: lidMonitor.isLidClosed(),
            clamshellCausesSleep: lidMonitor.clamshellCausesSleep()
        )
        guard decision.shouldSleepNow else { return }

        LogService.info("sleep re-enabled with lid closed → sleeping now", category: "KeepAwake")
        KeepAwakeEventLog.record("关闭防休眠时盖子已合上 → 已让机器入睡")
        PMSet.sleepNow()
    }

    // MARK: - 标记读写

    private func writeMarker() {
        do {
            try FileManager.default.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: markerURL, options: .atomic)
            LogService.info("ownership marker written at \(markerURL.path)", category: "KeepAwake")
        } catch {
            // 标记写不进去不该阻断开启 —— 只是丢了崩溃后的自我识别能力。
            LogService.error("could not write ownership marker: \(error.localizedDescription)", category: "KeepAwake")
        }
    }

    private func removeMarker() {
        do {
            try FileManager.default.removeItem(at: markerURL)
            LogService.info("ownership marker removed", category: "KeepAwake")
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            LogService.error("could not remove ownership marker: \(error.localizedDescription)", category: "KeepAwake")
        }
    }
}
