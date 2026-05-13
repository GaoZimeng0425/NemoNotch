import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview
    case claude
    case agents
    case launcher
    case system

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .claude: "cpu"
        case .agents: "ladybug.fill"
        case .launcher: "square.grid.2x2"
        case .system: "gearshape.2"
        }
    }

    var title: String {
        switch self {
        case .overview: String(localized: "models.tab.overview")
        case .claude: String(localized: "models.tab.ai")
        case .agents: String(localized: "models.tab.agents")
        case .launcher: String(localized: "models.tab.launcher")
        case .system: String(localized: "models.tab.system")
        }
    }
}

extension Tab {
    static func sorted(_ tabs: Set<Tab>) -> [Tab] {
        tabs.sorted { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
    }
}
