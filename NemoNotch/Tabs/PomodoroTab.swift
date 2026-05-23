import SwiftUI

struct PomodoroTab: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(AppSettings.self) var appSettings
    @Environment(\.quickStartController) var quickStartController

    @State private var showStatsPopover = false
    @State private var showCompleted = false
    @State private var editingTask: TodoTask?
    @State private var pendingFastStartTask: TodoTask?

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider().background(NotchTheme.stroke)
            if let pending = pendingFastStartTask {
                overrideConfirmBanner(for: pending)
            }
            PomodoroTodoListView(
                showCompleted: $showCompleted,
                onEdit: { editingTask = $0 },
                onStartTask: handleStartTask(_:)
            )
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

    private func handleStartTask(_ task: TodoTask) {
        if timerService.state.isActive {
            pendingFastStartTask = task
        } else {
            performStart(task)
        }
    }

    private func performStart(_ task: TodoTask) {
        let duration = timerService.lastUsedDuration > 0
            ? timerService.lastUsedDuration
            : appSettings.pomodoroWorkDuration
        let autoFlow = timerService.lastAutoFlow
        timerService.start(taskID: task.id, duration: duration, autoFlow: autoFlow)
        pendingFastStartTask = nil
    }

    private func overrideConfirmBanner(for task: TodoTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(String(format: String(localized: "pomodoro.confirm.override"), task.title))
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer()
            Button("pomodoro.action.start") {
                performStart(task)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                pendingFastStartTask = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
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
