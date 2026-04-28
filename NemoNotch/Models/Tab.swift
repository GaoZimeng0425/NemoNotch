import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case media
    case calendar
    case claude
    case openclaw
    case launcher
    case weather
    case system

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .media: "music.note"
        case .calendar: "calendar"
        case .claude: "cpu"
        case .openclaw: "ladybug"
        case .launcher: "square.grid.2x2"
        case .weather: "cloud.sun.fill"
        case .system: "gearshape.2"
        }
    }

    var title: String {
        switch self {
        case .media: String(localized: "models.tab.media")
        case .calendar: String(localized: "models.tab.calendar")
        case .claude: String(localized: "models.tab.ai")
        case .openclaw: String(localized: "models.tab.openclaw")
        case .launcher: String(localized: "models.tab.launcher")
        case .weather: String(localized: "models.tab.weather")
        case .system: String(localized: "models.tab.system")
        }
    }
}

extension Tab {
    static func sorted(_ tabs: Set<Tab>) -> [Tab] {
        tabs.sorted { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
    }
}
