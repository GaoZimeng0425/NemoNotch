import SwiftUI

/// Full-screen accent glow wrapping all four screen edges. A crisp solid line
/// hugs the very rim while a tighter blurred halo fades inward — same family
/// as the notch's `NotchGlowRing`, but a full-screen rectangle frame.
/// Opacity is driven by `service.flashActive` (animated by the service via
/// `withAnimation`). Purely visual — never intercepts events.
struct CompletionFlashView: View {
    let service: CompletionFlashService

    var body: some View {
        ZStack {
            // Soft halo — the glow spread, kept tight so the rim stays defined.
            Rectangle()
                .strokeBorder(NotchTheme.accent, lineWidth: NotchConstants.completionGlowWidth)
                .blur(radius: NotchConstants.completionGlowBlur)

            // Crisp solid line hugging the very edge so the outermost rim reads solid.
            Rectangle()
                .strokeBorder(NotchTheme.accent, lineWidth: NotchConstants.completionGlowEdgeWidth)
        }
        .blendMode(.screen)
        .opacity(service.flashActive ? NotchConstants.completionGlowOpacity : 0)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
