import AppKit

class NotchWindow: NSWindow {
    init(rect: NSRect) {
        super.init(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        alphaValue = 1
        level = .statusBar + 8
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        acceptsMouseMovedEvents = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PassThroughView: NSView {
    var isBlocking = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if view !== self { return view }
        return isBlocking ? self : nil
    }

    /// The notch window spans the full screen and therefore inherits the
    /// physical notch's `safeAreaInsets.top` from AppKit. Without overriding
    /// it, SwiftUI content is pushed below the notch on the first layout
    /// pass and only snaps back up once `.ignoresSafeArea()` takes effect on
    /// the next pass — producing a visible "drop then retract" on launch.
    /// Reporting zero here absorbs the inset at the AppKit layer, so the
    /// hosted SwiftUI tree never sees a notch inset and there is no two-frame
    /// relayout to animate. (Atoll gets this for free by sizing its window
    /// to just the notch; NemoNotch keeps a full-screen window for badge
    /// overflow + multi-screen pinning, so it strips the inset explicitly.)
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}
