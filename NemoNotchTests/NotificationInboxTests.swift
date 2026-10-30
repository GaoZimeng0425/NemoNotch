import Foundation
@testable import NemoNotch
import Testing

struct NotificationInboxTests {
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let mail = "com.apple.mail"
    private static let wechat = "com.tencent.xinwechat"

    private func rec(
        _ n: UInt8,
        app: String = slack,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = "m",
        t: Double = 0
    ) -> NotificationRecord {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = n
        let id = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        return NotificationRecord(
            id: id, bundleID: app, title: title, subtitle: subtitle, body: body,
            date: Date(timeIntervalSinceReferenceDate: t)
        )
    }

    // MARK: - Inbox

    @Test func baselineSeedsOnFirstSuccessfulRead() {
        var inbox = NotificationInbox()
        #expect(inbox.isSeeded == false)
        let r1 = rec(1), r2 = rec(2, app: Self.mail)
        #expect(inbox.ingest([r1, r2], watched: [Self.slack, Self.mail]).isEmpty)
        #expect(inbox.isSeeded)
        #expect(inbox.appsWithPending.isEmpty)
        let r3 = rec(3)
        #expect(inbox.ingest([r1, r2, r3], watched: [Self.slack, Self.mail]) == [Self.slack])
        #expect(inbox.pending(for: Self.slack) == [r3])
    }

    @Test func watchedMatchIsCaseInsensitive() {
        var inbox = NotificationInbox()
        _ = inbox.ingest([], watched: [Self.wechat])
        let w = rec(1, app: "com.tencent.xinWeChat")
        #expect(inbox.ingest([w], watched: [Self.wechat]) == [Self.wechat])
        #expect(inbox.pending(for: Self.wechat) == [w])
    }

    @Test func baselineCoversUnwatchedApps() {
        var inbox = NotificationInbox()
        let m1 = rec(1, app: Self.mail)
        _ = inbox.ingest([m1], watched: [Self.slack])
        #expect(inbox.ingest([m1], watched: [Self.slack, Self.mail]).isEmpty)
        #expect(inbox.pending(for: Self.mail).isEmpty)
    }

    @Test func unwatchedArrivalNeverSurfaces() {
        var inbox = NotificationInbox()
        _ = inbox.ingest([], watched: [Self.slack])
        let m2 = rec(2, app: Self.mail)
        #expect(inbox.ingest([m2], watched: [Self.slack]).isEmpty)
        #expect(inbox.ingest([m2], watched: [Self.slack, Self.mail]).isEmpty)
        #expect(inbox.appsWithPending.isEmpty)
    }

    @Test func markHandledHidesForever() {
        var inbox = NotificationInbox()
        _ = inbox.ingest([], watched: [Self.slack])
        let s1 = rec(1)
        _ = inbox.ingest([s1], watched: [Self.slack])
        inbox.markHandled(app: Self.slack)
        #expect(inbox.pending(for: Self.slack).isEmpty)
        #expect(inbox.ingest([s1], watched: [Self.slack]).isEmpty)
        let s2 = rec(2)
        #expect(inbox.ingest([s1, s2], watched: [Self.slack]) == [Self.slack])
        #expect(inbox.pending(for: Self.slack) == [s2])
    }

    @Test func removalShrinksWithoutArrival() {
        var inbox = NotificationInbox()
        _ = inbox.ingest([], watched: [Self.slack])
        let s1 = rec(1, t: 1), s2 = rec(2, t: 2)
        _ = inbox.ingest([s1, s2], watched: [Self.slack])
        #expect(inbox.ingest([s2], watched: [Self.slack]).isEmpty)
        #expect(inbox.pending(for: Self.slack) == [s2])
        _ = inbox.ingest([], watched: [Self.slack])
        #expect(inbox.appsWithPending.isEmpty)
    }

    @Test func resetReseeds() {
        var inbox = NotificationInbox()
        _ = inbox.ingest([], watched: [Self.slack])
        inbox.reset()
        #expect(inbox.isSeeded == false)
        #expect(inbox.ingest([rec(1)], watched: [Self.slack]).isEmpty)
        #expect(inbox.appsWithPending.isEmpty)
    }

    // MARK: - Card text

    @Test func cardSingle() {
        let card = NotificationCard.make(
            appName: "Slack",
            pending: [rec(1, title: "王小明", subtitle: "#design", body: "hi")],
            latestPrefix: "最新:"
        )
        #expect(card == NotificationCard(count: 1, line1: "王小明 · #design", line2: "hi"))
    }

    @Test func cardMultipleDedupesSendersNewestFirst() {
        let card = NotificationCard.make(
            appName: "Slack",
            pending: [
                rec(1, title: "李华", body: "a", t: 1),
                rec(3, title: "李华", body: "c", t: 3),
                rec(2, title: "王小明", body: "b", t: 2),
            ],
            latestPrefix: "最新:"
        )
        #expect(card == NotificationCard(count: 3, line1: "李华、王小明", line2: "最新:李华 — c"))
    }

    @Test func missingTitleFallsBackToAppName() {
        let multi = NotificationCard.make(
            appName: "微信",
            pending: [
                rec(1, app: Self.wechat, body: "你收到了一条消息", t: 1),
                rec(2, app: Self.wechat, body: "你收到了一条消息", t: 2),
            ],
            latestPrefix: "最新:"
        )
        #expect(multi == NotificationCard(count: 2, line1: "微信", line2: "最新:微信 — 你收到了一条消息"))
        let single = NotificationCard.make(
            appName: "微信",
            pending: [rec(1, app: Self.wechat, body: "你收到了一条消息")],
            latestPrefix: "最新:"
        )
        #expect(single == NotificationCard(count: 1, line1: nil, line2: "你收到了一条消息"))
    }

    @Test func cardEmptyIsNil() {
        #expect(NotificationCard.make(appName: "Slack", pending: [], latestPrefix: "最新:") == nil)
    }
}
