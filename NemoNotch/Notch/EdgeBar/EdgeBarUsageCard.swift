import AppKit
import SwiftUI

/// One provider's quota in detail, decided apart from the drawing: what the
/// usage card beside the bar says when its section of the usage block is
/// hovered. Built from `ProviderUsageQuota`, unit-tested.
struct EdgeBarUsageDetail: Equatable {
    struct Window: Equatable, Identifiable {
        let id: String
        let window: QuotaWindow
        /// 0...100 (used).
        let percent: Double
        let resetsAt: Date?

        /// The window's length, where it is known: what the pace is read
        /// against. Gemini's per-model buckets don't say theirs.
        var duration: TimeInterval? {
            switch window {
            case .fiveHour: 5 * 3600
            case .sevenDay, .sevenDayOpus, .sevenDaySonnet: 7 * 86400
            case let .rolling(minutes): minutes > 0 ? TimeInterval(minutes * 60) : nil
            case .gemini: nil
            }
        }
    }

    let provider: QuotaProvider
    let windows: [Window]
    let fetchedAt: Date

    init?(_ quota: ProviderUsageQuota) {
        guard quota.status == .valid, !quota.tiers.isEmpty else { return nil }
        provider = quota.provider
        fetchedAt = quota.fetchedAt
        windows = quota.tiers.enumerated().map { index, tier in
            Window(
                id: "\(index):\(EdgeBarUsage.label(tier.window))",
                window: tier.window,
                percent: min(100, max(0, tier.utilization)),
                resetsAt: tier.resetsAt
            )
        }
    }
}

/// Where a window is heading at the pace it has been used so far (idle time
/// included: the window's elapsed part, not the time anyone worked).
enum EdgeBarUsagePace: Equatable {
    /// Too little of the window has passed to read a pace.
    case early
    /// Nothing left until the reset.
    case exhausted
    /// At this pace it runs out this long from now — before its reset.
    case runsOutIn(TimeInterval)
    /// At this pace it ends its window at this share (it lasts).
    case endsAt(Int)

    /// A window younger than this share of its length (or 15 minutes) has
    /// no pace yet: one early burst would project a false run-out.
    static let minimumElapsedShare = 0.05
    static let minimumElapsed: TimeInterval = 15 * 60

    /// nil when the window's length or reset is unknown, or the reading
    /// doesn't fit its window (a reset already past, a stale reading).
    ///
    /// The share used is as of `readAt` (the fetch), so the pace is read
    /// there — elapsed time measured to `now` would count minutes nobody
    /// could have used anything in — and a run-out is then counted from
    /// `now`.
    static func of(_ window: EdgeBarUsageDetail.Window, readAt: Date, now: Date) -> Self? {
        guard let duration = window.duration, let resetsAt = window.resetsAt else { return nil }
        let remainingAtRead = resetsAt.timeIntervalSince(readAt)
        guard resetsAt > now, remainingAtRead <= duration else { return nil }
        if window.percent >= 100 {
            return .exhausted
        }
        let elapsed = duration - remainingAtRead
        guard elapsed >= max(duration * minimumElapsedShare, minimumElapsed) else { return .early }
        let rate = window.percent / elapsed
        let projected = window.percent + rate * remainingAtRead
        // Short of 100 it lasts: never round a lasting window up to "100%".
        guard projected >= 100 else { return .endsAt(min(99, Int(projected.rounded()))) }
        let runOut = (100 - window.percent) / rate - now.timeIntervalSince(readAt)
        return .runsOutIn(max(0, runOut))
    }
}

/// The AI tab's levels (and agent-hud's): warning from 70% used, critical
/// from 90%.
enum EdgeBarUsageLevel {
    case normal, warning, critical

    init(percent: Double) {
        self = percent >= 90 ? .critical : percent >= 70 ? .warning : .normal
    }

    var color: Color {
        switch self {
        case .normal: EdgeBarPalette.textPrimary
        case .warning: EdgeBarPalette.amber
        case .critical: Color(red: 1.0, green: 0.36, blue: 0.32)
        }
    }
}

enum EdgeBarUsageCardText {
    /// The window's full name: "5 小时", "7 天 Opus", a rolling window's
    /// length, a Gemini model.
    static func name(_ window: QuotaWindow) -> String {
        switch window {
        case .fiveHour: String(localized: "quota.window.5h")
        case .sevenDay: String(localized: "quota.window.7d")
        case .sevenDayOpus: String(localized: "quota.window.7d_opus")
        case .sevenDaySonnet: String(localized: "quota.window.7d_sonnet")
        case let .rolling(minutes): UsageQuotaFormatter.windowLabel(minutes: minutes)
        case let .gemini(label): label
        }
    }

    /// "Updated 3 min ago", "Updated just now".
    static func updated(_ fetchedAt: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(fetchedAt) / 60)
        return minutes < 1
            ? String(localized: "edge_bar.usage.updated_now")
            : String(format: String(localized: "edge_bar.usage.updated_fmt"), minutes)
    }

    /// "Resets Wed 14:00 · 2d3h left"; today's reset names only its time.
    static func reset(_ resetsAt: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let resetsAt else { return nil }
        guard case let .text(left) = UsageQuotaFormatter.countdown(until: resetsAt, now: now) else {
            return String(localized: "quota.reset")
        }
        let when = calendar.isDate(resetsAt, inSameDayAs: now)
            ? resetsAt.formatted(.dateTime.hour().minute())
            : resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return String(format: String(localized: "edge_bar.usage.resets_fmt"), when, left)
    }

    static func pace(_ pace: EdgeBarUsagePace, now: Date = Date()) -> String {
        switch pace {
        case .early:
            return String(localized: "edge_bar.usage.pace_early")
        case .exhausted:
            return String(localized: "edge_bar.usage.exhausted")
        case let .runsOutIn(seconds):
            // The countdown's own units ("1h40m"), read as a span from now.
            let left = switch UsageQuotaFormatter.countdown(until: now.addingTimeInterval(seconds), now: now) {
            case let .text(text): text
            case .reset: "<1m"
            }
            return String(format: String(localized: "edge_bar.usage.pace_runs_out_fmt"), left)
        case let .endsAt(percent):
            return String(format: String(localized: "edge_bar.usage.pace_ends_fmt"), percent)
        }
    }
}

/// The usage card, beside the usage block: the provider in small capitals
/// with when it was read, then per window its name and share used in its
/// level's colour, a meter, the reset (when and how long until) and where
/// the window is heading at its pace. Same ground and frame as the session
/// card; it has no buttons.
struct EdgeBarUsageCard: View {
    let detail: EdgeBarUsageDetail

    private static let padding: CGFloat = 18
    private static let corner: CGFloat = 16
    private static let ground = Color(red: 11 / 255, green: 11 / 255, blue: 13 / 255)
    private static let secondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 14) {
                header(now: context.date)
                ForEach(detail.windows) { window in
                    windowBlock(window, now: context.date)
                }
            }
            .padding(Self.padding)
        }
        .frame(width: EdgeBarMetrics.cardWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Self.ground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
        .animation(EdgeBarMotion.cardContent, value: detail)
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: EdgeBarUsage.heading(detail.provider))
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: EdgeBarUsageCardText.updated(detail.fetchedAt, now: now))
                .font(.system(size: 10))
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
        }
    }

    private func windowBlock(_ window: EdgeBarUsageDetail.Window, now: Date) -> some View {
        let level = EdgeBarUsageLevel(percent: window.percent)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: EdgeBarUsageCardText.name(window.window))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EdgeBarPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: "\(Int(window.percent.rounded()))%")
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)))
                    .foregroundStyle(level.color)
            }
            meter(window.percent / 100, color: level.color)
            if let reset = EdgeBarUsageCardText.reset(window.resetsAt, now: now) {
                Text(verbatim: reset)
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)))
                    .foregroundStyle(Self.secondary)
                    .lineLimit(1)
            }
            if let pace = EdgeBarUsagePace.of(window, readAt: detail.fetchedAt, now: now) {
                Text(verbatim: EdgeBarUsageCardText.pace(pace, now: now))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.paceColor(pace))
                    .lineLimit(1)
            }
        }
    }

    private static func paceColor(_ pace: EdgeBarUsagePace) -> Color {
        switch pace {
        case .exhausted: EdgeBarUsageLevel.critical.color
        case .runsOutIn: EdgeBarPalette.amber
        case .early, .endsAt: EdgeBarPalette.textPrimary.opacity(0.7)
        }
    }

    private func meter(_ fraction: Double, color: Color) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.12))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: fraction > 0 ? max(geo.size.width * min(1, fraction), 5) : 0)
                }
            }
    }
}
