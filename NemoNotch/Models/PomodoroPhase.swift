import Foundation

enum PomodoroPhase: String, Codable, Equatable, CaseIterable {
    case idle
    case work
    case shortBreak
    case longBreak
}
