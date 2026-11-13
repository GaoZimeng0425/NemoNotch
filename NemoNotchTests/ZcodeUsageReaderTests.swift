import CryptoKit
import Foundation
@testable import NemoNotch
import SQLite3
import Testing

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
            ("sess_a", "GLM-5.3", 100_000, 500, 90000, 0),
            ("sess_a", "GLM-5.3", 150_000, 1000, 140_000, 0),
            ("sess_b", "GLM-5.3-Flash", 10000, 100, 0, 2000),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let a = ZcodeUsageReader.readSessionUsage(sessionId: "sess_a", databaseURL: url)
        #expect(a?.model == "GLM-5.3")
        // Context = latest request only: input 150_000 + creation 0.
        #expect(a?.contextTokens == 150_000)
        // Totals span every request.
        #expect(a?.inputTokens == 250_000)
        #expect(a?.outputTokens == 1500)
        #expect(a?.cacheReadTokens == 230_000)
        #expect(a?.requestCount == 2)

        let b = ZcodeUsageReader.readSessionUsage(sessionId: "sess_b", databaseURL: url)
        #expect(b?.contextTokens == 12000)
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

/// enc:v2:os credential decryption — the CLI's keyring-based format. The
/// round-trip test seals with CryptoKit exactly like the CLI does, so a
/// format drift on either side fails here first.
@Suite("ZcodeCredentials v2")
struct ZcodeCredentialsV2Tests {
    private func seal(_ plaintext: String, key: Data) -> String {
        // swiftlint:disable:next force_try
        let box = try! AES.GCM.seal(
            Data(plaintext.utf8), using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: Data(repeating: 7, count: 12))
        )
        let fp = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined().prefix(24)
        let b64 = { (d: Data) in d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "=",
            with: ""
        ) }
        return "enc:v2:os:\(fp):\(b64(box.nonce.withUnsafeBytes { Data($0) })).\(b64(box.tag)).\(b64(box.ciphertext))"
    }

    @Test("round-trip: seal like the CLI, decrypt like the app")
    func roundTrip() {
        let key = Data((0 ..< 32).map { UInt8($0 & 0xFF) })
        let sealed = seal("sk-test-api-key-12345", key: key)
        #expect(sealed.hasPrefix("enc:v2:os:"))
        #expect(ZcodeCredentials.v2Decrypt(sealed, key: key) == "sk-test-api-key-12345")
    }

    @Test("a different key is rejected by the fingerprint before AES")
    func fingerprintMismatch() {
        let key = Data((0 ..< 32).map { UInt8($0 & 0xFF) })
        let other = Data((100 ..< 132).map { UInt8($0 & 0xFF) })
        let sealed = seal("secret", key: key)
        #expect(ZcodeCredentials.v2Decrypt(sealed, key: other) == nil)
    }

    @Test("a tampered fingerprint prefix is rejected even with the right key")
    func tamperedFingerprintRejected() {
        // The ONLY observable behavior of the fingerprint guard: with the
        // correct key and a genuine ciphertext, a corrupted prefix must still
        // refuse. Without the guard this decrypts fine (AES-GCM would pass).
        let key = Data((0 ..< 32).map { UInt8($0 & 0xFF) })
        let sealed = seal("secret", key: key)
        let tampered = sealed.replacingOccurrences(
            of: String(sealed.dropFirst("enc:v2:os:".count).prefix(24)),
            with: String(repeating: "f", count: 24)
        )
        #expect(tampered != sealed)
        #expect(ZcodeCredentials.v2Decrypt(tampered, key: key) == nil)
    }

    @Test("non-v2 values are not v2-decryptable")
    func shapeDispatch() {
        let key = Data(repeating: 9, count: 32)
        #expect(ZcodeCredentials.v2Decrypt("enc:v1:abc.def.ghi", key: key) == nil)
        #expect(ZcodeCredentials.v2Decrypt("plaintext-token", key: key) == nil)
        #expect(ZcodeCredentials.v2Decrypt("enc:v2:env:xx:aa.bb.cc", key: key) == nil)
    }

    @Test("api-key entry lookup finds the account-provider key only")
    func apiKeyEntryLookup() {
        let dict = [
            "oauth:bigmodel:access_token": "legacy",
            "account-provider:coding-plan:account:bigmodel-team-coding-plan:account:1:api-key": "enc:v2:os:aa:bb.cc.dd",
        ]
        let found = ZcodeCredentials.apiKeyEntry(in: dict)
        #expect(found?.value == "enc:v2:os:aa:bb.cc.dd")

        #expect(ZcodeCredentials.apiKeyEntry(in: ["oauth:bigmodel:access_token": "x"]) == nil)
    }

    @Test("keyring account is the sha256 hex of the file path")
    func keyringAccountStable() {
        let url = URL(fileURLWithPath: "/tmp/x/credentials.json")
        let expected = SHA256.hash(data: Data("/tmp/x/credentials.json".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(ZcodeCredentials.keyringAccount(fileURL: url) == expected)
    }
}

@Suite("ZcodeQuotaParser envelope")
struct ZcodeQuotaEnvelopeTests {
    @Test("HTTP 200 with code 401 is an API error, not a parse failure")
    func apiErrorExtracted() {
        let body = #"{"code":401,"msg":"令牌已过期或验证不正确","success":false}"#
        let error = ZcodeQuotaParser.apiError(data: Data(body.utf8))
        #expect(error?.code == 401)
        #expect(error?.msg == "令牌已过期或验证不正确")
        // The old path reported this as "parse failed" — the discriminator
        // must exist for the caller to classify (mutate it away to see red).
    }

    @Test("success envelope and junk are not API errors")
    func apiErrorNegative() {
        #expect(ZcodeQuotaParser.apiError(data: Data(#"{"code":200,"data":{}}"#.utf8)) == nil)
        #expect(ZcodeQuotaParser.apiError(data: Data("not json".utf8)) == nil)
    }

    @Test("five-hour-only payload (real 2026-11-13 capture: no unit-6 week tier) still parses")
    func fiveHourOnlyPayload() {
        let json = #"""
        {"code":200,"data":{"limits":[
          {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":21,"nextResetTime":1795830713978},
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":1,"nextResetTime":1794583237388}
        ]},"success":true}
        """#
        guard let quota = ZcodeQuotaParser.parse(data: Data(json.utf8), fetchedAt: Date()) else {
            Issue.record("expected a single-tier quota")
            return
        }
        #expect(quota.tiers.count == 1)
        #expect(quota.tiers[0].window == .fiveHour)
        #expect(quota.tiers[0].utilization == 1)
    }
}
