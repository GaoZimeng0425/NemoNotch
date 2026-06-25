import Foundation

enum AppLanguage: String, CaseIterable, Codable {
    case system
    case en
    case zhHans = "zh-Hans"

    var locale: Locale? {
        switch self {
        case .system: nil
        case .en: Locale(identifier: "en")
        case .zhHans: Locale(identifier: "zh-Hans")
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    var defaultTab: Tab {
        didSet { UserDefaults.standard.set(defaultTab.rawValue, forKey: "defaultTab") }
    }

    var enabledTabs: Set<Tab> {
        didSet {
            let raw = enabledTabs.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: "enabledTabs")
        }
    }

    var launcherApps: [AppItem] {
        didSet {
            if let data = try? JSONEncoder().encode(launcherApps) {
                UserDefaults.standard.set(data, forKey: "launcherApps")
            }
        }
    }

    var monitoredApps: [String] {
        didSet { UserDefaults.standard.set(monitoredApps, forKey: "monitoredApps") }
    }

    var weatherCity: String {
        didSet { UserDefaults.standard.set(weatherCity, forKey: "weatherCity") }
    }

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            updateAppleLanguages()
        }
    }

    var pomodoroWorkDuration: TimeInterval {
        didSet { UserDefaults.standard.set(pomodoroWorkDuration, forKey: "pomodoro.workDuration") }
    }

    var pomodoroShortBreakDuration: TimeInterval {
        didSet { UserDefaults.standard.set(pomodoroShortBreakDuration, forKey: "pomodoro.shortBreakDuration") }
    }

    var pomodoroLongBreakDuration: TimeInterval {
        didSet { UserDefaults.standard.set(pomodoroLongBreakDuration, forKey: "pomodoro.longBreakDuration") }
    }

    var pomodoroLongBreakInterval: Int {
        didSet { UserDefaults.standard.set(pomodoroLongBreakInterval, forKey: "pomodoro.longBreakInterval") }
    }

    var pomodoroSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(pomodoroSoundEnabled, forKey: "pomodoro.soundEnabled") }
    }

    var pomodoroNotificationEnabled: Bool {
        didSet { UserDefaults.standard.set(pomodoroNotificationEnabled, forKey: "pomodoro.notificationEnabled") }
    }

    // MARK: - OpenClaw

    static let openClawEnabledKey = "openClawEnabled"

    var openClawEnabled: Bool {
        didSet { UserDefaults.standard.set(openClawEnabled, forKey: Self.openClawEnabledKey) }
    }

    // MARK: - Provider enable flags (set false when user uninstalls hooks)

    static let claudeEnabledKey = "claudeEnabled"
    static let geminiEnabledKey = "geminiEnabled"
    static let hermesEnabledKey = "hermesEnabled"
    static let opencodeEnabledKey = "opencodeEnabled"
    static let completionFlashEnabledKey = "completionFlashEnabled"

    var claudeEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeEnabled, forKey: Self.claudeEnabledKey) }
    }

    var geminiEnabled: Bool {
        didSet { UserDefaults.standard.set(geminiEnabled, forKey: Self.geminiEnabledKey) }
    }

    var opencodeEnabled: Bool {
        didSet { UserDefaults.standard.set(opencodeEnabled, forKey: Self.opencodeEnabledKey) }
    }

    var hermesEnabled: Bool {
        didSet { UserDefaults.standard.set(hermesEnabled, forKey: Self.hermesEnabledKey) }
    }

    // MARK: - Completion flash

    var completionFlashEnabled: Bool {
        didSet { UserDefaults.standard.set(completionFlashEnabled, forKey: Self.completionFlashEnabledKey) }
    }

    var currentLocale: Locale {
        language.locale ?? Locale.current
    }

    private func updateAppleLanguages() {
        if let locale = language.locale {
            UserDefaults.standard.set([locale.identifier], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    init() {
        let storedTab = UserDefaults.standard.string(forKey: "defaultTab").flatMap { Tab(rawValue: $0) }
        defaultTab = storedTab ?? .overview

        // Migrate old "openclaw" → "agents" tab rename
        let rawTabs = UserDefaults.standard.stringArray(forKey: "enabledTabs")?
            .map { $0 == "openclaw" ? Tab.agents.rawValue : $0 }
        let storedTabs = rawTabs?.compactMap { Tab(rawValue: $0) }
        var tabs = storedTabs.map(Set.init) ?? Set(Tab.allCases)
        if storedTabs != nil { tabs.insert(.overview) }

        enabledTabs = tabs

        if let data = UserDefaults.standard.data(forKey: "launcherApps"),
           let apps = try? JSONDecoder().decode([AppItem].self, from: data) {
            launcherApps = apps
        } else {
            launcherApps = Self.defaultApps
        }

        monitoredApps = UserDefaults.standard.stringArray(forKey: "monitoredApps") ?? []
        weatherCity = UserDefaults.standard.string(forKey: "weatherCity") ?? ""

        let storedLang = UserDefaults.standard.string(forKey: "language").flatMap { AppLanguage(rawValue: $0) }
        language = storedLang ?? .system

        let workDefault: TimeInterval = 25 * 60
        let shortDefault: TimeInterval = 5 * 60
        let longDefault: TimeInterval = 15 * 60
        pomodoroWorkDuration = UserDefaults.standard
            .object(forKey: "pomodoro.workDuration") as? TimeInterval ?? workDefault
        pomodoroShortBreakDuration = UserDefaults.standard
            .object(forKey: "pomodoro.shortBreakDuration") as? TimeInterval ?? shortDefault
        pomodoroLongBreakDuration = UserDefaults.standard
            .object(forKey: "pomodoro.longBreakDuration") as? TimeInterval ?? longDefault
        pomodoroLongBreakInterval = UserDefaults.standard.object(forKey: "pomodoro.longBreakInterval") as? Int ?? 4
        pomodoroSoundEnabled = UserDefaults.standard.object(forKey: "pomodoro.soundEnabled") as? Bool ?? true
        pomodoroNotificationEnabled = UserDefaults.standard
            .object(forKey: "pomodoro.notificationEnabled") as? Bool ?? true
        openClawEnabled = UserDefaults.standard
            .object(forKey: Self.openClawEnabledKey) as? Bool ?? true
        claudeEnabled = UserDefaults.standard
            .object(forKey: Self.claudeEnabledKey) as? Bool ?? true
        geminiEnabled = UserDefaults.standard
            .object(forKey: Self.geminiEnabledKey) as? Bool ?? true
        opencodeEnabled = UserDefaults.standard
            .object(forKey: Self.opencodeEnabledKey) as? Bool ?? true
        hermesEnabled = UserDefaults.standard
            .object(forKey: Self.hermesEnabledKey) as? Bool ?? true
        completionFlashEnabled = UserDefaults.standard
            .object(forKey: Self.completionFlashEnabledKey) as? Bool ?? true
    }

    private static let defaultApps: [AppItem] = [
        AppItem(id: "safari", name: "Safari", bundleIdentifier: "com.apple.Safari"),
        AppItem(id: "xcode", name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
        AppItem(id: "terminal", name: "终端", bundleIdentifier: "com.apple.Terminal"),
        AppItem(id: "finder", name: "访达", bundleIdentifier: "com.apple.finder"),
        AppItem(id: "vscode", name: "VS Code", bundleIdentifier: "com.microsoft.VSCode"),
        AppItem(id: "music", name: "音乐", bundleIdentifier: "com.apple.Music"),
        AppItem(id: "calendar", name: "日历", bundleIdentifier: "com.apple.iCal"),
        AppItem(id: "settings", name: "系统设置", bundleIdentifier: "com.apple.SystemSettings"),
    ]
}
