import CoreGraphics
import Foundation
@testable import NemoNotch
import Testing

@Suite("EdgeBarPlacement")
struct EdgeBarPlacementTests {
    /// A 1000-wide visible frame starting at x = 100 (AppKit, y up).
    private let visible = CGRect(x: 100, y: 0, width: 1000, height: 800)

    private func capsule(minX: CGFloat) -> CGRect {
        CGRect(x: minX, y: 400, width: 150, height: 54)
    }

    private func drop(_ rect: CGRect, side: EdgeBarSide = .left) -> EdgeBarPlacement {
        EdgeBarPlacement.dropped(capsule: rect, visible: visible, side: side, top: 0.25, screen: "S")
    }

    @Test func releasedNearAnEdgeDocksToIt() {
        let left = drop(capsule(minX: 100 + 20))
        #expect(left == EdgeBarPlacement(mode: .docked, side: .left, screen: "S", top: 0.25))
        // Right end 20pt from the right edge.
        let right = drop(capsule(minX: 1100 - 150 - 20))
        #expect(right == EdgeBarPlacement(mode: .docked, side: .right, screen: "S", top: 0.25))
    }

    @Test func releasedAwayFromTheEdgesFloatsWhereItIs() {
        // 25pt off the left edge: past the snap distance.
        let left = drop(capsule(minX: 100 + 25))
        #expect(left.mode == .floating)
        #expect(left.side == .left)
        #expect(left.anchor == 0.025)
        // Anchored at its right end, the share is of that end.
        let right = drop(capsule(minX: 600), side: .right)
        #expect(right.mode == .floating)
        #expect(right.side == .right)
        #expect(right.anchor == 0.65)
        #expect(right.top == 0.25)
    }

    @Test func floatingSideFollowsTheRoom() {
        /// reach 400, a 150-long capsule, the frame spanning 100…1100.
        func side(_ leftEnd: CGFloat, _ current: EdgeBarSide, in frame: CGRect? = nil) -> EdgeBarSide {
            EdgeBarPlacement.floatingSide(
                leftEnd: leftEnd, length: 150, visible: frame ?? visible, reach: 400, current: current
            )
        }
        #expect(side(700, .left) == .left) // 400 of room to the right
        #expect(side(701, .left) == .right) // 399: anchors right, 751 to the left
        // A side that still fits is kept: the head never swaps ends needlessly.
        #expect(side(600, .right) == .right) // 650 to the left: kept, though the right has 500 too
        // One that doesn't is given up: 350 left of the right end, 800 right.
        #expect(side(300, .right) == .left)
        // Neither side has the room: the roomier one.
        let narrow = CGRect(x: 100, y: 0, width: 500, height: 800)
        #expect(side(250, .left, in: narrow) == .left) // 350 right vs 300 left
        #expect(side(300, .left, in: narrow) == .right) // 300 right vs 350 left
    }

    @Test func refittingKeepsTheCapsuleAndGivesItsPanelRoom() {
        // Anchored left at x = 900: only 200 of room to the right → the
        // right end (1050) becomes the anchor; the capsule doesn't move.
        let placement = EdgeBarPlacement(mode: .floating, side: .left, top: 0.5, anchor: 0.8)
        let fitted = placement.refitted(visible: visible, length: 150, reach: 400)
        #expect(fitted.side == .right)
        #expect(fitted.anchor == 0.95)
        // Neither side has the room (250 right, 400 left of a 450 reach):
        // the roomier side, its anchor pulled in until the panel fits —
        // the right end from 500 out to 550.
        let narrow = CGRect(x: 100, y: 0, width: 500, height: 800)
        let pulled = EdgeBarPlacement(mode: .floating, side: .left, anchor: 0.5)
            .refitted(visible: narrow, length: 150, reach: 450)
        #expect(pulled.side == .right)
        #expect(pulled.anchor == 0.9)
        // Docked placements are left alone.
        #expect(EdgeBarPlacement.standard.refitted(visible: visible, length: 150, reach: 400) == .standard)
    }

    /// Carried hard against the far edge, a capsule of any length gets
    /// within the snap distance and docks there.
    @Test func aCarriedCapsuleReachesEitherEdgeToDock() {
        for slots in 0 ... EdgeBarMetrics.slotCount {
            let length = EdgeBarMetrics.capsuleLength(slots: slots)
            // Anchored left, pushed past the right edge.
            let leftEnd = EdgeBarPlacement.clampedAnchor(5000, side: .left, length: length, visible: visible)
            let right = drop(CGRect(x: leftEnd, y: 400, width: length, height: 54))
            #expect(right.mode == .docked && right.side == .right, "\(slots) slots")
            // Anchored right, pushed past the left edge.
            let rightEnd = EdgeBarPlacement.clampedAnchor(-5000, side: .right, length: length, visible: visible)
            let left = drop(CGRect(x: rightEnd - length, y: 400, width: length, height: 54), side: .right)
            #expect(left.mode == .docked && left.side == .left, "\(slots) slots")
        }
    }

    @Test func persistsAndMigratesTheLeftOnlyTop() throws {
        let suite = "EdgeBarPlacementTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Nothing saved: the docked-left default.
        #expect(EdgeBarPlacement.load(from: defaults) == .standard)
        // The old bar's top fraction carries over.
        defaults.set(0.4, forKey: EdgeBarPlacement.legacyTopKey)
        #expect(EdgeBarPlacement.load(from: defaults) == EdgeBarPlacement(mode: .docked, side: .left, top: 0.4))
        // A saved placement wins, round-tripped whole.
        let floating = EdgeBarPlacement(mode: .floating, side: .right, screen: "S", top: 0.3, anchor: 0.8)
        floating.save(to: defaults)
        #expect(EdgeBarPlacement.load(from: defaults) == floating)
        // A save missing the optional fields (or carrying unknown ones) still
        // decodes — never "forget where the user put the bar".
        defaults.set(Data(#"{"mode":"floating","side":"left","future":1}"#.utf8), forKey: EdgeBarPlacement.defaultsKey)
        #expect(EdgeBarPlacement.load(from: defaults) == EdgeBarPlacement(mode: .floating, side: .left))
    }
}

@Suite("EdgeBarMetrics capsule")
struct EdgeBarCapsuleMetricsTests {
    private typealias Geo = EdgeBarMetrics

    @Test func capsuleIsTheClosedBarOnItsSide() {
        #expect(Geo.capsuleHeight == Geo.barWidth)
        // Its head sits where an open panel's head does.
        #expect(Geo.capsuleTop + (Geo.barWidth - Geo.headSize) / 2 == Geo.headTop)
    }

    @Test func capsuleLengthHugsTheHeadAndRings() {
        // No ring: the head alone, as round as the bar is wide.
        #expect(Geo.capsuleLength(slots: 0) == 54.0)
        // Margin 10 + head 34 + gap 18 + 4 rings of 20 + 3 gaps of 10 + 17.
        #expect(Geo.capsuleLength(slots: 4) == 189.0)
    }

    /// The closed capsule must lie inside the panel it opens wherever it
    /// may rest — else a cursor on the part outside folds the panel at once,
    /// and the next move opens it again.
    @Test func aRestingCapsuleLiesInsideThePanelItOpens() {
        for canvas: CGFloat in [600, 948] {
            let range = Geo.capsuleRestRange(canvasHeight: canvas)
            let lengths = [
                Geo.closedLength(slots: 0),
                Geo.openLength(rows: 2),
                canvas - 2 * (Geo.gutter - Geo.flare), // the longest that fits
            ]
            for rest in stride(from: range.lowerBound, through: range.upperBound, by: 7) {
                for length in lengths {
                    let top = Geo.floatingOpenTop(rest: rest, length: length, canvasHeight: canvas)
                    let panel = Geo.panelSpan(top: top, length: length)
                    let capsule = Geo.capsuleSpan(rest: rest)
                    #expect(
                        panel.contains(capsule.lowerBound) && panel.contains(capsule.upperBound),
                        "rest \(rest), length \(length), canvas \(canvas)"
                    )
                    // And the panel stays a gutter inside the canvas.
                    #expect(panel.lowerBound >= Geo.gutter && panel.upperBound <= canvas - Geo.gutter)
                }
            }
        }
        // Flush to the top (the old clamp let it rest at −capsuleTop) it would not.
        let flush = Geo.capsuleSpan(rest: -Geo.capsuleTop)
        let opened = Geo.panelSpan(
            top: Geo.floatingOpenTop(rest: -Geo.capsuleTop, length: 200, canvasHeight: 948),
            length: 200
        )
        #expect(!opened.contains(flush.lowerBound))
    }

    @Test func anOpenedCapsuleAlwaysFitsItsEnvelope() {
        // The widest panel and the card fit beside the anchored end.
        #expect(Geo.capsuleLength(slots: Geo.slotCount) <= Geo.maxOpenWidth)
        #expect(Geo.floatingCanvasWidth == Geo.gutter + Geo.reach)
    }
}
