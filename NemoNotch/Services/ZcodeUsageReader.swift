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
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

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
