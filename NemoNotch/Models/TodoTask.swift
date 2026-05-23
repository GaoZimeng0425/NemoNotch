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
        case low
        case medium
        case high
    }
}
