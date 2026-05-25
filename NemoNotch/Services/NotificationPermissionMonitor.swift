import AppKit
import UserNotifications

@MainActor
@Observable
final class NotificationPermissionMonitor {
    var status: UNAuthorizationStatus = .notDetermined

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        LogService.debug(
            "NotificationPermissionMonitor.refresh → \(status.rawValue)",
            category: "NotificationPermission"
        )
    }

    func request() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            await refresh()
        } catch {
            LogService.warn(
                "Notification authorization request failed: \(error)",
                category: "NotificationPermission"
            )
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
