import Darwin
import KeyboardShortcuts
import SwiftUI

@main
struct NemoNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                coordinator: appDelegate.coordinator,
                appSettings: appDelegate.appSettings,
                onOpenSettings: { appDelegate.showSettings() }
            )
            .environment(appDelegate.aiMonitorService ?? AICLIMonitorService())
            .environment(appDelegate.agentRegistry ?? AgentMonitorRegistry())
            .environment(appDelegate.mediaService ?? MediaService())
        } label: {
            MenuBarLabel()
                .environment(appDelegate.aiMonitorService ?? AICLIMonitorService())
                .environment(appDelegate.agentRegistry ?? AgentMonitorRegistry())
                .environment(appDelegate.mediaService ?? MediaService())
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        signal(SIGPIPE, SIG_IGN)
    }
}

struct MenuContent: View {
    let coordinator: NotchCoordinator?
    let appSettings: AppSettings?
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            NowPlayingSection()
            OpenNotchSubmenu(coordinator: coordinator, appSettings: appSettings)
            Divider()
            HooksSection()
            AppSection(onOpenSettings: onOpenSettings)
        }
        .environment(\.locale, appSettings?.currentLocale ?? Locale.current)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var suppressRestoreUntil: Date = .distantPast

    override nonisolated init() {
        super.init()
    }

    private(set) var coordinator: NotchCoordinator?
    private(set) var appSettings: AppSettings?
    private(set) var mediaService: MediaService?
    private var calendarService: CalendarService?
    private(set) var aiMonitorService: AICLIMonitorService?
    private var openClawService: OpenClawService?
    private var hermesService: HermesService?
    private(set) var agentRegistry: AgentMonitorRegistry?
    private var launcherService: LauncherService?
    private var notificationService: NotificationService?
    private var weatherService: WeatherService?
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

    @MainActor
    func showSettings() {
        suppressRestoreUntil = Date().addingTimeInterval(1.2)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil,
           let settings = appSettings,
           let aiMonitor = aiMonitorService,
           let launcher = launcherService,
           let notification = notificationService,
           let weather = weatherService,
           let hermes = hermesService {
            let view = SettingsView()
                .environment(settings)
                .environment(aiMonitor)
                .environment(launcher)
                .environment(notification)
                .environment(weather)
                .environment(hermes)
            let window = SettingsWindow(rootView: view)
            window.delegate = self
            settingsWindow = window
        }

        settingsWindow?.center()
        settingsWindow?.orderFrontRegardless()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            suppressRestoreUntil = Date().addingTimeInterval(0.6)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            settingsWindow = nil
            suppressRestoreUntil = .distantPast
            NSApp.setActivationPolicy(.accessory)
        }
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
                c.notchOpen(tab: tab)
            }
        }
    }
}
