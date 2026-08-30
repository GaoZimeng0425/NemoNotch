@testable import NemoNotch
import CoreGraphics
import Foundation
import Testing

@Suite("CalendarEvent meeting link selection")
struct CalendarEventTests {
    private func event(
        url: String? = nil,
        location: String? = nil,
        notes: String? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            calendarColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            isAllDay: false,
            url: url.flatMap(URL.init(string:)),
            location: location,
            notes: notes
        )
    }

    @Test("notes Meet link beats a generic link that appears earlier in the notes")
    func meetBeatsEarlierDocLink() {
        let e = event(notes: "会议记录: https://docs.google.com/document/d/abc\nMeet: https://meet.google.com/abc-defg-hij")
        #expect(e.meetingURL?.host == "meet.google.com")
        #expect(e.meetingPlatform == .googleMeet)
    }

    @Test("notes Meet link beats a generic URL field")
    func meetBeatsGenericURLField() {
        let e = event(url: "https://example.com/wiki/meeting", notes: "join: https://meet.google.com/xyz-abcd-123")
        #expect(e.meetingURL?.host == "meet.google.com")
    }

    @Test("URL-field Meet link wins ties against a notes Meet link")
    func urlFieldWinsTies() {
        let e = event(url: "https://meet.google.com/url-one", notes: "fallback https://meet.google.com/notes-two")
        #expect(e.meetingURL?.absoluteString == "https://meet.google.com/url-one")
    }

    @Test("zoom URL field beats generic links in text")
    func zoomBeatsGeneric() {
        let e = event(url: "https://example.com", notes: "https://us05web.zoom.us/j/123456")
        #expect(e.meetingURL?.host == "us05web.zoom.us")
        #expect(e.meetingPlatform == .zoom)
    }

    @Test("Meet outranks Zoom regardless of where each appears")
    func meetOutranksZoom() {
        let e = event(url: "https://zoom.us/j/999", notes: "https://meet.google.com/abc-defg-hij")
        #expect(e.meetingURL?.host == "meet.google.com")
    }

    @Test("teams link ranks between zoom and generic")
    func teamsRanking() {
        let e = event(notes: "https://example.com https://teams.microsoft.com/l/meetup-join/abc")
        #expect(e.meetingURL?.host?.contains("teams.microsoft.com") == true)
        #expect(e.meetingPlatform == .teams)
    }

    @Test("no known platform anywhere falls back to the first link in text order")
    func genericFallsBackToFirst() {
        let e = event(notes: "docs https://a.example.com then https://b.example.com")
        #expect(e.meetingURL?.host == "a.example.com")
    }

    @Test("no links at all yields nil and generic platform")
    func noLinksYieldsNil() {
        let e = event(location: "会议室 A", notes: "带好笔记本")
        #expect(e.meetingURL == nil)
        #expect(e.meetingPlatform == .generic)
    }

    @Test("bare domain text without scheme is still detected (http synthesized)")
    func bareDomainDetected() {
        let e = event(notes: "see meet.google.com/abc-defg-hij for details")
        #expect(e.meetingURL?.host == "meet.google.com")
        #expect(e.meetingPlatform == .googleMeet)
    }
}
