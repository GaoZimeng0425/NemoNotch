import CoreGraphics
@testable import NemoNotch
import Testing

@Suite("CompletionToastLayout")
struct CompletionToastLayoutTests {
    private let width = CompletionToastLayout.panelWidth(capacity: 4) // 4*280 + 3*8 = 1144

    @Test("panel width fits capacity cards plus gaps")
    func panelWidth() {
        #expect(width == 1144)
    }

    @Test("a single card is centered")
    func singleCentered() {
        let layout = CompletionToastLayout(panelWidth: width, count: 1)
        #expect(layout.cardRect(at: 0) == CGRect(x: 432, y: 0, width: 280, height: 66))
    }

    @Test("two cards sit side by side, centered as a group")
    func twoSideBySide() {
        let layout = CompletionToastLayout(panelWidth: width, count: 2)
        #expect(layout.cardRect(at: 0).minX == 288)
        #expect(layout.cardRect(at: 1).minX == 576)
    }

    @Test("close square is in the card's top-trailing corner and wins over the card")
    func closeHit() {
        let layout = CompletionToastLayout(panelWidth: width, count: 2)
        // Card 1 spans x 576...856; close = x 830...852, y 4...26.
        #expect(layout.closeRect(at: 1) == CGRect(x: 830, y: 4, width: 22, height: 22))
        #expect(layout.hit(CGPoint(x: 840, y: 10)) == .close(1))
        #expect(layout.hit(CGPoint(x: 600, y: 30)) == .card(1))
        #expect(layout.hit(CGPoint(x: 300, y: 10)) == .card(0))
    }

    @Test("gaps and space beside the row hit nothing")
    func missesPassThrough() {
        let layout = CompletionToastLayout(panelWidth: width, count: 2)
        #expect(layout.hit(CGPoint(x: 572, y: 20)) == nil) // gap between cards
        #expect(layout.hit(CGPoint(x: 100, y: 20)) == nil) // beside the row
        #expect(layout.hit(CGPoint(x: 300, y: 60)) == nil) // below the cards
    }
}
