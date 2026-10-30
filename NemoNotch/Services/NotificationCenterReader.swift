import Foundation
import SQLite3

/// Outcome of one read of usernoted's database.
enum NotificationCenterReadResult: Equatable {
    case records([NotificationRecord])
    /// The file exists but the open was refused (TCC): Full Disk Access needed.
    case noAccess
    /// Missing file, unrecognized schema, or another sqlite error.
    case unavailable(String)
}

/// Read-only access to Notification Center's private store. There is no
/// public API for other apps' notifications (`getDeliveredNotifications`
/// only returns the caller's own), so this reads the sqlite file usernoted
/// keeps. Never writes to it. Call off the main thread.
enum NotificationCenterReader {
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    static func read(databaseURL: URL = databaseURL) -> NotificationCenterReadResult {
        // Probe with a plain open first: sqlite folds EPERM into a generic
        // CANTOPEN, and the TCC refusal is the one case the UI must tell apart.
        do {
            try FileHandle(forReadingFrom: databaseURL).close()
        } catch {
            return classifyOpenFailure(error)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return .unavailable(message)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM record", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            return sqlite3_errcode(db) == SQLITE_AUTH ? .noAccess : .unavailable(message)
        }
        defer { sqlite3_finalize(stmt) }

        var records: [NotificationRecord] = []
        var skipped = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(stmt, 0) else {
                skipped += 1
                continue
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            if let record = NotificationRecord.decode(data) {
                records.append(record)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            LogService.debug("Skipped \(skipped) undecodable notification records", category: "NotificationToast")
        }
        return .records(records)
    }

    /// Maps a failed probe open to a result. A TCC refusal surfaces as
    /// `fileWriteNoPermission` (observed on macOS 27 for a plain read), not
    /// only `fileReadNoPermission` — any permission code means Full Disk Access.
    static func classifyOpenFailure(_ error: Error) -> NotificationCenterReadResult {
        let permissionCodes: Set<CocoaError.Code> = [.fileReadNoPermission, .fileWriteNoPermission]
        if let cocoa = error as? CocoaError {
            if permissionCodes.contains(cocoa.code) {
                return .noAccess
            }
            if cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile {
                return .unavailable("database not found")
            }
        }
        if let posix = error as? POSIXError, posix.code == .EPERM || posix.code == .EACCES {
            return .noAccess
        }
        return .unavailable(error.localizedDescription)
    }

    /// (mtime, size) of the database and its WAL — a new notification lands
    /// in the WAL first. nil when neither can be stat'ed.
    static func fingerprint(databaseURL: URL = databaseURL) -> [Int64]? {
        let paths = [databaseURL.path, databaseURL.path + "-wal"]
        var result: [Int64] = []
        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                result += [0, 0]
                continue
            }
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            result += [Int64(mtime * 1000), size]
        }
        return result.allSatisfy { $0 == 0 } ? nil : result
    }
}
