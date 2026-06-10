import SwiftUI

/// Compact card showing Claude Code and/or Codex usage quotas. Each present
/// provider gets a labeled section. Binds the quota service to its visibility
/// via `.activates`.
struct UsageQuotaCardView: View {
    @Environment(UsageQuotaService.self) private var service
    @Environment(AppSettings.self) private var appSettings

    /// Providers to show: Claude when enabled, Codex when a credential exists.
    private var visibleProviders: [QuotaProvider] {
        var result: [QuotaProvider] = []
        if appSettings.claudeEnabled { result.append(.claude) }
        if service.hasCodexCredential { result.append(.codex) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(visibleProviders, id: \.self) { provider in
                providerSection(provider)
            }
        }
        .padding(10)
        .notchCard(radius: 10, fill: NotchTheme.surface)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("quota.title")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer()
            Button {
                Task { await service.refresh(force: true) }
            } label: {
                refreshIcon
            }
            .buttonStyle(.plain)
            .disabled(service.isRefreshing)
            .help("quota.refresh")
        }
    }

    /// Spins only while refreshing, driven by a timeline rather than a
    /// `repeatForever` animation — a `repeatForever` animation, once started, is
    /// never cancelled by flipping the bound flag back, so it would keep spinning
    /// forever after the auto-refresh on tab-open. Swapping to a static icon when
    /// idle stops it instantly with no reverse sweep.
    @ViewBuilder
    private var refreshIcon: some View {
        let icon = Image(systemName: "arrow.clockwise")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(NotchTheme.textSecondary)
        if service.isRefreshing {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 0.8) / 0.8
                icon.rotationEffect(.degrees(phase * 360))
            }
        } else {
            icon
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: QuotaProvider) -> some View {
        let quota = service.quotas[provider]
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: provider.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)

            if let quota, quota.status == .valid, !quota.tiers.isEmpty {
                ForEach(quota.tiers, id: \.window) { tier in
                    tierRow(tier)
                }
            } else {
                Text(statusKey(for: quota))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private func tierRow(_ tier: QuotaTier) -> some View {
        HStack(spacing: 6) {
            label(for: tier.window)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 64, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(color(for: tier.utilization))
                        .frame(width: geo.size.width * min(max(tier.utilization, 0), 100) / 100)
                        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: tier.utilization)
                }
            }
            .frame(height: 5)

            Text(verbatim: "\(Int(tier.utilization.rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color(for: tier.utilization))
                .frame(width: 34, alignment: .trailing)

            countdownText(tier.resetsAt)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func countdownText(_ date: Date?) -> Text {
        guard let date else { return Text(verbatim: "--") }
        switch UsageQuotaFormatter.countdown(until: date) {
        case .reset: return Text("quota.reset")
        case let .text(value): return Text(verbatim: value)
        }
    }

    private func label(for window: QuotaWindow) -> Text {
        switch window {
        case .fiveHour: Text("quota.window.5h")
        case .sevenDay: Text("quota.window.7d")
        case .sevenDayOpus: Text("quota.window.7d_opus")
        case .sevenDaySonnet: Text("quota.window.7d_sonnet")
        case let .rolling(minutes): Text(verbatim: UsageQuotaFormatter.windowLabel(minutes: minutes))
        }
    }

    private func color(for utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }

    private func statusKey(for quota: ProviderUsageQuota?) -> LocalizedStringKey {
        guard let quota else { return "quota.status.reading" }
        switch quota.status {
        case .valid: return "quota.status.no_data"
        case .expired: return "quota.status.login_required"
        case .notFound: return "quota.status.not_logged_in"
        case .parseError: return "quota.status.error"
        }
    }
}

/// Condensed quota meters for the AI console header's right column. Shows at
/// most two rows; tapping expands the full `UsageQuotaCardView` in a popover.
/// Owns the service lifecycle (`.activates`) because the full card now only
/// exists inside the popover, so it can't keep the service active itself.
struct UsageQuotaCompactView: View {
    @Environment(UsageQuotaService.self) private var service
    @Environment(AppSettings.self) private var appSettings
    @State private var showDetail = false

    private enum LogicalWindow { case fiveHour, sevenDay }

    /// Providers to surface: Claude when enabled, Codex when a credential exists.
    private var visibleProviders: [QuotaProvider] {
        var result: [QuotaProvider] = []
        if appSettings.claudeEnabled { result.append(.claude) }
        if service.hasCodexCredential { result.append(.codex) }
        return result
    }

    /// At most two rows. One provider → its 5h + 7d. Two/three → each provider's
    /// 5h (capped at two). More than three → just Claude + Codex 5h.
    private var rows: [(provider: QuotaProvider, window: LogicalWindow)] {
        let providers = visibleProviders
        if providers.count <= 1 {
            guard let only = providers.first else { return [] }
            return [(only, .fiveHour), (only, .sevenDay)]
        }
        if providers.count > 3 {
            return [(.claude, .fiveHour), (.codex, .fiveHour)]
        }
        return providers.prefix(2).map { ($0, .fiveHour) }
    }

    var body: some View {
        if visibleProviders.isEmpty {
            EmptyView()
        } else {
            content.activates(service)
        }
    }

    private var content: some View {
        Button { showDetail.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    spinner
                    Text("quota.title")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .trailing, spacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        meterRow(provider: row.provider, window: row.window)
                    }
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchCard(radius: 10, fill: NotchTheme.surfaceSubtle)
        .help("quota.title")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            UsageQuotaCardView()
                .environment(service)
                .environment(appSettings)
                .frame(width: 260)
                .padding(8)
        }
    }

    /// Static refresh glyph that spins (timeline-driven, never a `repeatForever`)
    /// only while a fetch is in flight.
    @ViewBuilder
    private var spinner: some View {
        let glyph = Image(systemName: "arrow.clockwise")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(NotchTheme.textTertiary)
        if service.isRefreshing {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 0.8) / 0.8
                glyph.rotationEffect(.degrees(phase * 360))
            }
        } else {
            glyph
        }
    }

    private func meterRow(provider: QuotaProvider, window: LogicalWindow) -> some View {
        let tier = tier(provider, window)
        let pct = tier?.utilization ?? 0
        return HStack(spacing: 5) {
            Text(label(provider: provider, window: window))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 34, alignment: .trailing)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(NotchTheme.rail)
                    Capsule(style: .continuous)
                        .fill(color(for: pct))
                        .frame(width: tier == nil ? 0 : max(geo.size.width * CGFloat(min(max(pct, 0), 100) / 100), 4))
                }
            }
            .frame(width: 40, height: 6)

            Text(tier == nil ? "--" : "\(Int(pct.rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(tier == nil ? NotchTheme.textTertiary : color(for: pct))
                .frame(width: 30, alignment: .trailing)
        }
    }

    /// Resolves a provider's tier for a logical window, bridging Claude's named
    /// windows and Codex's rolling-minute windows (5h ≈ 300m, 7d ≈ 10080m).
    private func tier(_ provider: QuotaProvider, _ window: LogicalWindow) -> QuotaTier? {
        let tiers = service.quotas[provider]?.tiers ?? []
        switch window {
        case .fiveHour:
            return tiers.first { $0.window == .fiveHour || isRolling($0.window, minutes: 300) }
        case .sevenDay:
            return tiers.first { $0.window == .sevenDay || isRolling($0.window, minutes: 10080) }
        }
    }

    private func isRolling(_ window: QuotaWindow, minutes: Int) -> Bool {
        if case let .rolling(value) = window { return value == minutes }
        return false
    }

    private func label(provider: QuotaProvider, window: LogicalWindow) -> String {
        let win = window == .fiveHour ? "5h" : "7d"
        guard visibleProviders.count != 1 else { return win }
        return "\(provider == .claude ? "C" : "Cx") \(win)"
    }

    private func color(for utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }
}
