import Darwin
import Foundation

/// Claude Code's own session records: `~/.claude/sessions/<pid>.json`, one
/// per running `claude` process (evlat's `SessionsProvider`). They complete
/// the hooks, never replace them:
/// - hooks only fire for sessions that send an event after NemoNotch
///   started, so a session idling since before launch was invisible — every
///   live process has a record;
/// - a `kill -9`'d session never sends `SessionEnd`, and an idle one was
///   reaped after 30 silent minutes — pid liveness is the real lifetime;
/// - the session's `name` ("nemonotch-23") is right here.
///
/// The format is undocumented, so parsing is defensive: a record missing its
/// pid or session id is skipped, unknown `status` values read as nil.
enum ClaudeSessionRecords {
    struct Record: Equatable, Sendable {
        let pid: Int32
        let sessionId: String
        let cwd: String?
        let name: String?
        /// "busy" → true, "idle" → false, anything else → nil (unknown).
        let busy: Bool?
    }

    static var directory: String {
        NSString(string: "~/.claude/sessions").expandingTildeInPath
    }

    /// One record file's JSON → a record; nil when the essentials are missing.
    static func parse(_ data: Data) -> Record? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 1,
              let sessionId = json["sessionId"] as? String, !sessionId.isEmpty
        else { return nil }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let busy: Bool? = switch json["status"] as? String {
        case "busy": true
        case "idle": false
        default: nil
        }
        return Record(pid: pid, sessionId: sessionId, cwd: json["cwd"] as? String, name: name, busy: busy)
    }

    /// Every record whose process is alive. Off the main actor (file I/O).
    static func scanLive(directory: String = directory, isAlive: (Int32) -> Bool = isAlive) -> [Record] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                let path = (directory as NSString).appendingPathComponent(name)
                guard let data = fm.contents(atPath: path) else { return nil }
                return parse(data)
            }
            .filter { isAlive($0.pid) }
    }

    /// `kill(pid, 0)`: 0 → alive; EPERM → alive but not ours to signal.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// How a record's coarse status (busy / idle) meets the hook-driven phase.
/// Hooks are the finer truth (approval vs input vs working); the record only
/// fills a gap or corrects a phase that cannot be true:
/// - a session first seen through its record starts busy → processing,
///   otherwise idle;
/// - busy while the hooks say idle/ended → processing (a turn the hooks
///   didn't see begin, e.g. started before NemoNotch);
/// - idle while the hooks still say processing, and no hook has spoken for
///   a while → idle (a Stop that never came: killed turn, crashed hook).
///   The grace keeps a record that flips a beat before the Stop hook from
///   cutting a live turn short.
enum ClaudeRecordMerge {
    static let missedStopGrace: TimeInterval = 10

    /// The phase to move to, or nil to leave the session as it is.
    static func phase(current: SessionPhase?, busy: Bool?, silentFor: TimeInterval) -> SessionPhase? {
        guard let current else {
            return busy == true ? .processing : .idle
        }
        switch (busy, current) {
        case (true, .idle), (true, .ended):
            return .processing
        case (false, .processing), (false, .compacting):
            return silentFor > missedStopGrace ? .idle : nil
        default:
            return nil
        }
    }
}
