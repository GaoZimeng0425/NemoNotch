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
                .background(OpenSettingsBridge(appDelegate: appDelegate))
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

private struct OpenSettingsBridge: View {
    @Environment(\.openSettings) private var openSettings
    let appDelegate: AppDelegate

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appDelegate.openSettingsAction = { openSettings() }
            }
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
               let hermes = appDelegate.hermesService {
                SettingsView()
                    .environment(settings)
                    .environment(aiMonitor)
                    .environment(launcher)
                    .environment(notification)
                    .environment(weather)
                    .environment(hermes)
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

    var openSettingsAction: (() -> Void)?
    private(set) var coordinator: NotchCoordinator?
    private(set) var appSettings: AppSettings?
    private(set) var mediaService: MediaService?
    private var calendarService: CalendarService?
    private(set) var aiMonitorService: AICLIMonitorService?
    private var openClawService: OpenClawService?
    private(set) var hermesService: HermesService?
    private(set) var agentRegistry: AgentMonitorRegistry?
    private(set) var launcherService: LauncherService?
    private(set) var notificationService: NotificationService?
    private(set) var weatherService: WeatherService?
    private var hudService: HUDService?
    private var systemService: SystemService?

    var shouldSuppressPreviousAppRestore: Bool {
        Date() < suppressRestoreUntil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        _ = LogService.shared

        let settings = AppSettings()
        let media = MediaService()
        let calendar = CalendarService()
        let aiMonitor = AICLIMonitorService()
        let launcher = LauncherService(settings: settings)

        aiMonitor.startServer()

        let openClaw = OpenClawService()
        openClaw.connect()
        openClawService = openClaw

        let hermes = HermesService()
        hermes.connect()
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
        if !settings.weatherCity.isEmpty {
            weather.updateCity(settings.weatherCity)
        }
        weatherService = weather

        let hud = HUDService()
        hudService = hud

        let system = SystemService()
        systemService = system

        let notchCoordinator = NotchCoordinator { coordinator, screen in
            AnyView(
                NotchView(screen: screen)
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(calendar)
                    .environment(aiMonitor)
                    .environment(registry)
                    .environment(launcher)
                    .environment(notification)
                    .environment(weather)
                    .environment(hud)
                    .environment(system)
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
        notchCoordinator.onShowSettings = { [weak self] in
            self?.showSettings()
        }
        coordinator = notchCoordinator

        setupHotkeys(coordinator: notchCoordinator)
    }

    func applicationWillTerminate(_ notification: Notification) {
        LogService.info("applicationWillTerminate received", category: "AppDelegate")
    }

    @MainActor
    func showSettings() {
        LogService.info("showSettings invoked", category: "AppDelegate")
        handleSettingsAppear()
        if let action = openSettingsAction {
            action()
        } else {
            LogService.warn("openSettingsAction not yet captured, falling back to selector", category: "AppDelegate")
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
            case .closed: c.notchOpen()
            case .opened: c.notchClose()
            }
        }

        for tab in Tab.allCases {
            KeyboardShortcuts.onKeyDown(for: tab.hotkeyName) { [weak coordinator] in
                guard let c = coordinator else { return }
                switch c.status {
                case .closed:
                    c.notchOpen(tab: tab)
                case .opened:
                    if c.selectedTab == tab {
                        c.notchClose()
                    } else {
                        c.selectedTab = tab
                    }
                }
            }
        }
    }
}
