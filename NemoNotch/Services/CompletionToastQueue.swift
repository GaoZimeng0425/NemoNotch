import Foundation

/// One completion toast card: a single finished unit with its own timer.
struct CompletionToast: Identifiable, Equatable {
    let id: UUID
    var item: CompletionItem
    /// When this card auto-dismisses. Ignored while the queue is paused.
    var deadline: Date
}

/// Pure state of the toast row under the notch: one card per completion,
/// laid out side by side. Each card expires `duration` after it last arrived;
/// hovering the row pauses every timer, and leaving restarts them from full
/// (so a card the user was reading never vanishes the instant they look away).
///
/// - A completion whose name already has a card refreshes that card in place
///   (newer non-nil fields win, timer restarts) instead of adding a duplicate.
/// - At most `capacity` cards: a new arrival beyond it evicts the card that
///   last arrived longest ago (earliest deadline) — a just-refreshed card
///   keeps its slot even if it sits first in the row.
struct CompletionToastQueue {
    let duration: TimeInterval
    let capacity: Int
    private(set) var toasts: [CompletionToast] = []
    private(set) var isPaused = false

    /// The earliest deadline that should fire, or nil when nothing can expire
    /// (empty or paused).
    var nextDeadline: Date? {
        isPaused ? nil : toasts.map(\.deadline).min()
    }

    mutating func add(_ items: [CompletionItem], now: Date, makeID: () -> UUID = UUID.init) {
        // A paused row stays paused; the new card's clock starts on resume.
        let deadline = now.addingTimeInterval(duration)
        for item in items {
            if let idx = toasts.firstIndex(where: { $0.item.name == item.name }) {
                toasts[idx].item = CompletionFlashNames.merge(existing: [toasts[idx].item], new: [item])[0]
                toasts[idx].deadline = deadline
            } else {
                toasts.append(CompletionToast(id: makeID(), item: item, deadline: deadline))
            }
        }
        while toasts.count > capacity,
              let stalest = toasts.indices.min(by: { toasts[$0].deadline < toasts[$1].deadline }) {
            toasts.remove(at: stalest)
        }
    }

    mutating func dismiss(id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    mutating func pause() {
        isPaused = true
    }

    /// Ends a pause; every card gets a full `duration` from `now`.
    mutating func resume(now: Date) {
        guard isPaused else { return }
        isPaused = false
        let deadline = now.addingTimeInterval(duration)
        for idx in toasts.indices {
            toasts[idx].deadline = deadline
        }
    }

    /// Removes cards whose deadline has passed. Paused: removes nothing.
    @discardableResult
    mutating func expire(now: Date) -> [CompletionToast] {
        guard !isPaused else { return [] }
        let expired = toasts.filter { $0.deadline <= now }
        toasts.removeAll { $0.deadline <= now }
        return expired
    }
}
