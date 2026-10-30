import SwiftUI
import UniformTypeIdentifiers

/// 通知中心 → toast:总开关、读库状态(完全磁盘访问权限卡)、转 toast 的应用列表。
struct NotificationListSettingsPage: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(LauncherService.self) var launcherService
    @Environment(NotificationToastService.self) var notificationToast

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section {
                Toggle("settings.notificationToast.enabled", isOn: $settings.notificationToastEnabled)
                    .onChange(of: appSettings.notificationToastEnabled) { notificationToast.settingsChanged() }
            } footer: {
                Text("settings.monitored_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statusSection

            Section("settings.monitored_apps") {
                if appSettings.notificationToastApps.isEmpty {
                    Text("settings.no_monitored_apps")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appSettings.notificationToastApps, id: \.self) { bundleID in
                        HStack {
                            if let icon = launcherService.icon(forBundleID: bundleID) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }
                            VStack(alignment: .leading) {
                                Text(verbatim: NotificationToastService.displayName(bundleID: bundleID))
                                Text(bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                appSettings.notificationToastApps.removeAll { $0 == bundleID }
                                notificationToast.settingsChanged()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button("settings.add_monitored_app", action: addApp)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch notificationToast.status {
        case .noAccess:
            Section {
                PermissionCard(
                    icon: "exclamationmark.triangle.fill",
                    titleKey: "permission.fullDiskAccess.notifications.title",
                    detailKey: "permission.fullDiskAccess.notifications.detail",
                    status: .notDetermined,
                    primary: .settingsOnly,
                    // Full Disk Access has no request API: open the pane and park
                    // the drag guide beside it.
                    openSettings: { PermissionFlowController.shared.start(pane: .fullDiskAccess) },
                    style: .adaptive
                )
                .padding(.vertical, 4)
            }
        case let .unavailable(reason):
            Section {
                Text("settings.notificationToast.unavailable")
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle, .ok:
            EmptyView()
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "settings.select_monitored_app")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              !appSettings.notificationToastApps.contains(bundleID)
        else { return }
        appSettings.notificationToastApps.append(bundleID)
        notificationToast.settingsChanged()
    }
}
