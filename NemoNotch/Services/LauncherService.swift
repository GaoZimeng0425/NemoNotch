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
    }

    func icon(for app: AppItem) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func launchApp(at index: Int) {
        guard index < filteredApps.count else { return }
        let app = filteredApps[index]
        NSWorkspace.shared.launchApplication(withBundleIdentifier: app.bundleIdentifier, options: [], additionalEventParamDescriptor: nil, launchIdentifier: nil)
    }

    func addApp(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let app = AppItem(id: bundleIdentifier, name: name, bundleIdentifier: bundleIdentifier)
        if !apps.contains(app) {
            apps.append(app)
            settings.launcherApps = apps
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
}
