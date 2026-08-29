import Darwin
import KeyboardShortcuts
import SwiftUI

@main
struct NemoNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appSettings: appDelegate.appSettings)
                .environment(appDelegate.mediaService ?? MediaService())
                .environment(appDelegate.aiMonitorService ?? AICLIMonitorService())
                .environment(appDelegate.keepAwakeService ?? KeepAwakeService())
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsSceneRoot(appDelegate: appDelegate)
        }
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
            if let settings = appDelegate.appSettings,
               let aiMonitor = appDelegate.aiMonitorService,
               let launcher = appDelegate.launcherService,
               let notification = appDelegate.notificationService,
               let weather = appDelegate.weatherService,
               let hermes = appDelegate.hermesService,
               let openClaw = appDelegate.openClawService,
               let keepAwake = appDelegate.keepAwakeService,
               let notificationPermission = appDelegate.notificationPermissionMonitor {
                SettingsView()
                    .environment(settings)
                    .environment(aiMonitor)
                    .environment(launcher)
                    .environment(notification)
                    .environment(weather)
                    .environment(hermes)
                    .environment(openClaw)
                    .environment(keepAwake)
                    .environment(notificationPermission)
            } else {
                ProgressView()
                    .frame(width: 700, height: 460)
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

    private(set) var coordinator: NotchCoordinator?
    private(set) var appSettings: AppSettings?
    private(set) var mediaService: MediaService?
    private var calendarService: CalendarService?
    private(set) var aiMonitorService: AICLIMonitorService?
    private(set) var openClawService: OpenClawService?
    private(set) var hermesService: HermesService?
    private(set) var agentRegistry: AgentMonitorRegistry?
    private(set) var launcherService: LauncherService?
    private(set) var notificationService: NotificationService?
    private(set) var weatherService: WeatherService?
    private var hudService: HUDService?
    private var systemService: SystemService?
    private(set) var taskStore: TaskStore?
    private(set) var historyStore: PomodoroHistoryStore?
    private(set) var pomodoroTimerService: PomodoroTimerService?
    private(set) var notificationPermissionMonitor: NotificationPermissionMonitor?
    private(set) var usageQuotaService: UsageQuotaService?
    private(set) var quickStartController: QuickStartWindowController?
    private(set) var aiStatusController: AIStatusWindowController?
    private(set) var lockScreenMonitor: LockScreenMonitor?
    private(set) var lockScreenAIPanelController: LockScreenAIPanelController?
    private(set) var completionFlashService: CompletionFlashService?
    private(set) var completionFlashWindowController: CompletionFlashWindowController?
    private(set) var keepAwakeService: KeepAwakeService?
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
        if !UITestMode.isActive { ModelContextWindow.warm() }

        let settings = AppSettings()
        let media = MediaService(disableLiveUpdates: UITestMode.isActive)
        let calendar = CalendarService()
        let aiMonitor = AICLIMonitorService()
        let launcher = LauncherService(settings: settings)

        if !UITestMode.isActive { aiMonitor.startServer() }

        let openClaw = OpenClawService()
        if !UITestMode.isActive { openClaw.connect() }
        openClawService = openClaw

        let hermes = HermesService()
        if !UITestMode.isActive { hermes.connect() }
        aiMonitor.hermesService = hermes
        hermesService = hermes

        let registry = AgentMonitorRegistry()
        registry.register(openClaw)
        registry.register(hermes)
        agentRegistry = registry

        appSettings = settings
        mediaService = media
        calendarService = calendar
        aiMonitorService = aiMonitor
        launcherService = launcher

        let notification = NotificationService(monitoredApps: settings.monitoredApps)
        notificationService = notification

        let weather = WeatherService()
        if !UITestMode.isActive, !settings.weatherCity.isEmpty {
            weather.updateCity(settings.weatherCity)
        }
        weatherService = weather

        let usageQuota = UsageQuotaService()
        usageQuotaService = usageQuota

        let hud = HUDService()
        hudService = hud

        let keepAwake = KeepAwakeService(settings: settings)
        // UI 测试跑在无人值守的截图脚本里,绝不能让它去碰全局电源设置。
        if !UITestMode.isActive { keepAwake.start() }
        keepAwakeService = keepAwake

        let completionFlash = CompletionFlashService(
            store: aiMonitor.store,
            registry: registry,
            settings: settings
        )
        completionFlashService = completionFlash

        let system = SystemService()
        systemService = system

        let tasks = TaskStore(fileURL: UITestMode.isActive ? UITestSeeder.tasksURL : TaskStore.defaultURL)
        let history = PomodoroHistoryStore(fileURL: UITestMode.isActive ? UITestSeeder.historyURL : PomodoroHistoryStore
            .defaultURL)
        let notificationPermission = NotificationPermissionMonitor()
        let pomodoro = PomodoroTimerService(
            taskStore: tasks,
            historyStore: history,
            appSettings: settings,
            permissionMonitor: notificationPermission,
            completionFlash: completionFlash
        )
        taskStore = tasks
        historyStore = history
        notificationPermissionMonitor = notificationPermission
        pomodoroTimerService = pomodoro
        quickStartController = QuickStartWindowController(
            timerService: pomodoro,
            taskStore: tasks,
            appSettings: settings,
            notificationMonitor: notificationPermission
        )
        aiStatusController = AIStatusWindowController(
            store: aiMonitor.store,
            appSettings: settings
        )
        // 锁屏 AI 面板:纯展示窗,压在锁屏 shielding 层上。UI 测试跑在无人
        // 值守的截图脚本里,绝不能有窗口盖在锁屏层。
        let lockMonitor = LockScreenMonitor()
        lockScreenMonitor = lockMonitor
        if !UITestMode.isActive {
            lockScreenAIPanelController = LockScreenAIPanelController(
                store: aiMonitor.store,
                appSettings: settings,
                monitor: lockMonitor
            )
        }

        let qsController = quickStartController
        let aiController = aiStatusController
        let notchCoordinator = NotchCoordinator { coordinator, screen in
            AnyView(
                NotchView(screen: screen)
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(calendar)
                    .environment(aiMonitor)
                    .environment(usageQuota)
                    .environment(openClaw)
                    .environment(registry)
                    .environment(hermes)
                    .environment(launcher)
                    .environment(notification)
                    .environment(weather)
                    .environment(hud)
                    .environment(completionFlash)
                    .environment(system)
                    .environment(tasks)
                    .environment(history)
                    .environment(pomodoro)
                    .environment(notificationPermission)
                    .environment(\.quickStartController, qsController)
                    .environment(\.aiStatusController, aiController)
            )
        }
        notchCoordinator.autoSelectTab = { [weak self] in
            guard let self else { return nil }
            if let session = aiMonitorService?.activeSession, session.status == .working {
                return .claude
            }
            if agentRegistry?.hasAnyActiveAgent == true { return .agents }
            if mediaService?.playbackState.isPlaying == true { return .overview }
            return nil
        }
        notchCoordinator.appSettings = settings
        notchCoordinator.restoreSuppressionCheck = { [weak self] in
            self?.shouldSuppressPreviousAppRestore ?? false
        }
        notchCoordinator.onOpen = { [weak self] in
            self?.calendarService?.resetSelectedDateToToday()
        }
        coordinator = notchCoordinator

        // 正常运行时常驻;UI 测试下仅在 --flash 截图模式才需要全屏 glow 窗口。
        if !UITestMode.isActive || UITestMode.flash {
            completionFlashWindowController = CompletionFlashWindowController(service: completionFlash)
        }

        setupHotkeys(coordinator: notchCoordinator)

        if UITestMode.isActive {
            if UITestMode.flash {
                // 只填一个工作中的 Claude 会话,收起的刘海只显示 Claude Code 一行徽标。
                UITestSeeder.seedFlash(aiStore: aiMonitor.store)
            } else {
                UITestSeeder.seed(
                    media: media,
                    calendar: calendar,
                    weather: weather,
                    system: system,
                    aiStore: aiMonitor.store,
                    registry: registry,
                    pomodoro: pomodoro,
                    tasks: tasks
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
                completionFlash.holdForUITest(names: ["NemoNotch"])
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
        guard let keepAwake = keepAwakeService, keepAwake.needsRestoreOnQuit else {
            return .terminateNow
        }
        // 还原已在进行中(用户又按了一次 ⌘Q):继续等,别叠第二个授权框。
        guard !isRestoringSleepForQuit else { return .terminateLater }
        isRestoringSleepForQuit = true

        LogService.info("delaying termination to restore sleep settings", category: "AppDelegate")
        Task {
            let restored = await keepAwake.restoreForQuit()
            if !restored { Self.presentRestoreFailureAlert() }
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
        if let pomodoro = pomodoroTimerService {
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
            self?.quickStartController?.toggle()
        }
    }
}
