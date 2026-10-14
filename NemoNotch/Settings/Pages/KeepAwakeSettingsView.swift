import SwiftUI

struct KeepAwakeSettingsView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(KeepAwakeService.self) var keepAwake

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("settings.keepawake.title") {
                Toggle("settings.keepawake.enable", isOn: Binding(
                    get: { keepAwake.isEnabled },
                    set: { on in Task { await keepAwake.setEnabled(on) } }
                ))
                .disabled(keepAwake.isBusy)

                statusRow

                if let error = keepAwake.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(NotchTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("settings.keepawake.optionsHeader") {
                Toggle("settings.keepawake.lidDisplayOff", isOn: $settings.keepAwakeLidDisplayOff)
                    .onChange(of: settings.keepAwakeLidDisplayOff) { _, enabled in
                        keepAwake.applyLidDisplayOffSetting(enabled)
                    }
                Text("settings.keepawake.lidDisplayOff.detail")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.textSecondary)

                Toggle("settings.keepawake.restoreOnQuit", isOn: $settings.keepAwakeRestoreOnQuit)
                Text("settings.keepawake.restoreOnQuit.detail")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
            }

            Section("settings.keepawake.aboutHeader") {
                Text("settings.keepawake.about.privilege")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
                Text("settings.keepawake.about.persistent")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
                HStack {
                    Text(verbatim: "sudo pmset -a disablesleep 0")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("settings.keepawake.copyCommand") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("sudo pmset -a disablesleep 0", forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .task { await keepAwake.refresh() }
    }

    @ViewBuilder
    private var statusRow: some View {
        if keepAwake.isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("settings.keepawake.status.authorizing")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
            }
        } else if keepAwake.isEnabled, !keepAwake.isOwned {
            // 系统里已经开着,但不是本 App 开的 —— 说清楚,免得用户困惑于
            // "我没开过 NemoNotch 的开关,它怎么是亮的"。
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("settings.keepawake.status.external")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
            }
        } else if keepAwake.isEnabled {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("settings.keepawake.status.on")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
            }
        }
    }
}
