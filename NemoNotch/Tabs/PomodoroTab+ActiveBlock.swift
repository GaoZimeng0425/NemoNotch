import SwiftUI

struct PomodoroActiveBlock: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore
    @Environment(AppSettings.self) var appSettings

    let onPauseResume: () -> Void
    let onCompleteEarly: () -> Void
    let onAbandon: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PomodoroPieView(
                remainingFraction: remainingFraction,
                phase: timerService.currentPhase,
                style: .large,
                centerText: mmss(timerService.remainingSeconds)
            )
            .opacity(emojiPieOpacity)

            VStack(alignment: .leading, spacing: 4) {
                taskTitleRow
                phaseRow
                priorityAndDotsRow
                remainingLabel
            }
        }
        .padding(12)
        .background(NotchTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private var remainingFraction: Double {
        if case let .running(ctx) = timerService.state {
            return Double(timerService.remainingSeconds) / ctx.plannedDuration
        }
        if case let .paused(ctx) = timerService.state {
            return (ctx.plannedDuration - ctx.accumulatedElapsed) / ctx.plannedDuration
        }
        return 0
    }

    private var emojiPieOpacity: Double {
        if case .paused = timerService.state { return 0.55 }
        return 1.0
    }

    private var taskTitleRow: some View {
        let title: String = {
            if case let .running(ctx) = timerService.state,
               let id = ctx.taskID,
               let task = taskStore.tasks.first(where: { $0.id == id }) {
                return task.title
            }
            if case let .paused(ctx) = timerService.state,
               let id = ctx.taskID,
               let task = taskStore.tasks.first(where: { $0.id == id }) {
                return task.title
            }
            return String(localized: "pomodoro.active.noTask")
        }()
        return Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(NotchTheme.textPrimary)
            .lineLimit(1)
    }

    private var phaseRow: some View {
        let phaseLabel = phaseName(timerService.currentPhase)
        let counterStr: String
        let nextStr: String
        if timerService.lastAutoFlow {
            let n = timerService.workCounterSinceLongBreak + (timerService.currentPhase == .work ? 1 : 0)
            let m = appSettings.pomodoroLongBreakInterval
            counterStr = String(format: String(localized: "pomodoro.phase.counter"), n, m)
            nextStr = nextPhaseLabel()
        } else {
            counterStr = String(localized: "pomodoro.phase.singleWork")
            nextStr = ""
        }
        return HStack(spacing: 6) {
            Text(phaseLabel).font(.system(size: 11)).foregroundStyle(NotchTheme.textSecondary)
            Text("·").foregroundStyle(NotchTheme.textTertiary)
            Text(counterStr).font(.system(size: 11)).foregroundStyle(NotchTheme.textSecondary)
            if !nextStr.isEmpty {
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text(String(format: String(localized: "pomodoro.phase.next"), nextStr))
                    .font(.system(size: 11)).foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private var priorityAndDotsRow: some View {
        Group {
            if let taskID = currentTaskID,
               let task = taskStore.tasks.first(where: { $0.id == taskID }) {
                HStack(spacing: 6) {
                    Text(priorityLabel(task.priority))
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("·").foregroundStyle(NotchTheme.textTertiary)
                    completedDots(task.completedPomodoros)
                }
            }
        }
    }

    private var remainingLabel: some View {
        Text(String(format: String(localized: "pomodoro.active.remaining"), mmss(timerService.remainingSeconds)))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(NotchTheme.textPrimary)
    }

    private var currentTaskID: UUID? {
        if case let .running(ctx) = timerService.state { return ctx.taskID }
        if case let .paused(ctx) = timerService.state { return ctx.taskID }
        return nil
    }

    private func mmss(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func phaseName(_ p: PomodoroPhase) -> String {
        switch p {
        case .work: return String(localized: "pomodoro.phase.work")
        case .shortBreak: return String(localized: "pomodoro.phase.shortBreak")
        case .longBreak: return String(localized: "pomodoro.phase.longBreak")
        case .idle: return ""
        }
    }

    private func nextPhaseLabel() -> String {
        let m = appSettings.pomodoroLongBreakInterval
        switch timerService.currentPhase {
        case .work:
            let n = timerService.workCounterSinceLongBreak + 1
            return (n % m == 0)
                ? String(localized: "pomodoro.phase.longBreak")
                : String(localized: "pomodoro.phase.shortBreak")
        case .shortBreak, .longBreak: return String(localized: "pomodoro.phase.work")
        case .idle: return ""
        }
    }

    private func priorityLabel(_ p: TodoTask.Priority) -> String {
        switch p {
        case .low: return String(localized: "pomodoro.priority.low")
        case .medium: return String(localized: "pomodoro.priority.medium")
        case .high: return String(localized: "pomodoro.priority.high")
        }
    }

    private func completedDots(_ n: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 5, id: \.self) { i in
                Circle()
                    .fill(i < min(n, 5) ? NotchTheme.accent : NotchTheme.surfaceEmphasis)
                    .frame(width: 4, height: 4)
            }
            if n > 5 {
                Text("+").font(.system(size: 8)).foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }
}
