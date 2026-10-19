import SwiftUI

/// Activity glow shown on the expanded notch body. `running` = AI working or an
/// agent active (green); `attention` = a session waiting for approval (amber).
enum NotchGlow: Equatable {
    case none
    case running
    case attention
}

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
        case .agents: .claude
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

    /// The collapsed notch's AI-session badges: one per session of an enabled
    /// provider that awaits approval or is working. None while the edge bar
    /// is shown — its rings already carry these sessions, so the notch would
    /// only repeat them (and with no AI badge, the expanded glow follows only
    /// agents). Switch the bar off and they come back.
    static func sessionItems(
        _ sessions: [AISessionState],
        edgeBarShown: Bool,
        isEnabled: (AISource) -> Bool
    ) -> [BadgeItem] {
        guard !edgeBarShown else { return [] }
        return sessions.compactMap { session in
            guard isEnabled(session.source) else { return nil }
            if session.phase.isWaitingForApproval {
                return .ai(
                    source: session.source,
                    status: .waiting,
                    tool: session.phase.approvalToolName,
                    waitingApproval: true,
                    sessionID: session.id
                )
            }
            guard session.status == .working else { return nil }
            return .ai(
                source: session.source,
                status: session.status,
                tool: session.currentTool,
                waitingApproval: false,
                sessionID: session.id
            )
        }
    }

    /// Decides the expanded-notch glow from the currently active badge set.
    /// Approval wins over running work; media / calendar / notification /
    /// pomodoro never glow. Pure function — input is the already
    /// provider-filtered `activeBadgeItems`.
    static func glow(for items: [BadgeItem]) -> NotchGlow {
        var hasRunning = false
        for item in items {
            switch item {
            case let .ai(_, _, _, waitingApproval, _) where waitingApproval:
                return .attention
            case let .ai(_, status, _, _, _) where status == .working:
                hasRunning = true
            case .agents:
                hasRunning = true
            default:
                break
            }
        }
        return hasRunning ? .running : .none
    }
}
