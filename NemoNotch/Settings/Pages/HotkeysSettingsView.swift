import KeyboardShortcuts
import SwiftUI

struct HotkeysSettingsView: View {
    var body: some View {
        Form {
            Section("settings.hotkeys.notch") {
                KeyboardShortcuts.Recorder("settings.hotkeys.toggle_notch", name: .toggleNotch)
            }
            Section("settings.hotkeys.tabs") {
                KeyboardShortcuts.Recorder("models.tab.overview", name: .openOverview)
                KeyboardShortcuts.Recorder("models.tab.ai", name: .openAI)
            }
        }
        .formStyle(.grouped)
    }
}
