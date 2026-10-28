import Foundation

/// A usage-quota source.
enum QuotaProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case gemini
    case zcode

    /// Brand name shown as the section header (verbatim, not localized).
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .zcode: "ZCode"
        }
    }
}

/// Status of a provider's OAuth credential / quota fetch.
enum CredentialStatus: Equatable, Sendable {
    case valid
    case expired
    case notFound
    case parseError
    /// Keychain item exists but this app isn't authorized to read it yet.
    /// Surfaces a "Authorize" button rather than auto-prompting.
    case needsAuthorization
    /// Claude's usage snapshot file (`~/.claude/usage-snapshot.json`, written
    /// by claude-hud) is absent — claude-hud isn't installed/configured, or it
    /// has never written a snapshot.
    case snapshotMissing
    /// The snapshot exists but its `updated_at` is older than the fresh
    /// interval: no Claude session has rendered the statusline recently.
    /// Stale percentages are withheld (no tiers), not shown.
    case snapshotStale
}

/// A usage rolling-window. Claude uses named windows (localized labels);
/// Codex uses `.rolling` carrying the window length in minutes.
enum QuotaWindow: Hashable, Sendable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
    case rolling(minutes: Int)
    /// Gemini per-model daily quota; carries a short display label (e.g. "2.5 Pro").
    case gemini(label: String)
}

/// A single quota tier: utilization (0...100) + when it resets.
struct QuotaTier: Equatable, Sendable {
    let window: QuotaWindow
    let utilization: Double
    let resetsAt: Date?
}

extension QuotaTier {
    /// Carries a future reset time forward from a cached tier when the fresh
    /// data omits `resetsAt` (some endpoints drop it at 100% utilization).
    /// Borrowed from CodexBar's `RateWindow.backfillingResetTime`.
    func backfillingReset(from cached: QuotaTier?, now: Date = Date()) -> QuotaTier {
        guard resetsAt == nil, let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        return QuotaTier(window: window, utilization: utilization, resetsAt: cachedReset)
    }
}

/// Parsed usage quota for one provider (or an error state).
struct ProviderUsageQuota: Equatable, Sendable {
    let provider: QuotaProvider
    let status: CredentialStatus
    let tiers: [QuotaTier]
    let fetchedAt: Date
    let errorMessage: String?

    init(
        provider: QuotaProvider,
        status: CredentialStatus,
        tiers: [QuotaTier] = [],
        fetchedAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.provider = provider
        self.status = status
        self.tiers = tiers
        self.fetchedAt = fetchedAt
        self.errorMessage = errorMessage
    }
}

/// OAuth credential extracted from Keychain / credentials file.
struct UsageCredential: Equatable, Sendable {
    let token: String?
    let accountID: String?
    let status: CredentialStatus
    let message: String?

    init(token: String?, accountID: String? = nil, status: CredentialStatus, message: String? = nil) {
        self.token = token
        self.accountID = accountID
        self.status = status
        self.message = message
    }
}

/// Gemini CLI auth mode from `~/.gemini/settings.json` (`security.auth.selectedType`).
enum GeminiAuthType: String, Sendable {
    case oauthPersonal = "oauth-personal"
    case apiKey = "api-key"
    case vertexAI = "vertex-ai"
    case unknown
}

/// OAuth credential read from `~/.gemini/oauth_creds.json`.
struct GeminiOAuthCredential: Equatable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiryDate: Date?
    let status: CredentialStatus
    let message: String?

    init(
        accessToken: String?,
        refreshToken: String?,
        expiryDate: Date?,
        status: CredentialStatus,
        message: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDate = expiryDate
        self.status = status
        self.message = message
    }
}

enum UsageCredentialParser {
    /// Parses Codex's `~/.codex/auth.json`:
    /// `{ "auth_mode": "chatgpt", "tokens": { "access_token": "...", "account_id": "..." } }`.
    static func parseCodexCredentials(data: Data, now: Date = Date()) throws -> UsageCredential {
        let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        guard auth.authMode == "chatgpt" else {
            return UsageCredential(
                token: nil,
                status: .notFound,
                message: "Codex not using OAuth (auth_mode != chatgpt)"
            )
        }
        guard let token = auth.tokens?.accessToken, !token.isEmpty else {
            return UsageCredential(token: nil, status: .parseError, message: "Codex access_token missing")
        }
        return UsageCredential(token: token, accountID: auth.tokens?.accountID, status: .valid)
    }

    /// Parses `~/.gemini/oauth_creds.json`:
    /// `{ "access_token": "...", "refresh_token": "...", "expiry_date": <ms epoch> }`.
    /// Status is `.valid` when any usable token exists, `.notFound` when none do,
    /// `.parseError` when the payload isn't a JSON object. The service decides
    /// whether to refresh based on `expiryDate`.
    static func parseGeminiCredentials(data: Data, now: Date = Date()) throws -> GeminiOAuthCredential {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            return GeminiOAuthCredential(
                accessToken: nil, refreshToken: nil, expiryDate: nil,
                status: .parseError, message: "Gemini credentials JSON is not an object"
            )
        }
        let access = (root["access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let refresh = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var expiry: Date?
        if let ms = root["expiry_date"] as? Double {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = root["expiry_date"] as? Int {
            expiry = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        guard access != nil || refresh != nil else {
            return GeminiOAuthCredential(
                accessToken: nil, refreshToken: nil, expiryDate: nil,
                status: .notFound, message: "No Gemini tokens present"
            )
        }
        return GeminiOAuthCredential(
            accessToken: access, refreshToken: refresh, expiryDate: expiry, status: .valid
        )
    }
}

enum UsageQuotaParser {
    /// Parses Gemini's `retrieveUserQuota` response. Collapses each model's
    /// buckets to the lowest `remainingFraction` (most-constrained token type)
    /// and maps to `utilization = (1 - fraction) * 100`, descending.
    static func parseGeminiQuota(data: Data, fetchedAt: Date = Date()) throws -> ProviderUsageQuota {
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        let buckets = response.buckets ?? []

        var byModel: [String: (fraction: Double, reset: String?)] = [:]
        for bucket in buckets {
            guard let model = bucket.modelId, let fraction = bucket.remainingFraction else { continue }
            if let existing = byModel[model] {
                if fraction < existing.fraction {
                    byModel[model] = (fraction, bucket.resetTime)
                }
            } else {
                byModel[model] = (fraction, bucket.resetTime)
            }
        }

        // utilization descending = remaining fraction ascending; tie-break by model id.
        let tiers = byModel
            .sorted { lhs, rhs in
                lhs.value.fraction != rhs.value.fraction
                    ? lhs.value.fraction < rhs.value.fraction
                    : lhs.key < rhs.key
            }
            .map { model, info -> QuotaTier in
                let utilization = min(max((1 - info.fraction) * 100, 0), 100)
                return QuotaTier(
                    window: .gemini(label: geminiModelShortName(model)),
                    utilization: utilization,
                    resetsAt: info.reset.flatMap(parseResetDate)
                )
            }

        return ProviderUsageQuota(provider: .gemini, status: .valid, tiers: tiers, fetchedAt: fetchedAt)
    }

    /// `gemini-2.5-pro` → "2.5 Pro", `gemini-2.5-flash-lite` → "2.5 Flash Lite",
    /// unknown families fall back to the id minus the `gemini-` prefix.
    static func geminiModelShortName(_ modelId: String) -> String {
        let lower = modelId.lowercased()
        let version = modelId.split(separator: "-")
            .first { $0.contains(".") && $0.allSatisfy { $0.isNumber || $0 == "." } }
            .map(String.init)
        let family: String
        if lower.contains("flash-lite") {
            family = "Flash Lite"
        } else if lower.contains("flash") {
            family = "Flash"
        } else if lower.contains("pro") {
            family = "Pro"
        } else {
            return modelId.replacingOccurrences(of: "gemini-", with: "")
        }
        if let version {
            return "\(version) \(family)"
        }
        return family
    }

    static func parseCodexQuota(data: Data, fetchedAt: Date = Date()) throws -> ProviderUsageQuota {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let windows = [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow].compactMap(\.self)
        let tiers = windows.compactMap { window -> QuotaTier? in
            guard let used = window.usedPercent, let seconds = window.limitWindowSeconds else { return nil }
            return QuotaTier(
                window: .rolling(minutes: seconds / 60),
                utilization: used,
                resetsAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
        return ProviderUsageQuota(
            provider: .codex,
            status: .valid,
            tiers: CodexRateWindowNormalizer.order(tiers),
            fetchedAt: fetchedAt
        )
    }

    /// Robust ISO8601 parse. The live API returns 6-digit fractional seconds
    /// plus a `+00:00` offset (e.g. `2026-06-09T08:00:00.858062+00:00`).
    /// `ISO8601DateFormatter` with `.withFractionalSeconds` only accepts 3
    /// fractional digits, so we truncate to milliseconds before parsing.
    static func parseResetDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        if let truncated = truncateFractionalSeconds(value), let date = fractional.date(from: truncated) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// Trims fractional seconds to 3 digits: `...00.858062+00:00` → `...00.858+00:00`.
    private static func truncateFractionalSeconds(_ value: String) -> String? {
        guard let dot = value.firstIndex(of: ".") else { return nil }
        let afterDot = value.index(after: dot)
        var end = afterDot
        while end < value.endIndex, value[end].isNumber {
            end = value.index(after: end)
        }
        let digitCount = value.distance(from: afterDot, to: end)
        guard digitCount > 3 else { return nil }
        let keepEnd = value.index(afterDot, offsetBy: 3)
        return String(value[..<keepEnd]) + String(value[end...])
    }
}

enum UsageQuotaFormatter {
    enum CountdownResult: Equatable {
        case text(String)
        case reset
    }

    /// Formats time until `target` as `6d3h` / `4h12m` / `5m` / `<1m`, or `.reset` once past.
    static func countdown(until target: Date, now: Date = Date()) -> CountdownResult {
        let seconds = Int(target.timeIntervalSince(now))
        guard seconds > 0 else { return .reset }
        guard seconds >= 60 else { return .text("<1m") }

        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return .text(hours > 0 ? "\(days)d\(hours)h" : "\(days)d")
        }
        if hours > 0 {
            return .text(minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h")
        }
        return .text("\(minutes)m")
    }

    /// Short label for a rolling window of `minutes`:
    /// 300→"5h", 10080→"7d", 43200→"30d", else "Nd"/"Nh"/"Nm".
    static func windowLabel(minutes: Int) -> String {
        if minutes % 1440 == 0 {
            return "\(minutes / 1440)d"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }
}

/// Orders Codex rate windows so the short "session" window (300 min) precedes
/// the "weekly" window (10080 min); other lengths keep their relative order at
/// the end. Borrowed from CodexBar's CodexRateWindowNormalizer.
enum CodexRateWindowNormalizer {
    private enum Role { case session, weekly, other }

    private static func role(_ tier: QuotaTier) -> Role {
        guard case let .rolling(minutes) = tier.window else { return .other }
        switch minutes {
        case 300: return .session
        case 10080: return .weekly
        default: return .other
        }
    }

    private static func rank(_ role: Role) -> Int {
        switch role {
        case .session: 0
        case .weekly: 1
        case .other: 2
        }
    }

    static func order(_ tiers: [QuotaTier]) -> [QuotaTier] {
        tiers.enumerated()
            .sorted { lhs, rhs in
                let lr = rank(role(lhs.element)), rr = rank(role(rhs.element))
                return lr != rr ? lr < rr : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// Parses the usage snapshot written by claude-hud (`~/.claude/usage-snapshot.json`).
/// Claude Code pushes server-side `rate_limits` to statusline scripts over stdin;
/// claude-hud mirrors them into that file (atomic write, 0600, refreshed at most
/// every 30s while a Claude session renders its statusline; not written while
/// no session runs). This is Claude's ONLY quota source — reading it touches no
/// credential and makes no network call.
enum ClaudeUsageSnapshotParser {
    /// A snapshot older than the rolling five-hour window describes a window
    /// that has already rolled over, so its percentages can't be trusted:
    /// treat it as "waiting for a session to refresh" instead of showing stale
    /// numbers.
    static let claudeSnapshotFreshInterval: TimeInterval = 5 * 3600

    static func parse(data: Data?, now: Date = Date()) -> ProviderUsageQuota {
        guard let data else {
            return ProviderUsageQuota(provider: .claude, status: .snapshotMissing, fetchedAt: now)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ProviderUsageQuota(
                provider: .claude, status: .parseError, fetchedAt: now,
                errorMessage: "Usage snapshot is not a JSON object"
            )
        }
        guard let updatedAt = (root["updated_at"] as? String).flatMap(UsageQuotaParser.parseResetDate),
              now.timeIntervalSince(updatedAt) <= claudeSnapshotFreshInterval
        else {
            return ProviderUsageQuota(provider: .claude, status: .snapshotStale, fetchedAt: now)
        }
        let tiers = [
            tier(root["five_hour"], window: .fiveHour),
            tier(root["seven_day"], window: .sevenDay),
        ].compactMap(\.self)
        guard !tiers.isEmpty else {
            return ProviderUsageQuota(
                provider: .claude, status: .parseError, fetchedAt: now,
                errorMessage: "Usage snapshot has no usable window"
            )
        }
        // A tier whose server-side reset already passed describes a window that
        // rolled over after the snapshot's last write: its percentages are old
        // even while updated_at is still within the interval (no session has
        // rendered since the rollover). updated_at is only the fallback
        // freshness signal for tiers without a resets_at.
        if tiers.contains(where: { $0.resetsAt.map { $0 < now } == true }) {
            return ProviderUsageQuota(provider: .claude, status: .snapshotStale, fetchedAt: now)
        }
        return ProviderUsageQuota(provider: .claude, status: .valid, tiers: tiers, fetchedAt: now)
    }

    /// `{"used_percentage": 0-100, "resets_at": ISO8601-or-null}` → tier.
    /// An unparseable `resets_at` yields nil, never a dropped window.
    private static func tier(_ raw: Any?, window: QuotaWindow) -> QuotaTier? {
        guard let entry = raw as? [String: Any],
              let used = entry["used_percentage"] as? Double, used.isFinite
        else { return nil }
        return QuotaTier(
            window: window,
            utilization: used,
            resetsAt: (entry["resets_at"] as? String).flatMap(UsageQuotaParser.parseResetDate)
        )
    }
}

// MARK: - Wire decoding

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?
    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexWindow: Decodable {
    let usedPercent: Double?
    let resetAt: Int?
    let limitWindowSeconds: Int?
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}

private struct CodexAuthFile: Decodable {
    let authMode: String?
    let tokens: CodexAuthTokens?
    enum CodingKeys: String, CodingKey { case authMode = "auth_mode"
        case tokens
    }
}

private struct CodexAuthTokens: Decodable {
    let accessToken: String?
    let accountID: String?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"
        case accountID = "account_id"
    }
}

private struct GeminiQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]?
}

private struct GeminiQuotaBucket: Decodable {
    let modelId: String?
    let tokenType: String?
    let remainingFraction: Double?
    let resetTime: String?
}
