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
                .background(NotchTheme.stroke)
                .padding(.vertical, 4)

            eventListSection
        }
        .padding(.bottom, 12)
    }

    private var monthHeader: some View {
        Text(calendarService.selectedMonthLabel)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(NotchTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }

    private var permissionRequest: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.lock")
                .font(.system(size: 28))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("需要日历权限")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Button("授权访问") {
                calendarService.requestAccess()
            }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionDenied: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("日历访问被拒绝")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Button("打开系统设置") {
                calendarService.openSystemSettings()
            }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
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
                .foregroundStyle(NotchTheme.textTertiary)
            Text("该日无日程")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
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
                    .foregroundStyle(event.isPast ? NotchTheme.textMuted : NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(eventTimeRange(event))
                    .font(.system(size: 10))
                    .foregroundStyle(event.isPast ? NotchTheme.textMuted.opacity(0.75) : NotchTheme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(NotchTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NotchTheme.stroke, lineWidth: 0.6)
                )
        )
    }

    private func eventTimeRange(_ event: CalendarEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if event.isAllDay { return "全天" }
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }
}
