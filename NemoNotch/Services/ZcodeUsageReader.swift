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
