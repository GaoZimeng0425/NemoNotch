import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleNotch = Self("toggleNotch")
    static let openOverview = Self("openOverview", default: .init(.one, modifiers: [.option, .command]))
    static let openAI = Self("openAI", default: .init(.two, modifiers: [.option, .command]))
    static let openAgents = Self("openAgents", default: .init(.three, modifiers: [.option, .command]))
    static let openLauncher = Self("openLauncher", default: .init(.four, modifiers: [.option, .command]))
    static let openSystem = Self("openSystem", default: .init(.five, modifiers: [.option, .command]))
}

extension Tab {
    var hotkeyName: KeyboardShortcuts.Name {
        switch self {
        case .overview: return .openOverview
        case .claude: return .openAI
        case .agents: return .openAgents
        case .launcher: return .openLauncher
        case .system: return .openSystem
        }
    }
}
