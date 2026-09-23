import SwiftUI

/// Usage + quota footer for the expanded AI-status panel. Same data as
/// `UsageQuotaCompactView` in the AI tab, laid out horizontally for a wide
/// panel footer instead of a narrow column: one meter chip per provider, or
/// both windows when only a single provider is present.
///
/// Mounted ONLY while the panel is expanded (the panel layer itself is always
/// in the view tree, hidden by opacity — see the collapsed-state view-tree
/// pitfall in CLAUDE.md), so `.activates` keeps the quota service ticking
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
            if chips.isEmpty {
                Text("quota.status.reading")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
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
            /// Keychain item exists but this app isn't authorized to read it yet.
            case authorize
            /// zcode has no quota credential — show local token usage instead.
            case localUsage(tokens: Int)
            /// Credential missing / expired / still loading.
            case status(LocalizedStringKey)
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

    /// At most three chips. One provider → its two shortest windows; several →
    /// each provider's shortest window. The full breakdown stays in the AI tab.
    private var chips: [Chip] {
        let providers = visibleProviders
        var out: [Chip] = []

        if providers.count == 1, let only = providers.first {
            out.append(contentsOf: chips(for: only, tierLimit: 2))
        } else {
            for provider in providers.prefix(3) {
                out.append(contentsOf: chips(for: provider, tierLimit: 1))
            }
        }

        if zcodeStats != nil, service.quotas[.zcode] == nil, let stats = zcodeStats {
            out.append(Chip(id: "zcode.local", provider: .zcode, kind: .localUsage(tokens: stats.todayTokens)))
        }
        return Array(out.prefix(3))
    }

    private func chips(for provider: QuotaProvider, tierLimit: Int) -> [Chip] {
        let quota = service.quotas[provider]
        if quota?.status == .needsAuthorization {
            return [Chip(id: "\(provider.rawValue).auth", provider: provider, kind: .authorize)]
        }
        let tiers = quota?.tiers ?? []
        guard !tiers.isEmpty else {
            // zcode without a quota credential falls back to the local-usage chip
            // appended separately; don't also render an empty status chip for it.
            if provider == .zcode, zcodeStats != nil { return [] }
            return [Chip(id: "\(provider.rawValue).status", provider: provider, kind: .status(statusKey(quota)))]
        }
        return tiers.prefix(tierLimit).enumerated().map { index, tier in
            Chip(id: "\(provider.rawValue).\(index)", provider: provider, kind: .meter(tier))
        }
    }

    private func statusKey(_ quota: ProviderUsageQuota?) -> LocalizedStringKey {
        guard let quota else { return "quota.status.reading" }
        switch quota.status {
        case .valid: return "quota.status.no_data"
        case .expired: return "quota.status.login_required"
        case .notFound: return "quota.status.not_logged_in"
        case .parseError: return "quota.status.error"
        case .needsAuthorization: return "quota.status.needs_authorization"
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
            case .authorize: authorizeButton(chip.provider)
            case let .localUsage(tokens):
                Text("quota.zcode.compact \(ZcodeUsageFormatter.tokens(tokens))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
            case let .status(key):
                Text(key)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
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

    private func authorizeButton(_ provider: QuotaProvider) -> some View {
        Button {
            Task { await service.authorize(provider) }
        } label: {
            Text("quota.authorize")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(NotchTheme.accent))
                .foregroundStyle(Color.black.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    /// `Claude Code · 5h`, or just the provider name when the chip carries no
    /// window (authorize / status / local usage).
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
