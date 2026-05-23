import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct TaskStoreTests {
    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    @Test func initialStateEmpty() {
        let store = TaskStore(fileURL: tempURL())
        #expect(store.tasks.isEmpty)
    }

    @Test func addAppendsAndPersists() {
        let url = tempURL()
        let store = TaskStore(fileURL: url)
        let id = store.add(title: "write spec", priority: .high, notes: "n", tags: ["x"], dueDate: nil)
        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.id == id)
        #expect(store.tasks.first?.title == "write spec")
        #expect(store.tasks.first?.priority == .high)
        #expect(store.tasks.first?.sortIndex == 1.0)

        // Reload from disk
        let reloaded = TaskStore(fileURL: url)
        #expect(reloaded.tasks.count == 1)
        #expect(reloaded.tasks.first?.title == "write spec")
    }

    @Test func addSecondGetsLargerSortIndex() throws {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        let ta = try #require(store.tasks.first { $0.id == a })
        let tb = try #require(store.tasks.first { $0.id == b })
        #expect(ta.sortIndex < tb.sortIndex)
    }

    @Test func updateTitleAndPriority() throws {
        let store = TaskStore(fileURL: tempURL())
        let id = store.add(title: "old", priority: .low, notes: "", tags: [], dueDate: nil)
        store.update(id) { $0.title = "new"
            $0.priority = .high
        }
        let t = try #require(store.tasks.first { $0.id == id })
        #expect(t.title == "new")
        #expect(t.priority == .high)
    }

    @Test func markDoneTogglesIsDone() {
        let store = TaskStore(fileURL: tempURL())
        let id = store.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.markDone(id, isDone: true)
        #expect(store.tasks.first { $0.id == id }?.isDone == true)
        store.markDone(id, isDone: false)
        #expect(store.tasks.first { $0.id == id }?.isDone == false)
    }

    @Test func deleteRemovesTask() {
        let store = TaskStore(fileURL: tempURL())
        let id = store.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.delete(id)
        #expect(store.tasks.isEmpty)
    }

    @Test func incrementCompletedPomodoros() {
        let store = TaskStore(fileURL: tempURL())
        let id = store.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.incrementCompletedPomodoros(id)
        store.incrementCompletedPomodoros(id)
        #expect(store.tasks.first { $0.id == id }?.completedPomodoros == 2)
    }

    @Test func deleteOfMissingIDIsNoOp() {
        let store = TaskStore(fileURL: tempURL())
        store.delete(UUID()) // doesn't crash
        #expect(store.tasks.isEmpty)
    }
}
