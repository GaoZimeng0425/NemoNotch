import Foundation

/// UI 测试用的假 agent monitor:isInstalled+isOnline 恒为 true,
/// agents 由构造时注入。注册进 AgentMonitorRegistry 后即渲染 agentSections。
@MainActor
@Observable
final class UITestMockAgentMonitor: MultiAgentMonitor {
    let displayName: String
    let iconEmoji: String
    private(set) var agents: [String: MonitoredAgent]

    init(displayName: String, iconEmoji: String, agents: [MonitoredAgent]) {
        self.displayName = displayName
        self.iconEmoji = iconEmoji
        self.agents = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
    }

    var activeAgent: MonitoredAgent? {
        agents.values.first { $0.state != .idle }
    }

    var isOnline: Bool {
        true
    }

    var isInstalled: Bool {
        true
    }

    func connect() {}
    func disconnect() {}
}
