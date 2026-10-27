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

    @Test("a just-refreshed card is not the one evicted, even at the head of the row")
    func refreshedCardSurvivesEviction() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("A")], now: t0.addingTimeInterval(5))
        q.add([item("D")], now: t0.addingTimeInterval(6))
        #expect(q.toasts.map(\.item.name) == ["A", "C", "D"])
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
