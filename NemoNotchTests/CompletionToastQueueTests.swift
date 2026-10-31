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
        CompletionToastQueue(duration: 30, capacity: 3, waitingLimit: 2)
    }

    @Test("each completion gets its own card, oldest first")
    func separateCards() {
        var q = queue()
        q.add([item("A")], now: t0)
        q.add([item("B"), item("C")], now: t0)
        #expect(q.toasts.map(\.item.name) == ["A", "B", "C"])
        #expect(Set(q.toasts.map(\.id)).count == 3)
    }

    @Test("without a session key, same name refreshes its card in place: fields merge, timer restarts")
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

    @Test("two sessions in the same project get two cards, not one merged card")
    func sameNameDifferentSessions() {
        var q = queue()
        var claude = item("NemoNotch")
        claude.key = "ai:claude-1"
        var zcode = CompletionItem(name: "NemoNotch", source: .ai(.zcode))
        zcode.key = "ai:sess_zcode-1"
        var claude2 = item("NemoNotch")
        claude2.key = "ai:claude-2"
        q.add([claude], now: t0)
        q.add([zcode, claude2], now: t0)
        #expect(q.toasts.map(\.item.key) == ["ai:claude-1", "ai:sess_zcode-1", "ai:claude-2"])
        #expect(q.toasts.map(\.item.source) == [.ai(.claude), .ai(.zcode), .ai(.claude)])
    }

    @Test("the same session finishing again refreshes its own card")
    func sameSessionRefreshes() {
        var q = queue()
        var first = item("NemoNotch", tool: "Read")
        first.key = "ai:s1"
        var again = item("NemoNotch", tool: "Edit")
        again.key = "ai:s1"
        q.add([first], now: t0)
        let id = q.toasts[0].id
        q.add([again], now: t0.addingTimeInterval(10))
        #expect(q.toasts.count == 1)
        #expect(q.toasts[0].id == id)
        #expect(q.toasts[0].item.tool == "Edit")
    }

    @Test("the same session renamed between turns refreshes its card with the new name")
    func sameSessionRenamed() {
        var q = queue()
        var first = item("old-folder", tool: "Read")
        first.key = "ai:s1"
        var renamed = item("new-folder")
        renamed.key = "ai:s1"
        q.add([first], now: t0)
        q.add([renamed], now: t0.addingTimeInterval(5))
        #expect(q.toasts.map(\.item.name) == ["new-folder"])
        #expect(q.toasts.first?.item.tool == "Read") // nil newer field keeps the older value
    }

    @Test("beyond capacity the oldest card waits off-row instead of disappearing")
    func capacityParksOldest() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("D")], now: t0)
        #expect(q.toasts.map(\.item.name) == ["B", "C", "D"])
        #expect(q.waiting.map(\.item.name) == ["A"])
    }

    @Test("closing a card brings back the newest waiting card, with a fresh timer")
    func dismissRevealsWaiting() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("D")], now: t0.addingTimeInterval(1))
        q.add([item("E")], now: t0.addingTimeInterval(2))
        // A and B wait; B arrived later, so B comes back first.
        q.dismiss(id: q.toasts[2].id, now: t0.addingTimeInterval(100))
        #expect(q.toasts.map(\.item.name) == ["B", "C", "D"])
        #expect(q.toasts[0].deadline == t0.addingTimeInterval(130))
        #expect(q.waiting.map(\.item.name) == ["A"])
    }

    @Test("an expired card is replaced by a waiting one")
    func expiryRevealsWaiting() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("D")], now: t0.addingTimeInterval(10))
        q.expire(now: t0.addingTimeInterval(30))
        // B and C expired at 30; A (waiting) comes back next to D.
        #expect(q.toasts.map(\.item.name) == ["A", "D"])
        #expect(q.waiting.isEmpty)
    }

    @Test("the waiting pile keeps only the newest cards beyond its limit")
    func waitingLimitDropsOldest() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("D")], now: t0.addingTimeInterval(1))
        q.add([item("E")], now: t0.addingTimeInterval(2))
        q.add([item("F")], now: t0.addingTimeInterval(3))
        #expect(q.waiting.map(\.item.name) == ["B", "C"])
    }

    @Test("a waiting card that arrives again returns to the row as the newest")
    func waitingCardRearrives() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("D")], now: t0.addingTimeInterval(1))
        let aID = q.waiting[0].id
        q.add([item("A", tool: "Edit")], now: t0.addingTimeInterval(2))
        #expect(q.toasts.map(\.item.name) == ["C", "D", "A"])
        #expect(q.toasts[2].id == aID)
        #expect(q.toasts[2].item.tool == "Edit")
        #expect(q.waiting.map(\.item.name) == ["B"])
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
        q.dismiss(id: q.toasts[0].id, now: t0)
        #expect(q.toasts.map(\.item.name) == ["B"])
    }

    // MARK: - Notification cards

    private func notice(_ app: String, count: Int) -> CompletionItem {
        var item = CompletionItem(name: app, source: .notification(bundleID: app))
        item.key = "notify:\(app)"
        item.notice = NotificationCard(count: count, line1: nil, line2: "x")
        return item
    }

    @Test("replace swaps a card's content without restarting its timer")
    func replaceKeepsDeadline() {
        var q = queue()
        q.add([notice("slack", count: 2)], now: t0)
        let id = q.toasts[0].id
        let replaced = q.replace(key: "notify:slack", with: notice("slack", count: 1), now: t0)
        #expect(replaced)
        #expect(q.toasts[0].id == id)
        #expect(q.toasts[0].item.notice?.count == 1)
        #expect(q.toasts[0].deadline == t0.addingTimeInterval(30))
    }

    @Test("replace with nil removes the card; an unknown key changes nothing")
    func replaceNilRemoves() {
        var q = queue()
        q.add([item("A"), notice("slack", count: 1)], now: t0)
        let missing = q.replace(key: "notify:mail", with: nil, now: t0)
        #expect(missing == false)
        #expect(q.toasts.count == 2)
        let removed = q.replace(key: "notify:slack", with: nil, now: t0)
        #expect(removed)
        #expect(q.toasts.map(\.item.name) == ["A"])
    }

    @Test("notification cards share the row's capacity with completion cards")
    func notificationCardsShareCapacity() {
        var q = queue()
        q.add([item("A")], now: t0)
        q.add([item("B")], now: t0.addingTimeInterval(1))
        q.add([item("C")], now: t0.addingTimeInterval(2))
        q.add([notice("slack", count: 1)], now: t0.addingTimeInterval(3))
        #expect(q.toasts.map(\.item.name) == ["B", "C", "slack"])
    }

    @Test("replace also reaches a waiting card, and nil drops it from the pile")
    func replaceReachesWaiting() {
        var q = queue()
        q.add([notice("slack", count: 1)], now: t0)
        q.add([item("A"), item("B"), item("C")], now: t0.addingTimeInterval(1))
        let updated = q.replace(key: "notify:slack", with: notice("slack", count: 2), now: t0)
        #expect(updated)
        #expect(q.waiting.first?.item.notice?.count == 2)
        let dropped = q.replace(key: "notify:slack", with: nil, now: t0)
        #expect(dropped)
        #expect(q.waiting.isEmpty)
    }
}
