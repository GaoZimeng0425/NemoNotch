import Foundation

enum AgentMonitorState: String, Codable {
    case idle
    case working
    case speaking
    case toolCalling
    case error

    static func normalize(_ raw: String) -> AgentMonitorState {
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

struct MonitoredAgent: Identifiable {
    let id: String
    var name: String
    var emoji: String
    /// Asset catalog image name. When non-nil, UI prefers it over `emoji`.
    var iconAssetName: String?
    var state: AgentMonitorState
    var currentTool: String?
    var lastMessage: String?
    var workspace: String?
    var lastEventTime: Date

    init(
        id: String,
        name: String = "Agent",
        emoji: String = "🤖",
        iconAssetName: String? = nil,
        state: AgentMonitorState = .idle,
        currentTool: String? = nil,
        lastMessage: String? = nil,
        workspace: String? = nil,
        lastEventTime: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.iconAssetName = iconAssetName
        self.state = state
        self.currentTool = currentTool
        self.lastMessage = lastMessage
        self.workspace = workspace
        self.lastEventTime = lastEventTime
    }
}

@MainActor
protocol MultiAgentMonitor: AnyObject {
    var agents: [String: MonitoredAgent] { get }
    var activeAgent: MonitoredAgent? { get }
    var isOnline: Bool { get }
    var isInstalled: Bool { get }
    var displayName: String { get }
    var iconEmoji: String { get }
    /// Optional asset catalog image name. When non-nil, UI prefers it over `iconEmoji`. Default: nil.
    var iconAssetName: String? { get }
    /// Optional per-session recent messages, keyed by session id. Default: empty.
    var sessionMessages: [String: [ChatMessage]] { get }
    func connect()
    func disconnect()
}

@MainActor
extension MultiAgentMonitor {
    var iconAssetName: String? {
        nil
    }

    var sessionMessages: [String: [ChatMessage]] {
        [:]
    }
}
