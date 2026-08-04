import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(LauncherService.self) var launcherService
    @Environment(NotificationService.self) var notificationService
    @Environment(WeatherService.self) var weatherService
    @Environment(HermesService.self) var hermesService
    @Environment(OpenClawService.self) var openClawService

    @State private var selectedTab = 0
    @State private var showAppPicker = false
    @State private var cityDebounceTask: Task<Void, Never>? = nil

    var body: some View {
        TabView(selection: $selectedTab) {
            tabManagementView
                .tabItem { Label("settings.tabs", systemImage: "sidebar.left") }
                .tag(0)

            appListView
                .tabItem { Label("settings.app_list", systemImage: "square.grid.2x2") }
                .tag(1)

            claudeView
                .tabItem { Label("settings.tab.ai_agents", systemImage: "sparkles") }
                .tag(2)

            notificationListView
                .tabItem { Label("settings.notifications", systemImage: "bell.badge") }
                .tag(3)

            HotkeysSettingsView()
                .tabItem { Label("settings.hotkeys", systemImage: "keyboard") }
                .tag(4)

            PomodoroSettingsView()
                .tabItem { Label("settings.pomodoro.title", systemImage: "timer") }
                .tag(5)

            aboutView
                .tabItem { Label("settings.about.title", systemImage: "info.circle") }
                .tag(6)
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

            Section {
                TextField("settings.weather_city_placeholder", text: Binding(
                    get: { appSettings.weatherCity },
                    set: { appSettings.weatherCity = $0 }
                ))
                .onChange(of: appSettings.weatherCity) { _, newCity in
                    cityDebounceTask?.cancel()
                    cityDebounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        weatherService.updateCity(newCity)
                    }
                }
            } header: {
                Text("settings.weather_city")
            } footer: {
                Text("settings.weather_city_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("settings.completion_flash.header") {
                Toggle("settings.completion_flash.enabled", isOn: Binding(
                    get: { appSettings.completionFlashEnabled },
                    set: { appSettings.completionFlashEnabled = $0 }
                ))
            }

            Section("settings.ai_status_fab.header") {
                Toggle("settings.ai_status_fab.enabled", isOn: Binding(
                    get: { appSettings.aiStatusFabEnabled },
                    set: { appSettings.aiStatusFabEnabled = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About

    private static let githubURL = URL(string: "https://github.com/GaoZimeng0425/NemoNotch")!
    private static let releasesURL = URL(string: "https://github.com/GaoZimeng0425/NemoNotch/releases")!
    private static let issuesURL = URL(string: "https://github.com/GaoZimeng0425/NemoNotch/issues/new")!

    /// App version for display, e.g. "1.0 (1)". Read from the built Info.plist
    /// (populated from MARKETING_VERSION / CURRENT_PROJECT_VERSION in
    /// project.pbxproj since GENERATE_INFOPLIST_FILE = YES).
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Bundled open-source dependencies credited in the About tab, matching the
    /// resolved Swift Package graph (Package.resolved).
    private static let acknowledgements: [(name: String, url: URL)] = [
        ("CocoaLumberjack", URL(string: "https://github.com/CocoaLumberjack/CocoaLumberjack")!),
        ("KeyboardShortcuts", URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!),
        ("mediaremote-adapter", URL(string: "https://github.com/ejbills/mediaremote-adapter")!),
        ("swift-log", URL(string: "https://github.com/apple/swift-log")!),
    ]

    private var aboutView: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 4) {
                    Text("NemoNotch \(appVersionString)")
                        .font(.title3).fontWeight(.semibold)
                        .textSelection(.enabled)
                    Text("settings.about.tagline")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 18) {
                    Link("settings.about.github", destination: Self.githubURL)
                    Link("settings.about.check_updates", destination: Self.releasesURL)
                    Link("settings.about.report_issue", destination: Self.issuesURL)
                }
                .font(.callout)

                Divider().padding(.vertical, 2)

                VStack(spacing: 6) {
                    Text("settings.about.acknowledgements")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    ForEach(Self.acknowledgements, id: \.name) { dep in
                        Link(dep.name, destination: dep.url)
                            .font(.callout)
                    }
                }

                Text("settings.about.copyright")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
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
                    if let icon = launcherService.icon(forBundleID: app.bundleIdentifier) {
                        Image(nsImage: icon)
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
        ScrollView {
            VStack(spacing: 10) {
                // Claude Code
                hookCard(
                    name: "Claude Code",
                    tint: Self.claudeTint,
                    isInstalled: aiService.claudeProvider.isHookInstalled,
                    logo: { ClaudeCrabIcon(size: 20, color: Self.claudeTint) },
                    onInstall: {
                        appSettings.claudeEnabled = true
                        aiService.claudeProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.claudeEnabled = false
                        aiService.claudeProvider.uninstallHooks()
                    }
                )

                // Gemini CLI
                hookCard(
                    name: "Gemini CLI",
                    tint: Self.geminiTint,
                    isInstalled: aiService.geminiProvider.isHookInstalled,
                    logo: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Self.geminiTint)
                    },
                    onInstall: {
                        appSettings.geminiEnabled = true
                        aiService.geminiProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.geminiEnabled = false
                        aiService.geminiProvider.uninstallHooks()
                    }
                )

                // opencode
                hookCard(
                    name: "opencode",
                    tint: Self.opencodeTint,
                    isInstalled: aiService.opencodeProvider.isHookInstalled,
                    logo: { OpencodeLogoIcon(size: 19, color: Self.opencodeTint) },
                    onInstall: {
                        appSettings.opencodeEnabled = true
                        aiService.opencodeProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.opencodeEnabled = false
                        aiService.opencodeProvider.uninstallHooks()
                    }
                )

                // zcode
                hookCard(
                    name: "zcode",
                    tint: Self.zcodeTint,
                    isInstalled: aiService.zcodeProvider.isHookInstalled,
                    logo: { ZcodeLogoIcon(size: 19, color: Self.zcodeTint) },
                    onInstall: {
                        appSettings.zcodeEnabled = true
                        aiService.zcodeProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.zcodeEnabled = false
                        aiService.zcodeProvider.uninstallHooks()
                    }
                )

                // Hermes Agent
                hookCard(
                    name: "Hermes Agent",
                    tint: Self.hermesTint,
                    isInstalled: hermesService.isHookInstalled,
                    logo: {
                        Image("HermesIcon")
                            .renderingMode(.original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    },
                    onInstall: {
                        appSettings.hermesEnabled = true
                        hermesService.installHooks()
                    },
                    onUninstall: {
                        appSettings.hermesEnabled = false
                        hermesService.uninstallHooks()
                    }
                )

                // OpenClaw — connect/disconnect/revoke semantics rather than hooks.
                providerCard(
                    name: "OpenClaw",
                    tint: Self.openClawTint,
                    isOn: openClawService.gatewayOnline,
                    onLabel: "settings.openclaw.connected \(openClawService.deviceIdShort)",
                    offLabel: "settings.openclaw.disconnected",
                    logo: {
                        Image(systemName: "brain")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Self.openClawTint)
                    },
                    actions: {
                        VStack(alignment: .trailing, spacing: 6) {
                            if appSettings.openClawEnabled {
                                Button("settings.openclaw.disconnect") {
                                    appSettings.openClawEnabled = false
                                    openClawService.disconnect()
                                }
                                .controlSize(.small)
                            } else {
                                Button("settings.openclaw.connect") {
                                    appSettings.openClawEnabled = true
                                    openClawService.connect()
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                            }

                            if openClawService.gatewayOnline {
                                Button("settings.openclaw.remove_device", role: .destructive) {
                                    openClawService.removeDeviceSelf()
                                }
                                .controlSize(.small)
                                .disabled(openClawService.isRemovingDevice)
                            }
                        }
                    }
                )

                Text("settings.hooks_description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                if aiService.serverRunning {
                    Label("settings.server_running", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - Provider Cards

    // Per-provider brand tints, tuned to read on both light and dark windows
    // (the Settings window follows the system appearance, unlike the dark-only
    // NotchTheme used inside the notch panel).
    private static let claudeTint = Color(red: 0.93, green: 0.49, blue: 0.19)
    private static let geminiTint = Color(red: 0.26, green: 0.52, blue: 0.96)
    private static let opencodeTint = Color(red: 0.30, green: 0.66, blue: 0.40)
    private static let zcodeTint = Color(red: 0.11, green: 0.44, blue: 0.96)
    private static let hermesTint = Color(red: 0.52, green: 0.43, blue: 0.92)
    private static let openClawTint = Color(red: 0.14, green: 0.62, blue: 0.60)

    /// A hook-based provider card with install / reinstall / uninstall actions.
    private func hookCard(
        name: String,
        tint: Color,
        isInstalled: Bool,
        @ViewBuilder logo: () -> some View,
        onInstall: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) -> some View {
        providerCard(
            name: name,
            tint: tint,
            isOn: isInstalled,
            onLabel: "settings.status.installed",
            offLabel: "settings.status.not_installed",
            logo: logo,
            actions: {
                VStack(alignment: .trailing, spacing: 6) {
                    if isInstalled {
                        Button("settings.reinstall", action: onInstall)
                            .controlSize(.small)
                        Button("settings.uninstall_hooks", role: .destructive, action: onUninstall)
                            .controlSize(.small)
                    } else {
                        Button("settings.install_hooks", action: onInstall)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        )
    }

    /// Generic provider card shell: tinted logo chip + name + on/off status row
    /// + trailing actions. Used for both hook providers and OpenClaw.
    private func providerCard(
        name: String,
        tint: Color,
        isOn: Bool,
        onLabel: LocalizedStringKey,
        offLabel: LocalizedStringKey,
        @ViewBuilder logo: () -> some View,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(0.32), lineWidth: 1)
                )
                .frame(width: 40, height: 40)
                .overlay { logo() }

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isOn ? Color.green : Color.secondary)
                    Text(isOn ? onLabel : offLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            actions()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Notification List

    private var notificationListView: some View {
        Form {
            if !notificationService.isAXTrusted {
                Section {
                    PermissionCard(
                        icon: "exclamationmark.triangle.fill",
                        titleKey: "permission.accessibility.title",
                        detailKey: "permission.accessibility.detail",
                        status: .notDetermined,
                        primary: .settingsOnly,
                        openSettings: { notificationService.openAccessibilitySettings() }
                    )
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
                            if let icon = launcherService.icon(forBundleID: bundleID) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }
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
