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

    private func external(_ key: String) -> CompletionItem {
        var item = CompletionItem(name: key, source: .external(iconSymbol: nil))
        item.key = "ext:Herdr::\(key)"
        return item
    }

    @Test("close removes a shown external card")
    func closeRemovesShownCard() {
        withFlashDisabled { service in
            service.showExternalToast(external("t1"))
            service.showExternalToast(external("t2"))
            service.closeExternalToast(key: "ext:Herdr::t1")
            #expect(service.toasts.map(\.item.toastKey) == ["ext:Herdr::t2"])
        }
    }

    @Test("close removes a card parked in the waiting pile, so it never comes back")
    func closeRemovesWaitingCard() {
        withFlashDisabled { service in
            for key in ["t1", "t2", "t3", "t4", "t5"] {
                service.showExternalToast(external(key))
            }
            #expect(!service.toasts.map(\.item.toastKey).contains("ext:Herdr::t1"))
            service.closeExternalToast(key: "ext:Herdr::t1")
            for toast in service.toasts {
                service.dismissToast(id: toast.id)
            }
            #expect(service.toasts.isEmpty)
        }
    }

    @Test("closing an unknown key changes nothing")
    func closeUnknownKeyIsNoop() {
        withFlashDisabled { service in
            service.showExternalToast(external("t1"))
            service.closeExternalToast(key: "ext:Herdr::nope")
            #expect(service.toasts.map(\.item.toastKey) == ["ext:Herdr::t1"])
        }
    }
}
