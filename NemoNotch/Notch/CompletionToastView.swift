import SwiftUI

/// HUD-style capsule shown near the notch when a session/agent finishes.
/// Matches `HUDOverlayView`'s black-capsule styling. Lists one or more
/// project/agent names; when more than one, appends a count chip.
struct CompletionToastView: View {
    let names: [String]

    private var displayText: String {
        names.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
                .frame(width: 18, alignment: .center)

            Text(displayText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if names.count > 1 {
                Text("\(names.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.accent)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, NotchConstants.hudHorizontalPadding)
        .frame(height: NotchConstants.hudHeight)
        .frame(maxWidth: 320)
        .background(.black)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }
}
