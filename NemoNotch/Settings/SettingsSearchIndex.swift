import Foundation

/// 设置搜索索引:每页可被命中的词条来源(本地化 key + 不随语言变化的固定名),
/// 外加一个纯过滤函数。索引是纯数据,过滤是纯函数 —— 单测覆盖,不碰 UI。
///
/// 词条在过滤时按**应用内语言**解析(`String(localized:)` 走的是系统语言,
/// 用户在应用内切了语言而未重启时会对不上侧栏实际显示的文字)。
enum SettingsSearchIndex {
    /// 每页的搜索词条:本地化 key 与固定字面量(provider 名不进 xcstrings)。
    private static let entriesByPage: [SettingsPage: (keys: [String], literals: [String])] = [
        .general: (
            keys: [
                "settings.nav.general", "settings.visible_tabs", "settings.default_tab",
                "settings.default_tab_picker", "settings.weather_city", "settings.weather_city_footer",
                "settings.language",
                "models.tab.overview", "models.tab.ai", "models.tab.launcher", "models.tab.system",
            ],
            literals: []
        ),
        .alerts: (
            keys: [
                "settings.nav.alerts", "settings.completion_flash.header", "settings.completion_flash.enabled",
                "settings.event_alerts.header", "settings.bluetooth_alerts.enabled",
                "settings.calendar_alerts.enabled", "settings.charging_alerts.enabled",
            ],
            literals: []
        ),
        .aiAgents: (
            keys: [
                "settings.nav.ai", "settings.ai_status_fab.enabled", "settings.lockscreen_ai.enabled",
                "settings.status.installed", "settings.status.not_installed", "settings.install_hooks",
                "settings.reinstall", "settings.uninstall_hooks", "settings.openclaw.connected %@",
                "settings.openclaw.connect", "settings.openclaw.disconnect", "settings.openclaw.remove_device",
                "settings.hooks_description", "settings.server_running",
            ],
            literals: ["Claude Code", "Gemini CLI", "opencode", "zcode", "Hermes Agent", "OpenClaw"]
        ),
        .appList: (
            keys: [
                // 带 %lld/%@ 的 key 必须按目录里的完整格式串列出 —— 漏掉占位符
                // 会查不到词条,回退值(=key 本身)反而把原始 key 漏进搜索语料。
                "settings.nav.apps", "settings.apps_count %lld", "settings.add_app",
                "settings.app_picker_title", "settings.apps_selected_count %lld", "launcher.search_apps",
            ],
            literals: []
        ),
        .notifications: (
            keys: [
                "settings.nav.notifications", "settings.notificationToast.enabled", "settings.monitored_apps",
                "settings.no_monitored_apps", "settings.add_monitored_app", "settings.monitored_footer",
                "permission.fullDiskAccess.notifications.title", "permission.fullDiskAccess.notifications.detail",
            ],
            literals: []
        ),
        .hotkeys: (
            keys: [
                "settings.nav.hotkeys", "settings.hotkeys.notch", "settings.hotkeys.tabs",
                "settings.hotkeys.toggle_notch",
                "models.tab.overview", "models.tab.ai", "models.tab.launcher", "models.tab.system",
            ],
            literals: []
        ),
        .pomodoro: (
            keys: [
                "settings.nav.pomodoro", "settings.pomodoro.title", "settings.pomodoro.workDuration",
                "settings.pomodoro.shortBreakDuration", "settings.pomodoro.longBreakDuration",
                "settings.pomodoro.longBreakInterval", "settings.pomodoro.soundEnabled",
                "settings.pomodoro.notificationEnabled", "settings.pomodoro.hotkeyHeader",
                "settings.pomodoro.permissionHeader", "permission.notification.title",
            ],
            literals: []
        ),
        .keepAwake: (
            keys: [
                "settings.nav.awake", "settings.keepawake.title", "settings.keepawake.enable",
                "settings.keepawake.lidDisplayOff", "settings.keepawake.restoreOnQuit",
                "settings.keepawake.about.privilege", "settings.keepawake.about.persistent",
            ],
            literals: []
        ),
        .about: (
            keys: [
                "settings.nav.about", "settings.about.tagline", "settings.about.github",
                "settings.about.check_updates", "settings.about.report_issue", "settings.about.acknowledgements",
            ],
            literals: ["NemoNotch"]
        ),
    ]

    /// 按应用内语言解析出每页的可搜索文本。`language == nil`(跟随系统)时
    /// 走 `Bundle.main` 的默认解析。
    static func stringsByPage(language: AppLanguage?) -> [SettingsPage: [String]] {
        let bundle = Self.bundle(for: language)
        var result: [SettingsPage: [String]] = [:]
        for (page, entry) in entriesByPage {
            var strings = entry.literals
            strings.append(contentsOf: entry.keys.map {
                bundle.localizedString(forKey: $0, value: $0, table: nil)
            })
            result[page] = strings
        }
        return result
    }

    /// 纯过滤。query 去除首尾空白后为空 → `nil`(调用方据此回到正常分组展示);
    /// 否则返回命中的页,顺序保持 `SettingsPage.allCases` 原始顺序(稳定,可测)。
    /// 匹配忽略大小写、变音符号与全半角宽度。
    static func matchingPages(_ query: String, stringsByPage: [SettingsPage: [String]]) -> [SettingsPage]? {
        let needle = normalize(query)
        guard !needle.isEmpty else { return nil }
        return SettingsPage.allCases.filter { page in
            guard let strings = stringsByPage[page] else { return false }
            return strings.contains { normalize($0).contains(needle) }
        }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 应用内语言 → 对应 lproj 的 bundle。取不到路径时退回 `Bundle.main`
    /// (等于跟随系统,行为与未覆写时一致)。
    private static func bundle(for language: AppLanguage?) -> Bundle {
        guard let language,
              let identifier = language.locale?.identifier,
              let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let lproj = Bundle(path: path) else {
            return .main
        }
        return lproj
    }
}
