import SwiftUI

/// The notch shell: one clip, everything inside. The material (gradients,
/// highlights, glow) fills the frame, the caller's content (panel + chin)
/// layers on top, and a single `NotchShape` clips the whole subtree — content
/// exceeding the silhouette is structurally impossible (boring.notch-style
/// `content.background(.black).mask { NotchShape() }`).
///
/// Layers that must render OUTSIDE the silhouette stay siblings of this view
/// in `NotchView`: the HUD (hangs below the notch), the transient capsules
/// (grow wider than the closed shell), and the collapsed badge row (the badge
/// row is the *source* of the closed body width — the shell is sized from its
/// measurement, so it cannot overflow by construction, and keeping it a
/// sibling avoids a parent-size-depends-on-child layout loop).
struct NotchBackgroundView<Content: View>: View {
    let status: NotchCoordinator.Status
    let notchSize: CGSize
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    var glow: NotchGlow = .none
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            material

            content()
        }
        .frame(width: notchSize.width + topCornerRadius * 2, height: notchSize.height)
        .clipShape(NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius))
        .shadow(
            color: .black.opacity(showShadow ? NotchConstants.openedShadowOpacity : 0),
            radius: NotchConstants.openedShadowRadius
        )
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

    /// Shell material — gradient base plus the opened-state highlights and
    /// the activity glow, all plain rectangles. The silhouette comes solely
    /// from the outer `.clipShape`; nothing here paints inside a path.
    ///
    /// `drawingGroup` flattens the `.screen` blend modes and wraps ONLY the
    /// material — the caller's content tree must never be rasterized into the
    /// group (it carries live SwiftUI animations).
    private var material: some View {
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
        .drawingGroup()
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
