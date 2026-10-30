import Foundation
@testable import NemoNotch
import Testing

/// Runs against `UserDefaults.standard` (shared with the real app's bundle
/// id), so every test restores the two keys it touches.
@MainActor
@Suite(.serialized)
struct AppSettingsNotificationToastTests {
    private static let keys = [AppSettings.notificationToastEnabledKey, AppSettings.notificationToastAppsKey]

    private func withCleanKeys(_ body: () -> Void) {
        let saved = Self.keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(Self.keys, saved) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        for key in Self.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        body()
    }

    @Test func notificationToastDefaults() {
        withCleanKeys {
            let settings = AppSettings()
            #expect(settings.notificationToastEnabled == false)
            #expect(settings.notificationToastApps == [
                "com.apple.mail", "com.tinyspeck.slackmacgap", "com.tencent.xinWeChat",
            ])
        }
    }

    @Test func notificationToastPersists() {
        withCleanKeys {
            let settings = AppSettings()
            settings.notificationToastEnabled = true
            settings.notificationToastApps = ["x"]
            let reloaded = AppSettings()
            #expect(reloaded.notificationToastEnabled == true)
            #expect(reloaded.notificationToastApps == ["x"])
        }
    }
}
