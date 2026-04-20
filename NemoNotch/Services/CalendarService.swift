import EventKit
import SwiftUI

@Observable
final class CalendarService {
    var todayEvents: [CalendarEvent] = []
    var nextEvent: CalendarEvent?
    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    var selectedDate: Date = Date()

    private(set) var multiDayEvents: [Date: [CalendarEvent]] = [:]
    private let eventStore = EKEventStore()

    var eventsForSelectedDate: [CalendarEvent] {
        let key = startOfDay(for: selectedDate)
        return multiDayEvents[key] ?? []
    }

    var dateRange: [Date] {
        let calendar = Calendar.current
        let today = startOfDay(for: Date())
        return (-7...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    var selectedMonthLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月"
        return formatter.string(from: selectedDate)
    }

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        requestAccessIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventsChanged),
            name: .EKEventStoreChanged,
            object: nil
        )
    }

    func requestAccess() {
        Task { @MainActor in
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                authorizationStatus = granted ? .fullAccess : .denied
                if granted {
                    fetchEvents()
                }
            } catch {
                authorizationStatus = .denied
            }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func hasEvents(on date: Date) -> Bool {
        let key = startOfDay(for: date)
        return !(multiDayEvents[key]?.isEmpty ?? true)
    }

    private func startOfDay(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    @objc private func eventsChanged() {
        fetchEvents()
    }

    private func requestAccessIfNeeded() {
        switch authorizationStatus {
        case .notDetermined:
            requestAccess()
        case .fullAccess:
            fetchEvents()
        default:
            break
        }
    }

    private func fetchEvents() {
        guard authorizationStatus == .fullAccess else { return }

        let calendar = Calendar.current
        let today = Date()
        guard let rangeStart = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: today)),
              let rangeEnd = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: today)) else { return }

        let predicate = eventStore.predicateForEvents(
            withStart: rangeStart,
            end: rangeEnd,
            calendars: nil
        )

        let ekEvents = eventStore.events(matching: predicate)

        var grouped: [Date: [CalendarEvent]] = [:]
        for ek in ekEvents {
            let key = calendar.startOfDay(for: ek.startDate)
            let event = CalendarEvent(
                title: ek.title,
                startDate: ek.startDate,
                endDate: ek.endDate,
                calendarColor: ek.calendar.cgColor,
                isAllDay: ek.isAllDay
            )
            grouped[key, default: []].append(event)
        }

        for (key, var events) in grouped {
            events.sort { $0.startDate < $1.startDate }
            grouped[key] = events
        }

        multiDayEvents = grouped

        let todayKey = calendar.startOfDay(for: today)
        todayEvents = grouped[todayKey] ?? []
        nextEvent = todayEvents.first { !$0.isPast }
    }
}
