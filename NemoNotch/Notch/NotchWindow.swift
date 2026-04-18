import AppKit

class NotchWindow: NSPanel {
    init(rect: NSRect) {
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        alphaValue = 1
        level = .statusBar + 8
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}
