import Foundation
@testable import NemoNotch
import Testing

/// `showExternalToast` must bypass the `completionFlashEnabled` gate and never
/// fire the glow pipeline. Runs against `UserDefaults.standard`, so the key it
/// touches is restored.
@MainActor
@Suite(.serialized)
struct CompletionFlashExternalEntryTests {
    private static let key = AppSettings.completionFlashEnabledKey

    private func withFlashDisabled(_ body: (CompletionFlashService) -> Void) {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer { UserDefaults.standard.set(saved, forKey: Self.key) }
        UserDefaults.standard.set(false, forKey: Self.key)

        let service = CompletionFlashService(
            store: AISessionStore(),
            registry: AgentMonitorRegistry(),
            settings: AppSettings()
        )
        body(service)
    }

    @Test("external toasts enter the row even with completionFlashEnabled off, without the glow")
    func externalEntryIgnoresFlashGate() {
        withFlashDisabled { service in
            var item = CompletionItem(name: "Demo", source: .external(iconSymbol: nil))
            item.key = "ext:Demo::k1"
            service.showExternalToast(item)

            #expect(service.toasts.map(\.item.toastKey) == ["ext:Demo::k1"])
            #expect(service.flashLevel == 0)
            #expect(service.overlayVisible == false)
        }
    }
}
