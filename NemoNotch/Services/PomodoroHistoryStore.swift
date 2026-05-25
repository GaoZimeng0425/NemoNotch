import Foundation

@MainActor
@Observable
final class PomodoroHistoryStore {
    private(set) var records: [PomodoroRecord] = []
    private let fileURL: URL

    static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".NemoNotch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pomodoro-history.json")
    }

    init(fileURL: URL = PomodoroHistoryStore.defaultURL) {
        self.fileURL = fileURL
        load()
        LogService.info(
            "PomodoroHistoryStore loaded \(records.count) records",
            category: "PomodoroHistoryStore"
        )
    }

    func append(_ record: PomodoroRecord) {
        records.append(record)
        save()
    }

    func records(in range: ClosedRange<Date>) -> [PomodoroRecord] {
        records.filter { range.contains($0.endedAt) }
    }

    /// Number of work-phase records (completed OR partial) for a given task.
    /// Abandoned and non-work phases are excluded.
    func completedWorkCount(for taskID: UUID) -> Int {
        records.count(where: {
            $0.taskID == taskID &&
                $0.phase == .work &&
                ($0.outcome == .completed || $0.outcome == .partial)
        })
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try JSONDecoder().decode([PomodoroRecord].self, from: data)
        } catch {
            LogService.error(
                "PomodoroHistoryStore load failed: \(error)",
                category: "PomodoroHistoryStore"
            )
            records = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LogService.error(
                "PomodoroHistoryStore save failed: \(error)",
                category: "PomodoroHistoryStore"
            )
        }
    }
}
