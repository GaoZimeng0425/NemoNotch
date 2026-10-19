import SwiftUI

/// Geometry for the edge bar, in one place (evlat-measured). Every measure
/// along the edge is from the bar's TOP (the head's end of the drawn shape),
/// never the window's: the window is a fixed envelope and the bar hangs in
/// it at `EdgeBarController.barTop`.
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
    static var cardTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .leading))
                .combined(with: .offset(x: -cardTravel))
                .animation(cardIn),
            removal: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .leading))
                .animation(cardOut)
        )
    }
}
