import SwiftUI

struct AppSection: View {
    let onOpenSettings: () -> Void

    var body: some View {
        Button("menu.preferences") {
            onOpenSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("menu.about") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Button("menu.quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
