import Foundation
@testable import NemoNotch
import Testing

@Suite("EdgeBarMetrics")
struct EdgeBarMetricsTests {
    private typealias Geo = EdgeBarMetrics

    @Test func closedLengthHugsTheHeadAndSlots() {
        // flare 20 + margin 14, head 34, margin 14 + flare 20.
        #expect(Geo.closedLength(slots: 0) == 102.0)
        // + top gap 18 + 4 rings of 20 + 3 gaps of 10.
        #expect(Geo.closedLength(slots: 4) == 230.0)
    }

    @Test func openLengthHoldsListAndSummary() {
        // listTop = 34 + 34 + 18 − 5 = 81; two rows = 60; summary gap 8 +
        // height 12; closing margin 34.
        #expect(Geo.openLength(rows: 2) == 195.0)
        // Capped at 7.5 visible rows.
        #expect(Geo.openLength(rows: 20) == Geo.openLength(rows: 7) + 15)
        #expect(Geo.openLength(rows: 0) == Geo.closedLength(slots: 0))
    }

    @Test func slotIsTheRowUnderTheCursor() {
        let first = Geo.slotTop(0) + 5
        #expect(Geo.slot(x: 30, y: first, width: 200, rows: 3) == 0)
        #expect(Geo.slot(x: 30, y: first + Geo.rowPitch, width: 200, rows: 3) == 1)
        // Past the last row, over the head, past the body's width: none.
        #expect(Geo.slot(x: 30, y: Geo.slotTop(3) + 5, width: 200, rows: 3) == nil)
        #expect(Geo.slot(x: 30, y: Geo.headTop + 5, width: 200, rows: 3) == nil)
        #expect(Geo.slot(x: 210, y: first, width: 200, rows: 3) == nil)
    }

    @Test func slotFollowsTheScroll() {
        let y = Geo.slotTop(0) + 5
        #expect(Geo.slot(x: 30, y: y, width: 200, rows: 20, offset: Geo.rowPitch * 2) == 2)
    }

    @Test func halfVisibleRowIsNotPickable() {
        // 7.5 rows visible: the 8th row (index 7) is cut in half.
        let y = Geo.slotTop(7) + 2
        #expect(Geo.slot(x: 30, y: y, width: 200, rows: 20) == nil)
        #expect(Geo.maxScrollOffset(rows: 20) == 20 * Geo.rowPitch - 7.5 * Geo.rowPitch)
        #expect(Geo.maxScrollOffset(rows: 3) == 0)
    }

    @Test func headHitIsTheIconSquare() {
        #expect(Geo.isOverHead(x: 27, y: Geo.headTop + 17))
        #expect(!Geo.isOverHead(x: 27, y: Geo.headTop - 2))
        #expect(!Geo.isOverHead(x: 2, y: Geo.headTop + 17))
    }

    @Test func cardSitsLevelWithItsRowAndStaysOnCanvas() {
        // Row 1, plenty of room: level with the row less the lead.
        let level = Geo.cardTop(slot: 1, offset: 0, height: 200, barTop: 300, canvasHeight: 1000)
        #expect(level == 300 + Geo.slotTop(1) - Geo.cardLead)
        // Low rows are held at the last closed slot's level.
        let low = Geo.cardTop(slot: 7, offset: 0, height: 200, barTop: 300, canvasHeight: 1000)
        #expect(low == 300 + Geo.slotTop(Geo.slotCount - 1))
        // A tall card near the bottom rises to stay whole.
        let tall = Geo.cardTop(slot: 1, offset: 0, height: 500, barTop: 400, canvasHeight: 800)
        #expect(tall == 800 - 500 - Geo.gutter)
    }

    @Test func namesColumnSpansTheOpenBodyForRightSideLeftAlignment() {
        // lead = bar 54 − ringLead 17 + gap 8 = 45; inset 14.
        #expect(Geo.openWidth(namesWidth: 150) == 209.0)
        #expect(Geo.namesColumnWidth(openWidth: 209) == 150.0)
        // Short names: the body is held at minOpenWidth 110, and the column
        // widens with it (110 − 45 − 14) so it still starts at the far inset.
        #expect(Geo.namesColumnWidth(openWidth: Geo.openWidth(namesWidth: 20)) == 51.0)
        #expect(Geo.namesColumnWidth(openWidth: 0) == 0.0)
    }
}
