import SwiftUI

struct PomodoroEditSheet: View {
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(\.dismiss) var dismiss

    let taskID: UUID

    @State private var title: String = ""
    @State private var priority: TodoTask.Priority = .medium
    @State private var notes: String = ""
    @State private var loaded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("pomodoro.edit.title")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            Form {
                TextField("pomodoro.edit.titleField", text: $title)

                Picker("pomodoro.edit.priorityField", selection: $priority) {
                    Text("pomodoro.priority.low").tag(TodoTask.Priority.low)
                    Text("pomodoro.priority.medium").tag(TodoTask.Priority.medium)
                    Text("pomodoro.priority.high").tag(TodoTask.Priority.high)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading) {
                    Text("pomodoro.edit.notes")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textSecondary)
                    TextEditor(text: $notes)
                        .font(.system(size: 12))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(NotchTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                }

                if let task = taskStore.tasks.first(where: { $0.id == taskID }) {
                    Text(String(format: String(localized: "pomodoro.edit.completedCount"), task.completedPomodoros))
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text(String(
                        format: String(localized: "pomodoro.edit.createdAt"),
                        task.createdAt.formatted(date: .abbreviated, time: .omitted)
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.textTertiary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("button.cancel") { dismiss() }
                Button("button.save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard !loaded, let task = taskStore.tasks.first(where: { $0.id == taskID }) else { return }
        title = task.title
        priority = task.priority
        notes = task.notes
        loaded = true
    }

    private func save() {
        taskStore.update(taskID) { task in
            task.title = title
            task.priority = priority
            task.notes = notes
        }
    }
}
