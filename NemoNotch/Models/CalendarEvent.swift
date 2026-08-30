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
        // Collect every link we can see — the event's URL field, then every
        // link in location and notes in text order — and let the best-known
        // meeting platform win. A Meet link buried mid-notes should beat a
        // doc link that merely appears first; ties keep the earlier source.
        var candidates: [URL] = []
        if let url { candidates.append(url) }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return candidates.first
        }
        for field in [location, notes].compactMap({ $0 }) {
            let range = NSRange(field.startIndex..., in: field)
            candidates.append(contentsOf: detector.matches(in: field, range: range).compactMap(\.url))
        }
        return candidates.min { Self.platformRank($0) < Self.platformRank($1) }
    }

    /// Lower wins. macOS EventKit can't see Google's conferenceData (the
    /// "Join Meet" button data), so text links are all we ever get — rank
    /// the platforms we recognize and let real meeting links beat generic URLs.
    static func platformRank(_ url: URL) -> Int {
        switch platform(for: url) {
        case .googleMeet: 0
        case .zoom: 1
        case .teams: 2
        case .generic: 3
        }
    }

    static func platform(for url: URL) -> MeetingPlatform {
        guard let host = url.host?.lowercased() else { return .generic }
        if host.contains("meet.google.com") { return .googleMeet }
        if host.contains("zoom.us") { return .zoom }
        if host.contains("teams.microsoft.com") { return .teams }
        return .generic
    }

    var meetingPlatform: MeetingPlatform {
        meetingURL.map(Self.platform(for:)) ?? .generic
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
