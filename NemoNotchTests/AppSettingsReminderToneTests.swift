import Foundation
@testable import NemoNotch
import Testing

/// `attentionToastEnabled` / `failureToastEnabled` persistence. Runs against
/// `UserDefaults.standard` (shared with the real app's bundle id), so the
/// keys are restored.
@MainActor
@Suite(.serialized)
struct AppSettingsReminderToneTests {
    private func withCleanKey(_ key: String, _ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        body()
    }

    @Test func attentionDefaultsOn() {
        withCleanKey(AppSettings.attentionToastEnabledKey) {
            #expect(AppSettings().attentionToastEnabled == true)
        }
    }

    @Test func attentionPersistsOff() {
        withCleanKey(AppSettings.attentionToastEnabledKey) {
            let settings = AppSettings()
            settings.attentionToastEnabled = false
            #expect(AppSettings().attentionToastEnabled == false)
        }
    }

    @Test func failureDefaultsOn() {
        withCleanKey(AppSettings.failureToastEnabledKey) {
            #expect(AppSettings().failureToastEnabled == true)
        }
    }

    @Test func failurePersistsOff() {
        withCleanKey(AppSettings.failureToastEnabledKey) {
            let settings = AppSettings()
            settings.failureToastEnabled = false
            #expect(AppSettings().failureToastEnabled == false)
        }
    }
}
