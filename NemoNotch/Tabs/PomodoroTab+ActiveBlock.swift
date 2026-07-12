import SwiftUI

struct PomodoroActiveBlock: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore

    let onPauseResume: () -> Void
    let onCompleteEarly: () -> Void
    let onAbandon: () -> Void

    @State private var pendingConfirm: ConfirmKind? = nil

    enum ConfirmKind {
        case completeEarly
        case abandon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            compactRow
            if let kind = pendingConfirm {
                confirmBanner(kind)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(NotchTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private var compactRow: some View {
        HStack(spacing: 10) {
            PomodoroPieView(
                remainingFraction: remainingFraction,
                phase: timerService.currentPhase,
                style: .compact
            )
            .opacity(emojiOpacity)

            Text(taskTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(mmss(timerService.remainingSeconds))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(NotchTheme.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.28), value: timerService.remainingSeconds)

            iconButton(
                systemName: pauseResumeIcon,
                tint: NotchTheme.textPrimary,
                helpKey: pauseResumeLabel,
                action: onPauseResume
            )
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy(duration: 0.2), value: pauseResumeIcon)
            iconButton(
                systemName: "checkmark",
                tint: Color(red: 0.34, green: 0.78, blue: 0.51),
                helpKey: "pomodoro.action.completeEarly"
            ) {
                pendingConfirm = .completeEarly
            }
            iconButton(
                systemName: "xmark",
                tint: Color(red: 0.93, green: 0.36, blue: 0.36),
                helpKey: "pomodoro.action.abandon"
            ) {
                pendingConfirm = .abandon
            }
        }
    }

    private func iconButton(
        systemName: String,
        tint: Color,
        helpKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(NotchTheme.surface))
                .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.6))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpKey)
    }

    private var pauseResumeLabel: LocalizedStringKey {
        if case .paused = timerService.state {
            return "pomodoro.action.resume"
        }
        return "pomodoro.action.pause"
    }

    private var pauseResumeIcon: String {
        if case .paused = timerService.state {
            return "play.fill"
        }
        return "pause.fill"
    }

    private func confirmBanner(_ kind: ConfirmKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
            Text(confirmMessage(kind))
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer()
            Button("button.confirm") {
                switch kind {
                case .completeEarly: onCompleteEarly()
                case .abandon: onAbandon()
                }
                pendingConfirm = nil
            }
            .buttonStyle(NotchPillButtonStyle(prominent: true))
            Button("button.cancel") { pendingConfirm = nil }
                .buttonStyle(NotchPillButtonStyle())
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func confirmMessage(_ kind: ConfirmKind) -> String {
        switch kind {
        case .completeEarly:
            let remaining = mmss(timerService.remainingSeconds)
            return String(format: String(localized: "pomodoro.confirm.completeEarly"), remaining)
        case .abandon:
            return String(localized: "pomodoro.confirm.abandon")
        }
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

    private var emojiOpacity: Double {
        if case .paused = timerService.state {
            return 0.55
        }
        return 1.0
    }

    private var taskTitle: String {
        if let id = currentTaskID,
           let task = taskStore.tasks.first(where: { $0.id == id }) {
            return task.title
        }
        return String(localized: "pomodoro.active.noTask")
    }

    private var currentTaskID: UUID? {
        if case let .running(ctx) = timerService.state {
            return ctx.taskID
        }
        if case let .paused(ctx) = timerService.state {
            return ctx.taskID
        }
        return nil
    }

    private func mmss(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
