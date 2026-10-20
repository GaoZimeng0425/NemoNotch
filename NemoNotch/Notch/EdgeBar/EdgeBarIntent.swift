import Foundation

/// How the bar's hover decisions are scheduled. Injected so tests fire the
/// pending item by hand.
typealias EdgeBarScheduler = DelayScheduler

/// Decides when a cursor over the bar means "open", and when leaving means
/// "close". Raw enter/exit is too eager both ways: a cursor brushing the edge
/// would unfold the bar, a hand slipping a pixel off would fold it under
/// itself. Opening waits `openDelay`, closing tolerates `closeTolerance`.
///
/// One pending decision at a time: a new wish cancels the old one, and a late
/// item is dropped by the generation check — `DispatchWorkItem.cancel()`
/// alone is not a guarantee once the item is already dequeued.
@MainActor
final class EdgeBarHoverIntent {
    private(set) var isOpen = false
    /// Called once per real change, after `isOpen` is written.
    var onChange: ((Bool) -> Void)?

    private let schedule: EdgeBarScheduler
    private var pendingTarget: Bool?
    private var pendingItem: DispatchWorkItem?
    private var generation = 0

    init(schedule: @escaping EdgeBarScheduler = mainDelayScheduler) {
        self.schedule = schedule
    }

    /// Also the answer to every move inside the bar: moves arrive at display
    /// rate and must neither restart the open delay nor leave a pending close.
    func pointerEntered() {
        want(true)
    }

    func pointerExited() {
        want(false)
    }

    /// Close at once (Go-to-session sent the user elsewhere, the chat bubble
    /// opened). Through the intent, so it never believes a closed bar open.
    func closeNow() {
        guard isOpen else {
            cancelPending()
            return
        }
        cancelPending()
        isOpen = false
        onChange?(false)
    }

    private func want(_ open: Bool) {
        if open == isOpen {
            // Already there: whatever was pending went the other way.
            cancelPending()
            return
        }
        // Already on its way: rescheduling would push it out on every move.
        guard pendingTarget != open else { return }
        cancelPending()
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.pendingTarget = nil
                self.pendingItem = nil
                self.isOpen = open
                self.onChange?(open)
            }
        }
        pendingTarget = open
        pendingItem = item
        schedule(open ? EdgeBarMotion.openDelay : EdgeBarMotion.closeTolerance, item)
    }

    private func cancelPending() {
        generation &+= 1
        pendingItem?.cancel()
        pendingItem = nil
        pendingTarget = nil
    }
}

/// On the open list, decides when a cursor on a row means "show me that
/// one". Staying `rowDwell` on a row brings its card up; with a card up,
/// staying `rowSwitch` on another row moves the card there — so the card
/// doesn't jump under a hand crossing rows on its way to the card. Leaving
/// the rows (onto the card, the head, off the bar) drops the pending switch.
@MainActor
final class EdgeBarRowSwitch {
    var onSelect: ((String) -> Void)?

    private let schedule: EdgeBarScheduler
    private var pendingTarget: String?
    private var pendingItem: DispatchWorkItem?
    private var generation = 0

    init(schedule: @escaping EdgeBarScheduler = mainDelayScheduler) {
        self.schedule = schedule
    }

    /// Every move over the bar: `row` is the session under the cursor, `nil`
    /// when over no row.
    func hover(_ row: String?, selected: String?) {
        guard let row, row != selected else {
            cancel()
            return
        }
        guard row != pendingTarget else { return }
        cancel()
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.pendingTarget = nil
                self.pendingItem = nil
                self.onSelect?(row)
            }
        }
        pendingTarget = row
        pendingItem = item
        schedule(selected == nil ? EdgeBarMotion.rowDwell : EdgeBarMotion.rowSwitch, item)
    }

    func cancel() {
        generation &+= 1
        pendingItem?.cancel()
        pendingItem = nil
        pendingTarget = nil
    }
}
