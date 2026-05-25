import SwiftUI

struct PomodoroTab: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(AppSettings.self) var appSettings
    @Environment(\.quickStartController) var quickStartController

    @State private var showStatsPopover = false
    @State private var showCompleted = false
    @State private var pendingFastStartTask: TodoTask?

    var body: some View {
        VStack(spacing: 10) {
            header
            if let pending = pendingFastStartTask {
                overrideConfirmBanner(for: pending)
            }
            PomodoroTodoListView(
                showCompleted: $showCompleted,
                onEdit: { quickStartController?.presentEdit(taskID: $0.id) },
                onStartTask: handleStartTask(_:)
            )
            .frame(maxHeight: .infinity)
            if timerService.state.isActive {
                Divider().background(NotchTheme.stroke)
                PomodoroActiveBlock(
                    onPauseResume: handlePauseResume,
                    onCompleteEarly: handleCompleteEarly,
                    onAbandon: handleAbandon
                )
            }
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
            }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
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

    private func handlePauseResume() {
        if case .running = timerService.state {
            timerService.pause()
        } else if case .paused = timerService.state {
            timerService.resume()
        }
    }

    private func handleCompleteEarly() {
        timerService.completeEarly()
    }

    private func handleAbandon() {
        timerService.abandon()
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.accentText)
            Text(String(format: String(localized: "pomodoro.confirm.override"), task.title))
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("pomodoro.action.start") {
                performStart(task)
            }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
            Button {
                pendingFastStartTask = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(NotchTheme.surface))
                    .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(NotchTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NotchTheme.accentStroke, lineWidth: 0.7)
        )
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
