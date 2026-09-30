import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview
    case claude
    case launcher
    case pomodoro
    case system

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .claude: "sparkles"
        case .launcher: "square.grid.2x2"
        case .pomodoro: "timer"
        case .system: "gearshape.2"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "models.tab.overview"
        case .claude: "models.tab.ai"
        case .launcher: "models.tab.launcher"
        case .pomodoro: "models.tab.pomodoro"
        case .system: "models.tab.system"
        }
    }

    /// Which side of the chin bar this tab renders on. Most tabs sit on the
    /// left; pomodoro and system join settings/quit on the right so they read
    /// as a personal-tool cluster rather than content tabs.
    var chinPlacement: ChinPlacement {
        switch self {
        case .pomodoro, .system: .right
        default: .left
        }
    }
}

enum ChinPlacement {
    case left, right
}

extension Tab {
    static func sorted(_ tabs: Set<Tab>) -> [Tab] {
        tabs.sorted { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
    }
}
