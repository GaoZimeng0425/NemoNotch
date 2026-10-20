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

    /// 首帧挂载闸门,见 `toast` 的注释 —— 重建窗口的入场动画依赖它。
    @State private var toastMounted = false

    /// Warm near-white center — the "hot" core of the neon tube.
    private static let core = Color(red: 1.0, green: 0.93, blue: 0.82)

    var body: some View {
        // 闲置时窗口已 orderOut,每次闪光重建;`.idle` 只剩淡出尾段 ——
        // overlay 还在、glow 与 toast 都已归零的那几帧仍在重绘的部分。
        let _ = PerfProbe.hit(
            service.flashLevel == 0 && !service.toastVisible
                ? "CompletionFlashView.body.idle(overlay 仍在、内容已归零的淡出尾段)"
                : "CompletionFlashView.body.active"
        )
        ZStack {
            glow
                .opacity(NotchConstants.completionGlowOpacity * service.flashLevel)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            // Every screen: the toast is read where the user is looking,
            // like the glow it comes with.
            toast
        }
        .ignoresSafeArea()
    }

    /// The unified completion capsule, horizontally centered with its vertical
    /// center at `completionToastBottomFraction` of the screen height up from
    /// the bottom edge. Fades/slides in on `service.toastVisible`.
    ///
    /// `mounted` 延迟一帧才放行 toast:闪光窗口现在是**闪光时重建**的(具文窗口
    /// 修复,见 CompletionFlashWindow.applyOverlayVisibility),全新 SwiftUI 树挂载
    /// 时 `toastVisible` 往往已是 true —— 直接首渲染终态,入场弹簧/transition 不会
    /// 播放。先以"无 toast"状态挂载、下一帧翻 `mounted`,插入动画两条路径
    /// (新建窗/存活窗翻转)都照常播放。
    private var toast: some View {
        GeometryReader { geo in
            if toastMounted, service.toastVisible, !service.toastItems.isEmpty {
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
        .animation(
            .spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08),
            value: toastMounted
        )
        .onAppear {
            guard !toastMounted else { return }
            DispatchQueue.main.async { toastMounted = true }
        }
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
