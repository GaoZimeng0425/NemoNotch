import Foundation
@testable import NemoNotch
import Testing

/// `ExternalCardService` gate + assembly. Runs against `UserDefaults.standard`
/// (shared with the real app), so the one key touched is restored.
@MainActor
@Suite(.serialized)
struct ExternalCardServiceTests {
    private static let key = AppSettings.externalToastEnabledKey

    private func withSettings(_ enabled: Bool, _ body: (AppSettings) -> Void) {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        defer { UserDefaults.standard.set(saved, forKey: Self.key) }
        UserDefaults.standard.set(enabled, forKey: Self.key)
        body(AppSettings())
    }

    private func json(_ s: String) -> Data {
        s.data(using: .utf8)!
    }

    private func payload(
        app: String = "Demo",
        key: String? = nil,
        title: String = "下载完成",
        body: String? = "84 MB",
        iconSymbol: String? = "arrow.down.circle",
        jumpBundleId: String? = nil,
        jumpURL: String? = nil
    ) -> ExternalToastPayload {
        ExternalToastPayload(
            schema: 1, app: app, key: key, title: title,
            body: body, iconSymbol: iconSymbol, jumpBundleId: jumpBundleId, jumpURL: jumpURL
        )
    }

    @Test("gate open + valid JSON: presented exactly once with the payload's fields")
    func handleParsesAndPresents() {
        withSettings(true) { settings in
            var presented: [CompletionItem] = []
            let service = ExternalCardService(settings: settings) { presented.append($0) }
            let result = service.handle(body: json(
                #"{"schema":1,"app":"Demo","key":"dl-1","title":"下载完成","body":"84 MB","icon":"sf:arrow.down.circle"}"#
            ))
            #expect(result == .ok)
            #expect(presented.count == 1)
            let item = presented[0]
            #expect(item.name == "Demo")
            #expect(item.external?.title == "下载完成")
            #expect(item.external?.body == "84 MB")
            #expect(item.source == .external(iconSymbol: "arrow.down.circle"))
        }
    }

    @Test("gate open + malformed JSON: rejected, nothing presented")
    func handleRejectsBadPayload() {
        withSettings(true) { settings in
            var presented: [CompletionItem] = []
            let service = ExternalCardService(settings: settings) { presented.append($0) }
            let result = service.handle(body: json("not json"))
            #expect(result == .rejected(.malformedJSON))
            #expect(presented.isEmpty)
        }
    }

    @Test("gate closed: silent .ok even for malformed bodies (gate runs before parse)")
    func handleGateClosedIsSilentOk() {
        withSettings(false) { settings in
            var presented: [CompletionItem] = []
            let service = ExternalCardService(settings: settings) { presented.append($0) }
            let result = service.handle(body: json("not json"))
            #expect(result == .ok)
            #expect(presented.isEmpty)
        }
    }

    @Test("keyless pushes each get a unique card key (one-shot cards)")
    func keylessPushesGetUniqueCardKeys() {
        let base = payload(key: nil)
        let first = ExternalCardService.makeItem(payload: base, makeUniqueID: { "u1" })
        let second = ExternalCardService.makeItem(payload: base, makeUniqueID: { "u2" })
        #expect(first.toastKey != second.toastKey)
        #expect(first.toastKey == "ext:Demo::u1")
        #expect(second.toastKey == "ext:Demo::u2")
    }

    @Test("keyed pushes share one card key (same card refreshed)")
    func keyedPushesShareCardKey() {
        let first = ExternalCardService.makeItem(payload: payload(key: "dl-1"))
        let second = ExternalCardService.makeItem(payload: payload(key: "dl-1"))
        #expect(first.toastKey == second.toastKey)
        #expect(first.toastKey == "ext:Demo::dl-1")
    }

    @Test("jumpBundleId maps to a bundle-id-only jump; absent means no jump")
    func makeItemMapsJumpBundleId() {
        let jumping = ExternalCardService.makeItem(payload: payload(jumpBundleId: "com.me.demo"))
        #expect(jumping.jump?.hostBundleId == "com.me.demo")
        #expect(jumping.jump?.hostPID == nil)

        let bare = ExternalCardService.makeItem(payload: payload(jumpBundleId: nil))
        #expect(bare.jump == nil)
    }

    @Test("jumpURL maps to tabLink; alone it still yields a jump; with jumpBundleId both ride along")
    func makeItemMapsJumpURL() {
        let alone = ExternalCardService.makeItem(payload: payload(jumpURL: "pulse://alerts/1"))
        #expect(alone.jump?.tabLink == "pulse://alerts/1")
        #expect(alone.jump?.hostBundleId == nil)

        let both = ExternalCardService.makeItem(payload: payload(
            jumpBundleId: "com.me.pulse",
            jumpURL: "pulse://alerts/1"
        ))
        #expect(both.jump?.tabLink == "pulse://alerts/1")
        #expect(both.jump?.hostBundleId == "com.me.pulse")

        #expect(ExternalCardService.makeItem(payload: payload()).jump == nil)
    }
}
