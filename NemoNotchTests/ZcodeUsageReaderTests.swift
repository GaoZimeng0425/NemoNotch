import Foundation
import SQLite3
import Testing

@testable import NemoNotch

/// Builds a throwaway sqlite database with zcode's `model_usage` table and a
/// minimal column subset, then verifies the reader's day-boundary and 7-day
/// aggregation.
struct ZcodeUsageReaderTests {

    private func makeFixture(inserting rows: [(startedAt: Double, tokens: Int)]) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-usage-test-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            Issue.record("failed to open fixture db")
            return url
        }
        defer { sqlite3_close(db) }
        let create = """
        CREATE TABLE model_usage (
            id text primary key,
            session_id text not null,
            status text not null,
            started_at integer not null,
            computed_total_tokens integer not null default 0
        )
        """
        sqlite3_exec(db, create, nil, nil, nil)
        for (index, row) in rows.enumerated() {
            let insert = "INSERT INTO model_usage (id, session_id, status, started_at, computed_total_tokens) VALUES ('\(index)', 's', 'completed', \(Int64(row.startedAt)), \(row.tokens))"
            sqlite3_exec(db, insert, nil, nil, nil)
        }
        return url
    }

    @Test func aggregatesTodayAndWeek() {
        let now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now).timeIntervalSince1970 * 1000
        let nowMs = now.timeIntervalSince1970 * 1000

        let url = makeFixture(inserting: [
            // Today (after local midnight): 2 requests, 300 tokens.
            (dayStart + 1000, 100),
            (nowMs - 1000, 200),
            // 3 days ago: inside the 7-day window.
            (nowMs - 3 * 86400 * 1000, 1000),
            // 8 days ago: outside the 7-day window.
            (nowMs - 8 * 86400 * 1000, 5000),
            // Yesterday 23:59 (just before today's midnight): week only.
            (dayStart - 1000, 400),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let stats = ZcodeUsageReader.read(databaseURL: url, now: now)
        #expect(stats != nil)
        #expect(stats?.todayTokens == 300)
        #expect(stats?.todayRequests == 2)
        #expect(stats?.weekTokens == 1700)
        #expect(stats?.weekRequests == 4)
    }

    @Test func missingDatabaseReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-usage-missing-\(UUID().uuidString).sqlite")
        #expect(ZcodeUsageReader.read(databaseURL: url) == nil)
    }

    @Test func missingTableReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-usage-empty-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_close(db)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ZcodeUsageReader.read(databaseURL: url) == nil)
    }

    // MARK: - per-session usage

    /// Builds a fixture with zcode's real `model_usage` column subset and
    /// inserts completed requests for two sessions.
    private func makeSessionFixture(
        _ rows: [(session: String, model: String, input: Int, output: Int, cacheRead: Int, cacheCreation: Int)]
    ) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-sess-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            Issue.record("failed to open fixture db")
            return url
        }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, """
        CREATE TABLE model_usage (
            id text primary key, session_id text not null, status text not null,
            started_at integer not null, model_id text not null,
            input_tokens integer not null default 0, output_tokens integer not null default 0,
            cache_read_input_tokens integer not null default 0,
            cache_creation_input_tokens integer not null default 0,
            computed_total_tokens integer not null default 0
        )
        """, nil, nil, nil)
        for (index, row) in rows.enumerated() {
            sqlite3_exec(db, """
            INSERT INTO model_usage (id, session_id, status, started_at, model_id, input_tokens,
                output_tokens, cache_read_input_tokens, cache_creation_input_tokens, computed_total_tokens)
            VALUES ('\(index)', '\(row.session)', 'completed', \(1_700_000_000_000 + index * 1000),
                '\(row.model)', \(row.input), \(row.output), \(row.cacheRead), \(row.cacheCreation),
                \(row.input + row.output))
            """, nil, nil, nil)
        }
        return url
    }

    @Test func sessionUsageAggregatesAndContextUsesLatestRequest() {
        // GLM semantics: input_tokens already includes cache reads.
        let url = makeSessionFixture([
            ("sess_a", "GLM-5.3", 100_000, 500, 90_000, 0),
            ("sess_a", "GLM-5.3", 150_000, 1_000, 140_000, 0),
            ("sess_b", "GLM-5.3-Flash", 10_000, 100, 0, 2_000),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let a = ZcodeUsageReader.readSessionUsage(sessionId: "sess_a", databaseURL: url)
        #expect(a?.model == "GLM-5.3")
        // Context = latest request only: input 150_000 + creation 0.
        #expect(a?.contextTokens == 150_000)
        // Totals span every request.
        #expect(a?.inputTokens == 250_000)
        #expect(a?.outputTokens == 1_500)
        #expect(a?.cacheReadTokens == 230_000)
        #expect(a?.requestCount == 2)

        let b = ZcodeUsageReader.readSessionUsage(sessionId: "sess_b", databaseURL: url)
        #expect(b?.contextTokens == 12_000)
    }

    @Test func sessionUsageNilForUnknownSession() {
        let url = makeSessionFixture([])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ZcodeUsageReader.readSessionUsage(sessionId: "sess_none", databaseURL: url) == nil)
    }

    @Test func tokenFormatter() {
        #expect(ZcodeUsageFormatter.tokens(486) == "486")
        #expect(ZcodeUsageFormatter.tokens(486_000) == "486K")
        #expect(ZcodeUsageFormatter.tokens(23_072_037) == "23.1M")
        #expect(ZcodeUsageFormatter.tokens(1_200_000_000) == "1.2B")
    }

    // MARK: - credential decrypt

    /// Fixture produced with the same scheme zcode uses: AES-256-GCM,
    /// key = SHA256("zcode-credential-fallback:darwin:{home}:{user}").
    @Test func decryptCredential() {
        let secret = "zcode-credential-fallback:darwin:/Users/test:/tester"
        let blob = "enc:v1:AQEBAQEBAQEBAQEB.GdpfjOXBzYjSmXjYv2cVKw.odEYcS1-Q_8-eH0Z0nLkUg"
        #expect(ZcodeCredentials.decrypt(blob, secret: secret) == "test-token-value")
        // Wrong secret → GCM auth failure → nil, never garbage.
        #expect(ZcodeCredentials.decrypt(blob, secret: "wrong") == nil)
        // Plaintext passes through unchanged (zcode leaves raw values alone).
        #expect(ZcodeCredentials.decrypt("plain-token", secret: secret) == "plain-token")
    }

    // MARK: - quota parse

    @Test func parseQuota() throws {
        let json = """
        {"code":200,"data":{"limits":[
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":61,"remaining":939,"percentage":6,"nextResetTime":1790560313998},
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":6,"nextResetTime":1788634799640},
          {"type":"TOKENS_LIMIT","unit":6,"percentage":42}
        ]}}
        """
        let quota = try #require(ZcodeQuotaParser.parse(data: Data(json.utf8), fetchedAt: Date()))
        #expect(quota.provider == .zcode)
        #expect(quota.status == .valid)
        #expect(quota.tiers.count == 2)
        #expect(quota.tiers[0].window == .fiveHour)
        #expect(quota.tiers[0].utilization == 6)
        #expect(quota.tiers[0].resetsAt == Date(timeIntervalSince1970: 1_788_634_799.640))
        #expect(quota.tiers[1].window == .sevenDay)
        #expect(quota.tiers[1].utilization == 42)
        #expect(quota.tiers[1].resetsAt == nil)
    }

    @Test func parseQuotaRejectsBadResponses() {
        #expect(ZcodeQuotaParser.parse(data: Data("{\"code\":401}".utf8), fetchedAt: Date()) == nil)
        // No token-limit windows at all → nothing renderable.
        let json = "{\"code\":200,\"data\":{\"limits\":[{\"type\":\"TIME_LIMIT\",\"unit\":5,\"number\":1,\"percentage\":6}]}}"
        #expect(ZcodeQuotaParser.parse(data: Data(json.utf8), fetchedAt: Date()) == nil)
    }
}
