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
        // 600 of room to the right of x = 500 in a frame ending at 1100.
        #expect(EdgeBarPlacement.floatingSide(leftEnd: 500, visible: visible, reach: 600, current: .left) == .left)
        #expect(EdgeBarPlacement.floatingSide(leftEnd: 501, visible: visible, reach: 600, current: .left) == .right)
        // Back to the left only past the hysteresis.
        #expect(EdgeBarPlacement.floatingSide(leftEnd: 490, visible: visible, reach: 600, current: .right) == .right)
        #expect(EdgeBarPlacement.floatingSide(leftEnd: 476, visible: visible, reach: 600, current: .right) == .left)
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

    @Test func anOpenedCapsuleAlwaysFitsItsEnvelope() {
        // The widest panel and the card fit beside the anchored end.
        #expect(Geo.capsuleLength(slots: Geo.slotCount) <= Geo.maxOpenWidth)
        #expect(Geo.floatingCanvasWidth == Geo.gutter + Geo.reach)
    }
}
