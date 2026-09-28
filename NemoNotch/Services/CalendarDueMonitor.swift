import EventKit
import Foundation

/// Pure decision function for "which calendar events are due right now".
/// An event is due once `now` has crossed into its lead window but not yet
/// left the late grace: `startDate - lead <= now <= startDate + lateGrace`.
/// Events long past their start (e.g. from before the app launched) never
/// fire — a reminder for a meeting that started ten minutes ago is noise.
/// All-day events never fire (their startDate is midnight).
enum CalendarDueDetector {
    static func dueEvents(
        in events: [CalendarEvent],
        now: Date,
        leadMinutes: Int,
        lateGrace: TimeInterval = NotchConstants.calendarDueLateGrace
    ) -> [CalendarEvent] {
        let lead = TimeInterval(max(0, leadMinutes) * 60)
        return events.filter { event in
            guard !event.isAllDay else { return false }
            let start = event.startDate
            return now >= start.addingTimeInterval(-lead)
                && now <= start.addingTimeInterval(lateGrace)
        }
    }

    /// Stable identity for dedup across CalendarService refetches.
    /// `CalendarEvent.id` is a fresh UUID on every init (fetchEvents rebuilds
    /// all values on EKEventStoreChanged), so the due monitor keys "already
    /// announced" on start time + title instead.
    static func dedupKey(_ event: CalendarEvent) -> String {
        "\(event.startDate.timeIntervalSince1970)|\(event.title)"
    }
}

/// Ticks on a slow clock and fires the shared full-screen flash + toast when
/// a calendar event reaches its (configurable) lead window. CalendarService
/// only refetches on EKEventStoreChanged, so the monitor also nudges a
/// refresh at day rollover — `todayEvents` would otherwise go stale at
/// midnight with the -7…+8 day window already fetched but never regrouped.
@MainActor
@Observable
final class CalendarDueMonitor {
    private let calendar: CalendarService
    private let completionFlash: CompletionFlashService
    private let settings: AppSettings

    private var started = false
    private var currentDay: Date?
    private var firedKeys: Set<String> = []
    private var tickTask: Task<Void, Never>?

    init(calendar: CalendarService, completionFlash: CompletionFlashService, settings: AppSettings) {
        self.calendar = calendar
        self.completionFlash = completionFlash
        self.settings = settings
        LogService.info("CalendarDueMonitor init", category: "CalendarDueMonitor")
    }

    deinit {
        MainActor.assumeIsolated {
            tickTask?.cancel()
            LogService.info("CalendarDueMonitor deinit", category: "CalendarDueMonitor")
        }
    }

    func start() {
        guard !started else { return }
        started = true
        currentDay = Calendar.current.startOfDay(for: Date())
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(NotchConstants.calendarDueTickInterval))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
        LogService.info("Calendar due monitor started", category: "CalendarDueMonitor")
    }

    private func tick() {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        if today != currentDay {
            currentDay = today
            calendar.refresh()
            LogService.info("Day rollover — calendar refetched", category: "CalendarDueMonitor")
        }
        guard settings.calendarDueFlashEnabled,
              calendar.authorizationStatus == .fullAccess
        else { return }
        let due = CalendarDueDetector.dueEvents(
            in: calendar.todayEvents,
            now: now,
            leadMinutes: settings.calendarDueLeadMinutes
        )
        let fresh = due.filter { !firedKeys.contains(CalendarDueDetector.dedupKey($0)) }
        guard !fresh.isEmpty else { return }
        for event in fresh {
            firedKeys.insert(CalendarDueDetector.dedupKey(event))
        }
        let items = fresh.map { event in
            CompletionItem(
                name: event.title.isEmpty
                    ? String(localized: "calendar.untitled_event")
                    : event.title,
                source: .calendar
            )
        }
        LogService.info("Calendar event(s) due: \(items.map(\.name))", category: "CalendarDueMonitor")
        completionFlash.showCompletionFlash(items: items)
    }
}
