import AppKit

/// The edge bar's window: a fixed envelope docked to the main screen's LEFT
/// edge, spanning the visible height. Never resized — opening the bar and
/// showing the detail card are drawn inside this canvas (a window resize
/// behind a closing body showed a one-frame ghost). The envelope keeps room
/// for the open list and the detail card beside it; areas without drawn
/// content click through (`EdgeBarHitView`).
final class EdgeBarWindow: NSPanel {
    /// Canvas width: open body (≤ 248) + gap + detail card (320) + gutters.
    static let canvasWidth: CGFloat = 18 * 2 + 248 + 8 + 320
    // Canvas height: the full visible height of the main screen.

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    init(visibleFrame: NSRect) {
        super.init(
            contentRect: NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: Self.canvasWidth,
                height: visibleFrame.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    /// Pin to the left edge of `visibleFrame` (re-applied when displays
    /// change).
    func dock(to visibleFrame: NSRect) {
        setFrameOrigin(NSPoint(x: visibleFrame.minX, y: visibleFrame.minY))
    }
}

/// The window's content view. Clicks land on the hosting view only inside
/// the rects the controller reports (the drawn bar body and the detail
/// card); everywhere else the event passes through to whatever is behind —
/// the envelope is much larger than the drawn content.
final class EdgeBarHitView: NSView {
    /// Hit-testable rects in this view's coordinate system (flipped, top-left
    /// origin — same as the SwiftUI drawing).
    var hitRects: [CGRect] = []

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitRects.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point)
    }
}
