import KeyboardShortcuts
import SwiftUI

struct OpenNotchSubmenu: View {
    let coordinator: NotchCoordinator?
    let appSettings: AppSettings?

    var body: some View {
        Menu("menu.open_notch_submenu") {
            ForEach(Tab.sorted(enabledTabs), id: \.self) { tab in
                Button(action: { coordinator?.notchOpen(tab: tab) }) {
                    Text(menuLabel(for: tab))
                }
            }
        }
    }

    private var enabledTabs: Set<Tab> {
        appSettings?.enabledTabs ?? Set(Tab.allCases)
    }

    private func menuLabel(for tab: Tab) -> String {
        let title = tab.title
        let hint = KeyboardShortcuts.getShortcut(for: tab.hotkeyName)?.description ?? ""
        if hint.isEmpty { return title }
        return "\(title)  \(hint)"
    }
}
