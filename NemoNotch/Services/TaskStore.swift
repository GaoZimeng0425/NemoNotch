import Foundation

@MainActor
@Observable
final class TaskStore {
    private(set) var tasks: [TodoTask] = []
    private let fileURL: URL

    static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".NemoNotch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    init(fileURL: URL = TaskStore.defaultURL) {
        self.fileURL = fileURL
        load()
        LogService.info("TaskStore loaded \(tasks.count) tasks from \(fileURL.path)", category: "TaskStore")
    }

    @discardableResult
    func add(
        title: String,
        priority: TodoTask.Priority,
        notes: String,
        tags: [String],
        dueDate: Date?
    ) -> UUID {
        let maxIdx = tasks.map(\.sortIndex).max() ?? 0
        let task = TodoTask(
            id: UUID(),
            title: title,
            priority: priority,
            notes: notes,
            tags: tags,
            dueDate: dueDate,
            completedPomodoros: 0,
            isDone: false,
            createdAt: Date(),
            sortIndex: maxIdx + 1.0
        )
        tasks.append(task)
        save()
        return task.id
    }

    func update(_ id: UUID, _ mutate: (inout TodoTask) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[idx])
        save()
    }

    func markDone(_ id: UUID, isDone: Bool) {
        update(id) { $0.isDone = isDone }
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    func incrementCompletedPomodoros(_ id: UUID) {
        update(id) { $0.completedPomodoros += 1 }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            tasks = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            tasks = try JSONDecoder().decode([TodoTask].self, from: data)
        } catch {
            LogService.error("TaskStore load failed: \(error)", category: "TaskStore")
            tasks = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LogService.error("TaskStore save failed: \(error)", category: "TaskStore")
        }
    }
}
