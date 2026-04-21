import EventKit
import SwiftUI

struct CalendarTab: View {
    @Environment(CalendarService.self) var calendarService

    var body: some View {
        switch calendarService.authorizationStatus {
        case .fullAccess:
            calendarContent
        case .notDetermined:
            permissionRequest
        default:
            permissionDenied
        }
    }

    private var calendarContent: some View {
        VStack(spacing: 0) {
            monthHeader
            DateStripView(
                dates: calendarService.dateRange,
                selectedDate: calendarService.selectedDate,
                hasEvents: { calendarService.hasEvents(on: $0) },
                onSelect: { calendarService.selectedDate = $0 }
            )
            .padding(.vertical, 4)

            Divider()
                .background(.white.opacity(0.08))
                .padding(.vertical, 4)

            eventListSection
        }
    }

    private var monthHeader: some View {
        Text(calendarService.selectedMonthLabel)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }

    private var permissionRequest: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.lock")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("需要日历权限")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Button("授权访问") {
                calendarService.requestAccess()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12))
            .clipShape(Capsule())
            .foregroundStyle(.white)
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionDenied: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("日历访问被拒绝")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Button("打开系统设置") {
                calendarService.openSystemSettings()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12))
            .clipShape(Capsule())
            .foregroundStyle(.white)
            .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var eventListSection: some View {
        let events = calendarService.eventsForSelectedDate
        return Group {
            if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(events) { event in
                            eventRow(event)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("该日无日程")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(cgColor: event.calendarColor))
                .frame(width: 3, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(event.isPast ? .white.opacity(0.3) : .white)
                    .lineLimit(1)
                Text(eventTimeRange(event))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(event.isPast ? 0.2 : 0.45))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.06))
        )
    }

    private func eventTimeRange(_ event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if event.isAllDay { return "全天" }
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }
}
