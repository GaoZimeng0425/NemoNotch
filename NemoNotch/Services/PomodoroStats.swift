import Foundation

@MainActor
struct PomodoroStats {
    let history: PomodoroHistoryStore

    struct Counts: Equatable {
        var completed: Int
        var partial: Int
        var abandoned: Int
    }

    struct TaskFrequency: Equatable {
        let taskID: UUID
        let count: Int
    }

    func today() -> Counts {
        let start = Calendar.current.startOfDay(for: Date())
        return counts(in: start ... Date())
    }

    func week() -> Counts {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return counts(in: start ... Date())
    }

    func allTime() -> Counts {
        let workRecords = history.records.filter { $0.phase == .work }
        return reduceCounts(workRecords)
    }

    func mostFrequentTaskID() -> TaskFrequency? {
        let workRecords = history.records.filter {
            $0.phase == .work && $0.outcome != .abandoned && $0.taskID != nil
        }
        let grouped = Dictionary(grouping: workRecords) { $0.taskID! }
        guard let top = grouped.max(by: { $0.value.count < $1.value.count }) else { return nil }
        return TaskFrequency(taskID: top.key, count: top.value.count)
    }

    func recent(limit: Int) -> [PomodoroRecord] {
        return Array(history.records.reversed().prefix(limit))
    }

    private func counts(in range: ClosedRange<Date>) -> Counts {
        let workRecords = history.records.filter {
            $0.phase == .work && range.contains($0.endedAt)
        }
        return reduceCounts(workRecords)
    }

    private func reduceCounts(_ records: [PomodoroRecord]) -> Counts {
        var c = Counts(completed: 0, partial: 0, abandoned: 0)
        for r in records {
            switch r.outcome {
            case .completed: c.completed += 1
            case .partial: c.partial += 1
            case .abandoned: c.abandoned += 1
            }
        }
        return c
    }
}
