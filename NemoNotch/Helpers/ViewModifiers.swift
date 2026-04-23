import SwiftUI

enum NotchTheme {
    static let accent = Color(red: 1.0, green: 0.55, blue: 0.08)
    static let accentSoft = accent.opacity(0.18)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.42)
    static let textMuted = Color.white.opacity(0.30)
    static let surfaceSubtle = Color.white.opacity(0.045)
    static let surface = Color.white.opacity(0.07)
    static let surfaceEmphasis = Color.white.opacity(0.12)
    static let stroke = Color.white.opacity(0.10)
}

struct NotchCardModifier: ViewModifier {
    var radius: CGFloat = 10
    var fill: Color = NotchTheme.surface
    var stroke: Color = NotchTheme.stroke

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(stroke, lineWidth: 0.6)
                    )
            )
    }
}

struct NotchPillButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.86) : NotchTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? NotchTheme.accent : NotchTheme.surfaceEmphasis)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(prominent ? Color.clear : NotchTheme.stroke, lineWidth: 0.6)
                    )
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func notchCard(radius: CGFloat = 10, fill: Color = NotchTheme.surface) -> some View {
        modifier(NotchCardModifier(radius: radius, fill: fill))
    }
}

struct PulseModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0.74 : 1)
            .scaleEffect(isActive ? 1.04 : 1)
            .animation(
                isActive
                    ? .easeInOut(duration: NotchConstants.pulseDuration).repeatForever(autoreverses: true)
                    : .easeOut(duration: NotchConstants.fadeFastDuration),
                value: isActive
            )
    }
}

struct GlowPulseModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .opacity(0.78)
            .scaleEffect(1.02)
            .animation(.easeInOut(duration: NotchConstants.pulseDuration * 0.7).repeatForever(autoreverses: true), value: true)
    }
}
