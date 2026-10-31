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
/// - One card per session/agent (`CompletionItem.toastKey`): the same session
///   finishing again refreshes its card in place (newer non-nil fields win,
///   timer restarts); another session in the same project — another app or
///   the same app — gets its own card. Session-less sources (Pomodoro,
///   calendar) fall back to the name.
/// - A stack, not a conveyor: at most `capacity` cards show. A new arrival
///   beyond it parks the card that last arrived longest ago (earliest
///   deadline) in `waiting` instead of dropping it; whenever a shown card is
///   closed, expires or is removed, the most recently parked card comes back
///   with a full timer. Parked cards never tick — the user has not seen them.
///   The pile keeps the newest `waitingLimit` cards.
struct CompletionToastQueue {
    let duration: TimeInterval
    let capacity: Int
    var waitingLimit = 20
    private(set) var toasts: [CompletionToast] = []
    /// Cards pushed off the row, oldest first.
    private(set) var waiting: [CompletionToast] = []
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
            if let idx = toasts.firstIndex(where: { $0.item.toastKey == item.toastKey }) {
                toasts[idx].item = CompletionFlashNames.merge(existing: [toasts[idx].item], new: [item])[0]
                toasts[idx].deadline = deadline
            } else if let idx = waiting.firstIndex(where: { $0.item.toastKey == item.toastKey }) {
                var card = waiting.remove(at: idx)
                card.item = CompletionFlashNames.merge(existing: [card.item], new: [item])[0]
                card.deadline = deadline
                toasts.append(card)
            } else {
                toasts.append(CompletionToast(id: makeID(), item: item, deadline: deadline))
            }
        }
        while toasts.count > capacity,
              let stalest = toasts.indices.min(by: { toasts[$0].deadline < toasts[$1].deadline }) {
            waiting.append(toasts.remove(at: stalest))
        }
        if waiting.count > waitingLimit {
            waiting.removeFirst(waiting.count - waitingLimit)
        }
    }

    /// Swaps the content of the card keyed `key` — shown or waiting — without
    /// touching its timer (content changed, nothing new arrived); nil removes
    /// the card. Returns false when no card has that key.
    @discardableResult
    mutating func replace(key: String, with item: CompletionItem?, now: Date) -> Bool {
        if let idx = toasts.firstIndex(where: { $0.item.toastKey == key }) {
            if let item {
                toasts[idx].item = item
            } else {
                toasts.remove(at: idx)
                refill(now: now)
            }
            return true
        }
        if let idx = waiting.firstIndex(where: { $0.item.toastKey == key }) {
            if let item {
                waiting[idx].item = item
            } else {
                waiting.remove(at: idx)
            }
            return true
        }
        return false
    }

    mutating func dismiss(id: UUID, now: Date) {
        toasts.removeAll { $0.id == id }
        refill(now: now)
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

    /// Removes cards whose deadline has passed, then brings waiting cards
    /// back into the freed slots. Paused: removes nothing.
    @discardableResult
    mutating func expire(now: Date) -> [CompletionToast] {
        guard !isPaused else { return [] }
        let expired = toasts.filter { $0.deadline <= now }
        toasts.removeAll { $0.deadline <= now }
        refill(now: now)
        return expired
    }

    /// Most recently parked first; a returning card sits at the head of the
    /// row (it is older than what is showing) with a full timer.
    private mutating func refill(now: Date) {
        while toasts.count < capacity, var card = waiting.popLast() {
            card.deadline = now.addingTimeInterval(duration)
            toasts.insert(card, at: 0)
        }
    }
}
