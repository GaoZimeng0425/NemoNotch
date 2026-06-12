import Foundation

/// A usage-quota source.
enum QuotaProvider: String, CaseIterable, Sendable {
    case claude
    case codex

    /// Brand name shown as the section header (verbatim, not localized).
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
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
}

/// A usage rolling-window. Claude uses named windows (localized labels);
/// Codex uses `.rolling` carrying the window length in minutes.
enum QuotaWindow: Hashable, Sendable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
    case rolling(minutes: Int)
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

enum UsageCredentialParser {
    /// Parses `~/.claude/.credentials.json` or the Keychain blob.
    /// Shape: `{ "claudeAiOauth": { "accessToken": "...", "expiresAt": <ms epoch> } }`.
    static func parseClaudeCredentials(data: Data, now: Date = Date()) throws -> UsageCredential {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            return UsageCredential(token: nil, status: .parseError, message: "Claude credentials JSON is not an object")
        }
        guard let entry = (root["claudeAiOauth"] ?? root["claude.ai_oauth"]) as? [String: Any] else {
            return UsageCredential(token: nil, status: .parseError, message: "No OAuth entry in Claude credentials")
        }
        guard let token = entry["accessToken"] as? String, !token.isEmpty else {
            return UsageCredential(token: nil, status: .parseError, message: "accessToken is empty or missing")
        }
        if let expiresAt = entry["expiresAt"], isExpired(expiresAt, now: now) {
            return UsageCredential(token: token, status: .expired, message: "OAuth token has expired")
        }
        return UsageCredential(token: token, status: .valid)
    }

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

    private static func isExpired(_ value: Any, now: Date) -> Bool {
        let raw: Double
        if let d = value as? Double { raw = d }
        else if let i = value as? Int { raw = Double(i) }
        else { return false }
        // Claude stores milliseconds (13 digits); normalize to seconds.
        let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds) < now
    }
}

enum UsageQuotaParser {
    static func parseClaudeCodeQuota(data: Data, fetchedAt: Date = Date()) throws -> ProviderUsageQuota {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let tiers: [QuotaTier] = [
            response.fiveHour.map { tier(.fiveHour, $0) },
            response.sevenDay.map { tier(.sevenDay, $0) },
            response.sevenDayOpus.map { tier(.sevenDayOpus, $0) },
            response.sevenDaySonnet.map { tier(.sevenDaySonnet, $0) },
        ].compactMap(\.self)
        return ProviderUsageQuota(provider: .claude, status: .valid, tiers: tiers, fetchedAt: fetchedAt)
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
        if let date = fractional.date(from: value) { return date }
        if let truncated = truncateFractionalSeconds(value), let date = fractional.date(from: truncated) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func tier(_ window: QuotaWindow, _ source: ClaudeUsageTier) -> QuotaTier {
        QuotaTier(window: window, utilization: source.utilization, resetsAt: source.resetsAt.flatMap(parseResetDate))
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
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
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

// MARK: - Wire decoding

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeUsageTier?
    let sevenDay: ClaudeUsageTier?
    let sevenDayOpus: ClaudeUsageTier?
    let sevenDaySonnet: ClaudeUsageTier?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

private struct ClaudeUsageTier: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

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
