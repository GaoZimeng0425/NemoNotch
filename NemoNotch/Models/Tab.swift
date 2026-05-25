import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview
    case claude
    case agents
    case launcher
    case pomodoro
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
        case .pomodoro: "timer"
        case .system: "gearshape.2"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "models.tab.overview"
        case .claude: "models.tab.ai"
        case .agents: "models.tab.agents"
        case .launcher: "models.tab.launcher"
        case .pomodoro: "models.tab.pomodoro"
        case .system: "models.tab.system"
        }
    }
}

extension Tab {
    static func sorted(_ tabs: Set<Tab>) -> [Tab] {
        tabs.sorted { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
    }
}
