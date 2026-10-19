import SwiftUI

struct AppSection: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("menu.preferences") {
            SettingsWindow.open(with: openWindow)
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
