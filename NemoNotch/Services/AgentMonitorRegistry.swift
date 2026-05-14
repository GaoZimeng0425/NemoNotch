import Foundation

@MainActor
@Observable
final class AgentMonitorRegistry {
    private(set) var monitors: [any MultiAgentMonitor] = []

    func register(_ monitor: any MultiAgentMonitor) {
        monitors.append(monitor)
    }

    var installedMonitors: [any MultiAgentMonitor] {
        monitors.filter(\.isInstalled)
    }

    var anyActiveAgent: MonitoredAgent? {
        installedMonitors.lazy.compactMap(\.activeAgent).first
    }

    var hasAnyActiveAgent: Bool {
        anyActiveAgent != nil
    }

    /// Non-idle agents across all installed monitors, sorted by lastEventTime descending.
    var activeAgents: [MonitoredAgent] {
        installedMonitors
            .flatMap(\.agents.values)
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
    }
}
