import Foundation

/// Picks what the user actually typed out of a transcript's user-role lines.
enum UserPrompt {
    /// Current (pre-fix) behavior: any non-empty user text counts.
    static func isTyped(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The first typed prompt among `messages`, cut to 80 characters.
    static func first(in messages: [ChatMessage]) -> String? {
        messages.first { $0.role == .user && isTyped($0.content) }.map { String($0.content.prefix(80)) }
    }

    /// The last typed prompt among `messages`, cut to 80 characters.
    static func last(in messages: [ChatMessage]) -> String? {
        messages.last { $0.role == .user && isTyped($0.content) }.map { String($0.content.prefix(80)) }
    }
}
