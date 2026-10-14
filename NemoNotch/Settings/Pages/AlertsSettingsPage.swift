import SwiftUI

/// 提醒与动效:完成闪光 / 蓝牙·日历·充电动效开关。
struct AlertsSettingsPage: View {
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        Form {
            Section("settings.completion_flash.header") {
                Toggle("settings.completion_flash.enabled", isOn: Binding(
                    get: { appSettings.completionFlashEnabled },
                    set: { appSettings.completionFlashEnabled = $0 }
                ))
                .toggleStyle(.switch)
            }

            Section("settings.event_alerts.header") {
                Toggle("settings.bluetooth_alerts.enabled", isOn: Binding(
                    get: { appSettings.bluetoothToastEnabled },
                    set: { appSettings.bluetoothToastEnabled = $0 }
                ))
                .toggleStyle(.switch)
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
        }
        .formStyle(.grouped)
    }
}
