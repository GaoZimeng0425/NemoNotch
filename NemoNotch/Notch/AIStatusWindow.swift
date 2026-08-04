import AppKit

/// Borderless, non-activating floating panel for the AI-status FAB. Mirrors
/// `NotchWindow`'s fixed-canvas approach: the window is sized ONCE to the full
/// panel footprint and never resizes on expand/collapse — all transitions are
/// SwiftUI-internal `.animation(_:value:)`, so there is no flicker from
/// re-hosting or `setFrame(animate:)`. Click-through is handled by the
/// `PassThroughView` contentView (transparent canvas regions return `nil` from
/// `hitTest`, so they neither absorb clicks nor start drags).
final class AIStatusWindow: NSPanel {
    init() {
        // Canvas = panel size + shadow-blur room on both axes. Fixed for the
        // window's lifetime; the capsule/panel are positioned inside it.
        let canvasW = NotchConstants.aiStatusFabPanelWidth + NotchConstants.aiStatusFabShadowPad * 2
        let canvasH = NotchConstants.aiStatusFabPanelHeight + NotchConstants.aiStatusFabShadowPad * 2
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: canvasW, height: canvasH),
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
        // Dragging is driven by `DragHandleView` (an NSViewRepresentable) on the
        // capsule body and the expanded header — NOT by the window background.
        // With a fixed transparent canvas, `isMovableByWindowBackground = true`
        // would let clicks on empty canvas regions start drags (a bug), so it
        // stays false.
        isMovableByWindowBackground = false
        // Stay put across Space switches; visible on all Spaces.
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
