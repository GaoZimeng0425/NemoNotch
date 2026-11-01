import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview
    case claude

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .claude: "sparkles"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "models.tab.overview"
        case .claude: "models.tab.ai"
        }
    }

    /// Which side of the chin bar this tab renders on. Every remaining tab is
    /// a content tab and sits on the left; the right cluster holds only
    /// settings/quit. Kept as a seam for future personal-tool tabs.
    var chinPlacement: ChinPlacement {
        .left
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
