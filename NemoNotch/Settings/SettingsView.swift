import SwiftUI

struct SettingsView: View {
    let appSettings: AppSettings
    let claudeCodeService: ClaudeCodeService
    let launcherService: LauncherService

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
        }
        .frame(width: 430, height: 350)
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
                    ForEach(Array(appSettings.enabledTabs).sorted { Tab.allCases.firstIndex(of: $0)! < Tab.allCases.firstIndex(of: $1)! }) { tab in
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
                        if let data = app.iconData, let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
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
}
