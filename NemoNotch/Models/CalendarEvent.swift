import AppKit
import Foundation

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarColor: CGColor
    let isAllDay: Bool

    init(title: String, startDate: Date, endDate: Date, calendarColor: CGColor, isAllDay: Bool) {
        self.id = "\(title)-\(startDate.timeIntervalSince1970)"
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.calendarColor = calendarColor
        self.isAllDay = isAllDay
    }

    var isPast: Bool { endDate < Date() }
}
