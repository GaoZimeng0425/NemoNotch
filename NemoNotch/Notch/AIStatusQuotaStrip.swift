import SwiftUI

/// Usage + quota footer for the expanded AI-status panel. Same data as
/// `UsageQuotaCompactView` in the AI tab, laid out horizontally for a wide
/// panel footer instead of a narrow column: one meter chip per provider, or
/// both windows when only a single provider is present.
///
/// Mounted ONLY while the panel is expanded (the panel layer itself is always
/// in the view tree, hidden by opacity — see the collapsed-state view-tree
/// pitfall in AGENTS.md), so `.activates` keeps the quota service ticking
/// exactly while the user is looking at it.
struct AIStatusQuotaStrip: View {
    @Environment(UsageQuotaService.self) private var service
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        content.activates(service)
    }

    private var content: some View {
        HStack(spacing: 10) {
            ForEach(chips) { chip in
                chipView(chip)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Nothing resolved yet: say so only while a fetch is actually in
            // flight. Once it has settled with no data, the footer stays empty
            // rather than parking a permanent status line there.
            if chips.isEmpty {
                if service.isRefreshing {
                    Text("quota.status.reading")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chip model

    private struct Chip: Identifiable {
        enum Kind {
            /// A percentage meter for one rolling window.
            case meter(QuotaTier)
            /// zcode has no quota credential — show local token usage instead.
            case localUsage(tokens: Int)
        }

        let id: String
        let provider: QuotaProvider
        let kind: Kind
    }

    /// Providers to surface — mirrors `UsageQuotaCompactView.visibleProviders`.
    private var visibleProviders: [QuotaProvider] {
        var result: [QuotaProvider] = []
        if appSettings.claudeEnabled { result.append(.claude) }
        if service.hasCodexCredential { result.append(.codex) }
        if appSettings.geminiEnabled, service.hasGeminiCredential { result.append(.gemini) }
        if appSettings.zcodeEnabled, service.hasZcodeCredential { result.append(.zcode) }
        return result
    }

    private var zcodeStats: ZcodeUsageStats? {
        appSettings.zcodeEnabled ? service.zcodeUsage : nil
    }

    /// Providers that actually resolved to numbers. A provider that is merely
    /// *configured* (Claude is always in `visibleProviders`) but has no quota —
    /// not logged in, awaiting Keychain authorization, still fetching, parse
    /// error — is dropped rather than given a chip. The footer is a glanceable
    /// readout, and a dead "not logged in" slot used to eat a third of it while
    /// a provider with real data got squeezed out by the 3-chip cap. Granting
    /// Keychain access still lives on the AI tab's full quota card.
    private var providersWithData: [QuotaProvider] {
        visibleProviders.filter { provider in
            guard let quota = service.quotas[provider] else { return false }
            return quota.status == .valid && !quota.tiers.isEmpty
        }
    }

    /// At most three chips. One provider → its two shortest windows; several →
    /// each provider's shortest window. The full breakdown stays in the AI tab.
    private var chips: [Chip] {
        let providers = providersWithData
        var out: [Chip] = []

        if providers.count == 1, let only = providers.first {
            out.append(contentsOf: meterChips(only, tierLimit: 2))
        } else {
            for provider in providers.prefix(3) {
                out.append(contentsOf: meterChips(provider, tierLimit: 1))
            }
        }

        // zcode has no remote quota API on every setup — when its quota is
        // absent but the CLI's local sqlite has counts, that IS its data.
        if service.quotas[.zcode] == nil, let stats = zcodeStats {
            out.append(Chip(id: "zcode.local", provider: .zcode, kind: .localUsage(tokens: stats.todayTokens)))
        }
        return Array(out.prefix(3))
    }

    private func meterChips(_ provider: QuotaProvider, tierLimit: Int) -> [Chip] {
        let tiers = service.quotas[provider]?.tiers ?? []
        return tiers.prefix(tierLimit).enumerated().map { index, tier in
            Chip(id: "\(provider.rawValue).\(index)", provider: provider, kind: .meter(tier))
        }
    }

    // MARK: - Chip rendering

    @ViewBuilder
    private func chipView(_ chip: Chip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: providerLabel(chip))
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)
            switch chip.kind {
            case let .meter(tier): meterBody(tier)
            case let .localUsage(tokens):
                Text("quota.zcode.compact \(ZcodeUsageFormatter.tokens(tokens))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
            }
        }
    }

    private func meterBody(_ tier: QuotaTier) -> some View {
        let pct = min(max(tier.utilization, 0), 100)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(verbatim: "\(Int(pct.rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(color(for: pct))
                Spacer(minLength: 0)
                countdownText(tier.resetsAt)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(NotchTheme.rail)
                    Capsule(style: .continuous)
                        .fill(color(for: pct))
                        .frame(width: max(geo.size.width * CGFloat(pct / 100), 3))
                        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: pct)
                }
            }
            .frame(height: 5)
        }
    }

    /// `Claude Code · 5h`, or just the provider name for the windowless
    /// local-usage chip.
    private func providerLabel(_ chip: Chip) -> String {
        guard case let .meter(tier) = chip.kind else { return chip.provider.displayName }
        return "\(chip.provider.displayName) · \(windowShortLabel(tier.window))"
    }

    private func windowShortLabel(_ window: QuotaWindow) -> String {
        switch window {
        case .fiveHour: "5h"
        case .sevenDay, .sevenDayOpus, .sevenDaySonnet: "7d"
        case let .rolling(minutes): UsageQuotaFormatter.windowLabel(minutes: minutes)
        case let .gemini(label): label
        }
    }

    private func countdownText(_ date: Date?) -> Text {
        guard let date else { return Text(verbatim: "") }
        switch UsageQuotaFormatter.countdown(until: date) {
        case .reset: return Text("quota.reset")
        case let .text(value): return Text(verbatim: value)
        }
    }

    private func color(for utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }
}
