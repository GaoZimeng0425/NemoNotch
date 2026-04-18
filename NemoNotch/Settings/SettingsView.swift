import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let appSettings: AppSettings
    let claudeCodeService: ClaudeCodeService
    let launcherService: LauncherService
    let notificationService: NotificationService

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            tabManagementView
                .tabItem { Label("Tab 管理", systemImage: "sidebar.left") }
                .tag(0)

            appListView
                .tabItem { Label("应用列表", systemImage: "square.grid.2x2") }
                .tag(1)

            claudeView
                .tabItem { Label("Claude Code", systemImage: "cpu") }
                .tag(2)

            notificationListView
                .tabItem { Label("通知", systemImage: "bell.badge") }
                .tag(3)
        }
        .frame(width: 430, height: 420)
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
                    }
                }
                .onDelete { offsets in
                    for index in offsets.sorted().reversed() {
                        launcherService.removeApp(at: index)
                    }
                }
            }

            HStack {
                Text("\(launcherService.apps.count) 个应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Claude Code

    private var claudeView: some View {
        VStack(spacing: 16) {
            if claudeCodeService.isHookInstalled {
                Label("Hooks 已安装", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Label("Hooks 未安装", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            }

            if claudeCodeService.isHookInstalled && claudeCodeService.sessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("已安装的 Hooks 仅对新会话生效。如果 Claude Code 已在运行，请重启 Claude Code 以加载 Hooks。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
            }

            Text("Claude Code hooks 允许 NemoNotch 实时监控你的 Claude Code 会话状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button(claudeCodeService.isHookInstalled ? "重新安装" : "安装 Hooks") {
                    claudeCodeService.installHooks()
                }
                .controlSize(.large)

                if claudeCodeService.isHookInstalled {
                    Button("卸载 Hooks", role: .destructive) {
                        claudeCodeService.uninstallHooks()
                    }
                    .controlSize(.large)
                }
            }

            if claudeCodeService.serverRunning {
                Label("服务运行中", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Notification List

    private var notificationListView: some View {
        Form {
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
