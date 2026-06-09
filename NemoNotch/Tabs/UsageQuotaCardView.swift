import SwiftUI

/// Compact card showing Claude Code 5h / 7d usage quotas. Binds the quota
/// service to its own visibility via `.activates`.
struct UsageQuotaCardView: View {
    @Environment(UsageQuotaService.self) private var service

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(10)
        .notchCard(radius: 10, fill: NotchTheme.surface)
        .activates(service)
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
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .rotationEffect(service.isRefreshing ? .degrees(360) : .degrees(0))
                    .animation(
                        service.isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : nil, // stop instantly — no reverse (counterclockwise) sweep back to 0°
                        value: service.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(service.isRefreshing)
            .help("quota.refresh")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let quota = service.quota, quota.status == .valid, !quota.tiers.isEmpty {
            ForEach(quota.tiers, id: \.window) { tier in
                tierRow(tier)
            }
        } else {
            Text(statusKey)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchTheme.textTertiary)
        }
    }

    private func tierRow(_ tier: QuotaTier) -> some View {
        HStack(spacing: 6) {
            Text(label(for: tier.window))
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

    private func label(for window: QuotaWindow) -> LocalizedStringKey {
        switch window {
        case .fiveHour: "quota.window.5h"
        case .sevenDay: "quota.window.7d"
        case .sevenDayOpus: "quota.window.7d_opus"
        case .sevenDaySonnet: "quota.window.7d_sonnet"
        }
    }

    private func color(for utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }

    private var statusKey: LocalizedStringKey {
        guard let quota = service.quota else {
            return "quota.status.reading"
        }
        switch quota.status {
        case .valid: return "quota.status.no_data"
        case .expired: return "quota.status.login_required"
        case .notFound: return "quota.status.not_logged_in"
        case .parseError: return "quota.status.error"
        }
    }
}
