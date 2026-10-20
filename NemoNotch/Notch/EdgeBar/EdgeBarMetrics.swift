import SwiftUI

/// Geometry for the edge bar, in one place (evlat-measured). Every measure
/// along the edge is from the bar's TOP (the head's end of the drawn shape),
/// never the window's: the window is a fixed envelope and the bar hangs in
/// it at `EdgeBarController.barTop`. Across it, x is from the ANCHORED side
/// (the screen edge, or a floating capsule's head end) — the right side is
/// the same numbers mirrored.
///
/// Rows are fixed-height, so hit-testing is pure arithmetic here — the
/// controller reads the row under the cursor and the clicks from these
/// functions, never from per-element views (that's what made the old bar's
/// hover and buttons unreliable).
enum EdgeBarMetrics {
    // MARK: Body

    /// The closed body's width (the head plus 10pt each side).
    static let barWidth: CGFloat = 54
    static let corner: CGFloat = 18
    /// The inverse curve at both ends; part of the drawn length.
    static let flare: CGFloat = 20
    /// Room between the body's end and what it holds, the same at both ends.
    static let bodyMargin: CGFloat = 14
    /// Transparent room on the inner side for the shadow and around the card.
    static let gutter: CGFloat = 18

    /// The body's silhouette: the notch shell's shape, docked to `side`.
    static func shape(_ side: EdgeBarSide) -> BezelShape {
        BezelShape(edge: side == .left ? .leading : .trailing, flare: flare, corner: corner)
    }

    // MARK: Head

    static let headSize: CGFloat = 34
    /// From the bar's top to the head's top: the flare, then the margin.
    static var headTop: CGFloat {
        flare + bodyMargin
    }

    // MARK: Rings and rows

    static let ringSize: CGFloat = 20
    static let ringSpacing: CGFloat = 10
    /// From the head's bottom to the first ring.
    static let ringTopGap: CGFloat = 18
    /// The closed bar's slots: rings, the last one giving way to "+N" when
    /// there are more sessions than slots.
    static let slotCount = 4
    /// The open list shows at most this many rows; the half row says more
    /// follow (scroll for them).
    static let visibleRows: CGFloat = 7.5

    /// One row: its ring and one gap. A row's hover slot is this pitch.
    static var rowPitch: CGFloat {
        ringSize + ringSpacing
    }

    /// The ring's leading edge inside the bar's width (it is centred there).
    static var ringLead: CGFloat {
        (barWidth - ringSize) / 2
    }

    /// Top of ring `index`, from the bar's top.
    static func slotTop(_ index: Int) -> CGFloat {
        headTop + headSize + ringTopGap + CGFloat(index) * rowPitch
    }

    /// The list's visible area starts half a gap above the first ring.
    static var listTop: CGFloat {
        slotTop(0) - ringSpacing / 2
    }

    static func listHeight(rows: Int) -> CGFloat {
        min(CGFloat(max(0, rows)), visibleRows) * rowPitch
    }

    static func maxScrollOffset(rows: Int) -> CGFloat {
        max(0, CGFloat(rows) * rowPitch - listHeight(rows: rows))
    }

    // MARK: Names (open)

    static let nameGap: CGFloat = 8
    static let nameInset: CGFloat = 14
    /// How far a name travels as it comes in, from under its ring.
    static let nameTravel: CGFloat = 10
    static let nameMaxWidth: CGFloat = 210
    static let minOpenWidth: CGFloat = 110
    /// Name + status line, centred on the ring.
    static let labelHeight: CGFloat = 26
    /// The selected / hovered row's ground.
    static let groundInset: CGFloat = 5
    static let groundHeight: CGFloat = 28

    /// The open body's width for names this wide.
    static func openWidth(namesWidth: CGFloat) -> CGFloat {
        max(minOpenWidth, barWidth - ringLead + nameGap + namesWidth + nameInset)
    }

    static var maxOpenWidth: CGFloat {
        openWidth(namesWidth: nameMaxWidth)
    }

    // MARK: Summary

    static let summaryGap: CGFloat = 8
    static let summaryHeight: CGFloat = 12

    static func summaryTop(rows: Int) -> CGFloat {
        listTop + listHeight(rows: rows) + summaryGap
    }

    // MARK: Lengths

    /// The closed bar hugs what it holds: the head, then one slot per ring.
    static func closedLength(slots: Int) -> CGFloat {
        let head = headTop + headSize + headTop
        guard slots > 0 else { return head }
        return head + ringTopGap + CGFloat(slots) * ringSize + CGFloat(slots - 1) * ringSpacing
    }

    /// The open body: the head, the visible list and the summary line, the
    /// usage block under them, closed by the same margin the head opens with.
    /// With no session the block hangs under the head.
    static func openLength(rows: Int, usageLines: Int = 0) -> CGFloat {
        if usageLines > 0 {
            return EdgeBarUsage.top(rows: rows) + EdgeBarUsage.height(lines: usageLines) + headTop
        }
        guard rows > 0 else { return closedLength(slots: 0) }
        return summaryTop(rows: rows) + summaryHeight + headTop
    }

    /// The bar is laid out as if it held every slot, centred on the edge; a
    /// shorter bar hangs from the same head so the head never moves.
    static var anchorLength: CGFloat {
        closedLength(slots: slotCount)
    }

    // MARK: Capsule (floating)

    /// The capsule is the closed bar laid on its side: as tall as the bar is
    /// wide, its head exactly where an open panel's head is — so opening
    /// moves no head, and one `isOverHead` serves both.
    static var capsuleHeight: CGFloat {
        barWidth
    }

    /// The capsule's top under the bar's top.
    static var capsuleTop: CGFloat {
        headTop - (barWidth - headSize) / 2
    }

    /// From the anchored end to the first ring: the head's margin, the head,
    /// the gap a docked bar leaves under its head.
    static var capsuleRingStart: CGFloat {
        (barWidth - headSize) / 2 + headSize + ringTopGap
    }

    /// The capsule hugs what it holds, like the closed bar; the far end
    /// keeps a ring's own inset.
    static func capsuleLength(slots: Int) -> CGFloat {
        guard slots > 0 else { return barWidth }
        return capsuleRingStart + CGFloat(slots) * ringSize + CGFloat(slots - 1) * ringSpacing + ringLead
    }

    /// Where a capsule's top may rest: where the closed capsule lies inside
    /// the band an opened panel keeps to (a gutter off both canvas edges).
    /// Past it, part of the capsule is outside the panel it opens, and a
    /// cursor there folds the panel at once — over and over.
    static func capsuleRestRange(canvasHeight: CGFloat) -> ClosedRange<CGFloat> {
        let low = gutter - flare
        return low ... max(low, canvasHeight - gutter - capsuleTop - capsuleHeight)
    }

    /// An opened capsule's top: where it rests, risen just enough for a
    /// panel `length` long to fit the canvas.
    static func floatingOpenTop(rest: CGFloat, length: CGFloat, canvasHeight: CGFloat) -> CGFloat {
        max(gutter - flare, min(rest, canvasHeight - gutter - length + flare))
    }

    /// The closed capsule's span down the canvas, resting at `rest`.
    static func capsuleSpan(rest: CGFloat) -> ClosedRange<CGFloat> {
        (rest + capsuleTop) ... (rest + capsuleTop + capsuleHeight)
    }

    /// An opened panel's span down the canvas: the body inside the flares.
    static func panelSpan(top: CGFloat, length: CGFloat) -> ClosedRange<CGFloat> {
        (top + flare) ... (top + length - flare)
    }

    // MARK: Card

    static let cardWidth: CGFloat = 320
    static let cardGap: CGFloat = 8
    /// The card's top above its row's ring, so its header lines up with the
    /// row's name.
    static let cardLead: CGFloat = 16

    /// The envelope's width: the widest open body, the gap, the card and its
    /// shadow's room.
    static var canvasWidth: CGFloat {
        maxOpenWidth + cardGap + cardWidth + gutter
    }

    /// A floating bar's envelope: the docked one plus the gutter behind the
    /// anchored end (a docked bar's is the screen edge; a capsule's shadow
    /// needs the room).
    static var floatingCanvasWidth: CGFloat {
        gutter + canvasWidth
    }

    /// How far an opened bar and its card reach from the anchored end — the
    /// room a floating capsule needs on its open side.
    static var reach: CGFloat {
        canvasWidth
    }

    /// The card's top in canvas coordinates: level with its row (scrolled
    /// with the list), held at the last closed slot's level so a card for a
    /// low row doesn't hang off the bar, then pushed up only as far as it
    /// must to stay whole inside the canvas.
    static func cardTop(
        slot: Int,
        offset: CGFloat,
        height: CGFloat,
        barTop: CGFloat,
        canvasHeight: CGFloat
    ) -> CGFloat {
        let level = barTop + min(max(0, slotTop(slot) - offset - cardLead), slotTop(slotCount - 1))
        let lowest = canvasHeight - height - gutter
        return max(gutter, min(level, lowest))
    }

    // MARK: Hit-testing (bar coordinates: x from the edge, y from the bar's top)

    /// The row under a point while open; `nil` over the head, the summary,
    /// past the body's width, or over a row not wholly visible.
    static func slot(x: CGFloat, y: CGFloat, width: CGFloat, rows: Int, offset: CGFloat = 0) -> Int? {
        guard x >= 0, x <= width, y >= listTop, y < listTop + listHeight(rows: rows) else { return nil }
        let index = Int((y + offset - listTop) / rowPitch)
        guard index >= 0, index < rows else { return nil }
        return isRowVisible(index, rows: rows, offset: offset) ? index : nil
    }

    /// Whether row `index` lies wholly inside the visible list.
    static func isRowVisible(_ index: Int, rows: Int, offset: CGFloat) -> Bool {
        let top = slotTop(index) - offset
        return top >= listTop - 0.5 && top + ringSize <= listTop + listHeight(rows: rows) + 0.5
    }

    static func isOverList(x: CGFloat, y: CGFloat, width: CGFloat, rows: Int) -> Bool {
        x >= 0 && x <= width && y >= listTop && y < listTop + listHeight(rows: rows)
    }

    static func isOverHead(x: CGFloat, y: CGFloat) -> Bool {
        let lead = (barWidth - headSize) / 2
        return x >= lead && x <= lead + headSize && y >= headTop && y <= headTop + headSize
    }
}

/// The bar's timing and curves (evlat-measured).
enum EdgeBarMotion {
    /// Hover must stay this long before the bar opens (a brush doesn't).
    static let openDelay: TimeInterval = 0.08
    /// The cursor may be gone this long before the bar closes.
    static let closeTolerance: TimeInterval = 0.25
    /// Staying on a row this long brings its card up.
    static let rowDwell: TimeInterval = 0.15
    /// With a card up, staying on another row this long moves it there.
    static let rowSwitch: TimeInterval = 0.12
    /// How long a pressed button shows it before its action runs.
    static let pressFeedback: TimeInterval = 0.12
    /// The usage refresh waits out the opening's curve.
    static let usageRefreshDelay: TimeInterval = 0.3
    /// Seconds between beats (a waiting ring's wave).
    static let beatInterval: TimeInterval = 3

    static let body = Animation.smooth(duration: 0.24)
    /// Names arrive once the body has made some room, and leave at once.
    static let namesIn = Animation.easeOut(duration: 0.18).delay(0.07)
    static let namesOut = Animation.easeIn(duration: 0.1)
    /// The body lengthening or shortening as sessions come and go.
    static let length = Animation.easeOut(duration: 0.22)
    /// Rings reordering / changing phase: interruptible, keeps velocity.
    static let rows = Animation.spring(response: 0.38, dampingFraction: 0.72)
    static let cardIn = Animation.smooth(duration: 0.26)
    static let cardOut = Animation.easeIn(duration: 0.14)
    static let cardContent = Animation.easeOut(duration: 0.16)
    static let cardTravel: CGFloat = 8

    /// The card comes out of the bar's side — a few points of travel away
    /// from the edge, a touch of growth, a fade — and leaves quicker.
    static func cardTransition(_ side: EdgeBarSide) -> AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.96, anchor: side.unitPoint))
                .combined(with: .offset(x: -side.sign * cardTravel))
                .animation(cardIn),
            removal: .opacity
                .combined(with: .scale(scale: 0.98, anchor: side.unitPoint))
                .animation(cardOut)
        )
    }

}

/// The side, for layout: everything anchored on the left in the docked-left
/// bar is anchored on `side` here.
extension EdgeBarSide {
    /// +1 when x grows away from the anchor, −1 when mirrored.
    var sign: CGFloat {
        self == .left ? 1 : -1
    }

    var edge: Edge.Set {
        self == .left ? .leading : .trailing
    }

    var farEdge: Edge.Set {
        self == .left ? .trailing : .leading
    }

    var horizontal: HorizontalAlignment {
        self == .left ? .leading : .trailing
    }

    var alignment: Alignment {
        self == .left ? .leading : .trailing
    }

    var topAlignment: Alignment {
        self == .left ? .topLeading : .topTrailing
    }

    var bottomAlignment: Alignment {
        self == .left ? .bottomLeading : .bottomTrailing
    }

    var unitPoint: UnitPoint {
        self == .left ? .leading : .trailing
    }
}
