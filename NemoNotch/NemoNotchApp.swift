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
        Button("展开 Notch") {
            coordinator?.notchOpen()
        }

        Divider()

        if aiService.claudeProvider.isHookInstalled {
            Text("Claude Code Hooks: 已安装 ✓")
        } else {
            Button("安装 Claude Code Hooks...") {
                aiService.claudeProvider.installHooks()
            }
        }
        if aiService.geminiProvider.isHookInstalled {
            Text("Gemini CLI Hooks: 已安装 ✓")
        } else {
            Button("安装 Gemini CLI Hooks...") {
                aiService.geminiProvider.installHooks()
            }
        }

        Divider()

        Button("偏好设置...") {
            onOpenSettings()
        }

        Button("关于 NemoNotch") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button("退出 NemoNotch") {
            NSApplication.shared.terminate(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    static var shared = AppDelegate()

    private(set) var coordinator: NotchCoordinator?
    private var appSettings: AppSettings?
    private var mediaService: MediaService?
    private var calendarService: CalendarService?
    private(set) var aiMonitorService: AICLIMonitorService?
    private var openClawService: OpenClawService?
    private var launcherService: LauncherService?
    private var notificationService: NotificationService?
    private var hotkeyService: HotkeyService?
    private var weatherService: WeatherService?
    private var hudService: HUDService?

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
            )
        }
        notchCoordinator.autoSelectTab = { [weak self] in
            guard let self else { return nil }
            if self.aiMonitorService?.activeSession?.status == .working { return .claude }
            if self.openClawService?.activeAgent != nil { return .openclaw }
            if self.mediaService?.playbackState.isPlaying == true { return .media }
            return nil
        }
        notchCoordinator.appSettings = settings
        self.coordinator = notchCoordinator

        setupHotkeys(coordinator: notchCoordinator, settings: settings)
    }

    @MainActor
    func showSettings() {
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
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            settingsWindow = nil
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
