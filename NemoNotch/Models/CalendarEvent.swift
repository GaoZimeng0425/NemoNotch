import AppKit
import Foundation
import SwiftUI

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarColor: CGColor
    let isAllDay: Bool
    let url: URL?
    let location: String?
    let notes: String?

    init(
        title: String, startDate: Date, endDate: Date,
        calendarColor: CGColor, isAllDay: Bool,
        url: URL? = nil, location: String? = nil, notes: String? = nil
    ) {
        self.id = UUID().uuidString
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarColor = calendarColor
        self.isAllDay = isAllDay
        self.url = url
        self.location = location
        self.notes = notes
    }

    var isPast: Bool { endDate < Date() }

    var meetingURL: URL? {
        if let url { return url }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let fields = [location, notes].compactMap { $0 }
        for field in fields {
            let range = NSRange(field.startIndex..., in: field)
            if let match = detector.firstMatch(in: field, range: range),
               let url = match.url
            {
                return url
            }
        }
        return nil
    }

    var meetingPlatform: MeetingPlatform {
        guard let host = meetingURL?.host?.lowercased() else { return .generic }
        if host.contains("meet.google.com") { return .googleMeet }
        if host.contains("zoom.us") { return .zoom }
        if host.contains("teams.microsoft.com") { return .teams }
        return .generic
    }
}

enum MeetingPlatform {
    case googleMeet, zoom, teams, generic

    var iconName: String {
        switch self {
        case .googleMeet, .zoom, .teams: "video.fill"
        case .generic: "link"
        }
    }

    var iconColor: Color {
        switch self {
        case .googleMeet: Color(red: 0.27, green: 0.53, blue: 0.93)
        case .zoom: Color(red: 0.36, green: 0.58, blue: 0.89)
        case .teams: Color(red: 0.44, green: 0.29, blue: 0.79)
        case .generic: NotchTheme.textTertiary
        }
    }
}
