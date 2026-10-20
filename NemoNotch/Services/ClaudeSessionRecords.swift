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
        /// When `status` was last written — compared with the hooks' last
        /// word, so a stale reading never overrides a newer hook.
        var statusUpdatedAt: Date?
        /// When the CLI started — tells a reused pid from the session's own.
        var startedAt: Date?
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
        // Only interactive sessions: a `claude -p` turn (the chat bubble's
        // runner) is one process per turn and must not end its session.
        if let kind = json["kind"] as? String, kind != "interactive" {
            return nil
        }
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let busy: Bool? = switch json["status"] as? String {
        case "busy": true
        case "idle": false
        default: nil
        }
        return Record(
            pid: pid, sessionId: sessionId, cwd: json["cwd"] as? String, name: name, busy: busy,
            statusUpdatedAt: date(json["statusUpdatedAt"]), startedAt: date(json["startedAt"])
        )
    }

    /// Milliseconds since 1970 → a date.
    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    /// Every record whose process is alive; nil when the directory could not
    /// be read (an error is not "no sessions"). Off the main actor.
    static func scanLive(
        directory: String = directory,
        isAlive: (Record) -> Bool = { isAlive($0.pid, startedAt: $0.startedAt) }
    ) -> [Record]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                let path = (directory as NSString).appendingPathComponent(name)
                guard let data = fm.contents(atPath: path) else { return nil }
                return parse(data)
            }
            .filter(isAlive)
    }

    /// `kill(pid, 0)` says the pid exists; a process that started well after
    /// the record's CLI did is a stranger reusing the pid of a `kill -9`'d
    /// session whose record was left behind.
    static func isAlive(_ pid: Int32, startedAt: Date? = nil) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let startedAt, let processStart = processStart(pid) else { return true }
        return processStart <= startedAt.addingTimeInterval(reuseTolerance)
    }

    /// The CLI stamps `startedAt` a moment after its process starts.
    static let reuseTolerance: TimeInterval = 30

    /// A process's start time (`sysctl KERN_PROC_PID`), nil when unknown.
    static func processStart(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

/// How a record's coarse status (busy / idle) meets the hook-driven phase.
/// Hooks are the finer truth (approval vs input vs working); the record only
/// fills a gap or corrects a phase, and only when its status was written
/// AFTER the hooks last spoke — a stale "busy" read just after an Esc must
/// not resurrect the turn (and later fake a completion flash).
/// - first seen through its record: busy → processing, otherwise idle;
/// - newer busy while the hooks say idle/ended → processing (a turn the
///   hooks didn't see begin);
/// - newer idle while the hooks say processing / compacting / waiting for
///   approval → idle (a Stop that never came; an approval answered or timed
///   out with no follow-up hook).
enum ClaudeRecordMerge {
    /// The phase to move to, or nil to leave the session as it is.
    static func phase(current: SessionPhase?, busy: Bool?, recordIsNewer: Bool) -> SessionPhase? {
        guard let current else {
            return busy == true ? .processing : .idle
        }
        guard recordIsNewer else { return nil }
        switch (busy, current) {
        case (true, .idle), (true, .ended):
            return .processing
        case (false, .processing), (false, .compacting), (false, .waitingForApproval):
            return .idle
        default:
            return nil
        }
    }
}
