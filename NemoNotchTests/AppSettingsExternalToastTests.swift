import Foundation
@testable import NemoNotch
import Testing

/// `externalToastEnabled` persistence. Runs against `UserDefaults.standard`
/// (shared with the real app's bundle id), so the key is restored.
@MainActor
@Suite(.serialized)
struct AppSettingsExternalToastTests {
    private static let key = AppSettings.externalToastEnabledKey

    private func withCleanKey(_ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer { UserDefaults.standard.set(saved, forKey: Self.key) }
        UserDefaults.standard.removeObject(forKey: Self.key)
        body()
    }

    @Test func externalToastDefaultsOn() {
        withCleanKey {
            let settings = AppSettings()
            #expect(settings.externalToastEnabled == true)
        }
    }

    @Test func externalToastPersistsOff() {
        withCleanKey {
            let settings = AppSettings()
            settings.externalToastEnabled = false
            let reloaded = AppSettings()
            #expect(reloaded.externalToastEnabled == false)
        }
    }
}
