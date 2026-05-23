import SwiftUI

struct PomodoroTab: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(AppSettings.self) var appSettings
    @Environment(\.quickStartController) var quickStartController

    @State private var showStatsPopover = false
    @State private var showCompleted = false

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider().background(NotchTheme.stroke)
            todoListPlaceholder
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            statsSummary
            Spacer()
            Button {
                showStatsPopover = true
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStatsPopover, arrowEdge: .top) {
                PomodoroStatsPopover()
                    .environment(historyStore)
                    .environment(taskStore)
            }

            Button {
                quickStartController?.toggle()
            } label: {
                Label("pomodoro.action.newPomodoro", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(NotchTheme.accent.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
    }

    private var statsSummary: some View {
        let today = todayCounts()
        let week = weekCounts()
        return HStack(spacing: 10) {
            Text(String(
                format: "%@ ✓%d ~%d",
                String(localized: "pomodoro.stats.today"),
                today.completed,
                today.partial
            ))
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textSecondary)
            Text("·").foregroundStyle(NotchTheme.textTertiary)
            Text(String(
                format: "%@ ✓%d",
                String(localized: "pomodoro.stats.week"),
                week.completed
            ))
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textSecondary)
        }
    }

    private var todoListPlaceholder: some View {
        Text("(TODO list — Task 26)")
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func todayCounts() -> (completed: Int, partial: Int) {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Date()
        let recs = historyStore.records(in: start ... end).filter { $0.phase == .work }
        return (
            completed: recs.count(where: { $0.outcome == .completed }),
            partial: recs.count(where: { $0.outcome == .partial })
        )
    }

    private func weekCounts() -> (completed: Int, partial: Int) {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recs = historyStore.records(in: start ... Date()).filter { $0.phase == .work }
        return (
            completed: recs.count(where: { $0.outcome == .completed }),
            partial: recs.count(where: { $0.outcome == .partial })
        )
    }
}
