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

    // MARK: - Codex quota parsing

    @Test func parseCodexQuotaFreeTier() throws {
        let json = """
        { "rate_limit": {
            "primary_window": {"used_percent": 7, "limit_window_seconds": 2592000, "reset_at": 1782973688},
            "secondary_window": null
        } }
        """
        let quota = try UsageQuotaParser.parseCodexQuota(data: Data(json.utf8))
        #expect(quota.provider == .codex)
        #expect(quota.tiers.count == 1)
        #expect(quota.tiers[0].window == .rolling(minutes: 43200))
        #expect(quota.tiers[0].utilization == 7)
        #expect(quota.tiers[0].resetsAt != nil)
    }

    @Test func parseCodexQuotaPaidTierOrdersSessionFirst() throws {
        let json = """
        { "rate_limit": {
            "primary_window":   {"used_percent": 20, "limit_window_seconds": 604800, "reset_at": 1782973688},
            "secondary_window": {"used_percent": 50, "limit_window_seconds": 18000,  "reset_at": 1782900000}
        } }
        """
        let quota = try UsageQuotaParser.parseCodexQuota(data: Data(json.utf8))
        #expect(quota.tiers.map(\.window) == [.rolling(minutes: 300), .rolling(minutes: 10080)])
    }

    @Test func windowLabelFormats() {
        #expect(UsageQuotaFormatter.windowLabel(minutes: 300) == "5h")
        #expect(UsageQuotaFormatter.windowLabel(minutes: 10080) == "7d")
        #expect(UsageQuotaFormatter.windowLabel(minutes: 43200) == "30d")
        #expect(UsageQuotaFormatter.windowLabel(minutes: 1440) == "1d")
        #expect(UsageQuotaFormatter.windowLabel(minutes: 90) == "90m")
    }

    @Test func parseCodexCredentialsValid() throws {
        let json = #"{"auth_mode":"chatgpt","tokens":{"access_token":"tok","account_id":"acct-1"}}"#
        let c = try UsageCredentialParser.parseCodexCredentials(data: Data(json.utf8))
        #expect(c.token == "tok")
        #expect(c.accountID == "acct-1")
        #expect(c.status == .valid)
    }

    @Test func parseCodexCredentialsMissingToken() throws {
        let json = #"{"auth_mode":"chatgpt","tokens":{"account_id":"acct-1"}}"#
        let c = try UsageCredentialParser.parseCodexCredentials(data: Data(json.utf8))
        #expect(c.token == nil)
        #expect(c.status == .parseError)
    }

    @Test func parseCodexCredentialsNotChatGPT() throws {
        let json = #"{"auth_mode":"apikey","tokens":{"access_token":"tok"}}"#
        let c = try UsageCredentialParser.parseCodexCredentials(data: Data(json.utf8))
        #expect(c.status == .notFound)
    }

    @Test func backfillReusesCachedResetWhenMissing() {
        let now = Date(timeIntervalSince1970: 1000)
        let cached = QuotaTier(window: .rolling(minutes: 300), utilization: 10, resetsAt: now.addingTimeInterval(3600))
        let fresh = QuotaTier(window: .rolling(minutes: 300), utilization: 12, resetsAt: nil)
        let filled = fresh.backfillingReset(from: cached, now: now)
        #expect(filled.resetsAt == now.addingTimeInterval(3600))
        #expect(filled.utilization == 12)
    }

    @Test func backfillIgnoresPastCachedReset() {
        let now = Date(timeIntervalSince1970: 1000)
        let cached = QuotaTier(window: .rolling(minutes: 300), utilization: 10, resetsAt: now.addingTimeInterval(-10))
        let fresh = QuotaTier(window: .rolling(minutes: 300), utilization: 12, resetsAt: nil)
        #expect(fresh.backfillingReset(from: cached, now: now).resetsAt == nil)
    }

    // MARK: - Gemini credential parsing

    @Test func parseGeminiCredentialValid() throws {
        let json = #"{"access_token":"acc-1","refresh_token":"ref-1","expiry_date":1779783180264,"id_token":"x"}"#
        let cred = try UsageCredentialParser.parseGeminiCredentials(data: Data(json.utf8))
        #expect(cred.accessToken == "acc-1")
        #expect(cred.refreshToken == "ref-1")
        #expect(cred.expiryDate == Date(timeIntervalSince1970: 1_779_783_180.264))
        #expect(cred.status == .valid)
    }

    @Test func parseGeminiCredentialNoTokens() throws {
        let json = #"{"scope":"openid"}"#
        let cred = try UsageCredentialParser.parseGeminiCredentials(data: Data(json.utf8))
        #expect(cred.accessToken == nil)
        #expect(cred.refreshToken == nil)
        #expect(cred.status == .notFound)
    }

    @Test func parseGeminiCredentialMalformedThrows() {
        #expect(throws: (any Error).self) {
            try UsageCredentialParser.parseGeminiCredentials(data: Data("not json".utf8))
        }
    }

    @Test func parseGeminiCredentialNonObject() throws {
        // Valid JSON, but an array rather than an object → .parseError (no throw).
        let cred = try UsageCredentialParser.parseGeminiCredentials(data: Data("[1,2,3]".utf8))
        #expect(cred.status == .parseError)
    }

    @Test func geminiAuthTypeRawValues() {
        #expect(GeminiAuthType(rawValue: "oauth-personal") == .oauthPersonal)
        #expect(GeminiAuthType(rawValue: "api-key") == .apiKey)
        #expect(GeminiAuthType(rawValue: "vertex-ai") == .vertexAI)
        #expect(GeminiAuthType(rawValue: "nonsense") == nil)
    }

    // MARK: - Gemini quota parsing

    @Test func parseGeminiQuotaCollapsesPerModel() throws {
        // Two token-type buckets for pro (keep the lower fraction = more used);
        // one for flash. Order by utilization descending.
        let json = """
        {"buckets":[
          {"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","remainingFraction":0.4,"resetTime":"2026-06-16T00:00:00Z"},
          {"modelId":"gemini-2.5-pro","tokenType":"TOKENS","remainingFraction":0.1,"resetTime":"2026-06-16T00:00:00Z"},
          {"modelId":"gemini-2.5-flash","tokenType":"REQUESTS","remainingFraction":0.8,"resetTime":"2026-06-16T00:00:00Z"}
        ]}
        """
        let quota = try UsageQuotaParser.parseGeminiQuota(data: Data(json.utf8))
        #expect(quota.provider == .gemini)
        #expect(quota.status == .valid)
        #expect(quota.tiers.count == 2) // pro collapsed to one row
        // pro: 1 - 0.1 = 90% used (lowest fraction kept); flash: 1 - 0.8 = 20%
        #expect(quota.tiers[0].window == .gemini(label: "2.5 Pro"))
        #expect(abs(quota.tiers[0].utilization - 90.0) < 0.001)
        #expect(quota.tiers[1].window == .gemini(label: "2.5 Flash"))
        #expect(abs(quota.tiers[1].utilization - 20.0) < 0.001)
        #expect(quota.tiers[0].resetsAt != nil)
    }

    @Test func parseGeminiQuotaEmptyBuckets() throws {
        let quota = try UsageQuotaParser.parseGeminiQuota(data: Data(#"{"buckets":[]}"#.utf8))
        #expect(quota.status == .valid)
        #expect(quota.tiers.isEmpty)
    }

    @Test func parseGeminiQuotaNilBucketsKey() throws {
        // Response with no "buckets" key at all (some free tiers) → degrade to no tiers.
        let quota = try UsageQuotaParser.parseGeminiQuota(data: Data("{}".utf8))
        #expect(quota.status == .valid)
        #expect(quota.tiers.isEmpty)
    }

    @Test func parseGeminiQuotaSkipsBucketsMissingFraction() throws {
        // 100%-quota bucket omits remainingFraction → skipped, not crashed.
        let json = #"{"buckets":[{"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","resetTime":"2026-06-16T00:00:00Z"}]}"#
        let quota = try UsageQuotaParser.parseGeminiQuota(data: Data(json.utf8))
        #expect(quota.tiers.isEmpty)
    }

    @Test func geminiModelShortNames() {
        #expect(UsageQuotaParser.geminiModelShortName("gemini-2.5-pro") == "2.5 Pro")
        #expect(UsageQuotaParser.geminiModelShortName("gemini-2.5-flash") == "2.5 Flash")
        #expect(UsageQuotaParser.geminiModelShortName("gemini-2.5-flash-lite") == "2.5 Flash Lite")
        #expect(UsageQuotaParser.geminiModelShortName("gemini-exp-1206") == "exp-1206")
    }

    // MARK: - Gemini OAuth client extraction

    @Test func geminiOAuthClientParse() {
        let js = """
        const OAUTH_CLIENT_ID = '681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = 'xxxx-redacted-client-secret-xxxx';
        """
        let creds = GeminiOAuthClientLocator.parse(from: js)
        #expect(creds?.clientId == "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com")
        #expect(creds?.clientSecret == "xxxx-redacted-client-secret-xxxx")
    }

    @Test func geminiOAuthClientParseMissing() {
        #expect(GeminiOAuthClientLocator.parse(from: "const FOO = 'bar';") == nil)
    }
}
