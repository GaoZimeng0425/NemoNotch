import AppKit
import Foundation
import SwiftUI

@MainActor
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
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    struct InstalledApp: Identifiable, Equatable {
        let id: String
        let name: String
        let bundleIdentifier: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.bundleIdentifier == rhs.bundleIdentifier
        }
    }

    var scannedApps: [InstalledApp] = []
    var scanSearchText: String = "" {
        didSet { filterScannedApps() }
    }
    var filteredScannedApps: [InstalledApp] = []

    func scanInstalledApps() {
        let dirs = [
            "/Applications",
            NSSearchPathForDirectoriesInDomains(.applicationDirectory, .userDomainMask, true).first ?? ""
        ]

        var seen = Set<String>()
        var results: [InstalledApp] = []

        for dir in dirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      seen.insert(bundleID).inserted else { continue }

                let name = (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent

                results.append(InstalledApp(id: bundleID, name: name, bundleIdentifier: bundleID))
            }
        }

        results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        scannedApps = results
        filterScannedApps()
    }

    private func filterScannedApps() {
        if scanSearchText.isEmpty {
            filteredScannedApps = scannedApps
        } else {
            filteredScannedApps = scannedApps.filter {
                $0.name.localizedCaseInsensitiveContains(scanSearchText)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(scanSearchText)
            }
        }
    }

    func toggleInstalledApp(_ app: InstalledApp) {
        if apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        } else {
            apps.append(AppItem(id: app.bundleIdentifier, name: app.name, bundleIdentifier: app.bundleIdentifier))
        }
        settings.launcherApps = apps
        filterApps()
    }

    func moveApp(from source: IndexSet, to destination: Int) {
        apps.move(fromOffsets: source, toOffset: destination)
        settings.launcherApps = apps
        filterApps()
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
