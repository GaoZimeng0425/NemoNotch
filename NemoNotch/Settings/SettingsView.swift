import SwiftUI

/// Settings sidebar pages (System-Settings-style navigation). Raw values
/// persist via `@AppStorage` so reopening the window returns to the last
/// visited page.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, alerts, aiAgents, appList, notifications, hotkeys, pomodoro, keepAwake, about

    var id: String {
        rawValue
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
}

/// 设置窗外壳:手排双栏(侧栏 + 详情卡)+ 页切换。各页内容在 `Pages/` 下,
/// 共享视觉组件在 `SettingsComponents.swift`。
struct SettingsView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(NotificationService.self) var notificationService

    @AppStorage("settings.selectedPage") private var selectedPageRaw = SettingsPage.general.rawValue

    @State private var showSidebar = true
    /// 标题条(红绿灯 + 收起按钮那一排)的高度,取自系统安全区。
    @State private var titlebarInset: CGFloat = 0

    /// 卡片与窗口边、与侧栏之间的间距——也是收起侧栏后卡片四周
    /// 露出的"凹陷边框"宽度。
    private let cardInset: CGFloat = 8
    private let sidebarWidth: CGFloat = 200

    var body: some View {
        // 手排布局而非 NavigationSplitView:macOS 26 原生侧栏是"浮起的玻璃
        // 面板",与要求的层次相反——这里窗口底层是 sidebar 材质(凹陷层),
        // 侧栏直接画在上面,右侧内容是凸起的圆角卡片;收起侧栏后卡片四周
        // 留出等宽的凹陷边框。红绿灯与收起按钮同在标题条一排(AppKit
        // 工具栏桥,见 SettingsWindowChrome);卡片不让标题条安全区,四边
        // 等距铺满,只有侧栏行避让红绿灯。
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            detailCard
                .padding(.leading, showSidebar ? 0 : cardInset)
                .padding([.top, .trailing, .bottom], cardInset)
                .ignoresSafeArea(.container, edges: .top)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { titlebarInset = $0 }
        .background(SettingsSidebarMaterial().ignoresSafeArea())
        // min/ideal 而非固定 frame:固定 frame 在用户把窗口调小后会被居中
        // 裁切(侧栏首项消失、按钮错位全是它造成的)。
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 540)
        .onAppear { SettingsWindowChrome.install() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowChrome.toggleSidebar)) { _ in
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                showSidebar.toggle()
            }
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

    private var sidebar: some View {
        List(selection: Binding(
            get: { SettingsPage(rawValue: selectedPageRaw) ?? .general },
            set: {
                if let page = $0 {
                    selectedPageRaw = page.rawValue
                }
            }
        )) {
            ForEach(SettingsPage.allCases) { page in
                // LocalizedStringKey 包装是必须的:`labelKey` 是 String
                // 变量,直接传会被当字面文本渲染成 "settings.nav.general"。
                Label(LocalizedStringKey(page.labelKey), systemImage: page.symbol)
                    .tag(page)
            }
        }
        .listStyle(.sidebar)
        // 列表自身不铺底色,透出窗口底层的 sidebar 材质(凹陷层)。
        .scrollContentBackground(.hidden)
    }

    private var detailCard: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return detailView
            // 各页 Form/ScrollView 不铺自己的底,统一用卡片底色。
            .scrollContentBackground(.hidden)
            // 侧栏收起时红绿灯 + 收起按钮叠在卡片左上角:卡片仍铺满,
            // 只把内容让出标题条高度。
            .safeAreaPadding(.top, showSidebar ? 0 : max(0, titlebarInset - cardInset))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(shape)
            // 细描边 + 柔和投影让卡片浮起,周围的材质边框随之读作凹陷。
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

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
