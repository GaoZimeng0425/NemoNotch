import SwiftUI

/// Sidebar navigation groups (System-Settings-style sectioned sidebar).
enum SettingsNavGroup: String, CaseIterable, Identifiable {
    case general, aiWorkspace, system

    var id: String {
        rawValue
    }

    var labelKey: String {
        switch self {
        case .general: "settings.group.general"
        case .aiWorkspace: "settings.group.ai"
        case .system: "settings.group.system"
        }
    }

    var pages: [SettingsPage] {
        SettingsPage.allCases.filter { $0.navGroup == self }
    }
}

/// Settings sidebar pages (System-Settings-style navigation). Raw values
/// persist via `@AppStorage` so reopening the window returns to the last
/// visited page.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, alerts, aiAgents, appList, notifications, hotkeys, pomodoro, keepAwake, about

    var id: String {
        rawValue
    }

    /// "关于"单独成区不列组头,跟在分组之后(系统设置的尾部条目惯例)。
    static let ungrouped: [SettingsPage] = [.about]

    var navGroup: SettingsNavGroup? {
        switch self {
        case .general, .alerts: .general
        case .aiAgents, .hotkeys, .pomodoro: .aiWorkspace
        case .appList, .notifications, .keepAwake: .system
        case .about: nil
        }
    }

    var labelKey: String {
        switch self {
        case .general: "settings.nav.general"
        case .alerts: "settings.nav.alerts"
        case .aiAgents: "settings.nav.ai"
        case .appList: "settings.nav.apps"
        case .notifications: "settings.nav.notifications"
        case .hotkeys: "settings.nav.hotkeys"
        case .pomodoro: "settings.nav.pomodoro"
        case .keepAwake: "settings.nav.awake"
        case .about: "settings.nav.about"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .alerts: "bell.badge"
        case .aiAgents: "sparkles"
        case .appList: "square.grid.2x2"
        case .notifications: "bell"
        case .hotkeys: "keyboard"
        case .pomodoro: "timer"
        case .keepAwake: "moon.zzz"
        case .about: "info.circle"
        }
    }

    /// 侧栏图标渐变的起止色(固定色,不随明暗切换 —— 与系统设置图标一致)。
    var tintA: Color {
        switch self {
        case .general: Color(red: 0.62, green: 0.62, blue: 0.66)
        case .alerts: Color(red: 0.98, green: 0.62, blue: 0.09)
        case .aiAgents: Color(red: 0.60, green: 0.45, blue: 0.95)
        case .appList: Color(red: 0.25, green: 0.75, blue: 0.45)
        case .notifications: Color(red: 0.94, green: 0.30, blue: 0.30)
        case .hotkeys: Color(red: 0.45, green: 0.45, blue: 0.50)
        case .pomodoro: Color(red: 0.95, green: 0.42, blue: 0.25)
        case .keepAwake: Color(red: 0.30, green: 0.40, blue: 0.85)
        case .about: Color(red: 0.20, green: 0.55, blue: 0.95)
        }
    }

    var tintB: Color {
        switch self {
        case .general: Color(red: 0.42, green: 0.42, blue: 0.47)
        case .alerts: Color(red: 0.92, green: 0.42, blue: 0.10)
        case .aiAgents: Color(red: 0.35, green: 0.30, blue: 0.90)
        case .appList: Color(red: 0.10, green: 0.58, blue: 0.32)
        case .notifications: Color(red: 0.80, green: 0.15, blue: 0.20)
        case .hotkeys: Color(red: 0.25, green: 0.25, blue: 0.30)
        case .pomodoro: Color(red: 0.85, green: 0.20, blue: 0.15)
        case .keepAwake: Color(red: 0.15, green: 0.22, blue: 0.60)
        case .about: Color(red: 0.05, green: 0.35, blue: 0.80)
        }
    }
}

/// 设置窗外壳(Atoll 同构):标准 `NavigationSplitView` 双栏 + 侧栏顶搜索条
/// + 整窗玻璃背景。侧栏开关用 SwiftUI 自带的标准工具栏按钮,不手装
/// NSToolbar。各页内容在 `Pages/` 下,共享视觉组件在
/// `SettingsComponents.swift`,搜索索引/过滤在 `SettingsSearchIndex.swift`。
struct SettingsView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(NotificationService.self) var notificationService

    @AppStorage("settings.selectedPage") private var selectedPageRaw = SettingsPage.general.rawValue

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } detail: {
            detailView
                // 各页 Form/ScrollView/List 不铺自己的底,透出整窗玻璃。
                .scrollContentBackground(.hidden)
        }
        .navigationSplitViewStyle(.balanced)
        // 整窗玻璃(Atoll 同款):两栏共同浮在一块 macOS 26 玻璃上。
        .background(windowGlass.ignoresSafeArea())
        // min/ideal 而非固定 frame:固定 frame 在用户把窗口调小后会被居中
        // 裁切(侧栏首项消失、按钮错位全是它造成的)。
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 540)
        .onAppear {
            SettingsWindowChrome.install()
            // 模型跨窗口会话存活:重开窗口时搜索从空词开始,别让看不见的
            // 旧词继续过滤侧栏。
            SettingsSearchModel.shared.query = ""
        }
        .environment(\.locale, appSettings.currentLocale)
        .task {
            // The AX grant happens in System Settings, outside this process.
            // Poll while Settings is open so the permission card clears itself
            // the moment the user finishes the drag-and-toggle. Scoped to the
            // window's lifetime — no timer lingers once Settings closes.
            while !Task.isCancelled {
                notificationService.refreshAXTrust()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// macOS 26 玻璃:整窗一块圆角玻璃垫底,侧栏与详情都画在它上面。
    private var windowGlass: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.clear)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
    }

    // MARK: - 侧栏

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            SettingsSidebarSearchBar(
                text: Binding(
                    get: { SettingsSearchModel.shared.query },
                    set: { SettingsSearchModel.shared.query = $0 }
                ),
                onSubmit: {
                    // 回车 → 跳首个命中页(过滤器保留,可继续点其他命中行)。
                    if let first = matchedPages?.first {
                        selectedPageRaw = first.rawValue
                    }
                }
            )
            Divider()
            pageList
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
    }

    private var pageList: some View {
        List(selection: Binding(
            get: { SettingsPage(rawValue: selectedPageRaw) ?? .general },
            set: {
                if let page = $0 {
                    selectedPageRaw = page.rawValue
                }
            }
        )) {
            if let matches = matchedPages {
                // 搜索中:分组折叠成一个扁平的结果节。
                Section(LocalizedStringKey("settings.search.results")) {
                    if matches.isEmpty {
                        Text("settings.search.no_matches")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matches) { page in
                            sidebarRow(page)
                                .tag(page)
                        }
                    }
                }
            } else {
                ForEach(SettingsNavGroup.allCases) { group in
                    // LocalizedStringKey 包装是必须的:`labelKey` 是 String
                    // 变量,直接传会被当字面文本渲染成 "settings.group.general"。
                    Section(LocalizedStringKey(group.labelKey)) {
                        ForEach(group.pages) { page in
                            sidebarRow(page)
                                .tag(page)
                        }
                    }
                }
                // "关于"不列组头,静默跟在分组之后。
                Section {
                    ForEach(SettingsPage.ungrouped) { page in
                        sidebarRow(page)
                            .tag(page)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 搜索过滤

    /// 去空白后的有效搜索词;`nil` 表示"未在搜索",侧栏走正常分组。
    /// 读取 `SettingsSearchModel.shared.query` 发生在 body 求值期间,
    /// Observation 会自动建立依赖 —— 搜索条一改词,侧栏即重算。
    private var matchedPages: [SettingsPage]? {
        let query = SettingsSearchModel.shared.query
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return SettingsSearchIndex.matchingPages(
            query,
            stringsByPage: SettingsSearchIndex.stringsByPage(language: appSettings.language)
        )
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        HStack(spacing: 8) {
            SidebarIconView(symbol: page.symbol, tintA: page.tintA, tintB: page.tintB)
            // LocalizedStringKey 包装是必须的:`labelKey` 是 String
            // 变量,直接传会被当字面文本渲染成 "settings.nav.general"。
            Text(LocalizedStringKey(page.labelKey))
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private var detailView: some View {
        switch SettingsPage(rawValue: selectedPageRaw) ?? .general {
        case .general: GeneralSettingsPage()
        case .alerts: AlertsSettingsPage()
        case .aiAgents: AIAgentsSettingsPage()
        case .appList: AppListSettingsPage()
        case .notifications: NotificationListSettingsPage()
        case .hotkeys: HotkeysSettingsView()
        case .pomodoro: PomodoroSettingsView()
        case .keepAwake: KeepAwakeSettingsView()
        case .about: AboutSettingsPage()
        }
    }
}
