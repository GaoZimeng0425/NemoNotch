import AppKit
import SwiftUI

/// One line of the open bar's usage block: a provider's heading, or one of
/// its quota windows (evlat's usage block). Decided here from
/// `UsageQuotaService.quotas`, unit-tested; drawn by `EdgeBarUsageBlock`.
enum EdgeBarUsageLine: Equatable, Identifiable {
    case header(QuotaProvider)
    case window(Window)

    struct Window: Equatable {
        let provider: QuotaProvider
        let label: String
        /// 0...100.
        let percent: Int
        let resetsAt: Date?
    }

    var id: String {
        switch self {
        case let .header(provider): "header:\(provider.rawValue)"
        case let .window(window): "\(window.provider.rawValue):\(window.label)"
        }
    }
}

enum EdgeBarUsage {
    /// At or above this a window reads amber: it asks for attention.
    static let hotPercent = 80

    static let gap: CGFloat = 10
    static let inset: CGFloat = 6
    static let lineHeight: CGFloat = 14
    static let columnGap: CGFloat = 6
    static let meterMinWidth: CGFloat = 24
    static let meterHeight: CGFloat = 3

    static var lineFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    }

    static var headerFont: NSFont {
        .systemFont(ofSize: 8, weight: .semibold)
    }

    static let headerKerning: CGFloat = 0.8

    /// Providers with a readable quota, each a heading over its windows, in
    /// `QuotaProvider` order. A provider without data (not logged in, needs
    /// authorization, fetch failed) is left out — the AI tab's card is where
    /// those states are explained and fixed.
    ///
    /// A fetch that failed transiently (still `.valid`, no tiers, an error
    /// message) keeps that provider's `previous` lines, so an open block
    /// doesn't collapse under the cursor over a network blip.
    static func lines(
        from quotas: [QuotaProvider: ProviderUsageQuota],
        previous: [EdgeBarUsageLine] = []
    ) -> [EdgeBarUsageLine] {
        QuotaProvider.allCases.flatMap { provider -> [EdgeBarUsageLine] in
            guard let quota = quotas[provider], quota.status == .valid else { return [] }
            guard !quota.tiers.isEmpty else {
                return quota.errorMessage == nil ? [] : section(of: provider, in: previous)
            }
            let windows = quota.tiers.map { tier in
                EdgeBarUsageLine.window(.init(
                    provider: provider,
                    label: label(tier.window),
                    percent: Int(min(100, max(0, tier.utilization)).rounded()),
                    resetsAt: tier.resetsAt
                ))
            }
            return [.header(provider)] + windows
        }
    }

    /// One provider's heading and windows out of `lines`.
    static func section(of provider: QuotaProvider, in lines: [EdgeBarUsageLine]) -> [EdgeBarUsageLine] {
        lines.filter { line in
            switch line {
            case let .header(p): p == provider
            case let .window(window): window.provider == provider
            }
        }
    }

    /// The block cut to what fits: whole provider sections are dropped from
    /// the end until the open body is no longer than `maxLength` (a tall
    /// list plus many quota windows would otherwise run past the window).
    static func fitting(_ lines: [EdgeBarUsageLine], rows: Int, maxLength: CGFloat) -> [EdgeBarUsageLine] {
        var kept = lines
        while !kept.isEmpty, EdgeBarMetrics.openLength(rows: rows, usageLines: kept.count) > maxLength {
            guard let lastHeader = kept.lastIndex(where: {
                if case .header = $0 {
                    true
                } else {
                    false
                }
            }) else {
                return []
            }
            kept.removeSubrange(lastHeader...)
        }
        return kept
    }

    static func label(_ window: QuotaWindow) -> String {
        switch window {
        case .fiveHour: "5h"
        case .sevenDay: "7d"
        case .sevenDayOpus: "7d Opus"
        case .sevenDaySonnet: "7d Sonnet"
        case let .rolling(minutes): UsageQuotaFormatter.windowLabel(minutes: minutes)
        case let .gemini(label): label
        }
    }

    static func heading(_ provider: QuotaProvider) -> String {
        provider.displayName.uppercased()
    }

    /// "4h12m" until the reset, "Reset" once past, "--" when unknown.
    static func tail(_ resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return "--" }
        switch UsageQuotaFormatter.countdown(until: resetsAt, now: now) {
        case .reset: return String(localized: "quota.reset")
        case let .text(text): return text
        }
    }

    // MARK: - Geometry (from the bar's top, like `EdgeBarMetrics`)

    /// The block's hairline: under the summary, or under the head when there
    /// is no session (then there is no list and no summary).
    static func top(rows: Int) -> CGFloat {
        let above = rows > 0
            ? EdgeBarMetrics.summaryTop(rows: rows) + EdgeBarMetrics.summaryHeight
            : EdgeBarMetrics.headTop + EdgeBarMetrics.headSize
        return above + gap
    }

    static func height(lines: Int) -> CGFloat {
        lines > 0 ? inset + CGFloat(lines) * lineHeight : 0
    }

    // MARK: - Measured columns

    struct Columns: Equatable {
        var label: CGFloat
        var percent: CGFloat
        var tail: CGFloat
    }

    static func columns(_ lines: [EdgeBarUsageLine]) -> Columns {
        let labels = lines.compactMap { line -> String? in
            guard case let .window(window) = line else { return nil }
            return window.label
        }
        // The widest forms, so the block doesn't move as the countdown runs.
        let tails = ["29d23h", "6d23h", "23h59m", String(localized: "quota.reset")]
        return Columns(
            label: labels.map { width($0, lineFont) }.max() ?? 0,
            percent: width("100%", lineFont),
            tail: tails.map { width($0, lineFont) }.max() ?? 0
        )
    }

    /// The narrowest open body that holds the block whole.
    static func minWidth(_ lines: [EdgeBarUsageLine]) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        let c = columns(lines)
        let row = c.label + meterMinWidth + c.percent + c.tail + 3 * columnGap
        let headers = lines.compactMap { line -> CGFloat? in
            guard case let .header(provider) = line else { return nil }
            return ceil((heading(provider) as NSString)
                .size(withAttributes: [.font: headerFont, .kern: headerKerning]).width)
        }
        return max(row, headers.max() ?? 0) + EdgeBarMetrics.ringLead + EdgeBarMetrics.nameInset
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The usage block under the open list: a hairline, then per provider a
/// spaced-capitals heading over its windows — label, meter, percent, reset
/// countdown. Only in the tree while open, so its minute tick never runs on
/// the closed bar.
struct EdgeBarUsageBlock: View {
    let lines: [EdgeBarUsageLine]
    let width: CGFloat
    /// The anchored side: the rings' inset there, the names' inset across.
    let side: EdgeBarSide

    private static let track = Color.white.opacity(0.15)
    private static let fill = Color.white.opacity(0.55)
    private static let headerColor = EdgeBarPalette.textSecondary.opacity(0.72)

    var body: some View {
        let columns = EdgeBarUsage.columns(lines)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
                .padding(.bottom, EdgeBarUsage.inset - 1)
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        switch line {
                        case let .header(provider): header(provider)
                        case let .window(window): row(window, columns: columns, now: context.date)
                        }
                    }
                }
            }
        }
        .padding(side.edge, EdgeBarMetrics.ringLead)
        .padding(side.farEdge, EdgeBarMetrics.nameInset)
        .frame(width: width, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func header(_ provider: QuotaProvider) -> some View {
        Text(verbatim: EdgeBarUsage.heading(provider))
            .font(Font(EdgeBarUsage.headerFont))
            .kerning(EdgeBarUsage.headerKerning)
            .foregroundStyle(Self.headerColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .padding(.bottom, 1)
            .frame(height: EdgeBarUsage.lineHeight, alignment: .bottom)
    }

    private func row(_ window: EdgeBarUsageLine.Window, columns: EdgeBarUsage.Columns, now: Date) -> some View {
        let hot = window.percent >= EdgeBarUsage.hotPercent
        return HStack(spacing: EdgeBarUsage.columnGap) {
            Text(verbatim: window.label)
                .foregroundStyle(EdgeBarPalette.textSecondary)
                .frame(width: columns.label, alignment: .leading)
            meter(Double(window.percent) / 100, fill: hot ? EdgeBarPalette.amber : Self.fill)
            Text(verbatim: "\(window.percent)%")
                .foregroundStyle(hot ? EdgeBarPalette.amber : Color.white.opacity(0.74))
                .frame(width: columns.percent, alignment: .trailing)
            Text(verbatim: EdgeBarUsage.tail(window.resetsAt, now: now))
                .foregroundStyle(EdgeBarPalette.textSecondary)
                .frame(width: columns.tail, alignment: .trailing)
        }
        .font(Font(EdgeBarUsage.lineFont))
        .lineLimit(1)
        .frame(height: EdgeBarUsage.lineHeight)
    }

    private func meter(_ fraction: Double, fill: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Self.track)
                if fraction > 0 {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(EdgeBarUsage.meterHeight, proxy.size.width * CGFloat(min(1, fraction))))
                }
            }
        }
        .frame(minWidth: EdgeBarUsage.meterMinWidth)
        .frame(height: EdgeBarUsage.meterHeight)
    }
}
