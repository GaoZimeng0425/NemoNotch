import Foundation

/// The detail lines of a calendar-due toast card: "HH:mm–HH:mm · location"
/// and, when the event carries a link, the meeting platform or link host.
struct CalendarCard: Equatable {
    let timeLine: String
    let linkLabel: String?
}

/// Builds the toast item for a calendar event coming due. The link is
/// snapshotted into `jump` (opened through `AppActivator`'s URL path), so a
/// click still works after the calendar refreshes during the card's 5 minutes.
enum CalendarToastCard {
    static func item(for event: CalendarEvent, timeZone: TimeZone = .current) -> CompletionItem {
        var item = CompletionItem(
            name: event.title.isEmpty ? String(localized: "calendar.untitled_event") : event.title,
            source: .calendar
        )
        let link = event.meetingURL
        item.calendar = CalendarCard(
            timeLine: timeLine(event, timeZone: timeZone),
            linkLabel: link.map(linkLabel(for:))
        )
        item.jump = link.flatMap { CompletionJump.make(hostPID: nil, hostBundleId: nil, tabLink: $0.absoluteString) }
        return item
    }

    private static func timeLine(_ event: CalendarEvent, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let range = "\(formatter.string(from: event.startDate))–\(formatter.string(from: event.endDate))"
        // A location that is only a link (common for video calls) is not a place.
        guard let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !location.isEmpty, !location.lowercased().hasPrefix("http")
        else { return range }
        return "\(range) · \(location)"
    }

    static func linkLabel(for url: URL) -> String {
        switch CalendarEvent.platform(for: url) {
        case .googleMeet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .generic:
            let host = url.host ?? url.absoluteString
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }
}
