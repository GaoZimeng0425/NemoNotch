import CryptoKit
import Foundation
import SQLite3

/// Aggregated zcode usage read from the CLI's local database
/// (`~/.zcode/cli/db/db.sqlite`, table `model_usage`). zcode exposes no remote
/// quota API (its credentials are encrypted app-private), so the usage area
/// shows actual consumption instead of a percentage quota.
struct ZcodeUsageStats: Equatable {
    var todayTokens: Int
    var todayRequests: Int
    var weekTokens: Int
    var weekRequests: Int
}

/// Per-session token aggregates backfilled into `AISessionState` so zcode
/// sessions show real context % and token counts despite being notify-only.
struct ZcodeSessionUsage: Equatable {
    /// Model id of the most recent request (e.g. "GLM-5.3").
    var model: String?
    /// Context size of the most recent request. GLM's `input_tokens` already
    /// includes cache reads (computed_total = input + output), so this is
    /// `input + cache_creation`, plus `cache_read` when it exceeds input
    /// (i.e. when the provider reports cache separately from input).
    var contextTokens: Int
    /// Session totals across all requests.
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int
    var requestCount: Int
}

enum ZcodeUsageReader {

    static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/cli/db/db.sqlite")
    }

    /// Reads today's and the trailing 7 days' usage. Returns nil when the
    /// database (or its `model_usage` table) doesn't exist — zcode not
    /// installed — or the read fails, e.g. the DB is locked; callers keep the
    /// previous stats in that case.
    static func read(databaseURL: URL = defaultDatabaseURL, now: Date = Date()) -> ZcodeUsageStats? {
        open(databaseURL) { db in
            let calendar = Calendar.current
            let dayStart = calendar.startOfDay(for: now).timeIntervalSince1970 * 1000
            let weekStart = now.timeIntervalSince1970 * 1000 - 7 * 86400 * 1000

            guard
                let today = aggregate(db, since: dayStart),
                let week = aggregate(db, since: weekStart)
            else { return nil }
            return ZcodeUsageStats(
                todayTokens: today.tokens,
                todayRequests: today.requests,
                weekTokens: week.tokens,
                weekRequests: week.requests
            )
        }
    }

    /// Token aggregates for one session (hook session ids match the CLI's
    /// `sess_…` primary keys). Returns nil when the session has no completed
    /// model requests yet.
    static func readSessionUsage(
        sessionId: String,
        databaseURL: URL = defaultDatabaseURL
    ) -> ZcodeSessionUsage? {
        open(databaseURL) { db in
            let sql = """
            SELECT model_id, input_tokens, output_tokens,
                   cache_read_input_tokens, cache_creation_input_tokens,
                   computed_total_tokens
            FROM model_usage
            WHERE session_id = ? AND status = 'completed'
            ORDER BY started_at
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                sqlite3_finalize(stmt)
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, sessionId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            var model: String?
            var lastInput = 0, lastCacheCreation = 0, lastCacheRead = 0
            var input = 0, output = 0, cacheRead = 0, cacheCreation = 0, count = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                model = string(stmt, 0) ?? model
                lastCacheRead = Int(sqlite3_column_int64(stmt, 3))
                lastCacheCreation = Int(sqlite3_column_int64(stmt, 4))
                lastInput = Int(sqlite3_column_int64(stmt, 1))
                input += lastInput
                output += Int(sqlite3_column_int64(stmt, 2))
                cacheRead += lastCacheRead
                cacheCreation += lastCacheCreation
                count += 1
            }
            guard count > 0 else { return nil }
            let context = lastInput >= lastCacheRead
                ? lastInput + lastCacheCreation
                : lastInput + lastCacheRead + lastCacheCreation
            return ZcodeSessionUsage(
                model: model,
                contextTokens: context,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheCreation,
                requestCount: count
            )
        }
    }

    private static func open<T>(
        _ databaseURL: URL,
        _ body: (OpaquePointer) -> T?
    ) -> T? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        return body(db)
    }

    private static func string(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func aggregate(_ db: OpaquePointer, since millis: Double) -> (tokens: Int, requests: Int)? {
        let sql = """
        SELECT COALESCE(SUM(computed_total_tokens), 0), COUNT(*)
        FROM model_usage WHERE started_at > ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, millis)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let tokens = Int(sqlite3_column_int64(stmt, 0))
        let requests = Int(sqlite3_column_int64(stmt, 1))
        return (tokens, requests)
    }
}

/// Decrypts zcode's local credential file and reads the BigModel coding-plan
/// quota API — the same data ZCode's own usage page shows.
///
/// zcode stores credentials in `~/.zcode/v2/credentials.json` as
/// `enc:v1:<b64url(iv)>.<b64url(tag)>.<b64url(ciphertext)>`, AES-256-GCM with
/// key = SHA256(secret). The secret defaults to the deterministic local string
/// `zcode-credential-fallback:{platform}:{homedir}:{username}` (overridable
/// via the `ZCODE_CREDENTIAL_SECRET` env) — no Keychain involved, so this app
/// can decrypt it exactly like the CLI does.
enum ZcodeCredentials {

    static var credentialsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zcode/v2/credentials.json")
    }

    /// The decrypted `oauth:bigmodel:access_token`, or nil when the file is
    /// missing/undecryptable (zcode not logged in, or a future format bump).
    static func accessToken(fileURL: URL = credentialsURL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let encrypted = dict["oauth:bigmodel:access_token"]
        else { return nil }
        return decrypt(encrypted, secret: secret())
    }

    static func secret() -> String {
        if let fromEnv = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"], !fromEnv.isEmpty {
            return fromEnv
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "zcode-credential-fallback:darwin:\(home):\(NSUserName())"
    }

    static func decrypt(_ value: String, secret: String) -> String? {
        let prefix = "enc:v1:"
        guard value.hasPrefix(prefix) else { return value }
        let parts = value.dropFirst(prefix.count).split(separator: ".")
        guard parts.count == 3,
              let iv = base64URL(String(parts[0])), iv.count == 12,
              let tag = base64URL(String(parts[1])), tag.count == 16,
              let ciphertext = base64URL(String(parts[2]))
        else { return nil }
        let key = SHA256.hash(data: Data(secret.utf8))
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            return String(data: try AES.GCM.open(box, using: SymmetricKey(data: key)), encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func base64URL(_ s: String) -> Data? {
        var base64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if base64.count % 4 != 0 {
            base64 += String(repeating: "=", count: 4 - base64.count % 4)
        }
        return Data(base64Encoded: base64)
    }
}

/// Parses the BigModel quota response
/// (`GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`) into the
/// shared `QuotaTier` model. Window semantics mirror ZCode's own usage page:
/// `TOKENS_LIMIT` (unit 3, number 5) → rolling 5-hour tokens;
/// `TOKENS_LIMIT` (unit 6) → weekly tokens. `TIME_LIMIT` (unit 5, number 1)
/// is a prompt-count limit — not rendered.
enum ZcodeQuotaParser {

    struct Limit: Decodable {
        let type: String
        let unit: Int?
        let number: Int?
        let percentage: Double?
        let nextResetTime: Double?
    }

    static func parse(data: Data, fetchedAt: Date) -> ProviderUsageQuota? {
        struct Response: Decodable {
            let code: Int
            struct Data: Decodable { let limits: [Limit]? }
            let data: Data?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.code == 200,
              let limits = response.data?.limits
        else { return nil }

        let fiveHour = limits.first { $0.type == "TOKENS_LIMIT" && $0.unit == 3 && $0.number == 5 }
        let week = limits.first { $0.type == "TOKENS_LIMIT" && $0.unit == 6 }
        var tiers: [QuotaTier] = []
        if let fiveHour, let pct = fiveHour.percentage {
            tiers.append(QuotaTier(window: .fiveHour, utilization: pct, resetsAt: date(fiveHour.nextResetTime)))
        }
        if let week, let pct = week.percentage {
            tiers.append(QuotaTier(window: .sevenDay, utilization: pct, resetsAt: date(week.nextResetTime)))
        }
        guard !tiers.isEmpty else { return nil }
        return ProviderUsageQuota(provider: .zcode, status: .valid, tiers: tiers, fetchedAt: fetchedAt)
    }

    private static func date(_ millis: Double?) -> Date? {
        guard let millis else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

enum ZcodeUsageFormatter {
    /// Compact token count: "486K", "23.1M", "1.2B".
    static func tokens(_ value: Int) -> String {
        let double = Double(value)
        switch double {
        case 1_000_000_000...: return String(format: "%.1fB", double / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", double / 1_000_000)
        case 1_000...: return String(format: "%.0fK", double / 1_000)
        default: return "\(value)"
        }
    }
}
