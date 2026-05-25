import SwiftUI

struct PomodoroTodoListView: View {
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(AppSettings.self) var appSettings

    @Binding var showCompleted: Bool
    let onEdit: (TodoTask) -> Void
    let onStartTask: (TodoTask) -> Void

    private var visibleTasks: [TodoTask] {
        let all = taskStore.tasks.sorted { $0.sortIndex < $1.sortIndex }
        return showCompleted ? all : all.filter { !$0.isDone }
    }

    var body: some View {
        VStack(spacing: 8) {
            listHeader

            if visibleTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleTasks) { task in
                            TodoRow(
                                task: task,
                                onEdit: onEdit,
                                onStart: onStartTask
                            )
                        }
                    }
                    .padding(.bottom, 10)
                }
                .notchScrollEdgeShadow(.vertical, thickness: 16, intensity: 0.30)
            }
        }
        .padding(.horizontal, 2)
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchTheme.accentText)
                    .frame(width: 18, height: 18)
                    .background(
                        NotchTheme.accent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                Text(String(format: String(localized: "pomodoro.todo.countHeader"), visibleTasks.count))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle(isOn: $showCompleted) {
                Text("pomodoro.todo.showCompleted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
        }
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("pomodoro.todo.empty")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TodoRow: View {
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroTimerService.self) var timerService
    let task: TodoTask
    let onEdit: (TodoTask) -> Void
    let onStart: (TodoTask) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            completionButton

            detailsContent

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                pomodoroCount
                startButton
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(rowStroke, lineWidth: isActive ? 1 : 0.7)
                )
        )
        .shadow(color: isActive ? NotchTheme.accent.opacity(0.12) : .clear, radius: 14, y: 6)
        .opacity(task.isDone ? 0.68 : 1)
        .animation(.easeOut(duration: NotchConstants.fadeFastDuration), value: hovering)
        .animation(.easeOut(duration: NotchConstants.fadeFastDuration), value: isActive)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onEdit(task) }
        .help("pomodoro.todo.edit")
        .contextMenu {
            Button("pomodoro.todo.edit") { onEdit(task) }
            Button("pomodoro.todo.pin") { taskStore.pinToTop(task.id) }
            Divider()
            Button("pomodoro.todo.delete", role: .destructive) {
                taskStore.delete(task.id)
            }
        }
    }

    private var completionButton: some View {
        Button {
            taskStore.markDone(task.id, isDone: !task.isDone)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(priorityColor(task.priority).opacity(isActive ? 0.18 : 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(priorityColor(task.priority).opacity(isActive ? 0.46 : 0.28), lineWidth: 0.8)
                    )

                Image(systemName: task.isDone ? "checkmark" : "circle")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(task.isDone ? NotchTheme.accentText : priorityColor(task.priority))

                if isActive {
                    Circle()
                        .fill(NotchTheme.accent)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(NotchTheme.panelBase.opacity(0.92), lineWidth: 1.5)
                        )
                        .shadow(color: NotchTheme.accent.opacity(0.56), radius: 5)
                        .offset(x: 3, y: 3)
                }
            }
            .frame(width: 34, height: 34)
            .frame(width: 40, height: 40, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(task.isDone ? "pomodoro.todo.markOpen" : "pomodoro.todo.markDone")
    }

    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                titleText

                if isActive {
                    statusBadge(
                        text: String(localized: "pomodoro.todo.active"),
                        foreground: NotchTheme.accentText,
                        fill: NotchTheme.accentText.opacity(0.16)
                    )
                } else {
                    priorityBadge
                }
            }

            if !task.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(task.notes)
                    .font(.system(size: 10))
                    .foregroundStyle(task.isDone ? NotchTheme.textMuted : NotchTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.top, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: some View {
        Text(taskTitle)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(task.isDone ? NotchTheme.textTertiary : NotchTheme.textPrimary)
            .strikethrough(task.isDone)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priorityBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(priorityColor(task.priority))
                .frame(width: 5, height: 5)
            Text(priorityLabel(task.priority))
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(task.isDone ? NotchTheme.textMuted : priorityColor(task.priority))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(priorityColor(task.priority).opacity(0.14), in: Capsule(style: .continuous))
        .fixedSize()
    }

    private func statusBadge(text: String, foreground: Color, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(fill, in: Capsule(style: .continuous))
            .fixedSize()
    }

    private var pomodoroCount: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.system(size: 10, weight: .semibold))
            Text("\(task.completedPomodoros)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(task.completedPomodoros > 0 ? NotchTheme.accentText : NotchTheme.textTertiary)
        .frame(width: 42, alignment: .trailing)
        .lineLimit(1)
    }

    private var startButton: some View {
        Button {
            onStart(task)
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isActive ? Color.black.opacity(0.86) : NotchTheme.textPrimary)
                .frame(width: 24, height: 24)
                .background(isActive ? NotchTheme.accent : NotchTheme.surface, in: Circle())
                .overlay(Circle().stroke(isActive ? Color.clear : NotchTheme.stroke, lineWidth: 0.6))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("pomodoro.action.start")
    }

    private var taskTitle: String {
        task.title.isEmpty ? String(localized: "pomodoro.todo.untitled") : task.title
    }

    private var isActive: Bool {
        currentTaskID == task.id
    }

    private var currentTaskID: UUID? {
        if case let .running(ctx) = timerService.state { return ctx.taskID }
        if case let .paused(ctx) = timerService.state { return ctx.taskID }
        return nil
    }

    private var rowFill: Color {
        if isActive { return NotchTheme.surfaceWarm }
        if hovering { return NotchTheme.surface }
        return NotchTheme.surfaceSubtle
    }

    private var rowStroke: Color {
        isActive ? NotchTheme.accentStroke : NotchTheme.strokeStrong
    }

    private func priorityColor(_ p: TodoTask.Priority) -> Color {
        switch p {
        case .low: return NotchTheme.textTertiary
        case .medium: return Color(red: 0.95, green: 0.78, blue: 0.30)
        case .high: return Color(red: 0.93, green: 0.36, blue: 0.36)
        }
    }

    private func priorityLabel(_ p: TodoTask.Priority) -> String {
        switch p {
        case .low: return String(localized: "pomodoro.priority.low")
        case .medium: return String(localized: "pomodoro.priority.medium")
        case .high: return String(localized: "pomodoro.priority.high")
        }
    }
}
