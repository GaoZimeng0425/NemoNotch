import CoreGraphics
import Foundation
@testable import NemoNotch
import Testing

struct CalendarToastCardTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-30 06:00 UTC
    private let start = Date(timeIntervalSince1970: 1_793_340_000)

    private func event(location: String? = nil, url: URL? = nil, notes: String? = nil) -> CalendarEvent {
        CalendarEvent(
            title: "周会", startDate: start, endDate: start.addingTimeInterval(3600),
            calendarColor: CGColor(gray: 0, alpha: 1), isAllDay: false,
            url: url, location: location, notes: notes
        )
    }

    @Test func timeAndLocation() {
        let item = CalendarToastCard.item(for: event(location: "3F 会议室"), timeZone: utc)
        #expect(item.name == "周会")
        #expect(item.calendar == CalendarCard(timeLine: "06:00–07:00 · 3F 会议室", linkLabel: nil))
        #expect(item.jump == nil)
    }

    @Test func timeOnlyWithoutLocation() {
        let item = CalendarToastCard.item(for: event(), timeZone: utc)
        #expect(item.calendar?.timeLine == "06:00–07:00")
    }

    @Test func meetingLinkIsShownAndClickable() {
        let item = CalendarToastCard.item(
            for: event(location: "https://zoom.us/j/123", notes: "doc https://docs.google.com/x"),
            timeZone: utc
        )
        // A location that is just a link is not a place.
        #expect(item.calendar == CalendarCard(timeLine: "06:00–07:00", linkLabel: "Zoom"))
        #expect(item.jump == CompletionJump(hostPID: nil, hostBundleId: nil, tabLink: "https://zoom.us/j/123"))
    }

    @Test func genericLinkShowsHost() {
        let item = CalendarToastCard.item(for: event(url: URL(string: "https://www.example.com/agenda")), timeZone: utc)
        #expect(item.calendar?.linkLabel == "example.com")
        #expect(item.jump?.tabLink == "https://www.example.com/agenda")
    }

    @Test func untitledEventGetsPlaceholderName() {
        let untitled = CalendarEvent(
            title: "", startDate: start, endDate: start,
            calendarColor: CGColor(gray: 0, alpha: 1), isAllDay: false
        )
        #expect(CalendarToastCard.item(for: untitled, timeZone: utc)
            .name == String(localized: "calendar.untitled_event"))
    }
}
