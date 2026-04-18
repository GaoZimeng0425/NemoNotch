import AppKit
import SwiftUI

final class SettingsWindow: NSWindow {
    init(settingsView: SettingsView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "NemoNotch 偏好设置"
        isReleasedWhenClosed = false
        center()

        let hosting = NSHostingController(rootView: settingsView.frame(width: 450, height: 400))
        contentView = hosting.view
    }
}
