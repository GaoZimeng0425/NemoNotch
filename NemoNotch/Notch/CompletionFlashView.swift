import SwiftUI

/// Full-screen accent glow hugging all four screen edges, fading inward.
/// Opacity is driven by `service.flashActive` (animated by the service via
/// `withAnimation`). Purely visual — never intercepts events.
struct CompletionFlashView: View {
    let service: CompletionFlashService

    var body: some View {
        ZStack {
            edgeBand(.top)
            edgeBand(.bottom)
            edgeBand(.leading)
            edgeBand(.trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: NotchConstants.completionGlowBlur)
        .blendMode(.screen)
        .opacity(service.flashActive ? NotchConstants.completionGlowOpacity : 0)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// One edge's accent→clear gradient, pinned to that edge.
    @ViewBuilder
    private func edgeBand(_ edge: Edge) -> some View {
        let accent = NotchTheme.accent
        let band = NotchConstants.completionGlowWidth
        switch edge {
        case .top:
            LinearGradient(colors: [accent, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: band)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .bottom:
            LinearGradient(colors: [accent, .clear], startPoint: .bottom, endPoint: .top)
                .frame(height: band)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case .leading:
            LinearGradient(colors: [accent, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .trailing:
            LinearGradient(colors: [accent, .clear], startPoint: .trailing, endPoint: .leading)
                .frame(width: band)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}
