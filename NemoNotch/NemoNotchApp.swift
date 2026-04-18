import Carbon
import SwiftUI

@main
struct NemoNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appDelegateRef: AppDelegate?

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                coordinator: appDelegate.coordinator,
                claudeCodeService: appDelegate.claudeCodeService,
                onOpenSettings: { appDelegate.showSettings() }
            )
        } label: {
            Image(systemName: appDelegate.claudeCodeService?.isHookInstalled == true
                ? "menubar.rectangle.fill"
                : "menubar.rectangle")
        }
    }

    init() {
        // Wire up AppDelegate reference for use in MenuBarExtra
        let delegate = AppDelegate.shared
        _appDelegateRef = State(initialValue: delegate)
    }
}

struct MenuContent: View {
    let coordinator: NotchCoordinator?
    let claudeCodeService: ClaudeCodeService?
    let onOpenSettings: () -> Void

    var body: some View {
        Button("展开 Notch") {
            coordinator?.notchOpen()
        }

        Divider()

        if let cc = claudeCodeService {
            if cc.isHookInstalled {
                Text("Claude Code Hooks: 已安装 ✓")
            } else {
                Button("安装 Claude Code Hooks...") {
                    cc.installHooks()
                }
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
    private var settingsWindow: SettingsWindow?
    static var shared = AppDelegate()

    private(set) var coordinator: NotchCoordinator?
    private(set) var appSettings: AppSettings?
    private(set) var mediaService: MediaService?
    private(set) var calendarService: CalendarService?
    private(set) var claudeCodeService: ClaudeCodeService?
    private(set) var launcherService: LauncherService?
    private(set) var notificationService: NotificationService?
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

        let notchCoordinator = NotchCoordinator(
            mediaService: media,
            calendarService: calendar,
            claudeCodeService: claude,
            launcherService: launcher,
            notificationService: notification,
            appSettings: settings
        )
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
            let view = SettingsView(
                appSettings: settings,
                claudeCodeService: claude,
                launcherService: launcher,
                notificationService: notification
            )
            let window = SettingsWindow(settingsView: view)
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

        // ⌥⌘N — toggle notch
        hotkeys.register(keyCode: 45, modifiers: UInt32(optionKey | cmdKey)) {
            switch coordinator.status {
            case .closed: coordinator.notchOpen()
            case .opened: coordinator.notchClose()
            }
        }

        // ⌥⌘1..4 — open specific tab
        let tabs = settings.enabledTabs.sorted { Tab.allCases.firstIndex(of: $0)! < Tab.allCases.firstIndex(of: $1)! }
        for (i, tab) in tabs.enumerated() {
            let keyCode = UInt32(18 + i) // 18='1', 19='2', etc.
            hotkeys.register(keyCode: keyCode, modifiers: UInt32(optionKey | cmdKey)) {
                coordinator.notchOpen(tab: tab)
            }
        }
    }
}
