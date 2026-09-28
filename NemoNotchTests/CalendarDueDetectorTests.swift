@testable import NemoNotch
import CoreGraphics
import Foundation
import Testing

@Suite("CalendarDueDetector")
struct CalendarDueDetectorTests {
    private let color = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    private let now = Date()

    private func event(
        _ title: String,
        startOffset: TimeInterval,
        duration: TimeInterval = 3600,
        allDay: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            title: title,
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(startOffset + duration),
            calendarColor: color,
            isAllDay: allDay
        )
    }

    private func due(_ events: [CalendarEvent], leadMinutes: Int = 0) -> [String] {
        CalendarDueDetector.dueEvents(in: events, now: now, leadMinutes: leadMinutes).map(\.title)
    }

    @Test("event starting exactly now is due")
    func atStartIsDue() {
        #expect(due([event("Standup", startOffset: 0)]) == ["Standup"])
    }

    @Test("event starting in the future is not due with zero lead")
    func futureNotDue() {
        #expect(due([event("Standup", startOffset: 60)]).isEmpty)
    }

    @Test("event within the late grace is still due")
    func withinLateGraceIsDue() {
        #expect(due([event("Standup", startOffset: -60)]) == ["Standup"])
    }

    @Test("event past the late grace is never due")
    func pastLateGraceNotDue() {
        #expect(due([event("Standup", startOffset: -NotchConstants.calendarDueLateGrace - 1)]).isEmpty)
    }

    @Test("lead minutes open the window early")
    func leadOpensWindowEarly() {
        let e = event("Standup", startOffset: 4 * 60)
        #expect(due([e], leadMinutes: 5) == ["Standup"])
        #expect(due([e], leadMinutes: 3).isEmpty)
    }

    @Test("all-day events never fire")
    func allDayNeverFires() {
        #expect(due([event("Away day", startOffset: 0, duration: 24 * 3600, allDay: true)]).isEmpty)
    }

    @Test("multiple simultaneous events all reported")
    func multipleDue() {
        let events = [event("A", startOffset: 0), event("B", startOffset: -30), event("C", startOffset: 600)]
        #expect(due(events) == ["A", "B"])
    }

    @Test("dedup key is stable across refetched instances")
    func dedupKeyStable() {
        // fetchEvents rebuilds values on EKEventStoreChanged — same event comes
        // back as a new instance (fresh UUID id) but must dedup.
        let a = event("Standup", startOffset: 0)
        let b = event("Standup", startOffset: 0)
        #expect(a.id != b.id)
        #expect(CalendarDueDetector.dedupKey(a) == CalendarDueDetector.dedupKey(b))
    }

    @Test("dedup key separates same-time different-title events")
    func dedupKeySeparates() {
        #expect(CalendarDueDetector.dedupKey(event("A", startOffset: 0))
            != CalendarDueDetector.dedupKey(event("B", startOffset: 0)))
        #expect(CalendarDueDetector.dedupKey(event("A", startOffset: 0))
            != CalendarDueDetector.dedupKey(event("A", startOffset: 60)))
    }
}
