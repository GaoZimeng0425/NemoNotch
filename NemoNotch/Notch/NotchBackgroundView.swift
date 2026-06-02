import SwiftUI

struct NotchBackgroundView: View {
    let status: NotchCoordinator.Status
    let notchSize: CGSize
    let cornerRadius: CGFloat
    let spacing: CGFloat
    var glow: NotchGlow = .none

    var body: some View {
        notchedShape
            .drawingGroup()
    }

    private var showShadow: Bool {
        status != .closed
    }

    /// Resolved glow color, or nil when no activity glow should render. Both
    /// active states use the app's theme accent (orange).
    private var glowColor: Color? {
        switch glow {
        case .none: nil
        case .running, .attention: NotchTheme.accent
        }
    }

    private var notchedShape: some View {
        ZStack {
            Rectangle()
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            NotchTheme.panelRaised,
                            NotchTheme.panelBase,
                            .black,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            if showShadow {
                Rectangle()
                    .foregroundStyle(
                        RadialGradient(
                            colors: [
                                NotchTheme.accent.opacity(0.10),
                                .clear,
                            ],
                            center: .topLeading,
                            startRadius: 20,
                            endRadius: notchSize.width * 0.72
                        )
                    )

                Rectangle()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.11),
                                .clear,
                                NotchTheme.accent.opacity(0.04),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.screen)
                    .opacity(0.48)

                if let glowColor {
                    NotchGlowRing(
                        color: glowColor,
                        cornerRadius: cornerRadius,
                        notchSize: notchSize
                    )
                    .blendMode(.screen)
                }
            }
        }
        .mask(notchBackgroundMaskGroup)
        .frame(
            width: notchSize.width + cornerRadius * 2,
            height: notchSize.height
        )
        .shadow(
            color: .black.opacity(showShadow ? NotchConstants.openedShadowOpacity : 0),
            radius: NotchConstants.openedShadowRadius
        )
    }

    private var notchBackgroundMaskGroup: some View {
        Rectangle()
            .foregroundStyle(.black)
            .frame(width: notchSize.width, height: notchSize.height)
            .clipShape(.rect(
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius
            ))
            .overlay {
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .frame(width: cornerRadius, height: cornerRadius)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topTrailingRadius: cornerRadius))
                        .foregroundStyle(.white)
                        .frame(
                            width: cornerRadius + spacing,
                            height: cornerRadius + spacing
                        )
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: -cornerRadius - spacing + 0.5, y: -0.5)
            }
            .overlay {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: cornerRadius, height: cornerRadius)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topLeadingRadius: cornerRadius))
                        .foregroundStyle(.white)
                        .frame(
                            width: cornerRadius + spacing,
                            height: cornerRadius + spacing
                        )
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: cornerRadius + spacing - 0.5, y: -0.5)
            }
    }
}

/// Blurred inner edge ring with a gentle ambient breathing.
///
/// Strokes the notch's rounded shape and blurs it; the parent's `.mask` clips
/// the outward spread so only an inner-edge glow remains. A vertical fade keeps
/// it on the lower half (vanishing by the middle), and the opacity oscillates
/// slowly to read like a mood light. Owns its own `@State` so the breathing
/// (re)starts whenever the glow appears.
private struct NotchGlowRing: View {
    let color: Color
    let cornerRadius: CGFloat
    let notchSize: CGSize

    @State private var breathe = false

    var body: some View {
        UnevenRoundedRectangle(
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius
        )
        .stroke(
            color.opacity(NotchConstants.glowRingOpacity),
            lineWidth: NotchConstants.glowRingWidth
        )
        .frame(width: notchSize.width, height: notchSize.height)
        .blur(radius: NotchConstants.glowRingBlur)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 1.0 - NotchConstants.glowRingCoverage),
                    .init(color: .black, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .opacity(breathe ? NotchConstants.glowPulseMax : NotchConstants.glowPulseMin)
        .animation(
            .easeInOut(duration: NotchConstants.glowPulseDuration).repeatForever(autoreverses: true),
            value: breathe
        )
        .onAppear { breathe = true }
    }
}
