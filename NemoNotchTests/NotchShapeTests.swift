import SwiftUI
import Testing
@testable import NemoNotch

/// Topology guards for the hand-drawn shell path: the flares span the full
/// rect width only along the top edge, the body is inset by `topCornerRadius`
/// per side, and the bottom corners round convexly.
struct NotchShapeTests {
    let rect = CGRect(x: 10, y: 0, width: 400, height: 200)

    private func path(top: CGFloat = 19, bottom: CGFloat = 24, in rect: CGRect? = nil) -> Path {
        NotchShape(topCornerRadius: top, bottomCornerRadius: bottom).path(in: rect ?? self.rect)
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
}
