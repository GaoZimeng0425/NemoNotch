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
    /// Parsed from `icon` (`sf:` / `ai:` / `app:`); nil when absent or unrecognised.
    let icon: ExternalToastIcon?
    let jumpBundleId: String?
    /// Optional click target: an absolute URL (deep link or web page) opened on click;
    /// wins over `jumpBundleId`, which stays the fallback when the URL cannot be opened.
    /// Already trimmed; empty/whitespace input is normalised to nil.
    let jumpURL: String?
    /// Ring color class (Herdr mod and friends). nil = rainbow ring, as before.
    var tone: ExternalToastTone?
    /// Herdr agent address (`t7`, `vps/t7`); a click focuses that agent in Herdr.
    var herdrTerminal: String?
    /// `.close` removes the keyed card; its `title` is "" and never shown.
    var action: ExternalToastAction = .show
    /// When the card leaves on its own; nil = the queue's default timer.
    var expiry: ExternalToastExpiry?
}

/// The card's leading mark, parsed from the wire `icon` string.
enum ExternalToastIcon: Equatable, Hashable, Sendable {
    /// `sf:<name>` — an SF Symbol (unknown names fall back at render time).
    case symbol(String)
    /// `ai:<claude|gemini|opencode|zcode>` — NemoNotch's own brand mark for that CLI.
    case ai(AISource)
    /// `app:<bundle id>` — that installed app's icon (falls back when not installed).
    case app(bundleID: String)
}

/// Optional ring color class — the four reminder tones, never a free color.
enum ExternalToastTone: String, Sendable {
    case done, decide, approve, error

    /// Representative kind carrying the tone onto the card (ring only — external
    /// cards never render `kind.verb`).
    var reminderKind: ReminderKind {
        switch self {
        case .done: .turnDone
        case .decide: .needsDecision
        case .approve: .needsApproval
        case .error: .agentError
        }
    }
}

enum ExternalToastAction: String, Sendable {
    case show, close
}

/// `expiresAt`: an absolute deadline (Unix seconds) or `"infinity"` (never expires).
enum ExternalToastExpiry: Equatable, Sendable {
    case at(Date)
    case infinity
}

/// Validation failures for `/v1/toast` bodies. Order matters: malformed → schema →
/// app presence → `::` separator → lengths → jumpBundleId → jumpURL → action →
/// (show only) title → body → tone → herdrTerminal → expiresAt.
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
    case jumpURLInvalid
    case jumpURLTooLong
    case actionInvalid
    case closeRequiresKey
    case toneInvalid
    case herdrTerminalInvalid
    case expiresAtInvalid
    case expiresAtInPast
    case infinityRequiresKey

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
        case .jumpURLInvalid: "jumpURL must be an absolute URL with a scheme other than file"
        case .jumpURLTooLong: "jumpURL exceeds 2048 characters"
        case .actionInvalid: "action must be \"show\" or \"close\""
        case .closeRequiresKey: "action close requires a key"
        case .toneInvalid: "tone must be one of done, decide, approve, error"
        case .herdrTerminalInvalid: "herdrTerminal must look like t7 or machine/t7"
        case .expiresAtInvalid: "expiresAt must be Unix seconds or \"infinity\""
        case .expiresAtInPast: "expiresAt is in the past"
        case .infinityRequiresKey: "expiresAt infinity requires a key"
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
    let jumpURL: String?
    let tone: String?
    let herdrTerminal: String?
    let action: String?
    let expiresAt: RawExpiry?
}

/// `expiresAt` is a number or a string; anything else must reach validation as
/// `.invalid` instead of failing the whole body as malformed JSON.
private enum RawExpiry: Decodable {
    case seconds(Double)
    case text(String)
    case invalid

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            _ = bool
            self = .invalid
        } else if let seconds = try? container.decode(Double.self) {
            self = .seconds(seconds)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .invalid
        }
    }
}

extension ExternalToastPayload {
    private static let separator = "::"

    /// Decode + validate a `/v1/toast` body. Unknown JSON fields are ignored by the
    /// decoder (forward compatibility). Pure function, no MainActor.
    static func parse(_ data: Data, now: Date = Date()) -> Result<ExternalToastPayload, ExternalToastRejection> {
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

        if let jumpBundleId = raw.jumpBundleId, jumpBundleId.count > 255 {
            return .failure(.jumpBundleIdTooLong)
        }

        // jumpURL: trimmed; empty = absent. Must be an absolute URL (scheme present) and
        // never `file:` — a notification card must not open local files or scripts.
        // Passed through verbatim otherwise (no semantic translation); callers percent-encode.
        let trimmedJumpURL = raw.jumpURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jumpURL = trimmedJumpURL, !jumpURL.isEmpty {
            if jumpURL.count > 2048 {
                return .failure(.jumpURLTooLong)
            }
            guard let url = URL(string: jumpURL),
                  let scheme = url.scheme, !scheme.isEmpty,
                  scheme.lowercased() != "file"
            else {
                return .failure(.jumpURLInvalid)
            }
        }

        let key = (raw.key?.isEmpty == false) ? raw.key : nil
        let jumpURL = (trimmedJumpURL?.isEmpty == false) ? trimmedJumpURL : nil

        // action: close only needs app + key (title is never shown); show keeps
        // every original requirement.
        var action = ExternalToastAction.show
        if let rawAction = raw.action {
            guard let parsed = ExternalToastAction(rawValue: rawAction) else { return .failure(.actionInvalid) }
            action = parsed
        }
        if action == .close {
            guard key != nil else { return .failure(.closeRequiresKey) }
            var closing = ExternalToastPayload(
                schema: 1, app: app, key: key, title: "", body: nil, icon: nil,
                jumpBundleId: nil, jumpURL: nil
            )
            closing.action = .close
            return .success(closing)
        }

        guard let title = raw.title, !title.isEmpty else { return .failure(.titleInvalid) }
        if title.count > 120 {
            return .failure(.titleTooLong)
        }

        if let body = raw.body, body.count > 280 {
            return .failure(.bodyTooLong)
        }

        var payload = ExternalToastPayload(
            schema: 1,
            app: app,
            key: key,
            title: title,
            body: raw.body,
            icon: Self.icon(fromWire: raw.icon),
            jumpBundleId: raw.jumpBundleId,
            jumpURL: jumpURL
        )
        do {
            payload.tone = try Self.tone(raw.tone)
            payload.herdrTerminal = try Self.herdrTerminal(raw.herdrTerminal)
            payload.expiry = try Self.expiry(raw.expiresAt, hasKey: key != nil, now: now)
        } catch {
            return .failure(error)
        }
        return .success(payload)
    }

    private static func tone(_ raw: String?) throws(ExternalToastRejection) -> ExternalToastTone? {
        guard let raw else { return nil }
        guard let tone = ExternalToastTone(rawValue: raw) else { throw .toneInvalid }
        return tone
    }

    /// `t7` or `machine/t7`; never starts with `-` (it ends up as a CLI argument).
    private static func herdrTerminal(_ raw: String?) throws(ExternalToastRejection) -> String? {
        guard let raw else { return nil }
        let pattern = #"^([A-Za-z0-9._-]{1,64}/)?[A-Za-z0-9]{1,32}$"#
        guard raw.first != "-", raw.range(of: pattern, options: .regularExpression) != nil else {
            throw .herdrTerminalInvalid
        }
        return raw
    }

    /// `expiresAt` may be at most 30 days ahead.
    static let maxLifetime: TimeInterval = 30 * 86400

    private static func expiry(
        _ raw: RawExpiry?, hasKey: Bool, now: Date
    ) throws(ExternalToastRejection) -> ExternalToastExpiry? {
        switch raw {
        case nil:
            return nil
        case let .seconds(seconds):
            let deadline = Date(timeIntervalSince1970: seconds)
            guard deadline > now else { throw .expiresAtInPast }
            // Upper bound: a huge value overflows Duration in the expiry sleep
            // (1e19 traps the app) and would make a keyless card effectively permanent.
            guard deadline <= now.addingTimeInterval(maxLifetime) else { throw .expiresAtInvalid }
            return .at(deadline)
        case .text("infinity"):
            // Without a key nothing could ever close the card.
            guard hasKey else { throw .infinityRequiresKey }
            return .infinity
        case .text, .invalid:
            throw .expiresAtInvalid
        }
    }

    /// `sf:<name>`, `ai:<source>` or `app:<bundle id>` (non-empty value); anything
    /// else degrades to nil — a bad icon never rejects the card.
    static func icon(fromWire icon: String?) -> ExternalToastIcon? {
        guard let icon, let colon = icon.firstIndex(of: ":") else { return nil }
        let value = String(icon[icon.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch icon[..<colon] {
        case "sf":
            return .symbol(value)
        case "ai":
            return AISource(rawValue: value).map(ExternalToastIcon.ai)
        case "app":
            let pattern = #"^[A-Za-z0-9.-]{1,255}$"#
            guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
            return .app(bundleID: value)
        default:
            return nil
        }
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
