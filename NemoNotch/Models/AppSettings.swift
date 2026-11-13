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

    var weatherCity: String {
        didSet { UserDefaults.standard.set(weatherCity, forKey: "weatherCity") }
    }

    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "language")
            updateAppleLanguages()
        }
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

    /// The per-source monitoring toggle, read/written by source. Hermes is
    /// not an `AISource` — it stays on the plain `hermesEnabled` property.
    subscript(source: AISource) -> Bool {
        get {
            switch source {
            case .claude: return claudeEnabled
            case .gemini: return geminiEnabled
            case .opencode: return opencodeEnabled
            case .zcode: return zcodeEnabled
            }
        }
        set {
            switch source {
            case .claude: claudeEnabled = newValue
            case .gemini: geminiEnabled = newValue
            case .opencode: opencodeEnabled = newValue
            case .zcode: zcodeEnabled = newValue
            }
        }
    }

    static let opencodeEnabledKey = "opencodeEnabled"
    static let zcodeEnabledKey = "zcodeEnabled"
    static let completionFlashEnabledKey = "completionFlashEnabled"
    static let aiStatusFabEnabledKey = "aiStatusFabEnabled"
    static let aiStatusFabPositionKey = "aiStatusFabPosition"
    static let lockScreenAIPanelEnabledKey = "lockScreenAIPanelEnabled"
    static let waitingReminderEnabledKey = "waitingReminderEnabled"
    static let waitingReminderMinutesKey = "waitingReminderMinutes"
    static let quotaAlertEnabledKey = "quotaAlertEnabled"
    static let quotaAlertThresholdKey = "quotaAlertThreshold"

    var claudeEnabled: Bool {
        didSet { UserDefaults.standard.set(claudeEnabled, forKey: Self.claudeEnabledKey) }
    }

    var geminiEnabled: Bool {
        didSet { UserDefaults.standard.set(geminiEnabled, forKey: Self.geminiEnabledKey) }
    }

    var opencodeEnabled: Bool {
        didSet { UserDefaults.standard.set(opencodeEnabled, forKey: Self.opencodeEnabledKey) }
    }

    var zcodeEnabled: Bool {
        didSet { UserDefaults.standard.set(zcodeEnabled, forKey: Self.zcodeEnabledKey) }
    }

    var hermesEnabled: Bool {
        didSet { UserDefaults.standard.set(hermesEnabled, forKey: Self.hermesEnabledKey) }
    }

    // MARK: - Completion flash

    var completionFlashEnabled: Bool {
        didSet { UserDefaults.standard.set(completionFlashEnabled, forKey: Self.completionFlashEnabledKey) }
    }

    // MARK: - Notification Center → toast

    static let notificationToastEnabledKey = "notificationToastEnabled"
    static let notificationToastAppsKey = "notificationToastApps"
    static let defaultNotificationToastApps = ["com.apple.mail", "com.tinyspeck.slackmacgap", "com.tencent.xinWeChat"]

    /// Default off (opt-in, like the other reminders): cards show other apps'
    /// message text, so turning it on is the user's call.
    var notificationToastEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationToastEnabled, forKey: Self.notificationToastEnabledKey) }
    }

    /// Bundle ids whose Notification Center messages become toast cards.
    var notificationToastApps: [String] {
        didSet { UserDefaults.standard.set(notificationToastApps, forKey: Self.notificationToastAppsKey) }
    }

    // MARK: - Reminder tones(需要你决定 / 出事了)

    static let attentionToastEnabledKey = "attentionToastEnabled"
    static let failureToastEnabledKey = "failureToastEnabled"

    /// Amber/blue cards — AskUserQuestion, plan review, tool approvals.
    /// Default on: this is what the old misfiring completion flash was
    /// (accidentally) already telling the user, minus the lie.
    var attentionToastEnabled: Bool {
        didSet { UserDefaults.standard.set(attentionToastEnabled, forKey: Self.attentionToastEnabledKey) }
    }

    /// Red cards — agent error / API error / session lost. Default on:
    /// "come rescue" is the one signal that must not be silent.
    var failureToastEnabled: Bool {
        didSet { UserDefaults.standard.set(failureToastEnabled, forKey: Self.failureToastEnabledKey) }
    }

    // MARK: - External app toast API (POST /v1/toast)

    static let externalToastEnabledKey = "externalToastEnabled"

    /// Whether local apps may push toast cards via `POST /v1/toast`. Default
    /// on: the 0600 shared token is the admission gate, no system permission
    /// prompt is involved, and the toast queue's own cap bounds a flood.
    var externalToastEnabled: Bool {
        didSet { UserDefaults.standard.set(externalToastEnabled, forKey: Self.externalToastEnabledKey) }
    }

    // MARK: - Event alerts (calendar due / bluetooth audio / charging)

    static let calendarDueFlashEnabledKey = "calendarDueFlashEnabled"
    static let calendarDueLeadMinutesKey = "calendarDueLeadMinutes"
    static let bluetoothToastEnabledKey = "bluetoothToastEnabled"
    static let chargingCapsuleEnabledKey = "chargingCapsuleEnabled"

    var calendarDueFlashEnabled: Bool {
        didSet { UserDefaults.standard.set(calendarDueFlashEnabled, forKey: Self.calendarDueFlashEnabledKey) }
    }

    /// Minutes before an event's start the due flash fires; 0 = at start.
    var calendarDueLeadMinutes: Int {
        didSet { UserDefaults.standard.set(calendarDueLeadMinutes, forKey: Self.calendarDueLeadMinutesKey) }
    }

    var bluetoothToastEnabled: Bool {
        didSet { UserDefaults.standard.set(bluetoothToastEnabled, forKey: Self.bluetoothToastEnabledKey) }
    }

    var chargingCapsuleEnabled: Bool {
        didSet { UserDefaults.standard.set(chargingCapsuleEnabled, forKey: Self.chargingCapsuleEnabledKey) }
    }

    // MARK: - AI status FAB

    var aiStatusFabEnabled: Bool {
        didSet { UserDefaults.standard.set(aiStatusFabEnabled, forKey: Self.aiStatusFabEnabledKey) }
    }

    // MARK: - Lock screen AI panel

    var lockScreenAIPanelEnabled: Bool {
        didSet { UserDefaults.standard.set(lockScreenAIPanelEnabled, forKey: Self.lockScreenAIPanelEnabledKey) }
    }

    // MARK: - Waiting reminder

    /// System-notification reminder when a session sits in waiting-for-approval
    /// longer than `waitingReminderMinutes`. Default off — reminders nag by
    /// design, so they are strictly opt-in.
    var waitingReminderEnabled: Bool {
        didSet { UserDefaults.standard.set(waitingReminderEnabled, forKey: Self.waitingReminderEnabledKey) }
    }

    var waitingReminderMinutes: Int {
        didSet { UserDefaults.standard.set(waitingReminderMinutes, forKey: Self.waitingReminderMinutesKey) }
    }

    /// Edge-bar cards when a quota window passes `quotaAlertThreshold` (and when
    /// it recovers), held until acknowledged. Default off — alerts are opt-in,
    /// like `waitingReminderEnabled`.
    var quotaAlertEnabled: Bool {
        didSet { UserDefaults.standard.set(quotaAlertEnabled, forKey: Self.quotaAlertEnabledKey) }
    }

    /// Percent used (50...100) that fires the alert.
    var quotaAlertThreshold: Int {
        didSet { UserDefaults.standard.set(quotaAlertThreshold, forKey: Self.quotaAlertThresholdKey) }
    }

    // MARK: - Keep awake (合盖不休眠)

    static let keepAwakeLidDisplayOffKey = "keepAwake.lidDisplayOff"
    static let keepAwakeIdleEnabledKey = "keepAwake.idleEnabled"
    static let keepAwakeRestoreOnQuitKey = "keepAwake.restoreOnQuit"

    /// 合盖时自动熄屏。`disablesleep=1` 会让整条睡眠路径被禁,合盖屏幕不灭会
    /// 持续耗电发热 —— 所以默认开。接了外接显示器时本就不会熄屏。
    var keepAwakeLidDisplayOff: Bool {
        didSet { UserDefaults.standard.set(keepAwakeLidDisplayOff, forKey: Self.keepAwakeLidDisplayOffKey) }
    }

    /// 退出 App 时自动还原休眠设置。
    ///
    /// `SleepDisabled` 是跨重启持久的全局设置,不还原的话用户的 Mac 会一直不睡。
    /// 默认开。关掉的代价是要自己记得关 —— 换来的是退出时不再弹授权框。
    var keepAwakeRestoreOnQuit: Bool {
        didSet { UserDefaults.standard.set(keepAwakeRestoreOnQuit, forKey: Self.keepAwakeRestoreOnQuitKey) }
    }

    /// 空闲不休眠(租约版 A 开关):挂一份 `PreventUserIdleSystemSleep` 断言,
    /// 零弹窗;断言随进程退出自动失效,启动时按此设置重建 —— 状态即「记住」。
    /// 只挡开盖空闲睡,合盖照睡(那是 B 开关的事)。默认关。
    var keepAwakeIdleEnabled: Bool {
        didSet { UserDefaults.standard.set(keepAwakeIdleEnabled, forKey: Self.keepAwakeIdleEnabledKey) }
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
            .map { $0 == "openclaw" || $0 == "agents" ? Tab.claude.rawValue : $0 }
        let storedTabs = rawTabs?.compactMap { Tab(rawValue: $0) }
        var tabs = storedTabs.map(Set.init) ?? Set(Tab.allCases)
        if storedTabs != nil {
            tabs.insert(.overview)
        }

        enabledTabs = tabs

        weatherCity = UserDefaults.standard.string(forKey: "weatherCity") ?? ""

        let storedLang = UserDefaults.standard.string(forKey: "language").flatMap { AppLanguage(rawValue: $0) }
        language = storedLang ?? .system

        openClawEnabled = UserDefaults.standard
            .object(forKey: Self.openClawEnabledKey) as? Bool ?? true
        claudeEnabled = UserDefaults.standard
            .object(forKey: Self.claudeEnabledKey) as? Bool ?? true
        geminiEnabled = UserDefaults.standard
            .object(forKey: Self.geminiEnabledKey) as? Bool ?? true
        opencodeEnabled = UserDefaults.standard
            .object(forKey: Self.opencodeEnabledKey) as? Bool ?? true
        zcodeEnabled = UserDefaults.standard
            .object(forKey: Self.zcodeEnabledKey) as? Bool ?? true
        hermesEnabled = UserDefaults.standard
            .object(forKey: Self.hermesEnabledKey) as? Bool ?? true
        completionFlashEnabled = UserDefaults.standard
            .object(forKey: Self.completionFlashEnabledKey) as? Bool ?? true
        notificationToastEnabled = UserDefaults.standard
            .object(forKey: Self.notificationToastEnabledKey) as? Bool ?? false
        attentionToastEnabled = UserDefaults.standard
            .object(forKey: Self.attentionToastEnabledKey) as? Bool ?? true
        failureToastEnabled = UserDefaults.standard
            .object(forKey: Self.failureToastEnabledKey) as? Bool ?? true
        externalToastEnabled = UserDefaults.standard
            .object(forKey: Self.externalToastEnabledKey) as? Bool ?? true
        notificationToastApps = UserDefaults.standard
            .stringArray(forKey: Self.notificationToastAppsKey) ?? Self.defaultNotificationToastApps
        calendarDueFlashEnabled = UserDefaults.standard
            .object(forKey: Self.calendarDueFlashEnabledKey) as? Bool ?? true
        calendarDueLeadMinutes = UserDefaults.standard
            .object(forKey: Self.calendarDueLeadMinutesKey) as? Int ?? 0
        // 默认关闭:开启后才碰 IOBluetooth,而碰它正是蓝牙 TCC 弹窗的触发时刻
        // (BluetoothService.bind)。与 waitingReminderEnabled 的 opt-in 同理。
        bluetoothToastEnabled = UserDefaults.standard
            .object(forKey: Self.bluetoothToastEnabledKey) as? Bool ?? false
        chargingCapsuleEnabled = UserDefaults.standard
            .object(forKey: Self.chargingCapsuleEnabledKey) as? Bool ?? true
        aiStatusFabEnabled = UserDefaults.standard
            .object(forKey: Self.aiStatusFabEnabledKey) as? Bool ?? true
        lockScreenAIPanelEnabled = UserDefaults.standard
            .object(forKey: Self.lockScreenAIPanelEnabledKey) as? Bool ?? true
        waitingReminderEnabled = UserDefaults.standard
            .object(forKey: Self.waitingReminderEnabledKey) as? Bool ?? false
        waitingReminderMinutes = UserDefaults.standard
            .object(forKey: Self.waitingReminderMinutesKey) as? Int ?? 5
        quotaAlertEnabled = UserDefaults.standard
            .object(forKey: Self.quotaAlertEnabledKey) as? Bool ?? false
        quotaAlertThreshold = UserDefaults.standard
            .object(forKey: Self.quotaAlertThresholdKey) as? Int ?? 80
        keepAwakeLidDisplayOff = UserDefaults.standard
            .object(forKey: Self.keepAwakeLidDisplayOffKey) as? Bool ?? true
        keepAwakeRestoreOnQuit = UserDefaults.standard
            .object(forKey: Self.keepAwakeRestoreOnQuitKey) as? Bool ?? true
        keepAwakeIdleEnabled = UserDefaults.standard
            .object(forKey: Self.keepAwakeIdleEnabledKey) as? Bool ?? false
    }
}
