import SwiftUI

/// Full-screen neon edge glow wrapping all four screen edges. Built from
/// stacked **additive** (`.screen`) strokes — a wide soft bloom, a tighter
/// saturated halo, and a thin near-white hot core — so the rim reads as
/// emitted light (a neon tube) rather than a painted border. Stacking
/// `.screen` layers brightens toward the core, giving the white-hot center
/// and colored falloff of real neon.
/// Overall opacity is driven by `service.flashLevel` (0...1, animated by the
/// service through the double-pulse curve). Purely visual — never intercepts events.
struct CompletionFlashView: View {
    let service: CompletionFlashService
    /// Only one screen renders the toast (the built-in/primary display) so a
    /// multi-monitor setup doesn't show a duplicate capsule per screen. The
    /// edge glow still flashes every screen.
    var showsToast: Bool = true

    /// Warm near-white center — the "hot" core of the neon tube.
    private static let core = Color(red: 1.0, green: 0.93, blue: 0.82)

    var body: some View {
        // 承载窗口在 makeWindow 里 orderFrontRegardless 之后从不 orderOut,
        // 所以 flashLevel 为 0 时这个全屏层依然可见、依然参与合成。
        // `.idle` 命中就是"没有任何东西要显示却仍在重绘"的那部分。
        let _ = PerfProbe.hit(
            service.flashLevel == 0 && !service.toastVisible
                ? "CompletionFlashView.body.idle(全屏窗口常驻可见但无内容)"
                : "CompletionFlashView.body.active"
        )
        ZStack {
            glow
                .opacity(NotchConstants.completionGlowOpacity * service.flashLevel)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            if showsToast {
                toast
            }
        }
        .ignoresSafeArea()
    }

    /// The unified completion capsule, horizontally centered with its vertical
    /// center at `completionToastBottomFraction` of the screen height up from
    /// the bottom edge. Fades/slides in on `service.toastVisible`.
    private var toast: some View {
        GeometryReader { geo in
            if service.toastVisible, !service.toastItems.isEmpty {
                CompletionToastView(items: service.toastItems)
                    .position(
                        x: geo.size.width / 2,
                        y: geo.size.height * (1 - NotchConstants.completionToastBottomFraction)
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .allowsHitTesting(false)
        .animation(
            .spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08),
            value: service.toastVisible
        )
    }

    private var glow: some View {
        ZStack {
            // Wide ambient bloom — the glow spilling softly inward from the edge.
            edge(
                width: NotchConstants.completionGlowWidth,
                blur: NotchConstants.completionGlowBlur,
                color: NotchTheme.accent,
                opacity: 0.5
            )
            // Mid halo — tighter and brighter, saturates the rim.
            edge(
                width: NotchConstants.completionGlowWidth * 0.5,
                blur: NotchConstants.completionGlowBlur * 0.6,
                color: NotchTheme.accent,
                opacity: 0.85
            )
            // Inner rim — hotter orange hugging the very edge.
            edge(
                width: NotchConstants.completionGlowEdgeWidth * 2,
                blur: NotchConstants.completionGlowEdgeWidth,
                color: NotchTheme.accentHot,
                opacity: 0.95
            )
            // Hot core — thin near-white line, lightly blurred so it glows
            // instead of reading as a hard frame.
            edge(
                width: NotchConstants.completionGlowEdgeWidth,
                blur: NotchConstants.completionGlowEdgeWidth * 0.45,
                color: Self.core,
                opacity: 1
            )
        }
    }

    /// One additive edge stroke: a blurred rectangle border, `.screen`-blended
    /// so stacked layers brighten toward the core like a real neon tube.
    private func edge(width: CGFloat, blur: CGFloat, color: Color, opacity: Double) -> some View {
        Rectangle()
            .strokeBorder(color, lineWidth: width)
            .blur(radius: blur)
            .opacity(opacity)
            .blendMode(.screen)
    }
}
