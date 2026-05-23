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
        VStack(spacing: 6) {
            HStack {
                Text(String(format: String(localized: "pomodoro.todo.countHeader"), visibleTasks.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                Spacer()
                Toggle(isOn: $showCompleted) {
                    Text("pomodoro.todo.showCompleted")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if visibleTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleTasks) { task in
                            TodoRow(
                                task: task,
                                onEdit: onEdit,
                                onStart: onStartTask
                            )
                        }
                    }
                }
                .notchScrollEdgeShadow(.vertical, thickness: 8, intensity: 0.32)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("pomodoro.todo.empty")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TodoRow: View {
    @Environment(TaskStore.self) var taskStore
    let task: TodoTask
    let onEdit: (TodoTask) -> Void
    let onStart: (TodoTask) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                taskStore.markDone(task.id, isDone: !task.isDone)
            } label: {
                Image(systemName: task.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(task.isDone ? NotchTheme.accent : NotchTheme.textTertiary)
            }
            .buttonStyle(.plain)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(priorityColor(task.priority))
                .frame(width: 3, height: 14)

            Text(task.title.isEmpty ? "(untitled)" : task.title)
                .font(.system(size: 12))
                .foregroundStyle(task.isDone ? NotchTheme.textTertiary : NotchTheme.textPrimary)
                .strikethrough(task.isDone)
                .lineLimit(1)

            Spacer()

            completedDots
                .frame(width: 50, alignment: .trailing)

            Button {
                onStart(task)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(NotchTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            hovering ? NotchTheme.surfaceSubtle : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("pomodoro.todo.edit") { onEdit(task) }
            Button("pomodoro.todo.pin") { taskStore.pinToTop(task.id) }
            Divider()
            Button("pomodoro.todo.delete", role: .destructive) {
                taskStore.delete(task.id)
            }
        }
    }

    @ViewBuilder
    private var completedDots: some View {
        let n = min(task.completedPomodoros, 5)
        HStack(spacing: 2) {
            ForEach(0 ..< 5, id: \.self) { i in
                Circle()
                    .fill(i < n ? NotchTheme.accent : NotchTheme.surfaceEmphasis)
                    .frame(width: 4, height: 4)
            }
            if task.completedPomodoros > 5 {
                Text("+")
                    .font(.system(size: 8))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private func priorityColor(_ p: TodoTask.Priority) -> Color {
        switch p {
        case .low: return NotchTheme.textTertiary
        case .medium: return Color(red: 0.95, green: 0.78, blue: 0.30)
        case .high: return Color(red: 0.93, green: 0.36, blue: 0.36)
        }
    }
}
