import AppKit
import SwiftUI

/// Composition root for every service the app assembles at launch.
///
/// All services are non-optional `let`s — the dependency list reads as a
/// table of contents instead of 25 optional fields + `if let` chains. The
/// members are grouped by domain with the cross-group dependencies called
/// out where they exist (e.g. `completionFlash` consumes the AI store and
/// agent registry; the pomodoro stack feeds it completed sessions).
///
/// `build()` is a verbatim, order-preserving move of the construction block
/// that used to live inline in `AppDelegate.applicationDidFinishLaunching` —
/// construction order is behavior here (service lifecycles, UITestMode
/// gates), so it is not reorganized, only relocated.
@MainActor
struct AppDependencies {
    // MARK: Core

    let settings: AppSettings
    let media: MediaService
    let calendar: CalendarService
    let aiMonitor: AICLIMonitorService
    let launcher: LauncherService

    // MARK: Agents (registered into `registry`)

    let openClaw: OpenClawService
    let hermes: HermesService
    let registry: AgentMonitorRegistry

    // MARK: Interface data sources

    let notification: NotificationService
    let weather: WeatherService
    let usageQuota: UsageQuotaService
    let hud: HUDService
    let system: SystemService
    let notificationPermission: NotificationPermissionMonitor

    // MARK: AI-derived events (cross-domain: consumes `aiMonitor.store` + `registry`)

    let completionFlash: CompletionFlashService
    let aiStatus: AIStatusWindowController
    let lockScreenMonitor: LockScreenMonitor
    let lockScreenAIPanel: LockScreenAIPanelController?

    // MARK: Alerts (cross-domain: `calendarDue` consumes `calendar` + `completionFlash`)

    let bluetooth: BluetoothService
    let calendarDue: CalendarDueMonitor

    // MARK: System power

    let keepAwake: KeepAwakeService

    // MARK: Pomodoro (cross-domain: feeds `completionFlash`)

    let tasks: TaskStore
    let history: PomodoroHistoryStore
    let pomodoro: PomodoroTimerService
    let quickStart: QuickStartWindowController

    // MARK: Overlay windows

    let completionFlashWindow: CompletionFlashWindowController?

    // MARK: - Build (order-preserving; see the type's doc comment)

    static func build() -> AppDependencies {
        let settings = AppSettings()
        let media = MediaService(disableLiveUpdates: UITestMode.isActive)
        let calendar = CalendarService()
        let aiMonitor = AICLIMonitorService()
        let launcher = LauncherService(settings: settings)

        if !UITestMode.isActive {
            aiMonitor.startServer()
        }

        let openClaw = OpenClawService()
        if !UITestMode.isActive {
            openClaw.connect()
        }

        let hermes = HermesService()
        if !UITestMode.isActive {
            hermes.connect()
        }
        aiMonitor.hermesService = hermes

        let registry = AgentMonitorRegistry()
        registry.register(openClaw)
        registry.register(hermes)

        let notification = NotificationService(monitoredApps: settings.monitoredApps)

        let weather = WeatherService()
        if !UITestMode.isActive, !settings.weatherCity.isEmpty {
            weather.updateCity(settings.weatherCity)
        }

        let usageQuota = UsageQuotaService()

        let hud = HUDService(settings: settings)

        let keepAwake = KeepAwakeService(settings: settings)
        // UI 测试跑在无人值守的截图脚本里,绝不能让它去碰全局电源设置。
        if !UITestMode.isActive {
            keepAwake.start()
        }

        let completionFlash = CompletionFlashService(
            store: aiMonitor.store,
            registry: registry,
            settings: settings
        )

        // 事件提醒:蓝牙音频设备连接/断开走刘海就地展开胶囊(BluetoothService
        // 自持瞬时状态,NotchView 渲染);日历到期走 CompletionFlashService 的
        // 全屏闪烁 + Toast。UI 测试与单测宿主不启动蓝牙:后者的 TCC 授权弹窗
        // (进程模态)会挂起测试连接。
        let bluetooth = BluetoothService(settings: settings)
        if !UITestMode.isActive, !UITestMode.isTestHost {
            bluetooth.start()
        }
        let calendarDue = CalendarDueMonitor(
            calendar: calendar,
            completionFlash: completionFlash,
            settings: settings
        )
        if !UITestMode.isActive {
            calendarDue.start()
        }

        let system = SystemService()

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
        let quickStart = QuickStartWindowController(
            timerService: pomodoro,
            taskStore: tasks,
            appSettings: settings,
            notificationMonitor: notificationPermission
        )
        let aiStatus = AIStatusWindowController(
            store: aiMonitor.store,
            appSettings: settings,
            usageQuota: usageQuota
        )
        // 锁屏 AI 面板:纯展示窗,压在锁屏 shielding 层上。UI 测试跑在无人
        // 值守的截图脚本里,绝不能有窗口盖在锁屏层。
        let lockMonitor = LockScreenMonitor()
        let lockScreenAIPanel: LockScreenAIPanelController? = if !UITestMode.isActive {
            LockScreenAIPanelController(
                store: aiMonitor.store,
                appSettings: settings,
                monitor: lockMonitor
            )
        } else {
            nil
        }

        // 正常运行时常驻;UI 测试下仅在 --flash 截图模式才需要全屏 glow 窗口。
        let completionFlashWindow: CompletionFlashWindowController? = if !UITestMode.isActive || UITestMode.flash {
            CompletionFlashWindowController(service: completionFlash)
        } else {
            nil
        }

        return AppDependencies(
            settings: settings,
            media: media,
            calendar: calendar,
            aiMonitor: aiMonitor,
            launcher: launcher,
            openClaw: openClaw,
            hermes: hermes,
            registry: registry,
            notification: notification,
            weather: weather,
            usageQuota: usageQuota,
            hud: hud,
            system: system,
            notificationPermission: notificationPermission,
            completionFlash: completionFlash,
            aiStatus: aiStatus,
            lockScreenMonitor: lockMonitor,
            lockScreenAIPanel: lockScreenAIPanel,
            bluetooth: bluetooth,
            calendarDue: calendarDue,
            keepAwake: keepAwake,
            tasks: tasks,
            history: history,
            pomodoro: pomodoro,
            quickStart: quickStart,
            completionFlashWindow: completionFlashWindow
        )
    }

    // MARK: - Notch content

    /// The per-screen NotchView factory handed to `NotchCoordinator`, with
    /// every service injected into the SwiftUI environment. Kept next to the
    /// dependency list so a new service can't silently miss injection.
    func notchContent() -> (NotchCoordinator, NSScreen) -> AnyView {
        { coordinator, screen in
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
                    .environment(bluetooth)
                    .environment(system)
                    .environment(tasks)
                    .environment(history)
                    .environment(pomodoro)
                    .environment(notificationPermission)
                    .environment(\.quickStartController, quickStart)
                    .environment(\.aiStatusController, aiStatus)
            )
        }
    }
}
