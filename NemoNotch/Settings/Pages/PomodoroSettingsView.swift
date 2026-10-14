import KeyboardShortcuts
import SwiftUI
import UserNotifications

struct PomodoroSettingsView: View {
    @Environment(AppSettings.self) var appSettings

    private let workOptions: [TimeInterval] = [5, 10, 15, 20, 25, 30, 45, 60].map { $0 * 60 }
    private let breakOptions: [TimeInterval] = [3, 5, 7, 10, 15, 20].map { $0 * 60 }
    private let longBreakOptions: [TimeInterval] = [10, 15, 20, 25, 30].map { $0 * 60 }
    private let intervalOptions: [Int] = [3, 4, 5, 6]

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("settings.pomodoro.title") {
                Picker("settings.pomodoro.workDuration", selection: $settings.pomodoroWorkDuration) {
                    ForEach(workOptions, id: \.self) { interval in
                        Text(durationLabel(interval)).tag(interval)
                    }
                }

                Picker("settings.pomodoro.shortBreakDuration", selection: $settings.pomodoroShortBreakDuration) {
                    ForEach(breakOptions, id: \.self) { interval in
                        Text(durationLabel(interval)).tag(interval)
                    }
                }

                Picker("settings.pomodoro.longBreakDuration", selection: $settings.pomodoroLongBreakDuration) {
                    ForEach(longBreakOptions, id: \.self) { interval in
                        Text(durationLabel(interval)).tag(interval)
                    }
                }

                Picker("settings.pomodoro.longBreakInterval", selection: $settings.pomodoroLongBreakInterval) {
                    ForEach(intervalOptions, id: \.self) { n in
                        Text(String(format: String(localized: "settings.pomodoro.longBreakInterval.unit"), n)).tag(n)
                    }
                }

                Toggle("settings.pomodoro.soundEnabled", isOn: $settings.pomodoroSoundEnabled)
                Toggle("settings.pomodoro.notificationEnabled", isOn: $settings.pomodoroNotificationEnabled)
            }

            Section("settings.pomodoro.hotkeyHeader") {
                HStack {
                    Text("settings.pomodoro.hotkey.openTab")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .openPomodoro)
                }
                HStack {
                    Text("settings.pomodoro.hotkey.quickStart")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .openQuickStart)
                }
            }

            Section("settings.pomodoro.permissionHeader") {
                PermissionRow()
            }
        }
        .formStyle(.grouped)
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return String(format: String(localized: "settings.pomodoro.minutes"), minutes)
    }
}

private struct PermissionRow: View {
    @Environment(NotificationPermissionMonitor.self) var monitor

    var body: some View {
        if monitor.status == .authorized {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("settings.pomodoro.permission.granted")
                    .foregroundStyle(NotchTheme.textSecondary)
            }
        } else {
            PermissionCard(
                icon: "bell.badge",
                titleKey: "permission.notification.title",
                detailKey: "permission.notification.detail",
                status: monitor.status == .denied ? .denied : .notDetermined,
                primary: .programmatic { Task { await monitor.request() } },
                openSettings: { monitor.openSystemSettings() }
            )
        }
    }
}
