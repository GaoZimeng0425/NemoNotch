import SwiftUI

enum BadgeItem: Identifiable, Equatable {
    case notification(bundleID: String, count: Int)
    case media
    case ai(source: AISource, status: ClaudeStatus, tool: String?, waitingApproval: Bool, sessionID: String)
    case agents(agentID: String, state: AgentMonitorState, emoji: String)
    case calendar

    var id: String {
        switch self {
        case let .notification(bundleID, _): "notification:\(bundleID)"
        case .media: "media"
        case let .ai(source, status, tool, waitingApproval, sessionID):
            "ai:\(sessionID):\(source.rawValue):\(status):\(tool ?? "nil"):\(waitingApproval)"
        case let .agents(agentID, state, emoji): "agents:\(agentID):\(state.rawValue):\(emoji)"
        case .calendar: "calendar"
        }
    }

    var tab: Tab {
        switch self {
        case .notification: .overview
        case .media: .overview
        case .ai: .claude
        case .agents: .agents
        case .calendar: .overview
        }
    }

    /// Lower value = higher priority
    var priority: Int {
        switch self {
        case let .ai(_, _, _, waitingApproval, _) where waitingApproval:
            return 0
        case .notification:
            return 1
        case .agents:
            return 2
        case .ai:
            return 3
        case .media:
            return 4
        case .calendar:
            return 5
        }
    }
}
