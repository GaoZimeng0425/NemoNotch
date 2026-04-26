import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(LauncherService.self) var launcherService
    @Environment(NotificationService.self) var notificationService

    @State private var selectedTab = 0
    @State private var showAppPicker = false

    var body: some View {
        TabView(selection: $selectedTab) {
            tabManagementView
                .tabItem { Label("Tab 管理", systemImage: "sidebar.left") }
                .tag(0)

            appListView
                .tabItem { Label("应用列表", systemImage: "square.grid.2x2") }
                .tag(1)

            claudeView
                .tabItem { Label("AI CLI", systemImage: "cpu") }
                .tag(2)

            notificationListView
                .tabItem { Label("通知", systemImage: "bell.badge") }
                .tag(3)
        }
        .frame(width: 430, height: 480)
    }

    // MARK: - Tab Management

    private var tabManagementView: some View {
        Form {
            Section("显示的 Tab") {
                ForEach(Tab.allCases) { tab in
                    Toggle(tab.title, isOn: Binding(
                        get: { appSettings.enabledTabs.contains(tab) },
                        set: { enabled in
                            if enabled {
                                appSettings.enabledTabs.insert(tab)
                            } else if appSettings.enabledTabs.count > 1 {
                                appSettings.enabledTabs.remove(tab)
                            }
                        }
                    ))
                }
            }

            Section("默认 Tab") {
                Picker("展开时默认显示", selection: Binding(
                    get: { appSettings.defaultTab },
                    set: { appSettings.defaultTab = $0 }
                )) {
                    ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - App List

    private var appListView: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(launcherService.apps.enumerated()), id: \.element.id) { index, app in
                    HStack {
                        if let image = launcherService.icon(for: app) {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        Text(app.name)
                        Spacer()
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            launcherService.removeApp(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { source, destination in
                    launcherService.moveApp(from: source, to: destination)
                }
            }

            HStack {
                Text("\(launcherService.apps.count) 个应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("添加应用...") {
                    launcherService.scanInstalledApps()
                    showAppPicker = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showAppPicker) {
            appPickerSheet
        }
    }

    private var appPickerSheet: some View {
        VStack(spacing: 0) {
            Text("选择应用")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索应用", text: Binding(
                    get: { launcherService.scanSearchText },
                    set: { launcherService.scanSearchText = $0 }
                ))
                .textFieldStyle(.plain)
                if !launcherService.scanSearchText.isEmpty {
                    Button {
                        launcherService.scanSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            List(launcherService.filteredScannedApps) { app in
                HStack {
                    let isSelected = launcherService.apps.contains { $0.bundleIdentifier == app.bundleIdentifier }
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                    }
                    VStack(alignment: .leading) {
                        Text(app.name)
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .blue : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    launcherService.toggleInstalledApp(app)
                }
            }
            .listStyle(.plain)

            HStack {
                Text("已选 \(launcherService.apps.count) 个应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") {
                    showAppPicker = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 400, height: 500)
    }

    // MARK: - AI CLI Hooks

    private var claudeView: some View {
        VStack(spacing: 16) {
            // Claude Code
            hookSection(
                name: "Claude Code",
                icon: "cpu",
                isInstalled: aiService.claudeProvider.isHookInstalled,
                onInstall: { aiService.claudeProvider.installHooks() },
                onUninstall: { aiService.claudeProvider.uninstallHooks() }
            )

            Divider()

            // Gemini CLI
            hookSection(
                name: "Gemini CLI",
                icon: "sparkle",
                isInstalled: aiService.geminiProvider.isHookInstalled,
                onInstall: { aiService.geminiProvider.installHooks() },
                onUninstall: { aiService.geminiProvider.uninstallHooks() }
            )

            Text("Hooks 允许 NemoNotch 实时监控 AI CLI 的会话状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if aiService.serverRunning {
                Label("服务运行中", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    private func hookSection(name: String, icon: String, isInstalled: Bool, onInstall: @escaping () -> Void, onUninstall: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            if isInstalled {
                Label("\(name) Hooks: 已安装", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Label("\(name) Hooks: 未安装", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            }

            HStack(spacing: 12) {
                Button(isInstalled ? "重新安装" : "安装 Hooks") {
                    onInstall()
                }
                .controlSize(.large)

                if isInstalled {
                    Button("卸载 Hooks", role: .destructive) {
                        onUninstall()
                    }
                    .controlSize(.large)
                }
            }
        }
    }

    // MARK: - Notification List

    private var notificationListView: some View {
        Form {
            if !notificationService.isAXTrusted {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("需要辅助功能权限", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.headline)
                        Text("NemoNotch 需要辅助功能权限才能读取应用通知角标。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开系统设置") {
                            notificationService.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("已监控的应用") {
                if appSettings.monitoredApps.isEmpty {
                    Text("尚未添加监控应用")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appSettings.monitoredApps, id: \.self) { bundleID in
                        HStack {
                            let icon = NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? "")
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading) {
                                Text(appName(for: bundleID))
                                Text(bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                appSettings.monitoredApps.removeAll { $0 == bundleID }
                                notificationService.updateMonitoredApps(appSettings.monitoredApps)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted().reversed() {
                            appSettings.monitoredApps.remove(at: index)
                        }
                        notificationService.updateMonitoredApps(appSettings.monitoredApps)
                    }
                }
            }

            Section {
                Button("选择应用...") {
                    let panel = NSOpenPanel()
                    panel.title = "选择要监控的应用"
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")

                    if panel.runModal() == .OK, let url = panel.url {
                        if let bundle = Bundle(url: url),
                           let bundleID = bundle.bundleIdentifier {
                            if !appSettings.monitoredApps.contains(bundleID) {
                                appSettings.monitoredApps.append(bundleID)
                                notificationService.updateMonitoredApps(appSettings.monitoredApps)
                            }
                        }
                    }
                }
            } header: {
                Text("添加应用")
            } footer: {
                Text("选择需要监控未读通知的应用（如 Slack、微信）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.localizedInfoDictionary?["CFBundleName"] as? String
               ?? bundle.infoDictionary?["CFBundleName"] as? String {
            return name
        }
        return bundleID
    }
}
