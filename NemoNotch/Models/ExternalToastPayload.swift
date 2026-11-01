import Foundation

/// Wire schema for the external toast API (`POST /v1/toast`).
///
/// This is a **public contract** (see `docs/superpowers/specs/2026-11-01-external-toast-api-design.md`):
/// unknown fields must stay ignored, existing fields only gain optionals, and semantic
/// changes bump `schema`. Length limits are part of the contract — external data is
/// untrusted even with a valid token. `ExternalCardService` must not translate any of
/// this data: the request body *is* the whole card face, missing fields mean empty.
struct ExternalToastPayload: Equatable, Sendable {
    /// Contract version; currently always 1 after validation.
    let schema: Int
    /// Caller's display name (1–48 chars).
    let app: String
    /// Optional identity: same key refreshes the same card; absent = one-shot card.
    let key: String?
    let title: String
    let body: String?
    /// Parsed from `icon`: the SF Symbol name when `icon` is a valid `"sf:<name>"`, else nil.
    let iconSymbol: String?
    let jumpBundleId: String?
}

/// Validation failures for `/v1/toast` bodies. Order matters: malformed → schema →
/// app presence → `::` separator → lengths → title → body → jumpBundleId.
/// Icon degrades, never rejects.
enum ExternalToastRejection: Error, Equatable, Sendable {
    case malformedJSON
    case badSchemaVersion
    case appInvalid
    case appTooLong
    case keyTooLong
    case separatorInAppOrKey
    case titleInvalid
    case titleTooLong
    case bodyTooLong
    case jumpBundleIdTooLong

    /// Short English sentence for logs and the HTTP error body.
    var localizedDescription: String {
        switch self {
        case .malformedJSON: "Malformed JSON body"
        case .badSchemaVersion: "Unsupported schema version"
        case .appInvalid: "Missing or empty app"
        case .appTooLong: "app exceeds 48 characters"
        case .keyTooLong: "key exceeds 128 characters"
        case .separatorInAppOrKey: "app and key must not contain '::'"
        case .titleInvalid: "Missing or empty title"
        case .titleTooLong: "title exceeds 120 characters"
        case .bodyTooLong: "body exceeds 280 characters"
        case .jumpBundleIdTooLong: "jumpBundleId exceeds 255 characters"
        }
    }
}

/// The card-face content an external push contributes to `CompletionItem`.
struct ExternalCardContent: Equatable, Sendable {
    let app: String
    let title: String
    let body: String?
    let jumpBundleId: String?
}

private struct RawExternalToast: Decodable {
    let schema: Int?
    let app: String?
    let key: String?
    let title: String?
    let body: String?
    let icon: String?
    let jumpBundleId: String?
}

extension ExternalToastPayload {
    private static let separator = "::"

    /// Decode + validate a `/v1/toast` body. Unknown JSON fields are ignored by the
    /// decoder (forward compatibility). Pure function, no MainActor.
    static func parse(_ data: Data) -> Result<ExternalToastPayload, ExternalToastRejection> {
        let raw: RawExternalToast
        do {
            raw = try JSONDecoder().decode(RawExternalToast.self, from: data)
        } catch {
            return .failure(.malformedJSON)
        }

        guard raw.schema == 1 else { return .failure(.badSchemaVersion) }

        guard let app = raw.app, !app.isEmpty else { return .failure(.appInvalid) }
        if app.contains(separator) {
            return .failure(.separatorInAppOrKey)
        }
        if let key = raw.key, key.contains(separator) {
            return .failure(.separatorInAppOrKey)
        }

        if app.count > 48 {
            return .failure(.appTooLong)
        }
        if let key = raw.key, key.count > 128 {
            return .failure(.keyTooLong)
        }

        guard let title = raw.title, !title.isEmpty else { return .failure(.titleInvalid) }
        if title.count > 120 {
            return .failure(.titleTooLong)
        }

        if let body = raw.body, body.count > 280 {
            return .failure(.bodyTooLong)
        }

        if let jumpBundleId = raw.jumpBundleId, jumpBundleId.count > 255 {
            return .failure(.jumpBundleIdTooLong)
        }

        return .success(ExternalToastPayload(
            schema: 1,
            app: app,
            key: (raw.key?.isEmpty == false) ? raw.key : nil,
            title: title,
            body: raw.body,
            iconSymbol: Self.symbolName(fromIcon: raw.icon),
            jumpBundleId: raw.jumpBundleId
        ))
    }

    /// Only `"sf:<name>"` (non-empty name) is a valid icon; anything else degrades to nil.
    private static func symbolName(fromIcon icon: String?) -> String? {
        guard let icon, icon.hasPrefix("sf:") else { return nil }
        let name = icon.dropFirst(3)
        return name.isEmpty ? nil : String(name)
    }

    /// Card identity for the toast queue: keyed pushes share `ext:<app>::<key>`
    /// (same card refreshed); keyless pushes get a fresh unique id every call
    /// (each push is its own one-shot card).
    func cardKey(makeUniqueID: () -> String = { UUID().uuidString }) -> String {
        if let key, !key.isEmpty {
            return "ext:\(app)\(Self.separator)\(key)"
        }
        return "ext:\(app)\(Self.separator)\(makeUniqueID())"
    }
}
