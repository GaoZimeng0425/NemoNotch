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

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            updateAppleLanguages()
        }
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
        self.defaultTab = storedTab ?? .overview

        let storedTabs = UserDefaults.standard.stringArray(forKey: "enabledTabs")?.compactMap { Tab(rawValue: $0) }
        var tabs = storedTabs.map(Set.init) ?? Set(Tab.allCases)
        if storedTabs != nil { tabs.insert(.overview) }

        self.enabledTabs = tabs

        if let data = UserDefaults.standard.data(forKey: "launcherApps"),
           let apps = try? JSONDecoder().decode([AppItem].self, from: data)
        {
            self.launcherApps = apps
        } else {
            self.launcherApps = Self.defaultApps
        }

        self.monitoredApps = UserDefaults.standard.stringArray(forKey: "monitoredApps") ?? []

        let storedLang = UserDefaults.standard.string(forKey: "language").flatMap { AppLanguage(rawValue: $0) }
        self.language = storedLang ?? .system
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
