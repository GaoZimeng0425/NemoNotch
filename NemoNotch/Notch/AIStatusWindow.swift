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

    /// Keep the fixed canvas on-screen during drags. The visible shape
    /// (capsule/panel) hugs the canvas's top-right corner, and a borderless
    /// window gets no default drag constraint — unconstrained, the shape slides
    /// under the menu bar / off the screen edge, where the screen progressively
    /// clips its content away (reads as components vanishing right-to-left).
    /// The restore-path clamp in `AIStatusWindowController.applyPosition` only
    /// runs on the first placement; this covers the live drag.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame, visible.width > 0, visible.height > 0 else {
            return super.constrainFrameRect(frameRect, to: screen)
        }
        var rect = frameRect
        if rect.maxX > visible.maxX { rect.origin.x = visible.maxX - rect.width }
        if rect.minX < visible.minX { rect.origin.x = visible.minX }
        if rect.maxY > visible.maxY { rect.origin.y = visible.maxY - rect.height }
        if rect.minY < visible.minY { rect.origin.y = visible.minY }
        return super.constrainFrameRect(rect, to: screen)
    }
}
