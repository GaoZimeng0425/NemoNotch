import Foundation
@testable import NemoNotch
import Testing

@Suite("EdgeBarUsageCard")
struct EdgeBarUsageCardTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func window(_ kind: QuotaWindow, used: Double, resetsIn: TimeInterval?) -> EdgeBarUsageDetail.Window {
        .init(id: "w", window: kind, percent: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    // MARK: Pace

    @Test func lastsTheWindowAtItsPace() {
        // 5h window, 3h left (2h elapsed), 20% used → 50% by the reset.
        let pace = EdgeBarUsagePace.of(window(.fiveHour, used: 20, resetsIn: 3 * 3600), now: now)
        #expect(pace == .endsAt(50))
    }

    @Test func runsOutBeforeTheReset() {
        // 5h window, 3h left (2h elapsed), 80% used → 40%/h, 20% left → 30 min.
        let pace = EdgeBarUsagePace.of(window(.fiveHour, used: 80, resetsIn: 3 * 3600), now: now)
        #expect(pace == .runsOutIn(30 * 60))
    }

    @Test func tooEarlyToTell() {
        // 7d window, 10 min in: one burst must not project a run-out.
        let pace = EdgeBarUsagePace.of(window(.sevenDay, used: 9, resetsIn: 7 * 86400 - 600), now: now)
        #expect(pace == .early)
    }

    @Test func usedUp() {
        #expect(EdgeBarUsagePace.of(window(.fiveHour, used: 100, resetsIn: 3600), now: now) == .exhausted)
    }

    @Test func noPaceWithoutALengthOrAReset() {
        #expect(EdgeBarUsagePace.of(window(.gemini(label: "Pro"), used: 50, resetsIn: 3600), now: now) == nil)
        #expect(EdgeBarUsagePace.of(window(.fiveHour, used: 50, resetsIn: nil), now: now) == nil)
        // A reset already past, or further off than the window is long.
        #expect(EdgeBarUsagePace.of(window(.fiveHour, used: 50, resetsIn: -60), now: now) == nil)
        #expect(EdgeBarUsagePace.of(window(.fiveHour, used: 50, resetsIn: 6 * 3600), now: now) == nil)
    }

    @Test func rollingWindowsUseTheirLength() {
        // Codex 300-minute window behaves like the 5h one.
        let pace = EdgeBarUsagePace.of(window(.rolling(minutes: 300), used: 20, resetsIn: 3 * 3600), now: now)
        #expect(pace == .endsAt(50))
    }

    // MARK: Levels

    @Test func levelsFollowTheAITab() {
        #expect(EdgeBarUsageLevel(percent: 69.9) == .normal)
        #expect(EdgeBarUsageLevel(percent: 70) == .warning)
        #expect(EdgeBarUsageLevel(percent: 90) == .critical)
    }

    // MARK: Detail

    @Test func detailKeepsEveryWindowInOrder() {
        let quota = ProviderUsageQuota(provider: .claude, status: .valid, tiers: [
            QuotaTier(window: .fiveHour, utilization: 42, resetsAt: nil),
            QuotaTier(window: .sevenDay, utilization: 130, resetsAt: nil),
        ], fetchedAt: now)
        let detail = EdgeBarUsageDetail(quota)
        #expect(detail?.windows.map(\.window) == [.fiveHour, .sevenDay])
        #expect(detail?.windows.map(\.percent) == [42, 100])
    }

    @Test func noDetailWithoutAReading() {
        #expect(EdgeBarUsageDetail(ProviderUsageQuota(provider: .claude, status: .needsAuthorization)) == nil)
        #expect(EdgeBarUsageDetail(ProviderUsageQuota(provider: .claude, status: .valid)) == nil)
    }

    // MARK: Sections (hover targets)

    private let lines: [EdgeBarUsageLine] = [
        .header(.claude),
        .window(.init(provider: .claude, label: "5h", percent: 10, resetsAt: nil)),
        .window(.init(provider: .claude, label: "7d", percent: 20, resetsAt: nil)),
        .header(.codex),
        .window(.init(provider: .codex, label: "5h", percent: 30, resetsAt: nil)),
    ]

    @Test func cardIDRoundTrips() {
        #expect(EdgeBarUsage.provider(ofCardID: EdgeBarUsage.cardID(.codex)) == .codex)
        #expect(EdgeBarUsage.provider(ofCardID: "some-session-id") == nil)
    }

    @Test func sectionUnderThePoint() {
        let top = EdgeBarUsage.linesTop(rows: 2)
        let h = EdgeBarUsage.lineHeight
        func hit(_ line: CGFloat) -> QuotaProvider? {
            EdgeBarUsage.provider(x: 40, y: top + line * h + 1, width: 200, rows: 2, lines: lines)
        }
        #expect(hit(0) == .claude)
        #expect(hit(2) == .claude)
        #expect(hit(3) == .codex)
        #expect(hit(4) == .codex)
        #expect(hit(5) == nil)
        // Above the first line, or past the body's width.
        #expect(EdgeBarUsage.provider(x: 40, y: top - 1, width: 200, rows: 2, lines: lines) == nil)
        #expect(EdgeBarUsage.provider(x: 201, y: top + 1, width: 200, rows: 2, lines: lines) == nil)
    }

    @Test func sectionGeometry() {
        #expect(EdgeBarUsage.sectionRange(of: .claude, in: lines) == 0 ..< 3)
        #expect(EdgeBarUsage.sectionRange(of: .codex, in: lines) == 3 ..< 5)
        #expect(EdgeBarUsage.sectionRange(of: .gemini, in: lines) == nil)
        #expect(EdgeBarUsage.sectionTop(of: .codex, in: lines, rows: 2)
            == EdgeBarUsage.linesTop(rows: 2) + 3 * EdgeBarUsage.lineHeight)
    }

    @Test func cardSitsLevelWithItsSectionInsideTheCanvas() {
        #expect(EdgeBarMetrics.cardTop(level: 300, height: 200, barTop: 100, canvasHeight: 900)
            == 100 + 300 - EdgeBarMetrics.cardLead)
        // Pushed up to stay whole.
        #expect(EdgeBarMetrics.cardTop(level: 700, height: 200, barTop: 100, canvasHeight: 900)
            == 900 - 200 - EdgeBarMetrics.gutter)
    }
}
