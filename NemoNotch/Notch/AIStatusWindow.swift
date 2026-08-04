import AppKit

/// Borderless, non-activating floating panel for the AI-status FAB. Mirrors
/// `QuickStartWindow`'s proven config: floats above the notch, never steals
/// focus, draws its own shadow in SwiftUI (native shadow would clip to a black
/// square), and disables system window animation to dodge the
/// `_NSWindowTransformAnimation` dealloc crash recorded in QuickStartWindow.
final class AIStatusWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the notch panel (.statusBar + 8) so the FAB is never occluded.
        level = .statusBar + 9
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        // Stay put across Space switches; visible on all Spaces.
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
