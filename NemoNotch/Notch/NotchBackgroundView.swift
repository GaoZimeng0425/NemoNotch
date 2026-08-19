import SwiftUI

struct NotchBackgroundView: View {
    let status: NotchCoordinator.Status
    let notchSize: CGSize
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let spacing: CGFloat
    var glow: NotchGlow = .none
    /// When true the shape fills its parent container's width (used by the
    /// collapsed state, where the shape sits as a `.background` behind the
    /// badge content and must match its content-driven width). When false the
    /// shape uses the fixed `notchSize.width` (opened state, content is pinned
    /// to a constant width).
    var flexibleWidth: Bool = false

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
                        cornerRadius: bottomCornerRadius,
                        notchSize: notchSize
                    )
                    .blendMode(.screen)
                }
            }
        }
        .mask(notchBackgroundMaskGroup)
        .frame(height: notchSize.height)
        .modifier(NotchShapeWidth(flexible: flexibleWidth, fixed: notchSize.width + topCornerRadius * 2))
        .shadow(
            color: .black.opacity(showShadow ? NotchConstants.openedShadowOpacity : 0),
            radius: NotchConstants.openedShadowRadius
        )
    }

    private var notchBackgroundMaskGroup: some View {
        Rectangle()
            .foregroundStyle(.black)
            .frame(height: notchSize.height)
            .modifier(NotchShapeWidth(flexible: flexibleWidth, fixed: notchSize.width))
            .clipShape(.rect(
                bottomLeadingRadius: bottomCornerRadius,
                bottomTrailingRadius: bottomCornerRadius
            ))
            .overlay {
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .frame(width: topCornerRadius, height: topCornerRadius)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topTrailingRadius: topCornerRadius))
                        .foregroundStyle(.white)
                        .frame(
                            width: topCornerRadius + spacing,
                            height: topCornerRadius + spacing
                        )
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: -topCornerRadius - spacing + 0.5, y: -0.5)
            }
            .overlay {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: topCornerRadius, height: topCornerRadius)
                        .foregroundStyle(.black)
                    Rectangle()
                        .clipShape(.rect(topLeadingRadius: topCornerRadius))
                        .foregroundStyle(.white)
                        .frame(
                            width: topCornerRadius + spacing,
                            height: topCornerRadius + spacing
                        )
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: topCornerRadius + spacing - 0.5, y: -0.5)
            }
    }
}

/// Applies a width constraint that's either flexible (fill the parent, used by
/// the collapsed content-driven shape as a `.background`) or fixed (the opened
/// shape's constant width). SwiftUI's `frame` overloads don't allow `width` and
/// `maxWidth` in the same call, so this branches between the two.
private struct NotchShapeWidth: ViewModifier {
    let flexible: Bool
    let fixed: CGFloat

    func body(content: Content) -> some View {
        if flexible {
            content.frame(maxWidth: .infinity)
        } else {
            content.frame(width: fixed)
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
