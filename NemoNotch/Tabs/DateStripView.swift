import SwiftUI

struct DateStripView: View {
    let dates: [Date]
    let selectedDate: Date
    let hasEvents: (Date) -> Bool
    let onSelect: (Date) -> Void
    var locale: Locale = .current

    private var selectedDateId: Date {
        Calendar.current.startOfDay(for: selectedDate)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(dates, id: \.self) { date in
                        dateButton(date)
                            .id(date)
                    }
                }
                .padding(.horizontal, 8)
            }
            .notchScrollEdgeShadow(.horizontal, thickness: 10, intensity: 0.34)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo(selectedDateId, anchor: .center)
                }
            }
            .onChange(of: selectedDate) { _, _ in
                withAnimation(.spring(duration: NotchConstants.tabSwitchSpringDuration, bounce: NotchConstants.tabSwitchSpringBounce)) {
                    proxy.scrollTo(selectedDateId, anchor: .center)
                }
            }
        }
    }

    private func dateButton(_ date: Date) -> some View {
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.current.isDateInToday(date)
        let isWeekend = isWeekendDate(date)

        return Button {
            onSelect(date)
        } label: {
            VStack(spacing: 4) {
                Text(weekdayShort(for: date))
                    .font(.system(size: 9))
                    .foregroundStyle(isWeekend ? Color.red.opacity(0.72) : NotchTheme.textTertiary)

                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(
                        isToday ? NotchTheme.accent
                        : isSelected ? NotchTheme.textPrimary
                        : NotchTheme.textSecondary
                    )

                Circle()
                    .fill(hasEvents(date) ? NotchTheme.accent.opacity(0.9) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 36, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? NotchTheme.surfaceEmphasis : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? NotchTheme.stroke : .clear, lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func weekdayShort(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func isWeekendDate(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }
}
