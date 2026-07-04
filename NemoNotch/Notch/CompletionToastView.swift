import SwiftUI

/// Completion alert capsule shown centered in the lower portion of the screen
/// (inside the full-screen flash overlay) when a session/agent finishes or a
/// Pomodoro phase ends. Black-capsule styling matching `HUDOverlayView`, but
/// deliberately larger. Leads with the **source app's logo** (Claude Code /
/// Gemini / opencode / agent / Pomodoro) so it's clear which app finished,
/// then the name(s); when more than one, appends a count chip.
struct CompletionToastView: View {
    let items: [CompletionItem]

    private var displayText: String {
        items.map(\.name).joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            if let source = items.first?.source {
                sourceIcon(source)
                    .frame(
                        width: NotchConstants.completionToastIconSize + 4,
                        height: NotchConstants.completionToastIconSize + 4
                    )
            }

            Text(displayText)
                .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Only long names are bounded/truncated here; short ones keep
                // their intrinsic width so the capsule hugs the text.
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
        // Hug the content width (driven by text + padding) instead of stretching
        // to the offered full-screen width from the surrounding GeometryReader.
        .fixedSize(horizontal: true, vertical: false)
        .background(.black)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
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
