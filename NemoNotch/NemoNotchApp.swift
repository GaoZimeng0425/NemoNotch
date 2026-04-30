import Carbon
import Darwin
import SwiftUI

@main
struct NemoNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appDelegateRef: AppDelegate?

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                coordinator: appDelegate.coordinator,
                onOpenSettings: { appDelegate.showSettings() }
            )
            .environment(appDelegate.aiMonitorService ?? AICLIMonitorService())
        } label: {
            Image(systemName: appDelegate.aiMonitorService?.anyHookInstalled == true
                ? "menubar.rectangle.fill"
                : "menubar.rectangle")
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        signal(SIGPIPE, SIG_IGN)
        let delegate = AppDelegate.shared
        _appDelegateRef = State(initialValue: delegate)
    }
}

struct MenuContent: View {
    @Environment(AICLIMonitorService.self) var aiService
    let coordinator: NotchCoordinator?
    let onOpenSettings: () -> Void

    var body: some View {
        Button("menu.open_notch") {
            coordinator?.notchOpen()
        }

        Divider()

        if aiService.claudeProvider.isHookInstalled {
            Text("menu.claude_hooks_installed")
        } else {
            Button("menu.install_claude_hooks") {
                aiService.claudeProvider.installHooks()
            }
        }
        if aiService.geminiProvider.isHookInstalled {
            Text("menu.gemini_hooks_installed")
        } else {
            Button("menu.install_gemini_hooks") {
                aiService.geminiProvider.installHooks()
            }
        }

        Divider()

        Button("menu.preferences") {
            onOpenSettings()
        }

        Button("menu.about") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button("menu.quit") {
            NSApplication.shared.terminate(nil)
        }
        .environment(\.locale, AppDelegate.shared.appSettings?.currentLocale ?? Locale.current)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var suppressRestoreUntil: Date = .distantPast
    nonisolated(unsafe) static var shared = {
        let instance = AppDelegate()
        return instance
    }()

    nonisolated override init() { super.init() }

    private(set) var coordinator: NotchCoordinator?
    private(set) var appSettings: AppSettings?
    private var mediaService: MediaService?
    private var calendarService: CalendarService?
    private(set) var aiMonitorService: AICLIMonitorService?
    private var openClawService: OpenClawService?
    private var launcherService: LauncherService?
    private var notificationService: NotificationService?
    private var hotkeyService: HotkeyService?
    private var weatherService: WeatherService?
    private var hudService: HUDService?
    private var systemService: SystemService?

    var shouldSuppressPreviousAppRestore: Bool {
        Date() < suppressRestoreUntil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
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
        self.openClawService = openClaw

        self.appSettings = settings
        self.mediaService = media
        self.calendarService = calendar
        self.aiMonitorService = aiMonitor
        self.launcherService = launcher

        let notification = NotificationService(monitoredApps: settings.monitoredApps)
        self.notificationService = notification

        let weather = WeatherService()
        self.weatherService = weather

        let hud = HUDService()
        self.hudService = hud

        let system = SystemService()
        self.systemService = system

        let notchCoordinator = NotchCoordinator { coordinator in
            AnyView(
                NotchView()
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(calendar)
                    .environment(aiMonitor)
                    .environment(openClaw)
                    .environment(launcher)
                    .environment(notification)
                    .environment(weather)
                    .environment(hud)
                    .environment(system)
            )
        }
        notchCoordinator.autoSelectTab = { [weak self] in
            guard let self else { return nil }
            if let session = self.aiMonitorService?.activeSession, session.status == .working {
                return .claude
            }
            if self.openClawService?.activeAgent != nil { return .openclaw }
            if self.mediaService?.playbackState.isPlaying == true { return .overview }
            return nil
        }
        notchCoordinator.appSettings = settings
        self.coordinator = notchCoordinator

        setupHotkeys(coordinator: notchCoordinator, settings: settings)
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
           let notification = notificationService {
            let view = SettingsView()
                .environment(settings)
                .environment(aiMonitor)
                .environment(launcher)
                .environment(notification)
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

    private func setupHotkeys(coordinator: NotchCoordinator, settings: AppSettings) {
        let hotkeys = HotkeyService()
        self.hotkeyService = hotkeys

        hotkeys.register(keyCode: 45, modifiers: UInt32(optionKey | cmdKey)) {
            switch coordinator.status {
            case .closed: coordinator.notchOpen()
            case .opened: coordinator.notchClose()
            }
        }

        let tabs = Tab.sorted(settings.enabledTabs)
        for (i, tab) in tabs.enumerated() {
            let keyCode = UInt32(18 + i)
            hotkeys.register(keyCode: keyCode, modifiers: UInt32(optionKey | cmdKey)) {
                coordinator.notchOpen(tab: tab)
            }
        }
    }
}
