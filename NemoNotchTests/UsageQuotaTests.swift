import Foundation
@testable import NemoNotch
import Testing

struct UsageQuotaTests {
    // MARK: - Credential parsing

    @Test func parseCredentialValid() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":1780988250441}}"#
        let now = Date(timeIntervalSince1970: 1_700_000_000) // before expiry
        let cred = try UsageCredentialParser.parseClaudeCredentials(data: Data(json.utf8), now: now)
        #expect(cred.token == "tok-abc")
        #expect(cred.status == .valid)
    }

    @Test func parseCredentialExpired() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":1700000000000}}"#
        let now = Date(timeIntervalSince1970: 1_800_000_000) // after expiry
        let cred = try UsageCredentialParser.parseClaudeCredentials(data: Data(json.utf8), now: now)
        #expect(cred.token == "tok-abc")
        #expect(cred.status == .expired)
    }

    @Test func parseCredentialMissingToken() throws {
        let json = #"{"claudeAiOauth":{"expiresAt":1780988250441}}"#
        let cred = try UsageCredentialParser.parseClaudeCredentials(data: Data(json.utf8), now: Date())
        #expect(cred.token == nil)
        #expect(cred.status == .parseError)
    }

    // MARK: - Quota parsing (real payload shape, incl. microsecond resets_at)

    @Test func parseQuotaRealPayload() throws {
        let json = """
        {
          "five_hour": {"utilization": 6.0, "resets_at": "2026-06-09T08:00:00.858062+00:00"},
          "seven_day": {"utilization": 3.0, "resets_at": "2026-06-15T13:00:00.858087+00:00"},
          "seven_day_opus": null,
          "seven_day_sonnet": {"utilization": 0.0, "resets_at": "2026-06-15T13:00:00.858099+00:00"},
          "extra_usage": {"is_enabled": false}
        }
        """
        let quota = try UsageQuotaParser.parseClaudeCodeQuota(data: Data(json.utf8))
        #expect(quota.status == .valid)
        #expect(quota.provider == .claude)
        // null tiers dropped → 3 tiers, in declared order
        #expect(quota.tiers.map(\.window) == [.fiveHour, .sevenDay, .sevenDaySonnet])
        #expect(quota.tiers[0].utilization == 6.0)
        // regression: microsecond + offset resets_at MUST parse to a non-nil Date
        #expect(quota.tiers[0].resetsAt != nil)
    }

    @Test func parseQuotaMalformedThrows() {
        #expect(throws: (any Error).self) {
            try UsageQuotaParser.parseClaudeCodeQuota(data: Data("not json".utf8))
        }
    }

    @Test func parseResetDateMicroseconds() {
        let d = UsageQuotaParser.parseResetDate("2026-06-09T08:00:00.858062+00:00")
        #expect(d != nil)
    }

    @Test func parseResetDateThreeDigitFraction() {
        #expect(UsageQuotaParser.parseResetDate("2026-06-09T08:00:00.858+00:00") != nil)
    }

    @Test func parseResetDateNoFraction() {
        #expect(UsageQuotaParser.parseResetDate("2026-06-09T08:00:00+00:00") != nil)
    }

    @Test func parseCredentialNonJSONThrows() {
        #expect(throws: (any Error).self) {
            try UsageCredentialParser.parseClaudeCredentials(data: Data("not json".utf8), now: Date())
        }
    }

    // MARK: - Countdown formatting

    @Test func countdownDaysAndHours() {
        let now = Date(timeIntervalSince1970: 0)
        let target = now.addingTimeInterval(6 * 86400 + 3 * 3600)
        #expect(UsageQuotaFormatter.countdown(until: target, now: now) == .text("6d3h"))
    }

    @Test func countdownHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let target = now.addingTimeInterval(4 * 3600 + 12 * 60)
        #expect(UsageQuotaFormatter.countdown(until: target, now: now) == .text("4h12m"))
    }

    @Test func countdownMinutesOnly() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageQuotaFormatter.countdown(until: now.addingTimeInterval(300), now: now) == .text("5m"))
    }

    @Test func countdownUnderOneMinute() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageQuotaFormatter.countdown(until: now.addingTimeInterval(30), now: now) == .text("<1m"))
    }

    @Test func countdownAlreadyReset() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(UsageQuotaFormatter.countdown(until: now.addingTimeInterval(-10), now: now) == .reset)
    }
}
