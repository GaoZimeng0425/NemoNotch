import SwiftUI

extension AIChatTab {
    // MARK: - Summary cards (context · usage quota)

    /// Compact card pair living in the header's top-right: session context on
    /// the left, periodic-token usage quota on the right. Each is tappable for a
    /// detail popover.
    var contextSummaryCard: some View {
        Button { showContextDetail.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("ai.context")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                if headerMeterSessions.isEmpty {
                    serverStatus
                } else {
                    ForEach(headerMeterSessions) { session in
                        compactContextMeter(session)
                    }
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchCard(radius: 10, fill: NotchTheme.surfaceSubtle)
        .popover(isPresented: $showContextDetail, arrowEdge: .bottom) {
            contextDetailPopover
                .frame(width: 280)
        }
    }

    var contextDetailPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ai.context")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(allSessions) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                sourceIcon(session.source, size: 11)
                                Text(session.displayTitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(NotchTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if let model = session.displayModel {
                                    Text(model)
                                        .font(.system(size: 9))
                                        .foregroundStyle(NotchTheme.textTertiary)
                                }
                            }
                            contextBar(session: session)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(10)
    }

    var consoleIcon: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [NotchTheme.accent, NotchTheme.accentHot],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 44, height: 44)
            .overlay {
                if let dominantSource {
                    switch dominantSource {
                    case .claude:
                        ClaudeCrabIcon(size: 22, color: .white)
                    case .gemini:
                        Image(systemName: "sparkles")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    case .opencode:
                        OpencodeLogoIcon(size: 22, color: .white)
                    case .zcode:
                        ZcodeLogoIcon(size: 22, color: .white)
                    }
                } else {
                    HStack(spacing: 0) {
                        ClaudeCrabIcon(size: 18, color: .white)
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            }
            .shadow(color: NotchTheme.accent.opacity(0.32), radius: 16, y: 8)
    }

    func compactContextMeter(_ session: AISessionState) -> some View {
        HStack(spacing: 5) {
            Text(meterLabel(for: session))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 40, alignment: .trailing)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(NotchTheme.rail)
                    Capsule(style: .continuous)
                        .fill(NotchTheme.accentText)
                        .frame(width: max(geo.size.width * CGFloat(session.contextPercent), 4))
                }
            }
            .frame(width: 40, height: 6)

            Text(String(format: "%.0f%%", session.contextPercent * 100))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(NotchTheme.accentText)
                .frame(width: 30, alignment: .trailing)
        }
    }

    func meterLabel(for session: AISessionState) -> String {
        let source = sourceShortLabel(session.source)
        let duration = sessionDurationText(session.sessionStart)
        return "\(source) \(duration)"
    }

    func sessionDurationText(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "now"
        }
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = Int(minutes / 60)
        if hours < 24 {
            return "\(hours)h"
        }
        let days = Int(hours / 24)
        return "\(days)d"
    }
}
