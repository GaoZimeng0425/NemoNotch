import SwiftUI

struct DateStripView: View {
    let dates: [Date]
    let selectedDate: Date
    let hasEvents: (Date) -> Bool
    let onSelect: (Date) -> Void

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
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo(selectedDateId, anchor: .center)
                }
            }
            .onChange(of: selectedDate) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
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
                    .foregroundStyle(isWeekend ? .red.opacity(0.7) : .white.opacity(0.4))

                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(
                        isToday ? .blue
                        : isSelected ? .white
                        : .white.opacity(0.6)
                    )

                Circle()
                    .fill(hasEvents(date) ? Color.white.opacity(0.5) : .clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 36, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? .white.opacity(0.15) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func weekdayShort(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func isWeekendDate(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }
}
