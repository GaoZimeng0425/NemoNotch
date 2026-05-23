import SwiftUI

enum BadgeItem: Identifiable, Equatable {
    case notification(bundleID: String, count: Int)
    case media
    case ai(source: AISource, status: ClaudeStatus, tool: String?, waitingApproval: Bool, sessionID: String)
    case agents(agentID: String, state: AgentMonitorState, emoji: String)
    case calendar
    case pomodoro(phase: PomodoroPhase)

    var id: String {
        switch self {
        case let .notification(bundleID, _): "notification:\(bundleID)"
        case .media: "media"
        case let .ai(source, status, tool, waitingApproval, sessionID):
            "ai:\(sessionID):\(source.rawValue):\(status):\(tool ?? "nil"):\(waitingApproval)"
        case let .agents(agentID, state, emoji): "agents:\(agentID):\(state.rawValue):\(emoji)"
        case .calendar: "calendar"
        case let .pomodoro(phase): "pomodoro:\(phase.rawValue)"
        }
    }

    var tab: Tab {
        switch self {
        case .notification: .overview
        case .media: .overview
        case .ai: .claude
        case .agents: .agents
        case .calendar: .overview
        case .pomodoro: .pomodoro
        }
    }

    /// Lower value = higher priority
    var priority: Int {
        switch self {
        case let .ai(_, _, _, waitingApproval, _) where waitingApproval:
            return 0
        case .notification:
            return 1
        case .pomodoro:
            return 2
        case .agents:
            return 3
        case .ai:
            return 4
        case .media:
            return 5
        case .calendar:
            return 6
        }
    }
}
