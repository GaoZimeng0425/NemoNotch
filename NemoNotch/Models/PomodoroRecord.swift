import Foundation

struct PomodoroRecord: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let taskID: UUID?
    let phase: PomodoroPhase
    let plannedDuration: TimeInterval
    let actualDuration: TimeInterval
    let startedAt: Date
    let endedAt: Date
    let outcome: Outcome

    enum Outcome: String, Codable, Equatable, Hashable {
        case completed
        case partial
        case abandoned
    }
}
