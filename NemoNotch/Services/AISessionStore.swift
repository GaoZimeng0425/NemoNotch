import Foundation

/// Single source of truth for AI session state across all providers
/// (Claude Code, Gemini, future DeepSeek/OpenAI/etc).
///
/// Providers translate hook events + file-parse results into mutations on
/// this store. UI reads `sortedSessions` directly and never touches the
/// providers' internal state.
@MainActor
@Observable
final class AISessionStore {
    /// All known sessions keyed by their unique session id (assumed unique
    /// across providers — Claude and Gemini use UUID-like ids that don't
    /// collide in practice).
    private(set) var sessions: [String: AISessionState] = [:]

    /// Cached descending-by-lastEventTime view of `sessions`. Rebuilt on
    /// every mutation; N is small (typically < 50) so simple sort is fine.
    private(set) var sortedSessions: [AISessionState] = []

    /// UI's currently selected session id (may span providers).
    var selectedSessionId: String?

    // MARK: - Reads

    func get(_ id: String) -> AISessionState? {
        sessions[id]
    }

    func contains(_ id: String) -> Bool {
        sessions[id] != nil
    }

    /// Filter the sorted view by provider source. Used by per-provider UI
    /// surfaces (e.g. badges that only care about Claude state).
    func sessions(for source: AISource) -> [AISessionState] {
        sortedSessions.filter { $0.source == source }
    }

    /// Highest-priority session across all providers. Priority order:
    /// awaiting permission > working > waiting > idle > ended.
    /// Within the same priority, the most recently active wins.
    var activeSession: AISessionState? {
        sortedSessions.max { lhs, rhs in
            let lp = Self.priority(of: lhs.phase)
            let rp = Self.priority(of: rhs.phase)
            if lp != rp { return lp < rp }
            return lhs.lastEventTime < rhs.lastEventTime
        }
    }

    // MARK: - Writes

    /// Insert or replace a session. Providers use this for the "I just
    /// learned about a new session" case (initial scan, first hook event).
    func upsert(_ session: AISessionState) {
        sessions[session.id] = session
        rebuildSorted()
    }

    /// In-place mutation by id. No-op if the session doesn't exist —
    /// callers that need to create-or-mutate should `upsert` first.
    func mutate(_ id: String, _ block: (inout AISessionState) -> Void) {
        guard var session = sessions[id] else { return }
        block(&session)
        sessions[id] = session
        rebuildSorted()
    }

    /// Get-or-create then mutate. Returns the post-mutation state.
    @discardableResult
    func mutateOrCreate(_ id: String, source: AISource, _ block: (inout AISessionState) -> Void) -> AISessionState {
        var session = sessions[id] ?? AISessionState(sessionId: id, source: source)
        // The caller's cli_source is authoritative: correct a session that a
        // different provider created first (the untagged-event phantom race).
        session.source = source
        block(&session)
        sessions[id] = session
        rebuildSorted()
        return session
    }

    func remove(_ id: String) {
        sessions.removeValue(forKey: id)
        if selectedSessionId == id { selectedSessionId = nil }
        rebuildSorted()
    }

    /// Drop all sessions for a given provider — used when uninstalling its
    /// hook, or when shutting it down for diagnostics.
    func removeAll(source: AISource) {
        sessions = sessions.filter { $0.value.source != source }
        if let id = selectedSessionId, sessions[id] == nil { selectedSessionId = nil }
        rebuildSorted()
    }

    // MARK: - Internal

    private func rebuildSorted() {
        // 每次 mutate 都全量重排；hook 事件密集时这里会被高频调用。
        let probe = PerfProbe.begin()
        defer { PerfProbe.end("AISessionStore.rebuildSorted", probe) }
        sortedSessions = sessions.values.sorted { $0.lastEventTime > $1.lastEventTime }
    }

    /// Lower number = higher priority. See `activeSession` comparator.
    private static func priority(of phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval: 0
        case .processing, .compacting: 1
        case .waitingForInput: 2
        case .idle: 3
        case .ended: 4
        }
    }
}
