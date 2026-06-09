import Foundation

/// Status of the Claude OAuth credential / quota fetch.
enum CredentialStatus: Equatable, Sendable {
    case valid
    case expired
    case notFound
    case parseError
}

/// One Claude usage rolling-window.
enum QuotaWindow: String, Sendable, CaseIterable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
}

/// A single quota tier: utilization (0...100) + when it resets.
struct QuotaTier: Equatable, Sendable {
    let window: QuotaWindow
    let utilization: Double
    let resetsAt: Date?
}

/// Parsed Claude Code usage quota (or an error state).
struct ClaudeUsageQuota: Equatable, Sendable {
    let status: CredentialStatus
    let tiers: [QuotaTier]
    let fetchedAt: Date
    let errorMessage: String?

    init(status: CredentialStatus, tiers: [QuotaTier] = [], fetchedAt: Date = Date(), errorMessage: String? = nil) {
        self.status = status
        self.tiers = tiers
        self.fetchedAt = fetchedAt
        self.errorMessage = errorMessage
    }
}

/// OAuth credential extracted from Keychain / credentials file.
struct UsageCredential: Equatable, Sendable {
    let token: String?
    let status: CredentialStatus
    let message: String?

    init(token: String?, status: CredentialStatus, message: String? = nil) {
        self.token = token
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
    static func parseClaudeCodeQuota(data: Data, fetchedAt: Date = Date()) throws -> ClaudeUsageQuota {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let tiers: [QuotaTier] = [
            response.fiveHour.map { tier(.fiveHour, $0) },
            response.sevenDay.map { tier(.sevenDay, $0) },
            response.sevenDayOpus.map { tier(.sevenDayOpus, $0) },
            response.sevenDaySonnet.map { tier(.sevenDaySonnet, $0) },
        ].compactMap(\.self)
        return ClaudeUsageQuota(status: .valid, tiers: tiers, fetchedAt: fetchedAt)
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
