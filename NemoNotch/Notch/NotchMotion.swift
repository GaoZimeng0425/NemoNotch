import SwiftUI

/// The notch's open/close choreography, in one place — the coordinator's
/// state change and the view's shell and content all read these, so they
/// can never run on different curves (they used to: interactiveSpring in
/// the coordinator, a bouncy spring on the shell, and the content mount in
/// a separate transaction a beat later).
///
/// Same recipe as the edge bar: the body moves on one critically damped
/// curve; content follows it in, a moment late and from close to its final
/// size (no 0.2× → 1× zoom of the whole panel), and leaves first and fast,
/// so the shell closes over nothing.
enum NotchMotion {
    static var open: Animation {
        .smooth(duration: NotchConstants.openSpringDuration)
    }

    static var close: Animation {
        .smooth(duration: NotchConstants.closeSpringDuration)
    }

    static func state(opened: Bool) -> Animation {
        opened ? open : close
    }

    /// Content waits this long into the opening: the shell has made room.
    static let contentInDelay: Double = 0.06
    static let contentInDuration: Double = 0.26
    static let contentOutDuration: Double = 0.1
    /// Content arrives from this scale (anchored at the top) and offset.
    static let contentInScale: CGFloat = 0.95
    static let contentInOffset: CGFloat = -8

    static var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: contentInScale, anchor: .top))
                .combined(with: .offset(y: contentInOffset))
                .animation(.smooth(duration: contentInDuration).delay(contentInDelay)),
            removal: .opacity
                .animation(.easeIn(duration: contentOutDuration))
        )
    }
}
