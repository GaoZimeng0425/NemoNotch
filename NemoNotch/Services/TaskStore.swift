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

    func pinToTop(_ id: UUID) {
        let minIdx = tasks.map(\.sortIndex).min() ?? 1.0
        update(id) { $0.sortIndex = minIdx - 1.0 }
    }

    /// Reorder `id` to sit between `before` and `after` (either nil → edge).
    func move(_ id: UUID, between before: UUID?, and after: UUID?) {
        let beforeIdx = before.flatMap { idx in tasks.first { $0.id == idx }?.sortIndex }
        let afterIdx = after.flatMap { idx in tasks.first { $0.id == idx }?.sortIndex }

        let newIdx: Double
        switch (beforeIdx, afterIdx) {
        case let (b?, a?):
            newIdx = (b + a) / 2
            if abs(b - a) < 1e-9 {
                LogService.warn(
                    "TaskStore.move: sortIndex underflow risk (b=\(b) a=\(a)); rebalance TODO",
                    category: "TaskStore"
                )
            }
        case let (b?, nil):
            newIdx = b + 1.0
        case let (nil, a?):
            newIdx = a - 1.0
        case (nil, nil):
            newIdx = 1.0
        }
        update(id) { $0.sortIndex = newIdx }
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
