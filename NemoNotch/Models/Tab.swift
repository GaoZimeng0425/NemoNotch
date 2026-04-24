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
        case .media: "媒体"
        case .calendar: "日历"
        case .claude: "AI"
        case .openclaw: "OpenClaw"
        case .launcher: "启动器"
        case .weather: "天气"
        case .system: "系统"
        }
    }
}

extension Tab {
    static func sorted(_ tabs: Set<Tab>) -> [Tab] {
        tabs.sorted { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
    }
}
