import SwiftUI

/// Full-screen accent glow wrapping all four screen edges. A crisp solid line
/// hugs the very rim while a tighter blurred halo fades inward — same family
/// as the notch's `NotchGlowRing`, but a full-screen rectangle frame.
/// Opacity is driven by `service.flashLevel` (0...1, animated by the service
/// through the double-pulse curve). Purely visual — never intercepts events.
struct CompletionFlashView: View {
    let service: CompletionFlashService

    var body: some View {
        ZStack {
            // Soft halo — the glow spread, kept tight so the rim stays defined.
            // `.screen` blends it into the desktop so it reads as light/glow.
            Rectangle()
                .strokeBorder(NotchTheme.accent, lineWidth: NotchConstants.completionGlowWidth)
                .blur(radius: NotchConstants.completionGlowBlur)
                .blendMode(.screen)

            // Crisp solid line hugging the very edge. Normal blend (NOT .screen)
            // so the rim stays a solid, saturated accent instead of washing out.
            Rectangle()
                .strokeBorder(NotchTheme.accent, lineWidth: NotchConstants.completionGlowEdgeWidth)
        }
        .opacity(NotchConstants.completionGlowOpacity * service.flashLevel)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
