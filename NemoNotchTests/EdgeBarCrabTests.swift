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

@Suite("Source logo shapes")
struct SourceLogoShapeTests {
    private let rect = CGRect(x: 10, y: 20, width: 100, height: 100)

    @Test func opencodeFrameIsHollowAndTheBlockFillsItsLowerHalf() {
        // 512 viewBox → fit by height: x' = (x − 128)·0.3125 + 10 + 10, y' = (y − 96)·0.3125 + 20.
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - 128) * 0.3125 + 30, y: (y - 96) * 0.3125 + 20)
        }
        let frame = OpencodeLogoShape(part: .frame).path(in: rect)
        #expect(frame.contains(at(140, 400), eoFill: true)) // the frame's bottom bar
        #expect(!frame.contains(at(256, 200), eoFill: true)) // the hole
        let block = OpencodeLogoShape(part: .block).path(in: rect)
        #expect(block.contains(at(256, 300)))
        #expect(!block.contains(at(256, 190)))
    }

    @Test func zcodeZHasItsBarsAndAnOpenMiddle() {
        // 30 viewBox, uniform: x' = x·(100/30) + 10, y' = y·(100/30) + 20.
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * 100 / 30 + 10, y: y * 100 / 30 + 20)
        }
        let z = ZcodeLogoShape().path(in: rect)
        #expect(z.contains(at(8, 8))) // top bar
        #expect(z.contains(at(22, 22))) // bottom bar
        #expect(z.contains(at(15, 15))) // diagonal
        // Open beside the diagonal (its left edge at y 18 is x ≈ 9.2, its
        // right edge at y 12 is x ≈ 20.8).
        #expect(!z.contains(at(6, 18)))
        #expect(!z.contains(at(24, 12)))
    }
}
