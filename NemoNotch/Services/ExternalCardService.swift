import Foundation

/// What `POST /v1/toast` gets back for a body: accepted (card shown, or the
/// feature is off and the push was silently acknowledged) or rejected with
/// the validation reason.
enum ExternalToastAcceptance: Equatable, Sendable {
    case ok
    case rejected(ExternalToastRejection)
}

/// The single landing point for external-app toasts (`POST /v1/toast`).
///
/// Responsibilities, in order: feature gate → decode + validate (pure,
/// `ExternalToastPayload.parse`) → assemble a `CompletionItem` → hand it to
/// the toast pipeline through `present`.
@MainActor
final class ExternalCardService {
    private let settings: AppSettings
    private let present: (CompletionItem) -> Void

    init(settings: AppSettings, present: @escaping (CompletionItem) -> Void) {
        self.settings = settings
        self.present = present
        LogService.info("ExternalCardService init", category: "ExternalCard")
    }

    /// Gate → parse → present. With the feature off, any body is acknowledged
    /// `.ok` without parsing — the caller did nothing wrong, we're just not
    /// showing cards.
    func handle(body: Data) -> ExternalToastAcceptance {
        guard settings.externalToastEnabled else {
            LogService.debug("External toast ignored — feature disabled", category: "ExternalCard")
            return .ok
        }
        switch ExternalToastPayload.parse(body) {
        case let .success(payload):
            let item = Self.makeItem(payload: payload)
            present(item)
            LogService.debug("External toast accepted: \(item.toastKey)", category: "ExternalCard")
            return .ok
        case let .failure(rejection):
            return .rejected(rejection)
        }
    }

    /// 1:1 projection of the validated payload onto the shared card model.
    /// Keyed pushes share `ext:<app>::<key>`; keyless ones get a fresh id per
    /// call so every push is its own card.
    static func makeItem(
        payload: ExternalToastPayload,
        makeUniqueID: () -> String = { UUID().uuidString }
    ) -> CompletionItem {
        var item = CompletionItem(name: payload.app, source: .external(iconSymbol: payload.iconSymbol))
        item.key = payload.cardKey(makeUniqueID: makeUniqueID)
        item.external = ExternalCardContent(
            app: payload.app,
            title: payload.title,
            body: payload.body,
            jumpBundleId: payload.jumpBundleId
        )
        item.jump = CompletionJump.make(hostPID: nil, hostBundleId: payload.jumpBundleId, tabLink: nil)
        return item
    }
}
