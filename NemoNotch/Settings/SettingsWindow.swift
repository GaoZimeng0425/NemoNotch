import AppKit
import SwiftUI

final class SettingsWindow<Content: View>: NSWindow {
    init(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "NemoNotch 偏好设置"
        isReleasedWhenClosed = false
        hasShadow = false
        center()

        let hosting = NSHostingController(rootView: rootView.frame(width: 450, height: 400))
        contentView = hosting.view
    }
}
