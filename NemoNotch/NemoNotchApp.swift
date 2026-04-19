import Carbon
import SwiftUI

@main
struct NemoNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appDelegateRef: AppDelegate?

    var body: some Scene {
        MenuBarExtra {
            if let cc = appDelegate.claudeCodeService {
                MenuContent(
                    coordinator: appDelegate.coordinator,
                    onOpenSettings: { appDelegate.showSettings() }
                )
                .environment(cc)
            }
        } label: {
            Image(systemName: appDelegate.claudeCodeService?.isHookInstalled == true
                ? "menubar.rectangle.fill"
                : "menubar.rectangle")
        }
    }

    init() {
        let delegate = AppDelegate.shared
        _appDelegateRef = State(initialValue: delegate)
    }
}

struct MenuContent: View {
    @Environment(ClaudeCodeService.self) var claudeCodeService
    let coordinator: NotchCoordinator?
    let onOpenSettings: () -> Void

    var body: some View {
        Button("展开 Notch") {
            coordinator?.notchOpen()
        }

        Divider()

        if claudeCodeService.isHookInstalled {
            Text("Claude Code Hooks: 已安装 ✓")
        } else {
            Button("安装 Claude Code Hooks...") {
                claudeCodeService.installHooks()
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
    private(set) var claudeCodeService: ClaudeCodeService?
    private var launcherService: LauncherService?
    private var notificationService: NotificationService?
    private var hotkeyService: HotkeyService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        let settings = AppSettings()
        let media = MediaService()
        let calendar = CalendarService()
        let claude = ClaudeCodeService()
        let launcher = LauncherService(settings: settings)

        claude.startServer()

        self.appSettings = settings
        self.mediaService = media
        self.calendarService = calendar
        self.claudeCodeService = claude
        self.launcherService = launcher

        let notification = NotificationService(monitoredApps: settings.monitoredApps)
        self.notificationService = notification

        let notchCoordinator = NotchCoordinator { coordinator in
            AnyView(
                NotchView()
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(calendar)
                    .environment(claude)
                    .environment(launcher)
                    .environment(notification)
            )
        }
        notchCoordinator.autoSelectTab = { [weak self] in
            guard let self else { return nil }
            if self.claudeCodeService?.activeSession?.status == .working { return .claude }
            if self.mediaService?.playbackState.isPlaying == true { return .media }
            return nil
        }
        self.coordinator = notchCoordinator

        setupHotkeys(coordinator: notchCoordinator, settings: settings)
    }

    @MainActor
    func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil,
           let settings = appSettings,
           let claude = claudeCodeService,
           let launcher = launcherService,
           let notification = notificationService {
            let view = SettingsView()
                .environment(settings)
                .environment(claude)
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
