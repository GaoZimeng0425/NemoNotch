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
               let notificationPermission = appDelegate.notificationPermissionMonitor {
                SettingsView()
                    .environment(settings)
                    .environment(aiMonitor)
                    .environment(launcher)
                    .environment(notification)
                    .environment(weather)
                    .environment(hermes)
                    .environment(openClaw)
                    .environment(notificationPermission)
            } else {
                ProgressView()
                    .frame(width: 430, height: 460)
            }
        }
        .onAppear { appDelegate.handleSettingsAppear() }
        .onDisappear { appDelegate.handleSettingsDisappear() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var suppressRestoreUntil: Date = .distantPast

    override nonisolated init() {
        super.init()
    }

    private(set) var coordinator: NotchCoordinator?
    private(set) var appSettings: AppSettings?
    private(set) var mediaService: MediaService?
    private(set) var automationPermissionMonitor: MediaAutomationPermissionMonitor?
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
    private(set) var completionFlashService: CompletionFlashService?
    private(set) var completionFlashWindowController: CompletionFlashWindowController?
    /// `--uitest --flash` 截图用的暗色背景窗(仅此模式存在),让 `.screen` 混合的
    /// 全屏 glow 不被亮色壁纸冲淡,得到稳定可复现的演示图。
    private var uiTestFlashBackdrop: NSWindow?

    var shouldSuppressPreviousAppRestore: Bool {
        Date() < suppressRestoreUntil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        _ = LogService.shared

        let settings = AppSettings()
        let media = MediaService(disableLiveUpdates: UITestMode.isActive)
        let permissionMonitor = MediaAutomationPermissionMonitor(
            monitoredBundles: KnownPlayer.allCases.map(\.rawValue)
        )
        media.permissionDeniedHandler = { [weak permissionMonitor] bundleID in
            permissionMonitor?.recordDenied(bundleID: bundleID)
        }
        media.automationAuthorizedHandler = { [weak permissionMonitor] bundleID in
            permissionMonitor?.recordAuthorized(bundleID: bundleID)
        }
        if !UITestMode.isActive { permissionMonitor.startProbing() }
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
        automationPermissionMonitor = permissionMonitor
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
            permissionMonitor: notificationPermission
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

        let qsController = quickStartController
        let notchCoordinator = NotchCoordinator { coordinator, screen in
            AnyView(
                NotchView(screen: screen)
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(permissionMonitor)
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
        suppressRestoreUntil = Date().addingTimeInterval(1.2)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func handleSettingsDisappear() {
        LogService.info("Settings window closed", category: "AppDelegate")
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
