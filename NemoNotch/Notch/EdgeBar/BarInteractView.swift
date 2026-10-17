import AppKit
import SwiftUI

/// Transparent AppKit view owning an element's tap and hover. This is the
/// ONLY event path that works in the bar's non-activating panel — SwiftUI
/// discrete gestures (onTapGesture / Button) never fire here — so every
/// interactive element in the bar (head, rings, rows, card buttons) draws
/// itself as plain SwiftUI and hands interaction to this overlay.
struct BarInteractView: NSViewRepresentable {
    var onTap: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var isDraggingEnabled = false
    var onDrag: ((NSEvent) -> Void)?

    func makeNSView(context: Context) -> InteractView {
        let view = InteractView()
        view.onTap = onTap
        view.onHover = onHover
        view.isDraggingEnabled = isDraggingEnabled
        view.onDrag = onDrag
        view.acceptsFirstMouse = true
        return view
    }

    func updateNSView(_ view: InteractView, context: Context) {
        view.onTap = onTap
        view.onHover = onHover
        view.isDraggingEnabled = isDraggingEnabled
        view.onDrag = onDrag
    }

    final class InteractView: NSView {
        var onTap: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        /// When set, a drag beyond the threshold calls `onDrag` (window move)
        /// instead of tap — used by the head.
        var isDraggingEnabled = false
        var onDrag: ((NSEvent) -> Void)?
        var acceptsFirstMouse = true

        private var dragStart: NSPoint?

        override var acceptsFirstResponder: Bool {
            false
        }

        override var isFlipped: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            acceptsFirstMouse
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.userInfo?["hover"] != nil {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: ["hover": "hover"]
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(false)
        }

        override func mouseDown(with event: NSEvent) {
            guard event.buttonNumber == 0 else {
                super.mouseDown(with: event)
                return
            }
            if isDraggingEnabled, let window {
                // Drag-vs-tap, the head's pattern: past the threshold the
                // window takes over and moves; below it this is a tap.
                dragStart = NSEvent.mouseLocation
                while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    if next.type == .leftMouseUp {
                        break
                    }
                    let now = NSEvent.mouseLocation
                    if hypot(now.x - dragStart!.x, now.y - dragStart!.y) > 4 {
                        onDrag?(event)
                        return
                    }
                }
                onTap?()
                return
            }
            // Plain tap: wait for mouseUp anywhere (a tiny slide off a small
            // target still reads as the intended click).
            _ = window?.nextEvent(matching: [.leftMouseUp])
            onTap?()
        }
    }
}

private func hypot(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
    (dx * dx + dy * dy).squareRoot()
}
