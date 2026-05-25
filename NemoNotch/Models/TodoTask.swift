import Foundation

struct TodoTask: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var priority: Priority
    var notes: String
    var tags: [String]
    var dueDate: Date?
    var completedPomodoros: Int
    var isDone: Bool
    let createdAt: Date
    var sortIndex: Double

    enum Priority: String, Codable, CaseIterable, Hashable {
        case low, medium, high
    }

    init(
        id: UUID,
        title: String,
        priority: Priority,
        notes: String,
        tags: [String],
        dueDate: Date?,
        completedPomodoros: Int,
        isDone: Bool,
        createdAt: Date,
        sortIndex: Double
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.notes = notes
        self.tags = tags
        self.dueDate = dueDate
        self.completedPomodoros = completedPomodoros
        self.isDone = isDone
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        priority = try c.decode(Priority.self, forKey: .priority)
        notes = try c.decode(String.self, forKey: .notes)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        completedPomodoros = try c.decode(Int.self, forKey: .completedPomodoros)
        isDone = try c.decode(Bool.self, forKey: .isDone)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        sortIndex = try c.decode(Double.self, forKey: .sortIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, priority, notes, tags, dueDate
        case completedPomodoros, isDone, createdAt, sortIndex
    }
}
