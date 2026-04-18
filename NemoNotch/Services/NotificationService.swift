import AppKit
import Foundation

struct BadgeItem: Equatable {
    let bundleID: String
    let count: Int
    let icon: NSImage
}

@Observable
final class NotificationService {
    var badges: [String: BadgeItem] = [:]

    private var monitoredApps: [String]
    private var pollTimer: Timer?
    // Cache dock element lookups: bundleID -> matching AXUIElement in Dock
    private var dockElements: [String: AXUIElement] = [:]

    init(monitoredApps: [String] = []) {
        self.monitoredApps = monitoredApps
        startPolling()
    }

    func updateMonitoredApps(_ apps: [String]) {
        monitoredApps = apps
        // Remove badge entries for apps no longer monitored
        let appSet = Set(apps)
        for bundleID in badges.keys where !appSet.contains(bundleID) {
            badges.removeValue(forKey: bundleID)
        }
        // Clear cached elements so they get re-resolved
        dockElements = dockElements.filter { appSet.contains($0.key) }
        pollDock()
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollDock()
        }
    }

    private func pollDock() {
        guard !monitoredApps.isEmpty else { return }

        // Get Dock PID
        guard let dockPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).last?.processIdentifier else {
            return
        }

        let dockApp = AXUIElementCreateApplication(dockPID)
        let allElements = getSubElements(root: dockApp)

        // Build a map: localizedName -> bundleID for monitored apps
        var nameToBundleID: [String: String] = [:]
        for bundleID in monitoredApps {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let name = app.localizedName {
                nameToBundleID[name] = bundleID
            }
        }

        // If no monitored apps are running, clear stale entries
        guard !nameToBundleID.isEmpty else {
            if !badges.isEmpty {
                badges = [:]
            }
            return
        }

        // Match dock elements by title (AXTitle == app localizedName)
        var newElements: [String: AXUIElement] = [:]
        for element in allElements {
            var title: AnyObject?
            let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            guard err == .success, let titleStr = title as? String, let bundleID = nameToBundleID[titleStr] else {
                continue
            }
            newElements[bundleID] = element
        }

        dockElements = newElements

        // Read badge counts from matched elements
        var updatedBadges: [String: BadgeItem] = [:]
        for (bundleID, element) in dockElements {
            var statusLabel: AnyObject?
            AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &statusLabel)

            let label = statusLabel as? String ?? ""
            guard let count = parseBadgeCount(label) else {
                // Empty label means no badge — skip
                continue
            }
            let icon = appIcon(for: bundleID)
            updatedBadges[bundleID] = BadgeItem(bundleID: bundleID, count: count, icon: icon)
        }

        badges = updatedBadges
    }

    // MARK: - Badge Parsing

    /// Parse a Dock badge label into an integer count.
    /// - "3" -> 3, "12" -> 12, "•" -> 0 (dot indicator), "" or nil -> nil (no badge)
    private func parseBadgeCount(_ label: String) -> Int? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        // Dot indicator used by some apps (e.g. App Store)
        if trimmed == "•" || trimmed == "…" {
            return 0
        }
        if let count = Int(trimmed) {
            return count
        }
        // Non-numeric, non-dot label — treat as a single unread indicator
        return 0
    }

    // MARK: - App Icon

    private func appIcon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage()
    }

    // MARK: - AX Tree Traversal

    /// Recursively collect all descendant AXUIElements.
    private func getSubElements(root: AXUIElement) -> [AXUIElement] {
        var count: CFIndex = 0
        let err = AXUIElementGetAttributeValueCount(root, "AXChildren" as CFString, &count)
        guard err == .success, count > 0 else { return [] }

        var children: CFArray?
        let copyErr = AXUIElementCopyAttributeValues(
            root, "AXChildren" as CFString, 0, count, &children)
        guard copyErr == .success, let elements = children as? [AXUIElement] else {
            return []
        }

        var result: [AXUIElement] = []
        result.append(contentsOf: elements)
        for element in elements {
            result.append(contentsOf: getSubElements(root: element))
        }
        return result
    }
}
