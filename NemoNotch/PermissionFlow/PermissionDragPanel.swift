import AppKit

/// The floating guide panel that parks beside System Settings.
///
/// Two properties matter most:
/// - `.nonactivatingPanel` — the panel never steals focus, so the user can keep
///   clicking through the privacy list behind it.
/// - `.floating` level — above ordinary windows (System Settings is level 0)
///   while staying below the menu bar and the app's own notch overlays.
final class PermissionDragPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Matches NotchWindow: the window server's default order-front "zoom
        // pop" would slide a freshly shown panel a few points out of place.
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ESC dismisses the guide. The panel has no title bar, so without this a
    /// user who changes their mind has to hunt for the close button.
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
