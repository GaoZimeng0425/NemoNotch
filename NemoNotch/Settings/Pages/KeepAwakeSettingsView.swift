import SwiftUI

struct KeepAwakeSettingsView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(KeepAwakeService.self) var keepAwake

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("settings.keepawake.title") {
                Toggle("settings.keepawake.idle.enable", isOn: $settings.keepAwakeIdleEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: settings.keepAwakeIdleEnabled) { _, enabled in
                        keepAwake.setIdleKeepAwake(enabled)
                    }
                Text("settings.keepawake.idle.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("settings.keepawake.enable", isOn: Binding(
                    get: { keepAwake.isEnabled },
                    set: { on in Task { await keepAwake.setEnabled(on) } }
                ))
                .toggleStyle(.switch)
                .disabled(keepAwake.isBusy)

                statusRow

                if let error = keepAwake.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let idleError = keepAwake.idleKeepAwakeError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(verbatim: idleError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            assertionsPanelSection

            Section("settings.keepawake.optionsHeader") {
                Toggle("settings.keepawake.lidDisplayOff", isOn: $settings.keepAwakeLidDisplayOff)
                    .toggleStyle(.switch)
                    .onChange(of: settings.keepAwakeLidDisplayOff) { _, enabled in
                        keepAwake.applyLidDisplayOffSetting(enabled)
                    }
                Text("settings.keepawake.lidDisplayOff.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("settings.keepawake.restoreOnQuit", isOn: $settings.keepAwakeRestoreOnQuit)
                    .toggleStyle(.switch)
                Text("settings.keepawake.restoreOnQuit.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.keepawake.aboutHeader") {
                Text("settings.keepawake.about.privilege")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("settings.keepawake.about.persistent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        // 面板数据 10s 一刷;`.task` 随视图离屏自动取消 —— 无 Timer 状态、无常驻轮询。
        .task {
            while !Task.isCancelled {
                keepAwake.refreshExternalAssertions()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - 「谁在阻止休眠」面板

    /// 两层如实展示:空闲层 = 外部 app 的断言(枚举而来,带归属与剩余时间);
    /// 合盖层 = `SleepDisabled` 全局开关状态(无归属者,只有开/关 + 是否我们开的)。
    private var assertionsPanelSection: some View {
        Section("settings.keepawake.panel.header") {
            if keepAwake.externalSummaries.isEmpty {
                Text("settings.keepawake.panel.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(keepAwake.externalSummaries, id: \.pid) { summary in
                    assertionRow(summary)
                }
            }
            Divider()
            HStack {
                Text("settings.keepawake.panel.clamshell")
                    .font(.caption)
                Spacer()
                clamshellStateText
                    .font(.caption)
                    .foregroundStyle(clamshellStateColor)
            }
        }
    }

    private func assertionRow(_ summary: ExternalSleepAssertionSummary) -> some View {
        let age = ExternalSleepAssertions.ageComponents(startedAt: summary.oldestStartedAt, now: Date.now)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: summary.processName + (summary.count > 1 ? " ×\(summary.count)" : ""))
                    .font(.caption.weight(.medium))
                if let remaining = ExternalSleepAssertions.remainingMinutes(summary.timeoutRemaining) {
                    Text("settings.keepawake.panel.remaining \(remaining)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Text("settings.keepawake.panel.age \(age.hours) \(age.minutes)")
                if let behalf = summary.onBehalfOfPID,
                   let name = keepAwake.externalOnBehalfNames[behalf] {
                    Text("settings.keepawake.panel.onBehalf \(name)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// 合盖层状态:开/关 + 归属。非我们开的用橙色提醒(来源不明,值得被看见)。
    private var clamshellStateText: Text {
        if keepAwake.isEnabled {
            return keepAwake.isOwned
                ? Text("settings.keepawake.panel.clamshell.owned")
                : Text("settings.keepawake.panel.clamshell.external")
        }
        return Text("settings.keepawake.panel.clamshell.off")
    }

    private var clamshellStateColor: Color {
        keepAwake.isEnabled && !keepAwake.isOwned ? .orange : .secondary
    }

    @ViewBuilder
    private var statusRow: some View {
        if keepAwake.isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("settings.keepawake.status.authorizing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if keepAwake.isEnabled, !keepAwake.isOwned {
            // 系统里已经开着,但不是本 App 开的 —— 说清楚,免得用户困惑于
            // "我没开过 NemoNotch 的开关,它怎么是亮的"。
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("settings.keepawake.status.external")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if keepAwake.isEnabled {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("settings.keepawake.status.on")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
