import SwiftUI
import UniformTypeIdentifiers

/// 通知监控:AX 权限卡(未授权时)+ 受监控应用列表的增删。
struct NotificationListSettingsPage: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(LauncherService.self) var launcherService
    @Environment(NotificationService.self) var notificationService

    var body: some View {
        Form {
            if !notificationService.isAXTrusted {
                Section {
                    PermissionCard(
                        icon: "exclamationmark.triangle.fill",
                        titleKey: "permission.accessibility.title",
                        detailKey: "permission.accessibility.detail",
                        status: .notDetermined,
                        primary: .settingsOnly,
                        // Opens the pane *and* parks the drag guide beside it —
                        // Accessibility has no programmatic request API, so the
                        // user has to drop the app into the list themselves.
                        openSettings: { PermissionFlowController.shared.start(pane: .accessibility) }
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
