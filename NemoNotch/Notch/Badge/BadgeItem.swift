import SwiftUI

enum BadgeItem: Identifiable, Equatable {
    case notification(bundleID: String, count: Int)
    case media
    case ai(source: AISource, status: ClaudeStatus, tool: String?, waitingApproval: Bool, sessionID: String)
    case openclaw(state: AgentState, emoji: String)
    case calendar

    var id: String {
        switch self {
        case .notification(let bundleID, _): "notification:\(bundleID)"
        case .media: "media"
        case .ai(let source, let status, let tool, let waitingApproval, let sessionID):
            "ai:\(sessionID):\(source.rawValue):\(status):\(tool ?? "nil"):\(waitingApproval)"
        case .openclaw(let state, let emoji): "openclaw:\(state.rawValue):\(emoji)"
        case .calendar: "calendar"
        }
    }

    var tab: Tab {
        switch self {
        case .notification: .overview
        case .media: .overview
        case .ai: .claude
        case .openclaw: .openclaw
        case .calendar: .overview
        }
    }

    // Lower value = higher priority
    var priority: Int {
        switch self {
        case .ai(_, _, _, let waitingApproval, _) where waitingApproval:
            return 0
        case .notification:
            return 1
        case .openclaw:
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
