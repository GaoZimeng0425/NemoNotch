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

    @Test func pinToTopPlacesAboveAllOthers() throws {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.pinToTop(b)
        let minIdx = try #require(store.tasks.map(\.sortIndex).min())
        #expect(store.tasks.first { $0.id == b }?.sortIndex == minIdx)
        #expect(try #require(store.tasks.first { $0.id == a }?.sortIndex) > minIdx)
    }

    @Test func moveBetweenComputesMidpoint() throws {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        let c = store.add(title: "c", priority: .medium, notes: "", tags: [], dueDate: nil)
        // Sort order: a (1.0) < b (2.0) < c (3.0). Move c between a and b → new sort = 1.5.
        store.move(c, between: a, and: b)
        let tc = try #require(store.tasks.first { $0.id == c })
        #expect(tc.sortIndex == 1.5)
    }

    @Test func moveToTopUsesMinMinusOne() throws {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.move(b, between: nil, and: a)
        let tb = try #require(store.tasks.first { $0.id == b })
        #expect(tb.sortIndex == 0.0) // 1.0 - 1.0
    }

    @Test func moveToBottomUsesMaxPlusOne() throws {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.move(a, between: b, and: nil)
        let ta = try #require(store.tasks.first { $0.id == a })
        #expect(ta.sortIndex == 3.0) // 2.0 + 1.0
    }

    @Test func loadsV1JSONWithoutTagsAndDueDate() throws {
        let url = tempURL()
        // v1 JSON shape: no `tags`, no `dueDate` keys
        let v1JSON = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "old task",
            "priority": "medium",
            "notes": "",
            "completedPomodoros": 5,
            "isDone": false,
            "createdAt": 1700000000,
            "sortIndex": 1.0
          }
        ]
        """.data(using: .utf8)!
        try v1JSON.write(to: url)

        let store = TaskStore(fileURL: url)
        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.title == "old task")
        #expect(store.tasks.first?.tags == [])
        #expect(store.tasks.first?.dueDate == nil)
    }
}
