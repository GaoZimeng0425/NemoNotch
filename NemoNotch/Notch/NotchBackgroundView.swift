import SwiftUI

struct NotchBackgroundView: View {
    let status: NotchCoordinator.Status
    let notchSize: CGSize
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
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

    /// The shell is one `NotchShape`: the body is `notchSize.width` wide
    /// (opened: the fixed panel width, closed: the measured badge-row width)
    /// and the flares extend the top edge by `topCornerRadius` per side. The
    /// same shape clips the fills and sizes the glow ring, so the silhouette
    /// has exactly one definition.
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
                        topCornerRadius: topCornerRadius,
                        bottomCornerRadius: bottomCornerRadius,
                        notchSize: notchSize
                    )
                    .blendMode(.screen)
                }
            }
        }
        .frame(width: notchSize.width + topCornerRadius * 2, height: notchSize.height)
        .clipShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius))
        .shadow(
            color: .black.opacity(showShadow ? NotchConstants.openedShadowOpacity : 0),
            radius: NotchConstants.openedShadowRadius
        )
    }
}

/// Blurred inner edge ring with a gentle ambient breathing.
///
/// Strokes the same `NotchShape` the shell is clipped by, so the glow hugs
/// the exact silhouette (flares included) instead of an approximation; the
/// parent's clip shape removes the outward blur spread so only an inner-edge
/// glow remains. A vertical fade keeps it on the lower half (vanishing by the
/// middle), and the opacity oscillates slowly to read like a mood light.
/// Owns its own `@State` so the breathing (re)starts whenever the glow
/// appears.
private struct NotchGlowRing: View {
    let color: Color
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let notchSize: CGSize

    @State private var breathe = false

    var body: some View {
        NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
            .stroke(
                color.opacity(NotchConstants.glowRingOpacity),
                lineWidth: NotchConstants.glowRingWidth
            )
            .frame(width: notchSize.width + topCornerRadius * 2, height: notchSize.height)
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
