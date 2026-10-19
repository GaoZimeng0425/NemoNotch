import Foundation
@testable import NemoNotch
import Testing

@Suite("EdgeBarUsage")
struct EdgeBarUsageTests {
    private let reset = Date(timeIntervalSince1970: 10000)

    @Test func readableProvidersBecomeHeadingsOverTheirWindows() {
        let lines = EdgeBarUsage.lines(from: [
            .codex: ProviderUsageQuota(provider: .codex, status: .valid, tiers: [
                QuotaTier(window: .rolling(minutes: 300), utilization: 12.4, resetsAt: reset),
            ]),
            .claude: ProviderUsageQuota(provider: .claude, status: .valid, tiers: [
                QuotaTier(window: .fiveHour, utilization: 81.6, resetsAt: reset),
                QuotaTier(window: .sevenDay, utilization: 140, resetsAt: nil),
            ]),
        ])
        // Provider order is `QuotaProvider`'s (Claude before Codex), percents
        // rounded and clamped to 0...100.
        #expect(lines == [
            .header(.claude),
            .window(.init(provider: .claude, label: "5h", percent: 82, resetsAt: reset)),
            .window(.init(provider: .claude, label: "7d", percent: 100, resetsAt: nil)),
            .header(.codex),
            .window(.init(provider: .codex, label: "5h", percent: 12, resetsAt: reset)),
        ])
    }

    @Test func providersWithoutDataAreLeftOut() {
        let lines = EdgeBarUsage.lines(from: [
            .claude: ProviderUsageQuota(provider: .claude, status: .needsAuthorization),
            .gemini: ProviderUsageQuota(provider: .gemini, status: .valid, tiers: []),
            .zcode: ProviderUsageQuota(provider: .zcode, status: .expired, tiers: [
                QuotaTier(window: .fiveHour, utilization: 50, resetsAt: nil),
            ]),
        ])
        #expect(lines.isEmpty)
    }

    @Test func tailCountsDownThenSaysReset() {
        let now = Date(timeIntervalSince1970: 10000 - (4 * 3600 + 12 * 60))
        #expect(EdgeBarUsage.tail(reset, now: now) == "4h12m")
        #expect(EdgeBarUsage.tail(nil, now: now) == "--")
        #expect(EdgeBarUsage.tail(reset, now: reset.addingTimeInterval(1)) != "--")
    }

    @Test func openLengthMakesRoomForTheBlock() {
        // Under the summary: hairline gap 10, inset 6, 3 lines of 14, margin 34.
        let withRows = EdgeBarMetrics.openLength(rows: 2, usageLines: 3)
        let summaryEnd = EdgeBarMetrics.summaryTop(rows: 2) + EdgeBarMetrics.summaryHeight
        #expect(withRows == summaryEnd + 10.0 + 6.0 + 42.0 + 34.0)
        // No session: the block hangs under the head.
        let headEnd = EdgeBarMetrics.headTop + EdgeBarMetrics.headSize
        #expect(EdgeBarMetrics.openLength(rows: 0, usageLines: 2) == headEnd + 10.0 + 6.0 + 28.0 + 34.0)
    }

    @Test func blockOpensTheBodyEvenWithoutSessions() {
        let usage: [EdgeBarUsageLine] = [
            .header(.claude),
            .window(.init(provider: .claude, label: "5h", percent: 30, resetsAt: nil)),
        ]
        let width = EdgeBarModel.openWidth(of: .empty, usage: usage)
        #expect(width > EdgeBarMetrics.barWidth)
        #expect(width >= EdgeBarUsage.minWidth(usage))
        #expect(EdgeBarModel.openWidth(of: .empty) == EdgeBarMetrics.barWidth)
    }
}
