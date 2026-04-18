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
    var cwd: String?
    var lastMessage: String?
    var lastEventName: String?
    var isPreToolUse = false
    var sessionStart: Date
    var lastEventTime: Date

    init(sessionId: String) {
        self.id = sessionId
        self.sessionStart = Date()
        self.lastEventTime = Date()
    }

    var projectFolder: String? {
        guard let cwd else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
