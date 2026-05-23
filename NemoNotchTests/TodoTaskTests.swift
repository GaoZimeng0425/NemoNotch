import Foundation
@testable import NemoNotch
import Testing

struct TodoTaskTests {
    @Test func defaultsForOptionalFields() {
        let t = TodoTask(
            id: UUID(),
            title: "x",
            priority: .medium,
            notes: "",
            tags: [],
            dueDate: nil,
            completedPomodoros: 0,
            isDone: false,
            createdAt: Date(),
            sortIndex: 1.0
        )
        #expect(t.tags == [])
        #expect(t.dueDate == nil)
        #expect(t.completedPomodoros == 0)
        #expect(t.isDone == false)
    }

    @Test func codableRoundtrip() throws {
        let t = TodoTask(
            id: UUID(),
            title: "写设计文档",
            priority: .high,
            notes: "spec → plan → code",
            tags: ["notch", "spec"],
            dueDate: Date(timeIntervalSince1970: 1_700_000_000),
            completedPomodoros: 3,
            isDone: false,
            createdAt: Date(timeIntervalSince1970: 1_690_000_000),
            sortIndex: 2.5
        )
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(TodoTask.self, from: data)
        #expect(decoded == t)
    }

    @Test func phaseRoundtrip() throws {
        for phase in [PomodoroPhase.idle, .work, .shortBreak, .longBreak] {
            let data = try JSONEncoder().encode(phase)
            let decoded = try JSONDecoder().decode(PomodoroPhase.self, from: data)
            #expect(decoded == phase)
        }
    }

    @Test func recordRoundtrip() throws {
        let r = PomodoroRecord(
            id: UUID(),
            taskID: UUID(),
            phase: .work,
            plannedDuration: 1500,
            actualDuration: 1500,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_500),
            outcome: .completed
        )
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(PomodoroRecord.self, from: data)
        #expect(decoded == r)
    }

    @Test func recordWithNilTaskID() throws {
        let r = PomodoroRecord(
            id: UUID(),
            taskID: nil,
            phase: .shortBreak,
            plannedDuration: 300,
            actualDuration: 180,
            startedAt: Date(),
            endedAt: Date(),
            outcome: .partial
        )
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(PomodoroRecord.self, from: data)
        #expect(decoded.taskID == nil)
        #expect(decoded.outcome == .partial)
    }
}
