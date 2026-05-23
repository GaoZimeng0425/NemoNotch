import Foundation

/// Pure state machine for the "should we auto-close when mouse moves outside?"
/// decision. Separated from `NotchCoordinator` so the logic can be unit-tested
/// without instantiating NSPanels.
///
/// Lifecycle: `didOpen(viaHotkey:)` on each open, `observe(mouseInside:)` per
/// mouse-move tick while opened, `reset()` on close.
struct HotkeyDismissState: Equatable {
    enum MoveOutcome: Equatable {
        /// No state change; coordinator should do nothing.
        case ignore
        /// Mouse just entered for the first time. Coordinator should cancel
        /// the hotkey-auto-close timer.
        case markedEntered
        /// Mouse left after having entered. Coordinator should close the notch.
        case shouldClose
    }

    private(set) var openedViaHotkey: Bool = false
    private(set) var mouseHasEnteredContent: Bool = false

    mutating func didOpen(viaHotkey: Bool) {
        openedViaHotkey = viaHotkey
        // Mouse-hover open: cursor is already in the hitbox, so existing
        // "close on leave" semantics apply from frame 1. Hotkey open: cursor
        // is somewhere else, so don't trigger close until it actually arrives.
        mouseHasEnteredContent = !viaHotkey
    }

    mutating func observe(mouseInside: Bool) -> MoveOutcome {
        if mouseInside {
            if mouseHasEnteredContent { return .ignore }
            mouseHasEnteredContent = true
            return .markedEntered
        }
        return mouseHasEnteredContent ? .shouldClose : .ignore
    }

    mutating func reset() {
        openedViaHotkey = false
        mouseHasEnteredContent = false
    }
}
