import Foundation

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

    deinit {
        LogService.info("KeepAwakeService deinit", category: "KeepAwake")
    }

    /// 订阅合盖事件并做一次首轮对账。
    ///
    /// 刻意不放在 `init` 里 —— `MenuBarExtra` 的 environment 注入需要一个非
    /// optional 值,兜底构造出的实例不该去跑 `pmset` 和订阅 IOKit。只有
    /// `AppDelegate` 持有的那一个会被 `start()`。
    func start() {
        do {
            try lidMonitor.start()
        } catch {
            // 台式机没有 clamshell,或 IOKit 不给订阅 —— 防休眠本身仍然可用,
            // 只是少了合盖自动熄屏。不阻断。
            LogService.warn("LidMonitor unavailable: \(error.localizedDescription)", category: "KeepAwake")
        }
        lidMonitor.autoDisplayOff = settings?.keepAwakeLidDisplayOff ?? true

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
    func refresh() async {
        let system = await PMSet.readSleepDisabled()
        let hasMarker = FileManager.default.fileExists(atPath: markerURL.path)
        let outcome = KeepAwakeReconciliation(systemSleepDisabled: system, hasMarker: hasMarker)

        if isEnabled != outcome.isEnabled {
            LogService.info(
                "keep-awake state \(isEnabled) → \(outcome.isEnabled) (marker=\(hasMarker))",
                category: "KeepAwake"
            )
        }
        isEnabled = outcome.isEnabled
        isOwned = outcome.isOwned

        if outcome.shouldDropMarker {
            LogService.info("stale marker with sleep re-enabled → dropping marker", category: "KeepAwake")
            removeMarker()
        }

        lidMonitor.setEnabled(isEnabled)
        if isEnabled { lidMonitor.turnDisplayOffIfNeeded() }
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
        if on { writeMarker() }

        do {
            try await PMSet.writeSleepDisabled(on)
        } catch .userCancelled {
            if on { removeMarker() }
            LogService.info("keep-awake toggle cancelled by user", category: "KeepAwake")
            KeepAwakeEventLog.record("切换防休眠 → \(on ? "开" : "关")失败:用户取消授权")
            await refresh()
            return
        } catch let error {
            if on { removeMarker() }
            lastError = error.localizedDescription
            LogService.error("keep-awake toggle failed: \(error.localizedDescription)", category: "KeepAwake")
            KeepAwakeEventLog.record("切换防休眠 → \(on ? "开" : "关")失败:\(error.localizedDescription)")
            await refresh()
            return
        }

        if !on { removeMarker() }
        KeepAwakeEventLog.record("防休眠已\(on ? "开启" : "关闭")")
        await refresh()
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
            LogService.info("normal sleep restored", category: "KeepAwake")
            KeepAwakeEventLog.record("退出前已还原休眠设置")
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
