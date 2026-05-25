import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct PomodoroHistoryStoreTests {
    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pomodoro-history.json")
    }

    private func makeRecord(
        phase: PomodoroPhase = .work,
        outcome: PomodoroRecord.Outcome = .completed,
        taskID: UUID? = nil,
        endedAt: Date = Date()
    ) -> PomodoroRecord {
        PomodoroRecord(
            id: UUID(), taskID: taskID, phase: phase,
            plannedDuration: 1500, actualDuration: 1500,
            startedAt: endedAt.addingTimeInterval(-1500), endedAt: endedAt,
            outcome: outcome
        )
    }

    @Test func initialEmpty() {
        let store = PomodoroHistoryStore(fileURL: tempURL())
        #expect(store.records.isEmpty)
    }

    @Test func appendPersistsAcrossReload() {
        let url = tempURL()
        let store = PomodoroHistoryStore(fileURL: url)
        let r = makeRecord()
        store.append(r)
        #expect(store.records.count == 1)

        let reloaded = PomodoroHistoryStore(fileURL: url)
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records.first?.id == r.id)
    }

    @Test func appendKeepsInsertionOrder() {
        let store = PomodoroHistoryStore(fileURL: tempURL())
        let r1 = makeRecord(endedAt: Date(timeIntervalSince1970: 100))
        let r2 = makeRecord(endedAt: Date(timeIntervalSince1970: 200))
        let r3 = makeRecord(endedAt: Date(timeIntervalSince1970: 300))
        store.append(r1)
        store.append(r2)
        store.append(r3)
        #expect(store.records.map(\.id) == [r1.id, r2.id, r3.id])
    }

    @Test func recordsInRangeFilters() {
        let store = PomodoroHistoryStore(fileURL: tempURL())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.append(makeRecord(endedAt: base.addingTimeInterval(-86400 * 2))) // 2 days ago
        store.append(makeRecord(endedAt: base.addingTimeInterval(-3600))) // 1 hour ago
        store.append(makeRecord(endedAt: base.addingTimeInterval(-60))) // 1 minute ago

        let lastDay = store.records(in: base.addingTimeInterval(-86400) ... base)
        #expect(lastDay.count == 2)
    }

    @Test func completedCountForTaskIgnoresAbandonedAndBreak() {
        let store = PomodoroHistoryStore(fileURL: tempURL())
        let taskID = UUID()
        store.append(makeRecord(phase: .work, outcome: .completed, taskID: taskID))
        store.append(makeRecord(phase: .work, outcome: .partial, taskID: taskID))
        store.append(makeRecord(phase: .work, outcome: .abandoned, taskID: taskID))
        store.append(makeRecord(phase: .shortBreak, outcome: .completed, taskID: taskID))
        store.append(makeRecord(phase: .work, outcome: .completed, taskID: UUID())) // other task

        #expect(store.completedWorkCount(for: taskID) == 2) // completed + partial of THIS task, work phase only
    }
}
