import Foundation

enum ClaudeStatus: Equatable {
    case idle
    case working
    case waiting
}

struct ClaudeState: Identifiable {
    let id: String
    var status: ClaudeStatus = .idle
    var currentTool: String?
    var sessionStart: Date
    var lastEventTime: Date

    init(sessionId: String) {
        self.id = sessionId
        self.sessionStart = Date()
        self.lastEventTime = Date()
    }
}
