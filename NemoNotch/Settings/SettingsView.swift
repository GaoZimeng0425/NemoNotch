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
                .tabItem { Label("settings.tabs", systemImage: "sidebar.left") }
                .tag(0)

            appListView
                .tabItem { Label("settings.app_list", systemImage: "square.grid.2x2") }
                .tag(1)

            claudeView
                .tabItem { Label("AI CLI", systemImage: "cpu") }
                .tag(2)

            notificationListView
                .tabItem { Label("settings.notifications", systemImage: "bell.badge") }
                .tag(3)
        }
        .frame(width: 430, height: 460)
        .environment(\.locale, appSettings.currentLocale)
    }

    // MARK: - Tab Management

    private var tabManagementView: some View {
        Form {
            Section("settings.visible_tabs") {
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

            Section("settings.default_tab") {
                Picker("settings.default_tab_picker", selection: Binding(
                    get: { appSettings.defaultTab },
                    set: { appSettings.defaultTab = $0 }
                )) {
                    ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
            }

            Section("settings.language") {
                Picker("settings.language", selection: Binding(
                    get: { appSettings.language },
                    set: { appSettings.language = $0 }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(languageDisplayName(lang)).tag(lang)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - App List

    private var appListView: some View {
        List {
            ForEach(Array(launcherService.apps.enumerated()), id: \.element.id) { index, app in
                HStack(spacing: 10) {
                    if let image = launcherService.icon(for: app) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.body)
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        launcherService.removeApp(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            .onMove { source, destination in
                launcherService.moveApp(from: source, to: destination)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("settings.apps_count \(launcherService.apps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    launcherService.scanInstalledApps()
                    showAppPicker = true
                } label: {
                    Label("settings.add_app", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(isPresented: $showAppPicker) {
            appPickerSheet
        }
    }

    private var appPickerSheet: some View {
        VStack(spacing: 0) {
            Text("settings.app_picker_title")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("launcher.search_apps", text: Binding(
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
                let isSelected = launcherService.apps.contains { $0.bundleIdentifier == app.bundleIdentifier }
                HStack(spacing: 10) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.body)
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? .blue : .secondary.opacity(0.5))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    launcherService.toggleInstalledApp(app)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)

            HStack {
                Text("settings.apps_selected_count \(launcherService.apps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("common.done") {
                    showAppPicker = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
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

            Text("settings.hooks_description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if aiService.serverRunning {
                Label("settings.server_running", systemImage: "antenna.radiowaves.left.and.right")
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
                Label("settings.hooks_installed \(name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Label("settings.hooks_not_installed \(name)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            }

            HStack(spacing: 12) {
                Button(isInstalled ? "settings.reinstall" : "settings.install_hooks") {
                    onInstall()
                }
                .controlSize(.large)

                if isInstalled {
                    Button("settings.uninstall_hooks", role: .destructive) {
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
                        Label("settings.accessibility_required", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.headline)
                        Text("settings.accessibility_description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("settings.open_system_settings") {
                            notificationService.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("settings.monitored_apps") {
                if appSettings.monitoredApps.isEmpty {
                    Text("settings.no_monitored_apps")
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
                Button("settings.add_monitored_app") {
                    let panel = NSOpenPanel()
                    panel.title = String(localized: "settings.select_monitored_app")
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
                Text("settings.add_monitored_app")
            } footer: {
                Text("settings.monitored_footer")
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

    private func languageDisplayName(_ language: AppLanguage) -> String {
        switch language {
        case .system: return String(localized: "settings.language.system")
        case .en: return String(localized: "settings.language.en")
        case .zhHans: return String(localized: "settings.language.zh")
        }
    }
}
