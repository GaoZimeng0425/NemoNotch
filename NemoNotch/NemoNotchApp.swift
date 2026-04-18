import SwiftUI

@main
struct NemoNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("退出 NemoNotch") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "menubar.rectangle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: NotchCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator = NotchCoordinator()
    }
}
