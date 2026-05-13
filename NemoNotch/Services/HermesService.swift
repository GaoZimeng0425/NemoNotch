import Foundation
import SQLite3

@MainActor
@Observable
final class HermesService: MultiAgentMonitor {
    var agents: [String: MonitoredAgent] = [:]
    var activeAgent: MonitoredAgent?
    var isOnline = false
    var isInstalled = false
    let displayName = "Hermes"
    let iconEmoji = "🐦"

    private var pollTimer: Timer?
    private let hermesDir: String
    private var lastMessageTimestamps: [String: Double] = [:]

    init() {
        hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        isInstalled = FileManager.default.fileExists(atPath: hermesDir)
        LogService.info("HermesService initialized, installed=\(isInstalled)", category: "HermesService")
    }

    func connect() {
        guard isInstalled else { return }
        LogService.info("Starting Hermes file-based monitoring", category: "HermesService")
        startPolling()
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        isOnline = false
        LogService.info("Disconnected from Hermes monitoring", category: "HermesService")
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        pollTimer?.fire()
    }

    private func poll() {
        checkOnline()
        guard isOnline else { return }
        queryActiveSessions()
    }

    // MARK: - Online Detection

    private func checkOnline() {
        let pidPath = (hermesDir as NSString).appendingPathComponent("gateway.pid")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pidPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int else {
            if isOnline {
                LogService.info("Hermes gateway.pid missing", category: "HermesService")
            }
            isOnline = false
            return
        }

        let alive = kill(pid_t(pid), 0) == 0
        let wasOnline = isOnline
        isOnline = alive

        if !wasOnline, alive {
            LogService.info("Hermes gateway online (pid \(pid))", category: "HermesService")
        } else if wasOnline, !alive {
            LogService.info("Hermes gateway offline", category: "HermesService")
        }
    }

    // MARK: - Session Query

    private func queryActiveSessions() {
        let profileName = activeProfileName()
        let dbPath = hermesDir + "/profiles/" + profileName + "/state.db"

        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        // Set WAL mode to avoid blocking the writer
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)

        var updated: [String: MonitoredAgent] = [:]

        // Query sessions with ended_at IS NULL (still active)
        let query = """
            SELECT s.id, s.source, s.model, s.message_count, s.tool_call_count, s.title,
                   (SELECT m.content FROM messages m WHERE m.session_id = s.id AND m.role = 'assistant' ORDER BY m.timestamp DESC LIMIT 1) as last_msg,
                   (SELECT m.tool_name FROM messages m WHERE m.session_id = s.id AND m.role = 'tool' ORDER BY m.timestamp DESC LIMIT 1) as last_tool,
                   (SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = s.id) as last_ts,
                   (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id AND m.timestamp > ?) as recent_count
            FROM sessions s
            WHERE s.ended_at IS NULL
            ORDER BY s.started_at DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        let cutoff = Date().timeIntervalSince1970 - 10
        sqlite3_bind_double(stmt, 1, cutoff)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let source = String(cString: sqlite3_column_text(stmt, 1))
            let model = String(cString: sqlite3_column_text(stmt, 2))
            let messageCount = sqlite3_column_int(stmt, 3)
            let toolCallCount = sqlite3_column_int(stmt, 4)

            let title: String = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let lastMsg: String? = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let lastTool: String? = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let lastTs = sqlite3_column_double(stmt, 8)
            let recentCount = sqlite3_column_int(stmt, 9)

            let state = determineState(
                source: source,
                lastTool: lastTool,
                lastTs: lastTs,
                recentCount: recentCount
            )

            let displayTitle = title.isEmpty ? "Hermes (\(model))" : title
            let truncatedMsg = lastMsg.map { String($0.prefix(120)) }

            updated[id] = MonitoredAgent(
                id: id,
                name: displayTitle,
                emoji: "🐦",
                state: state,
                currentTool: lastTool,
                lastMessage: truncatedMsg,
                workspace: nil,
                lastEventTime: Date(timeIntervalSince1970: lastTs)
            )

            lastMessageTimestamps[id] = lastTs
        }

        agents = updated
        updateActiveAgent()
    }

    // MARK: - State Detection

    private func determineState(
        source: String,
        lastTool: String?,
        lastTs: Double,
        recentCount: Int32
    ) -> AgentMonitorState {
        let timeSinceLastMessage = Date().timeIntervalSince1970 - lastTs

        // If last activity was within 30 seconds and there's a tool, agent is tool-calling
        if let tool = lastTool, !tool.isEmpty, timeSinceLastMessage < 30 {
            return .toolCalling
        }

        // If recent messages (within 10s window), agent is actively working
        if recentCount > 0, timeSinceLastMessage < 30 {
            return lastTool != nil ? .toolCalling : .speaking
        }

        // If last activity was within 2 minutes, consider it working
        if timeSinceLastMessage < 120 {
            return .working
        }

        return .idle
    }

    private func activeProfileName() -> String {
        let path = hermesDir + "/active_profile"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return "default" }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    private func updateActiveAgent() {
        activeAgent = agents.values
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
            .first
    }
}
