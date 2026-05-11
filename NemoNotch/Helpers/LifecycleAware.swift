import SwiftUI

/// Services that should pause work when their consumer view is offscreen
/// implement this. Calls are idempotent — `setActive(true)` while already
/// active is a no-op; same for `setActive(false)`.
@MainActor
protocol LifecycleAware: AnyObject {
    func setActive(_ active: Bool)
}

extension View {
    /// Activate the given service on appear, deactivate on disappear.
    /// Use on the leaf view that consumes the service, not on a container —
    /// that way the service only runs while its UI is visible.
    func activates(_ service: any LifecycleAware) -> some View {
        self
            .onAppear { service.setActive(true) }
            .onDisappear { service.setActive(false) }
    }
}
