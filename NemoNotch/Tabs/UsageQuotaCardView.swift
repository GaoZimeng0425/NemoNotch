import SwiftUI

/// Compact card showing Claude Code and/or Codex usage quotas. Each present
/// provider gets a labeled section. Binds the quota service to its visibility
/// via `.activates`.
struct UsageQuotaCardView: View {
    @Environment(UsageQuotaService.self) private var service
    @Environment(AppSettings.self) private var appSettings

    /// Providers to show: Claude when enabled, Codex when a credential exists, Gemini when enabled and a credential
    /// exists.
    private var visibleProviders: [QuotaProvider] {
        var result: [QuotaProvider] = []
        if appSettings.claudeEnabled { result.append(.claude) }
        if service.hasCodexCredential { result.append(.codex) }
        if appSettings.geminiEnabled, service.hasGeminiCredential { result.append(.gemini) }
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
            } else if quota?.status == .needsAuthorization {
                authorizeButton(provider)
            } else {
                Text(statusKey(for: quota))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    /// Shown when the credential lives only in the Keychain and this app hasn't
    /// been granted access. Explains *why* access is needed, then triggers the
    /// (one-time) macOS consent dialog on tap.
    private func authorizeButton(_ provider: QuotaProvider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("quota.authorize.reason")
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await service.authorize(provider) }
            } label: {
                Text("quota.authorize")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(NotchTheme.accent))
                    .foregroundStyle(Color.black.opacity(0.85))
            }
            .buttonStyle(.plain)
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
        case let .gemini(label): Text(verbatim: label)
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
        case .needsAuthorization: return "quota.status.needs_authorization"
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

    /// A compact meter slot: the provider's primary (shortest) tier or its
    /// secondary (next) tier. Provider-agnostic so Codex — whose windows are
    /// arbitrary rolling lengths, often without a literal 5h — surfaces whatever
    /// windows it actually reports instead of an empty "5h" meter.
    private enum Slot { case primary, secondary }

    /// Providers to surface: Claude when enabled, Codex when a credential exists, Gemini when enabled and a credential
    /// exists.
    private var visibleProviders: [QuotaProvider] {
        var result: [QuotaProvider] = []
        if appSettings.claudeEnabled { result.append(.claude) }
        if service.hasCodexCredential { result.append(.codex) }
        if appSettings.geminiEnabled, service.hasGeminiCredential { result.append(.gemini) }
        return result
    }

    /// At most two meters. One provider → its primary + secondary tier. Two or
    /// more providers (Claude/Codex/Gemini) → the first two providers' primary
    /// tier. The full breakdown for every provider is in the click-to-open card.
    private var rows: [(provider: QuotaProvider, slot: Slot)] {
        let providers = visibleProviders
        if providers.count <= 1 {
            guard let only = providers.first else { return [] }
            return [(only, .primary), (only, .secondary)]
        }
        return providers.prefix(2).map { ($0, .primary) }
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
                    ForEach(displayRows, id: \.self) { row in
                        switch row {
                        case let .meter(provider, slot):
                            meterRow(provider: provider, slot: slot)
                        case let .authorize(provider):
                            compactAuthorizeButton(provider)
                        }
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

    /// One row per logical meter, except a provider awaiting authorization
    /// collapses to a single authorize chip (instead of two "--" meters).
    private enum CompactRow: Hashable {
        case meter(provider: QuotaProvider, slot: Slot)
        case authorize(provider: QuotaProvider)
    }

    private var displayRows: [CompactRow] {
        var seenAuth: Set<QuotaProvider> = []
        var out: [CompactRow] = []
        for row in rows {
            let status = service.quotas[row.provider]?.status
            if status == .needsAuthorization {
                if seenAuth.insert(row.provider).inserted {
                    out.append(.authorize(provider: row.provider))
                }
            } else if status == .valid, tier(row.provider, row.slot) == nil {
                // Loaded but no window in this slot (e.g. Codex free tier reports a
                // single window) — skip rather than render an empty "--" meter.
                continue
            } else {
                out.append(.meter(provider: row.provider, slot: row.slot))
            }
        }
        return out
    }

    private func compactAuthorizeButton(_ provider: QuotaProvider) -> some View {
        Button {
            Task { await service.authorize(provider) }
        } label: {
            Text("quota.authorize")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(NotchTheme.accent))
                .foregroundStyle(Color.black.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private func meterRow(provider: QuotaProvider, slot: Slot) -> some View {
        let tier = tier(provider, slot)
        let pct = tier?.utilization ?? 0
        return HStack(spacing: 5) {
            Text(label(provider: provider, tier: tier))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 40, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

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

    /// The provider's tier for a slot, taken from its ordered tiers. Claude's are
    /// ordered [5h, 7d, …]; Codex's are normalized session→weekly→other. So
    /// `.primary` is the shortest window and `.secondary` the next — and a
    /// provider that omits one simply has no tier for that slot.
    private func tier(_ provider: QuotaProvider, _ slot: Slot) -> QuotaTier? {
        let tiers = service.quotas[provider]?.tiers ?? []
        switch slot {
        case .primary: return tiers.first
        case .secondary: return tiers.count > 1 ? tiers[1] : nil
        }
    }

    /// Window label from the resolved tier (Claude named windows → "5h"/"7d";
    /// Codex rolling → "5h"/"7d"/"30d"/…), prefixed with the provider initial
    /// when more than one provider is shown.
    private func label(provider: QuotaProvider, tier: QuotaTier?) -> String {
        let win = tier.map { windowShortLabel($0.window) } ?? "--"
        guard visibleProviders.count != 1 else { return win }
        let prefix = switch provider {
        case .claude: "C"
        case .codex: "Cx"
        case .gemini: "G"
        }
        return "\(prefix) \(win)"
    }

    private func windowShortLabel(_ window: QuotaWindow) -> String {
        switch window {
        case .fiveHour: return "5h"
        case .sevenDay, .sevenDayOpus, .sevenDaySonnet: return "7d"
        case let .rolling(minutes): return UsageQuotaFormatter.windowLabel(minutes: minutes)
        case let .gemini(label): return label
        }
    }

    private func color(for utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }
}
