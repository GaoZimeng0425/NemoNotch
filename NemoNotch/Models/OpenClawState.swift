import Foundation

enum AgentState: String, Codable {
    case idle
    case working
    case speaking
    case toolCalling
    case error

    static func normalize(_ raw: String) -> AgentState {
        switch raw.lowercased() {
        case "idle": return .idle
        case "working", "busy", "write", "writing": return .working
        case "speaking", "talking": return .speaking
        case "tool_calling", "toolcalling", "executing", "run", "running", "execute", "exec":
            return .toolCalling
        case "error": return .error
        default: return .idle
        }
    }

    var icon: String {
        switch self {
        case .idle: "pause.circle"
        case .working: "gearshape"
        case .speaking: "bubble.left.fill"
        case .toolCalling: "wrench.and.screwdriver"
        case .error: "exclamationmark.triangle"
        }
    }

    var color: String {
        switch self {
        case .idle: "gray"
        case .working: "blue"
        case .speaking: "green"
        case .toolCalling: "orange"
        case .error: "red"
        }
    }
}

struct AgentInfo: Identifiable {
    let id: String
    var name: String
    var state: AgentState
    var currentTool: String?
    var lastMessage: String?
    var workspace: String?
    var lastEventTime: Date

    init(id: String, name: String = "Agent", state: AgentState = .idle) {
        self.id = id
        self.name = name
        self.state = state
        self.lastEventTime = Date()
    }
}
