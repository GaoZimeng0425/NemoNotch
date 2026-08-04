import SwiftUI

/// Formats a completion duration: <60s → "42s", <1h → "2m 14s", else "1h 5m".
private func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    let (m, rs) = (s / 60, s % 60)
    if m < 60 { return "\(m)m \(rs)s" }
    let (h, rm) = (m / 60, m % 60)
    return "\(h)h \(rm)m"
}

/// Completion alert capsule shown centered in the lower portion of the screen
/// (inside the full-screen flash overlay) when a session/agent finishes or a
/// Pomodoro phase ends. Black-capsule styling matching `HUDOverlayView`, but
/// deliberately larger. Leads with the **source app's logo** (Claude Code /
/// Gemini / opencode / agent / Pomodoro) so it's clear which app finished,
/// then the name(s); when more than one, appends a count chip.
struct CompletionToastView: View {
    let items: [CompletionItem]

    var body: some View {
        if items.count == 1, let item = items.first {
            singleItemBody(item)
        } else {
            multiItemBody
        }
    }

    /// Rich two-line layout: title + tool·model·tokens·duration.
    @ViewBuilder
    private func singleItemBody(_ item: CompletionItem) -> some View {
        HStack(spacing: 10) {
            sourceIcon(item.source)
                .frame(
                    width: NotchConstants.completionToastIconSize + 4,
                    height: NotchConstants.completionToastIconSize + 4
                )

            VStack(alignment: .leading, spacing: 2) {
                // Prefer the task title (firstUserMessage-derived); fall back to name.
                Text(item.subtitle ?? item.name)
                    .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: NotchConstants.completionToastMaxWidth, alignment: .leading)

                if let detail = detailLine(for: item) {
                    Text(detail)
                        .font(.system(size: NotchConstants.completionToastFontSize - 5, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: NotchConstants.completionToastMaxWidth, alignment: .leading)
                }
            }

            // The "name" (project folder) is dropped from the visible text when a
            // richer subtitle is present; otherwise it's the title line above.
        }
        .padding(.horizontal, NotchConstants.completionToastHPadding)
        .frame(minHeight: NotchConstants.completionToastHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(.black)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(NotchTheme.stroke, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    /// Multi-item layout: source logo + names joined by "·" + count chip (unchanged).
    @ViewBuilder
    private var multiItemBody: some View {
        HStack(spacing: 10) {
            if let source = items.first?.source {
                sourceIcon(source)
                    .frame(
                        width: NotchConstants.completionToastIconSize + 4,
                        height: NotchConstants.completionToastIconSize + 4
                    )
            }

            Text(items.map(\.name).joined(separator: " · "))
                .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: NotchConstants.completionToastMaxWidth)

            if items.count > 1 {
                Text("\(items.count)")
                    .font(.system(size: NotchConstants.completionToastCountFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.accent)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, NotchConstants.completionToastHPadding)
        .frame(height: NotchConstants.completionToastHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background(.black)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(NotchTheme.stroke, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    /// "tool · model · tokens · duration" for the single-item detail line,
    /// skipping nil fields. Returns nil when there is no detail at all.
    private func detailLine(for item: CompletionItem) -> String? {
        var parts: [String] = []
        if let tool = item.tool, !tool.isEmpty { parts.append(tool) }
        if let model = item.model { parts.append(model) }
        if let tokens = item.tokenDisplay { parts.append(tokens) }
        if let duration = item.duration { parts.append(formatDuration(duration)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The leading brand mark for the completion's source. Mirrors
    /// `AIChatTab.sourceIcon` for the AI cases.
    @ViewBuilder
    private func sourceIcon(_ source: CompletionSource) -> some View {
        let s = NotchConstants.completionToastIconSize
        switch source {
        case .ai(.claude):
            ClaudeCrabIcon(size: s, color: Color(red: 0.85, green: 0.47, blue: 0.34))
        case .ai(.gemini):
            Image(systemName: "sparkles")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(Color(red: 0.42, green: 0.55, blue: 0.95))
        case .ai(.opencode):
            OpencodeLogoIcon(size: s, color: .white)
        case .ai(.zcode):
            ZcodeLogoIcon(size: s, color: Color(red: 0.11, green: 0.44, blue: 0.96))
        case .agent:
            Image(systemName: "cpu")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
        case .pomodoro:
            Image(systemName: "timer")
                .font(.system(size: s * 0.9, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
        }
    }
}
