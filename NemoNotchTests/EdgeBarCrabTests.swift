import CoreGraphics
@testable import NemoNotch
import SwiftUI
import Testing

@Suite("EdgeBarCrab")
struct EdgeBarCrabTests {
    /// Drawn at twice the 66 × 52 grid, offset, to exercise the transform.
    private let rect = CGRect(x: 10, y: 20, width: 132, height: 104)

    private func filled(_ x: CGFloat, _ y: CGFloat) -> Bool {
        EdgeBarCrab().path(in: rect).contains(CGPoint(x: rect.minX + x * 2, y: rect.minY + y * 2), eoFill: true)
    }

    @Test func legsReachTheBottomEdge() {
        // Inside each of the four legs, just above the bottom.
        for x: CGFloat in [9, 21, 45, 57] {
            #expect(filled(x, 51), "leg at x \(x)")
        }
        // Between the legs: open.
        #expect(!filled(15, 45))
        #expect(!filled(33, 45))
    }

    @Test func eyesAreHolesInTheBody() {
        #expect(filled(33, 30)) // body
        #expect(!filled(15, 16)) // left eye
        #expect(!filled(51, 16)) // right eye
        #expect(filled(3, 20)) // an arm
    }
}
