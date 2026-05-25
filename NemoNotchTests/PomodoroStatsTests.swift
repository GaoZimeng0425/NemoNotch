import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct PomodoroStatsTests {
    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func makeRec(
        outcome: PomodoroRecord.Outcome = .completed,
        phase: PomodoroPhase = .work,
        endedAt: Date,
        taskID: UUID? = nil
    ) -> PomodoroRecord {
        PomodoroRecord(
            id: UUID(), taskID: taskID, phase: phase,
            plannedDuration: 1500, actualDuration: 1500,
            startedAt: endedAt.addingTimeInterval(-1500), endedAt: endedAt,
            outcome: outcome
        )
    }

    @Test func todayBucketIgnoresYesterdayAndBreakRecords() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400 - 60)
        history.append(makeRec(endedAt: now))
        history.append(makeRec(outcome: .partial, endedAt: now))
        history.append(makeRec(phase: .shortBreak, endedAt: now))
        history.append(makeRec(endedAt: yesterday))

        let stats = PomodoroStats(history: history)
        let today = stats.today()
        #expect(today.completed == 1)
        #expect(today.partial == 1)
        #expect(today.abandoned == 0)
    }

    @Test func weekBucketIncludesLast7Days() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let now = Date()
        for i in 0 ..< 7 {
            history.append(makeRec(endedAt: now.addingTimeInterval(-86400 * Double(i) - 60)))
        }
        history.append(makeRec(endedAt: now.addingTimeInterval(-86400 * 8)))

        let stats = PomodoroStats(history: history)
        let week = stats.week()
        #expect(week.completed == 7)
    }

    @Test func allTimeIncludesAllWorkRecords() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        history.append(makeRec(outcome: .completed, endedAt: Date(timeIntervalSince1970: 100)))
        history.append(makeRec(outcome: .partial, endedAt: Date(timeIntervalSince1970: 200)))
        history.append(makeRec(outcome: .abandoned, endedAt: Date(timeIntervalSince1970: 300)))
        history.append(makeRec(phase: .longBreak, endedAt: Date(timeIntervalSince1970: 400)))

        let stats = PomodoroStats(history: history)
        let all = stats.allTime()
        #expect(all.completed == 1)
        #expect(all.partial == 1)
        #expect(all.abandoned == 1)
    }

    @Test func mostFrequentTaskIDReturnsHighestCount() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let a = UUID(), b = UUID()
        history.append(makeRec(endedAt: Date(), taskID: a))
        history.append(makeRec(endedAt: Date(), taskID: b))
        history.append(makeRec(endedAt: Date(), taskID: a))
        history.append(makeRec(endedAt: Date(), taskID: a))

        let stats = PomodoroStats(history: history)
        #expect(stats.mostFrequentTaskID()?.taskID == a)
        #expect(stats.mostFrequentTaskID()?.count == 3)
    }

    @Test func mostFrequentTaskIDIgnoresAbandonedAndNilTaskID() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let a = UUID()
        history.append(makeRec(endedAt: Date(), taskID: nil))
        history.append(makeRec(outcome: .abandoned, endedAt: Date(), taskID: a))
        history.append(makeRec(endedAt: Date(), taskID: a))
        let stats = PomodoroStats(history: history)
        #expect(stats.mostFrequentTaskID()?.taskID == a)
        #expect(stats.mostFrequentTaskID()?.count == 1)
    }

    @Test func recentReturnsLastNRecordsInReverseOrder() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0 ..< 7 {
            history.append(makeRec(endedAt: base.addingTimeInterval(Double(i) * 60)))
        }
        let stats = PomodoroStats(history: history)
        let recent = stats.recent(limit: 5)
        #expect(recent.count == 5)
        #expect(recent.first?.endedAt == base.addingTimeInterval(360))
    }

    @Test func emptyHistoryReturnsZeros() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let stats = PomodoroStats(history: history)
        let today = stats.today()
        #expect(today.completed == 0 && today.partial == 0 && today.abandoned == 0)
        #expect(stats.mostFrequentTaskID() == nil)
        #expect(stats.recent(limit: 5).isEmpty)
    }
}
