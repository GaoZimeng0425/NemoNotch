import AppKit
import SwiftUI

/// The edge bar's window: a fixed envelope on the dock screen's LEFT edge,
/// spanning the visible height. Never resized at interaction time — opening
/// the bar and showing the card are drawn inside it (a window growing into
/// the screen shows its old content one frame at the old origin). Areas
/// without drawn content pass clicks through (`EdgeBarHostingView.hitTest`).
final class EdgeBarWindow: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    init(frame: NSRect, hosting: EdgeBarHostingView) {
        super.init(
            contentRect: frame,
            // .nonactivatingPanel: clicking the bar never takes focus from
            // the front app (the user's terminal).
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .none
        // The window owns its size; the hosting view must never resize it.
        hosting.sizingOptions = []
        contentView = hosting
    }
}

/// The window's content: SwiftUI for pixels, plus the AppKit pieces the
/// bar's interaction needs. SwiftUI hover/tap don't reliably fire in a
/// non-activating panel of a never-active app, so:
///
/// - **Hover** is two tracking areas (`.activeAlways`) — the bar body and
///   the card — reported as ONE inside/outside: crossing from the body onto
///   the card is not a leave.
/// - **Clicks and scrolls** are handed to the controller with their point,
///   which resolves them from geometry (`EdgeBarMetrics`), so a click and a
///   hover can never disagree about where anything is.
final class EdgeBarHostingView: NSHostingView<AnyView> {
    enum Pointer {
        case entered
        case exited
        /// A move over the bar, in this view's (flipped) coordinates.
        case moved(CGPoint)
    }

    var onPointer: ((Pointer) -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }

    /// A left mouse-down at a point, with its event (the controller may run
    /// a drag from it); `true` = taken.
    var onMouseDown: ((CGPoint, NSEvent) -> Bool)?
    /// A scroll at a point: `scrollingDeltaY`, and whether it is precise
    /// (trackpad points) or a notched wheel (lines). `true` = taken.
    var onScroll: ((CGPoint, CGFloat, Bool) -> Bool)?

    /// The drawn body's rect (flipped coordinates).
    var bodyRect: CGRect = .zero {
        didSet {
            if bodyRect != oldValue {
                updateTrackingAreas()
            }
        }
    }

    /// The card's hover rect while it is up.
    var cardRect: CGRect? {
        didSet {
            if cardRect != oldValue {
                updateTrackingAreas()
            }
        }
    }

    private let relay = PointerRelay()
    private var areas: [NSTrackingArea] = []

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        relay.view = self
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("not built from a nib")
    }

    /// The app is never active, so every click is a "first" click; accepting
    /// it activates nothing (non-activating panel, can't become key).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Only the drawn body and the card take events; the rest of the
    /// envelope passes them through to whatever is behind.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bodyRect.contains(local) || cardRect?.contains(local) == true else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.buttonNumber == 0, !event.modifierFlags.contains(.control), onMouseDown?(point, event) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if onScroll?(point, event.scrollingDeltaY, event.hasPreciseScrollingDeltas) == true {
            return
        }
        super.scrollWheel(with: event)
    }

    /// Rebuilt whenever geometry changes (AppKit calls this) or the drawn
    /// rects move. An area installed once would keep the closed size: the
    /// strip revealed by opening would read as outside and fold the bar
    /// under the cursor.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        areas.forEach(removeTrackingArea)
        var parts: [(PointerRelay.Region, CGRect)] = [(.body, bodyRect)]
        if let cardRect {
            parts.append((.card, cardRect))
        }
        areas = parts.map { region, rect in
            NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                owner: relay,
                userInfo: [PointerRelay.regionKey: region.rawValue]
            )
        }
        areas.forEach(addTrackingArea)

        let rects = Dictionary(uniqueKeysWithValues: parts)
        relay.holds = { [weak self] region in
            guard let self, let rect = rects[region], let cursor = cursor() else { return false }
            return rect.contains(cursor)
        }
        // A removed area sends no exit, and a shorter body can leave the
        // cursor outside without one (a session leaving the last row while
        // hovered). Ask the new rects where the cursor is.
        if let cursor = cursor() {
            relay.keep(Set(parts.filter { $0.1.contains(cursor) }.map(\.0)))
        }
    }

    private func cursor() -> CGPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// The tracking areas' owner — separate from the hosting view so
    /// SwiftUI's own tracking never sees our events.
    ///
    /// Exits are verified before they are believed: a tracking area rebuilt
    /// under a still cursor (the card's frame moving through its transition)
    /// can send an enter and at once an exit; believed, it closed the open
    /// bar under the cursor. A doubted exit is rechecked every 0.25s until
    /// the cursor really left or an enter clears the doubt.
    final class PointerRelay: NSResponder {
        enum Region: String {
            case body, card
        }

        static let regionKey = "edgeBarRegion"
        static let recheck: TimeInterval = 0.25

        var handler: ((Pointer) -> Void)?
        /// The view whose coordinates moves are reported in.
        weak var view: NSView?
        var holds: ((Region) -> Bool)?

        private var inside: Set<Region> = []
        private var doubted: Set<Region> = []
        private var recheckScheduled = false

        override func mouseEntered(with event: NSEvent) {
            entered(Self.region(of: event))
        }

        override func mouseExited(with event: NSEvent) {
            exited(Self.region(of: event))
        }

        override func mouseMoved(with event: NSEvent) {
            guard let view else { return }
            handler?(.moved(view.convert(event.locationInWindow, from: nil)))
        }

        private static func region(of event: NSEvent) -> Region {
            (event.trackingArea?.userInfo?[regionKey] as? String).flatMap(Region.init(rawValue:)) ?? .body
        }

        private func entered(_ region: Region) {
            doubted.remove(region)
            let wasOutside = inside.isEmpty
            inside.insert(region)
            if wasOutside {
                handler?(.entered)
            }
        }

        /// Reported even without a matching enter: an area installed under
        /// the cursor never says "entered", and swallowing its exit would
        /// strand the bar open.
        private func exited(_ region: Region) {
            if holds?(region) == true {
                doubted.insert(region)
                recheckLater()
                return
            }
            doubted.remove(region)
            inside.remove(region)
            if inside.isEmpty {
                handler?(.exited)
            }
        }

        private func recheckLater() {
            guard !recheckScheduled else { return }
            recheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.recheck) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recheckScheduled = false
                    for region in self.doubted {
                        self.exited(region)
                    }
                }
            }
        }

        /// Areas that are gone send no exit; forgetting the last one the
        /// cursor was in is leaving.
        /// Also when nothing was counted inside: an area installed under the
        /// cursor never says "entered" (the bar can still open from moves),
        /// and a repeated exit is harmless to the hover intent.
        func keep(_ regions: Set<Region>) {
            inside.formIntersection(regions)
            if regions.isEmpty {
                doubted.removeAll()
                handler?(.exited)
            }
        }
    }
}
