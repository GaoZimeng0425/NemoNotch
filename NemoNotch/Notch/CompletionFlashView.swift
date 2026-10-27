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

    /// Warm near-white center — the "hot" core of the neon tube.
    private static let core = Color(red: 1.0, green: 0.93, blue: 0.82)

    var body: some View {
        // 闲置时窗口已 orderOut,每次闪光重建;`.idle` 只剩淡出尾段 ——
        // overlay 还在、glow 已归零的那几帧仍在重绘的部分。
        let _ = PerfProbe.hit(
            service.flashLevel == 0
                ? "CompletionFlashView.body.idle(overlay 仍在、内容已归零的淡出尾段)"
                : "CompletionFlashView.body.active"
        )
        // The toast lives in its own clickable panel under the notch
        // (`CompletionToastWindowController`); this overlay is glow only.
        glow
            .opacity(NotchConstants.completionGlowOpacity * service.flashLevel)
            .allowsHitTesting(false)
            .ignoresSafeArea()
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
