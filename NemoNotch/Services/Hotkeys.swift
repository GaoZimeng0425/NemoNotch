import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleNotch = Self("toggleNotch")
    static let openOverview = Self("openOverview", default: .init(.one, modifiers: [.option, .command]))
    static let openAI = Self("openAI", default: .init(.two, modifiers: [.option, .command]))
}

extension Tab {
    var hotkeyName: KeyboardShortcuts.Name {
        switch self {
        case .overview: return .openOverview
        case .claude: return .openAI
        }
    }
}
