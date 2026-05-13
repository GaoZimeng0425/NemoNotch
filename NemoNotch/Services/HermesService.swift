import Foundation

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
    private let baseURL: String

    init() {
        let hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        isInstalled = FileManager.default.fileExists(atPath: hermesDir)
        baseURL = "http://127.0.0.1:8787"

        LogService.info("HermesService initialized, installed=\(isInstalled)", category: "HermesService")
    }

    func connect() {
        guard isInstalled else { return }
        LogService.info("Connecting to Hermes WebUI at \(baseURL)", category: "HermesService")
        startPolling()
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        isOnline = false
        LogService.info("Disconnected from Hermes WebUI", category: "HermesService")
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await pollHealth()
                if isOnline {
                    await pollSessions()
                }
            }
        }
        pollTimer?.fire()
    }

    private func pollHealth() async {
        guard let url = URL(string: "\(baseURL)/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let wasOnline = isOnline
            isOnline = statusCode == 200

            if !wasOnline, isOnline {
                LogService.info("Hermes WebUI online", category: "HermesService")
            } else if wasOnline, !isOnline {
                LogService.info("Hermes WebUI offline", category: "HermesService")
            }
        } catch {
            if isOnline {
                LogService.warn("Hermes health check failed: \(error)", category: "HermesService")
            }
            isOnline = false
        }
    }

    private func pollSessions() async {
        guard let url = URL(string: "\(baseURL)/api/sessions") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            parseSessions(json)
        } catch {
            LogService.warn("Hermes sessions poll failed: \(error)", category: "HermesService")
        }
    }

    // MARK: - Parsing

    private func parseSessions(_ sessions: [[String: Any]]) {
        var updated: [String: MonitoredAgent] = [:]

        for session in sessions {
            guard let id = session["id"] as? String else { continue }
            let name = session["title"] as? String ?? "Session"
            let stateStr = session["status"] as? String ?? "idle"
            let tool = session["current_tool"] as? String
            let msg = session["last_message"] as? String
            let workspace = session["workspace"] as? String

            let state = AgentMonitorState.normalize(stateStr)
            let truncated = msg.map { String($0.prefix(120)) }

            updated[id] = MonitoredAgent(
                id: id,
                name: name,
                emoji: "🐦",
                state: state,
                currentTool: tool,
                lastMessage: truncated,
                workspace: workspace,
                lastEventTime: Date()
            )
        }

        agents = updated
        updateActiveAgent()
    }

    private func updateActiveAgent() {
        activeAgent = agents.values
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
            .first
    }
}
