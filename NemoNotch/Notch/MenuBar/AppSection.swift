import SwiftUI

struct AppSection: View {
    var body: some View {
        SettingsLink {
            Text("menu.preferences")
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
