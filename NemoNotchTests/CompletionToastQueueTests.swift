import CoreGraphics
import Foundation
@testable import NemoNotch
import Testing

@Suite("CompletionToastQueue")
struct CompletionToastQueueTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    private func item(_ name: String, tool: String? = nil) -> CompletionItem {
        var item = CompletionItem(name: name, source: .ai(.claude))
        item.tool = tool
        return item
    }

    private func queue() -> CompletionToastQueue {
        CompletionToastQueue(duration: 30, capacity: 3)
    }

    @Test("each completion gets its own card, oldest first")
    func separateCards() {
        var q = queue()
        q.add([item("A")], now: t0)
        q.add([item("B"), item("C")], now: t0)
        #expect(q.toasts.map(\.item.name) == ["A", "B", "C"])
        #expect(Set(q.toasts.map(\.id)).count == 3)
    }

    @Test("same name refreshes its card in place: fields merge, timer restarts")
    func sameNameRefreshes() {
        var q = queue()
        q.add([item("A", tool: "Read")], now: t0)
        let id = q.toasts[0].id
        q.add([item("A", tool: "Edit")], now: t0.addingTimeInterval(20))
        #expect(q.toasts.count == 1)
        #expect(q.toasts[0].id == id)
        #expect(q.toasts[0].item.tool == "Edit")
        #expect(q.toasts[0].deadline == t0.addingTimeInterval(50))
    }

    @Test("beyond capacity the oldest card is evicted")
    func capacityEvictsOldest() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("D")], now: t0)
        #expect(q.toasts.map(\.item.name) == ["B", "C", "D"])
    }

    @Test("cards expire independently at their own deadline")
    func expiresIndependently() {
        var q = queue()
        q.add([item("A")], now: t0)
        q.add([item("B")], now: t0.addingTimeInterval(10))
        #expect(q.nextDeadline == t0.addingTimeInterval(30))
        #expect(q.expire(now: t0.addingTimeInterval(29.9)).isEmpty)
        let gone = q.expire(now: t0.addingTimeInterval(30))
        #expect(gone.map(\.item.name) == ["A"])
        #expect(q.toasts.map(\.item.name) == ["B"])
    }

    @Test("paused: nothing expires and there is no deadline to arm")
    func pauseFreezes() {
        var q = queue()
        q.add([item("A")], now: t0)
        q.pause()
        #expect(q.nextDeadline == nil)
        #expect(q.expire(now: t0.addingTimeInterval(600)).isEmpty)
        #expect(q.toasts.count == 1)
    }

    @Test("resume gives every card a full duration from now")
    func resumeRestartsFull() {
        var q = queue()
        q.add([item("A")], now: t0)
        q.pause()
        q.resume(now: t0.addingTimeInterval(100))
        #expect(q.toasts[0].deadline == t0.addingTimeInterval(130))
        #expect(q.expire(now: t0.addingTimeInterval(129)).isEmpty)
    }

    @Test("resume without a pause leaves deadlines alone")
    func resumeIdempotent() {
        var q = queue()
        q.add([item("A")], now: t0)
        q.resume(now: t0.addingTimeInterval(20))
        #expect(q.toasts[0].deadline == t0.addingTimeInterval(30))
    }

    @Test("dismiss removes only that card")
    func dismissOne() {
        var q = queue()
        q.add([item("A"), item("B")], now: t0)
        q.dismiss(id: q.toasts[0].id)
        #expect(q.toasts.map(\.item.name) == ["B"])
    }
}

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
        #expect(layout.cardRect(at: 0) == CGRect(x: 432, y: 0, width: 280, height: 52))
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
