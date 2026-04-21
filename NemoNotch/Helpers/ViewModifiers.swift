import SwiftUI

struct PulseModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0.4 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: isActive
            )
    }
}

struct GlowPulseModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .opacity(0.6)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: true)
    }
}
