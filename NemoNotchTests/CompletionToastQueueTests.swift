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

    // MARK: - Sticky(attention 卡挂到撤回,不计时)

    @Test("sticky card never expires while its neighbor does")
    func stickyNeverExpires() {
        var q = queue()
        var ask = item("A")
        ask.key = "ask:s1"
        ask.sticky = true
        var done = item("B")
        done.key = "ai:s2"
        q.add([ask, done], now: t0)
        // 只有非 sticky 的 B 有到期点
        #expect(q.nextDeadline == t0.addingTimeInterval(30))
        let expired = q.expire(now: t0.addingTimeInterval(31))
        #expect(expired.map(\.item.name) == ["B"])
        #expect(q.toasts.map(\.item.name) == ["A"])
        #expect(q.nextDeadline == nil)
    }

    @Test("a re-pushed sticky key stays sticky")
    func stickySurvivesRepush() {
        var q = queue()
        var ask = item("A")
        ask.key = "ask:s1"
        ask.sticky = true
        q.add([ask], now: t0)
        q.add([ask], now: t0.addingTimeInterval(5))
        #expect(q.toasts.count == 1)
        #expect(q.toasts[0].item.sticky)
    }

    // MARK: - 跨键顶换(apiError 迟到红卡)

    private func keyed(_ name: String, _ key: String) -> CompletionItem {
        var i = item(name)
        i.key = key
        return i
    }

    @Test("demote removes only the same session's other cards")
    func demoteSameSessionOnly() {
        var q = queue()
        q.add([keyed("green", "ai:s1"), keyed("other", "ai:s2"), item("cal")], now: t0)
        let removed = q.demote(sessionKey: "s1", keeping: "fail:s1", now: t0.addingTimeInterval(1))
        #expect(removed.map(\.item.key) == ["ai:s1"])
        #expect(q.toasts.map(\.item.name).sorted() == ["cal", "other"])
        #expect(q.demote(sessionKey: "nope", keeping: "k", now: t0).isEmpty)
    }

    @Test("demote reaches into the waiting pile")
    func demoteWaitingPile() {
        var q = queue()
        q.add([keyed("green", "ai:s1")], now: t0)
        q.add([keyed("x", "ai:x"), keyed("y", "ai:y"), keyed("z", "ai:z")], now: t0.addingTimeInterval(1))
        // capacity 3:最早到的 ai:s1 被挤进等待堆
        #expect(q.toasts.count == 3)
        #expect(q.waiting.map(\.item.key) == ["ai:s1"])
        let removed = q.demote(sessionKey: "s1", keeping: "fail:s1", now: t0.addingTimeInterval(2))
        #expect(removed.map(\.item.key) == ["ai:s1"])
        #expect(q.waiting.isEmpty)
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

    @Test("removing a shown card through replace brings a waiting card back with a fresh timer")
    func replaceNilRevealsWaiting() {
        var q = queue()
        q.add([item("A")], now: t0)
        q.add([notice("slack", count: 1), item("B")], now: t0.addingTimeInterval(1))
        q.add([item("C")], now: t0.addingTimeInterval(2))
        // A waits; slack is shown.
        let removed = q.replace(key: "notify:slack", with: nil, now: t0.addingTimeInterval(300))
        #expect(removed)
        #expect(q.toasts.map(\.item.name) == ["A", "B", "C"])
        #expect(q.toasts[0].deadline == t0.addingTimeInterval(330))
        #expect(q.waiting.isEmpty)
    }

    // MARK: - Shown-at (the card's "N minutes ago")

    @Test("a card is stamped when it arrives and re-stamped when the same unit arrives again")
    func arrivalStampsShownAt() {
        var q = queue()
        q.add([item("A")], now: t0)
        #expect(q.toasts[0].shownAt == t0)
        q.add([item("A")], now: t0.addingTimeInterval(20))
        #expect(q.toasts[0].shownAt == t0.addingTimeInterval(20))
    }

    @Test("a card returning from the waiting pile keeps its original time; resume does not touch it")
    func refillAndResumeKeepShownAt() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("D")], now: t0.addingTimeInterval(1))
        q.dismiss(id: q.toasts[2].id, now: t0.addingTimeInterval(100))
        #expect(q.toasts[0].item.name == "A")
        #expect(q.toasts[0].shownAt == t0)
        q.pause()
        q.resume(now: t0.addingTimeInterval(200))
        #expect(q.toasts[0].shownAt == t0)
    }

    @Test("a waiting card that arrives again is re-stamped with the new arrival")
    func waitingRearrivalStampsShownAt() {
        var q = queue()
        q.add([item("A"), item("B"), item("C")], now: t0)
        q.add([item("D")], now: t0.addingTimeInterval(1))
        q.add([item("A")], now: t0.addingTimeInterval(50))
        #expect(q.toasts.last?.item.name == "A")
        #expect(q.toasts.last?.shownAt == t0.addingTimeInterval(50))
    }

    // MARK: - Fixed deadline (external expiresAt)

    private func fixed(_ name: String, at seconds: TimeInterval) -> CompletionItem {
        var card = item(name)
        card.fixedDeadline = t0.addingTimeInterval(seconds)
        return card
    }

    @Test("a fixed deadline is the card's deadline and expires it exactly then")
    func fixedDeadlineUsedOnAdd() {
        var q = queue()
        q.add([fixed("F", at: 60)], now: t0)
        #expect(q.toasts[0].deadline == t0.addingTimeInterval(60))
        #expect(q.expire(now: t0.addingTimeInterval(59)).isEmpty)
        #expect(q.expire(now: t0.addingTimeInterval(61)).map(\.item.name) == ["F"])
    }

    @Test("leaving the hovered row restarts default cards only; fixed ones keep their deadline")
    func resumeKeepsFixedDeadline() {
        var q = queue()
        q.add([fixed("F", at: 60), item("D")], now: t0)
        q.pause()
        q.resume(now: t0.addingTimeInterval(30))
        #expect(q.toasts.first { $0.item.name == "F" }?.deadline == t0.addingTimeInterval(60))
        #expect(q.toasts.first { $0.item.name == "D" }?.deadline == t0.addingTimeInterval(60))
        q.pause()
        q.resume(now: t0.addingTimeInterval(45))
        #expect(q.toasts.first { $0.item.name == "F" }?.deadline == t0.addingTimeInterval(60))
        #expect(q.toasts.first { $0.item.name == "D" }?.deadline == t0.addingTimeInterval(75))
    }

    @Test("a fixed card coming back from the waiting pile keeps its deadline")
    func refillKeepsFixedDeadline() {
        var q = CompletionToastQueue(duration: 30, capacity: 1, waitingLimit: 2)
        q.add([fixed("F", at: 60)], now: t0)
        q.add([item("D")], now: t0.addingTimeInterval(1))
        #expect(q.toasts.map(\.item.name) == ["D"])
        q.dismiss(id: q.toasts[0].id, now: t0.addingTimeInterval(10))
        #expect(q.toasts.map(\.item.name) == ["F"])
        #expect(q.toasts[0].deadline == t0.addingTimeInterval(60))
    }

    @Test("same key refreshed from sticky to default becomes expirable again")
    func refreshReplacesStickiness() {
        var q = queue()
        var waiting = item("A")
        waiting.sticky = true
        q.add([waiting], now: t0)
        #expect(q.expire(now: t0.addingTimeInterval(1000)).isEmpty)
        q.add([item("A")], now: t0.addingTimeInterval(1000))
        #expect(q.toasts[0].item.sticky == false)
        #expect(q.expire(now: t0.addingTimeInterval(1031)).map(\.item.name) == ["A"])
    }
}
