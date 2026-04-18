import AppKit
import Foundation

@Observable
final class LauncherService {
    var apps: [AppItem]
    var filteredApps: [AppItem]
    var searchText: String = "" {
        didSet { filterApps() }
    }

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        self.apps = settings.launcherApps
        self.filteredApps = settings.launcherApps
        loadIcons()
    }

    func launchApp(at index: Int) {
        guard index < filteredApps.count else { return }
        let app = filteredApps[index]
        NSWorkspace.shared.launchApplication(withBundleIdentifier: app.bundleIdentifier, options: [], additionalEventParamDescriptor: nil, launchIdentifier: nil)
    }

    func addApp(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let app = AppItem(id: bundleIdentifier, name: name, bundleIdentifier: bundleIdentifier, iconData: nil)
        if !apps.contains(app) {
            apps.append(app)
            settings.launcherApps = apps
            loadIcon(for: app)
            filterApps()
        }
    }

    func removeApp(at index: Int) {
        guard index < apps.count else { return }
        apps.remove(at: index)
        settings.launcherApps = apps
        filterApps()
    }

    private func filterApps() {
        if searchText.isEmpty {
            filteredApps = apps
        } else {
            filteredApps = apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private func loadIcons() {
        for i in apps.indices {
            loadIcon(for: apps[i])
        }
    }

    private func loadIcon(for app: AppItem) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        if let tiffData = icon.tiffRepresentation {
            if let idx = apps.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                apps[idx].iconData = tiffData
                settings.launcherApps = apps
                filterApps()
            }
        }
    }
}
