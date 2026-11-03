import SwiftUI
import UserNotifications

/// 提醒与动效:完成闪光 / 蓝牙·日历·充电动效 / 审批等待提醒开关。
struct AlertsSettingsPage: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(NotificationPermissionMonitor.self) var notificationMonitor

    var body: some View {
        Form {
            Section("settings.completion_flash.header") {
                Toggle("settings.completion_flash.enabled", isOn: Binding(
                    get: { appSettings.completionFlashEnabled },
                    set: { appSettings.completionFlashEnabled = $0 }
                ))
                .toggleStyle(.switch)
                Text("settings.completion_flash.hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("settings.attention_toast.header") {
                Toggle("settings.attention_toast.enabled", isOn: Binding(
                    get: { appSettings.attentionToastEnabled },
                    set: { appSettings.attentionToastEnabled = $0 }
                ))
                .toggleStyle(.switch)
                Text("settings.attention_toast.hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("settings.failure_toast.header") {
                Toggle("settings.failure_toast.enabled", isOn: Binding(
                    get: { appSettings.failureToastEnabled },
                    set: { appSettings.failureToastEnabled = $0 }
                ))
                .toggleStyle(.switch)
            }

            Section("settings.external_toast.header") {
                Toggle("settings.external_toast.enabled", isOn: Binding(
                    get: { appSettings.externalToastEnabled },
                    set: { appSettings.externalToastEnabled = $0 }
                ))
                .toggleStyle(.switch)
                Text("settings.external_toast.hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ExternalToastGuideSection()
            }

            Section("settings.event_alerts.header") {
                Toggle("settings.bluetooth_alerts.enabled", isOn: Binding(
                    get: { appSettings.bluetoothToastEnabled },
                    set: { appSettings.bluetoothToastEnabled = $0 }
                ))
                .toggleStyle(.switch)
                // 只在已明确拒绝时提示;notDetermined 下开开关会正常弹系统
                // 授权框(那正是用户触发的时刻),不需要打扰。
                if appSettings.bluetoothToastEnabled, BluetoothService.isDenied {
                    Text("settings.bluetooth_alerts.no_permission")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("settings.calendar_alerts.enabled", isOn: Binding(
                    get: { appSettings.calendarDueFlashEnabled },
                    set: { appSettings.calendarDueFlashEnabled = $0 }
                ))
                .toggleStyle(.switch)
                Picker("settings.calendar_alerts.lead", selection: Binding(
                    get: { appSettings.calendarDueLeadMinutes },
                    set: { appSettings.calendarDueLeadMinutes = $0 }
                )) {
                    Text("settings.calendar_alerts.lead.at_start").tag(0)
                    Text("settings.calendar_alerts.lead.5min").tag(5)
                    Text("settings.calendar_alerts.lead.10min").tag(10)
                    Text("settings.calendar_alerts.lead.15min").tag(15)
                }
                Toggle("settings.charging_alerts.enabled", isOn: Binding(
                    get: { appSettings.chargingCapsuleEnabled },
                    set: { appSettings.chargingCapsuleEnabled = $0 }
                ))
                .toggleStyle(.switch)
            }

            Section("settings.waiting_reminder.header") {
                Toggle("settings.waiting_reminder.enabled", isOn: Binding(
                    get: { appSettings.waitingReminderEnabled },
                    set: { appSettings.waitingReminderEnabled = $0 }
                ))
                .toggleStyle(.switch)
                Picker("settings.waiting_reminder.minutes", selection: Binding(
                    get: { appSettings.waitingReminderMinutes },
                    set: { appSettings.waitingReminderMinutes = $0 }
                )) {
                    Text("settings.waiting_reminder.1min").tag(1)
                    Text("settings.waiting_reminder.2min").tag(2)
                    Text("settings.waiting_reminder.5min").tag(5)
                    Text("settings.waiting_reminder.10min").tag(10)
                    Text("settings.waiting_reminder.20min").tag(20)
                }
                // The grant button lived on the removed Pomodoro page; the
                // reminder is now its only user. Shown only once the user
                // turns the reminder on — never asked for unprompted.
                if appSettings.waitingReminderEnabled, notificationMonitor.status != .authorized {
                    PermissionCard(
                        icon: "bell.badge",
                        titleKey: "permission.notification.title",
                        detailKey: "permission.notification.detail",
                        status: notificationMonitor.status == .denied ? .denied : .notDetermined,
                        primary: .programmatic { Task { await notificationMonitor.request() } },
                        openSettings: { notificationMonitor.openSystemSettings() },
                        style: .adaptive
                    )
                    .padding(.vertical, 4)
                }
            }

            Section("settings.quota_alert.header") {
                Toggle("settings.quota_alert.enabled", isOn: Binding(
                    get: { appSettings.quotaAlertEnabled },
                    set: { appSettings.quotaAlertEnabled = $0 }
                ))
                .toggleStyle(.switch)
                Picker("settings.quota_alert.threshold", selection: Binding(
                    get: { appSettings.quotaAlertThreshold },
                    set: { appSettings.quotaAlertThreshold = $0 }
                )) {
                    ForEach([50, 60, 70, 80, 90, 100], id: \.self) { percent in
                        Text(verbatim: "\(percent)%").tag(percent)
                    }
                }
                if !appSettings.aiStatusFabEnabled {
                    Text("settings.quota_alert.needs_bar")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
