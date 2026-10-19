@testable import NemoNotch
import SwiftUI
import Testing

/// Topology guards for the hand-drawn shell path: the flares span the full
/// rect width only along the top edge, the body is inset by `topCornerRadius`
/// per side, and the bottom corners round convexly.
struct BezelShapeTests {
    let rect = CGRect(x: 10, y: 0, width: 400, height: 200)

    private func path(top: CGFloat = 19, bottom: CGFloat = 24, in rect: CGRect? = nil) -> Path {
        BezelShape(edge: .top, flare: top, corner: bottom).path(in: rect ?? self.rect)
    }

    @Test func flaresReachTheRectsFullWidth() {
        // The flares only touch the side extremes along the top edge itself,
        // so the bounding box — not interior points near the corners — is the
        // robust assertion here.
        let box = path().boundingRect
        #expect(abs(box.minX - rect.minX) < 0.001)
        #expect(abs(box.maxX - rect.maxX) < 0.001)
        #expect(abs(box.minY - rect.minY) < 0.001)
        #expect(abs(box.maxY - rect.maxY) < 0.001)
    }

    @Test func bodyIsInsetByTopRadius() {
        let p = path()
        #expect(!p.contains(CGPoint(x: rect.minX + 9, y: rect.midY)))
        #expect(p.contains(CGPoint(x: rect.minX + 20, y: rect.midY)))
        #expect(!p.contains(CGPoint(x: rect.maxX - 9, y: rect.midY)))
        #expect(p.contains(CGPoint(x: rect.maxX - 20, y: rect.midY)))
    }

    @Test func bottomCornersRoundOff() {
        let p = path()
        // 2pt diagonally in from the body corner falls outside the 24pt
        // corner curve; a point past the curve's end is filled.
        #expect(!p.contains(CGPoint(x: rect.minX + 19 + 2, y: rect.maxY - 2)))
        #expect(p.contains(CGPoint(x: rect.minX + 19 + 24, y: rect.maxY - 6)))
    }

    @Test func zeroRadiiFallBackToPlainRect() {
        let p = path(top: 0, bottom: 0)
        #expect(abs(p.boundingRect.minX - rect.minX) < 0.001)
        #expect(abs(p.boundingRect.maxX - rect.maxX) < 0.001)
        #expect(p.contains(CGPoint(x: rect.minX + 0.5, y: rect.midY)))
    }

    @Test func degenerateRectProducesEmptyPath() {
        #expect(path(in: CGRect(x: 0, y: 0, width: 0, height: 0)).isEmpty)
    }

    @Test func oversizedRadiiClampInsideTheRect() {
        let p = path(top: 500, bottom: 500)
        #expect(!p.isEmpty)
        #expect(p.boundingRect.minX >= rect.minX)
        #expect(p.boundingRect.maxX <= rect.maxX)
    }

    // MARK: - Leading edge (the left bar): the same path, transposed

    private let tall = CGRect(x: 5, y: 30, width: 200, height: 400)

    private func leading(_ shape: BezelShape = BezelShape(edge: .leading, flare: 19, corner: 24)) -> Path {
        shape.path(in: tall)
    }

    @Test func leadingIsTheTopPathTransposed() {
        // Every point inside the top-edge path at (x, y) is inside the
        // leading path at (y, x) — sampled over a grid.
        let top = BezelShape(edge: .top, flare: 19, corner: 24)
            .path(in: CGRect(x: 0, y: 0, width: tall.height, height: tall.width))
        let left = leading()
        for x in stride(from: 1.0, to: tall.height, by: 7) {
            for y in stride(from: 1.0, to: tall.width, by: 7) {
                let inTop = top.contains(CGPoint(x: x, y: y))
                let inLeft = left.contains(CGPoint(x: tall.minX + y, y: tall.minY + x))
                #expect(inTop == inLeft, "mismatch at (\(x), \(y))")
            }
        }
    }

    @Test func leadingFlaresReachTheEdgeAndBodyIsInset() {
        let p = leading()
        let box = p.boundingRect
        #expect(abs(box.minX - tall.minX) < 0.001)
        #expect(abs(box.minY - tall.minY) < 0.001)
        #expect(abs(box.maxY - tall.maxY) < 0.001)
        // Near the docked edge at the very ends: outside (the flare's gap).
        #expect(!p.contains(CGPoint(x: tall.minX + 15, y: tall.minY + 2)))
        // Mid-body, hugging the edge: inside.
        #expect(p.contains(CGPoint(x: tall.minX + 1, y: tall.midY)))
        // The far side is a plain body edge; its corners round off.
        #expect(p.contains(CGPoint(x: tall.maxX - 1, y: tall.midY)))
        #expect(!p.contains(CGPoint(x: tall.maxX - 2, y: tall.minY + 19 + 2)))
    }

    @Test func outlineLeavesTheEdgeSegmentOut() {
        let open = BezelShape(edge: .leading, flare: 19, corner: 24).outline.path(in: tall)
        // The open outline ends where the closed one would start drawing
        // back along the edge: its last point is on the edge, not its first.
        #expect(open.currentPoint.map { abs($0.x - tall.minX) < 0.001 && abs($0.y - tall.maxY) < 0.001 } == true)
        #expect(!open.description.contains("h"))
    }
}
