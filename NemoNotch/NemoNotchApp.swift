import Darwin
import KeyboardShortcuts
import SwiftUI

@main
struct NemoNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appSettings: appDelegate.deps?.settings)
                .environment(appDelegate.deps?.media ?? MediaService())
                .environment(appDelegate.deps?.aiMonitor ?? AICLIMonitorService())
                .environment(appDelegate.deps?.keepAwake ?? KeepAwakeService())
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsSceneRoot(appDelegate: appDelegate)
        }
        // Settings 场景不认内容根视图的 ideal 尺寸(实测被无视、开成 900 宽),
        // 默认宽高必须在 scene 级声明;内容侧保留 frame(minWidth:minHeight:)
        // 作为拖拽下限的 auto-layout 约束。
        .defaultSize(width: 680, height: 540)
    }

    init() {
        signal(SIGPIPE, SIG_IGN)
    }
}

struct MenuContent: View {
    let appSettings: AppSettings?

    var body: some View {
        Group {
            NowPlayingSection()
            HooksSection()
            KeepAwakeSection()
            AppSection()
        }
        .environment(\.locale, appSettings?.currentLocale ?? Locale.current)
    }
}

struct SettingsSceneRoot: View {
    let appDelegate: AppDelegate

    var body: some View {
        Group {
            if let deps = appDelegate.deps {
                SettingsView()
                    .environment(deps.settings)
                    .environment(deps.aiMonitor)
                    .environment(deps.launcher)
                    .environment(deps.notification)
                    .environment(deps.weather)
                    .environment(deps.hermes)
                    .environment(deps.openClaw)
                    .environment(deps.keepAwake)
                    .environment(deps.notificationPermission)
            } else {
                ProgressView()
                    .frame(width: 680, height: 480)
            }
        }
        .onAppear { appDelegate.handleSettingsAppear() }
        .onDisappear { appDelegate.handleSettingsDisappear() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var suppressRestoreUntil: Date = .distantPast
    /// 设置窗当前是否在场(由 Settings scene 的 onAppear/onDisappear 维护)。
    private var isSettingsVisible = false
    private var isRestoringSleepForQuit = false

    override nonisolated init() {
        super.init()
    }

    /// Every service, assembled in `AppDependencies.build()` — one non-optional
    /// table instead of 25 optional fields. nil only before
    /// `applicationDidFinishLaunching` runs (the SwiftUI scenes' `??`
    /// fallbacks cover that window).
    private(set) var deps: AppDependencies?
    private(set) var coordinator: NotchCoordinator?
    /// `--uitest --flash` 截图用的暗色背景窗(仅此模式存在),让 `.screen` 混合的
    /// 全屏 glow 不被亮色壁纸冲淡,得到稳定可复现的演示图。
    private var uiTestFlashBackdrop: NSWindow?

    var shouldSuppressPreviousAppRestore: Bool {
        // 计时窗只覆盖"打开设置的那一瞬间"。真正的判据是设置窗此刻是否握着键盘
        // 焦点 —— 若是,收起刘海时把上一个 app 拉回前台就等于把设置窗埋掉。
        // 刘海面板/浮窗都是 borderless,所以"设置窗在场 + key 窗有标题栏"唯一
        // 指向设置窗;用户切到别的 app 干活时 key 窗是刘海面板,恢复照旧生效。
        if isSettingsVisible, NSApp.keyWindow?.styleMask.contains(.titled) == true {
            return true
        }
        return Date() < suppressRestoreUntil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        _ = LogService.shared

        // 主线程卡顿探针:抓 watchdog 杀进程前那一轮主 runloop 卡在哪个业务函数。
        // 诊断 cpu_resource 崩溃(主线程卡在 NSView 递归 layout,由 CA::Transaction 每帧驱动)。
        MainThreadProbe.shared.install()

        // 热点频率/耗时探针。默认关闭,NEMONOTCH_PERF=1 开启 —— 用来定位
        // "主线程没卡顿但 CPU 常驻偏高" 这类被 MainThreadProbe 阈值漏掉的消耗。
        PerfProbe.start()

        // Warm the OpenRouter-backed model-context overlay (offline-safe; the
        // curated hardcoded table still resolves every lookup if this lags).
        if !UITestMode.isActive {
            ModelContextWindow.warm()
        }

        let deps = AppDependencies.build()
        self.deps = deps

        let notchCoordinator = NotchCoordinator(content: deps.notchContent())
        notchCoordinator.autoSelectTab = { [weak self] in
            guard let deps = self?.deps else { return nil }
            if let session = deps.aiMonitor.activeSession, session.status == .working {
                return .claude
            }
            if deps.registry.hasAnyActiveAgent {
                return .claude
            }
            if deps.media.playbackState.isPlaying {
                return .overview
            }
            return nil
        }
        notchCoordinator.appSettings = deps.settings
        notchCoordinator.restoreSuppressionCheck = { [weak self] in
            self?.shouldSuppressPreviousAppRestore ?? false
        }
        notchCoordinator.onOpen = { [weak self] in
            self?.deps?.calendar.resetSelectedDateToToday()
        }
        coordinator = notchCoordinator

        setupHotkeys(coordinator: notchCoordinator)

        if UITestMode.isActive {
            if UITestMode.flash {
                // 只填一个工作中的 Claude 会话,收起的刘海只显示 Claude Code 一行徽标。
                UITestSeeder.seedFlash(aiStore: deps.aiMonitor.store)
            } else {
                UITestSeeder.seed(
                    media: deps.media,
                    calendar: deps.calendar,
                    weather: deps.weather,
                    system: deps.system,
                    aiStore: deps.aiMonitor.store,
                    registry: deps.registry,
                    pomodoro: deps.pomodoro,
                    tasks: deps.tasks
                )
            }
            let target = NSScreen.screens.first(where: { $0.isBuiltInDisplay && $0.hasNotch })
                ?? NSScreen.main
            let tab = UITestMode.tab
            if let target {
                UITestSeeder.writeCaptureRect(for: tab, on: target)
            }
            // --flash:在面板/glow 之下铺一层暗色背景窗,让全屏 glow 在截图里清晰可见。
            if UITestMode.flash, let target {
                uiTestFlashBackdrop = makeUITestFlashBackdrop(on: target)
            }

            NSApp.activate(ignoringOtherApps: true)

            if UITestMode.flash {
                // 保持刘海收起,只钉住完成态 glow + toast —— 贴合真实开发场景:
                // 正在写代码、刘海收着,AI 跑完时屏幕一闪 + 刘海旁弹出完成 Toast。
                deps.completionFlash.holdForUITest(names: ["NemoNotch"])
                // 安全网:--flash 会铺满屏的暗色背景窗;万一截图脚本被强杀来不及
                // 清理,也让 app 自己 12s 后退出,绝不把全屏窗永久挂在屏幕上。
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    LogService.info("--flash self-terminate (safety timeout)", category: "AppDelegate")
                    NSApp.terminate(nil)
                }
            } else {
                notchCoordinator.notchOpen(tab: tab, on: target)
            }
        }
    }

    /// 截图专用:覆盖整屏的暗色渐变背景窗,层级压在 glow / 面板之下。
    private func makeUITestFlashBackdrop(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.hasShadow = false
        window.level = .statusBar + 7 // 低于 glow / 面板(statusBar + 8)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        let backdrop = LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.07, blue: 0.10),
                Color(red: 0.02, green: 0.02, blue: 0.04),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        let host = NSHostingView(rootView: backdrop.ignoresSafeArea())
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        window.contentView = host
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        return window
    }

    /// `SleepDisabled` 是**跨重启持久的全局系统设置** —— 退出不还原,用户的
    /// Mac 就会永远不睡,而且没有任何线索指向 NemoNotch。所以这里拦住退出,
    /// 先把它关掉(需要一次授权框),再真正退出。
    ///
    /// 只还原我们自己开的那份(`needsRestoreOnQuit` 检查落盘标记);用户自己
    /// `sudo pmset` 开的不动。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let keepAwake = deps?.keepAwake, keepAwake.needsRestoreOnQuit else {
            return .terminateNow
        }
        // 还原已在进行中(用户又按了一次 ⌘Q):继续等,别叠第二个授权框。
        guard !isRestoringSleepForQuit else { return .terminateLater }
        isRestoringSleepForQuit = true

        LogService.info("delaying termination to restore sleep settings", category: "AppDelegate")
        Task {
            let restored = await keepAwake.restoreForQuit()
            if !restored {
                Self.presentRestoreFailureAlert()
            }
            // 无论还原成功与否都放行退出 —— 卡住不让用户退出更糟。失败时
            // 落盘标记会保留,下次启动仍能认出这份残留。
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 还原失败(含用户点掉授权框)时必须明确告知,否则这台 Mac 会一直不睡
    /// 而用户无从得知原因。顺手给出手动补救命令。
    private static func presentRestoreFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "keepawake.restoreFailed.title")
        alert.informativeText = String(localized: "keepawake.restoreFailed.detail")
        alert.addButton(withTitle: String(localized: "keepawake.restoreFailed.copyCommand"))
        alert.addButton(withTitle: String(localized: "keepawake.restoreFailed.dismiss"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("sudo pmset -a disablesleep 0", forType: .string)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogService.info("applicationWillTerminate received", category: "AppDelegate")
        if let pomodoro = deps?.pomodoro {
            switch pomodoro.state {
            case .running, .paused:
                pomodoro.abandon()
                LogService.info(
                    "applicationWillTerminate: abandoned active pomodoro",
                    category: "AppDelegate"
                )
            default:
                break
            }
        }
    }

    @MainActor
    func handleSettingsAppear() {
        isSettingsVisible = true
        suppressRestoreUntil = Date().addingTimeInterval(1.2)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func handleSettingsDisappear() {
        LogService.info("Settings window closed", category: "AppDelegate")
        isSettingsVisible = false
        suppressRestoreUntil = .distantPast
        NSApp.setActivationPolicy(.accessory)
    }

    private func setupHotkeys(coordinator: NotchCoordinator) {
        KeyboardShortcuts.onKeyDown(for: .toggleNotch) { [weak coordinator] in
            guard let c = coordinator else { return }
            switch c.status {
            case .closed: c.notchOpen(viaHotkey: true)
            case .opened: c.notchClose()
            }
        }

        for tab in Tab.allCases {
            KeyboardShortcuts.onKeyDown(for: tab.hotkeyName) { [weak coordinator] in
                guard let c = coordinator else { return }
                switch c.status {
                case .closed:
                    c.notchOpen(tab: tab, viaHotkey: true)
                case .opened:
                    if c.selectedTab == tab {
                        c.notchClose()
                    } else {
                        c.selectedTab = tab
                        c.bumpHotkeyAutoCloseTimerIfActive()
                    }
                }
            }
        }

        KeyboardShortcuts.onKeyDown(for: .openQuickStart) { [weak self] in
            self?.deps?.quickStart.toggle()
        }
    }
}
