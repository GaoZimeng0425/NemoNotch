import EventKit
import SwiftUI

@Observable
final class CalendarService {
    var todayEvents: [CalendarEvent] = []
    var nextEvent: CalendarEvent?
    var authorizationStatus: EKAuthorizationStatus = .notDetermined

    private let eventStore = EKEventStore()

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .fullAccess || authorizationStatus == .authorized {
            fetchEvents()
        }

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

    @objc private func eventsChanged() {
        fetchEvents()
    }

    private func fetchEvents() {
        let calendar = Calendar.current
        let now = Date()
        guard let startOfDay = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: now)),
              let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }

        let predicate = eventStore.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: nil
        )

        let ekEvents = eventStore.events(matching: predicate)
        let events = ekEvents
            .filter { !$0.isAllDay || true }
            .sorted { $0.startDate < $1.startDate }
            .map { ek in
                CalendarEvent(
                    title: ek.title,
                    startDate: ek.startDate,
                    endDate: ek.endDate,
                    calendarColor: ek.calendar.cgColor,
                    isAllDay: ek.isAllDay
                )
            }

        todayEvents = events
        nextEvent = events.first { !$0.isPast }
    }
}
