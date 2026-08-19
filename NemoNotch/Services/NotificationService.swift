import AppKit
import Foundation

struct DockBadge: Equatable {
    let bundleID: String
    let count: Int
    let icon: NSImage
}

@MainActor
@Observable
final class NotificationService {
    var badges: [String: DockBadge] = [:]
    var isAXTrusted: Bool = AXIsProcessTrusted()

    private var monitoredApps: [String]
    private var pollTimer: Timer?
    private var iconCache: [String: NSImage] = [:]
    /// 上次写进日志的 AX 授权状态；`nil` 表示还没记过。
    private var loggedAXTrusted: Bool?

    init(monitoredApps: [String] = []) {
        self.monitoredApps = monitoredApps
        syncPollingState()
    }

    func updateMonitoredApps(_ apps: [String]) {
        monitoredApps = apps
        // Remove badge entries for apps no longer monitored
        let appSet = Set(apps)
        for bundleID in badges.keys where !appSet.contains(bundleID) {
            badges.removeValue(forKey: bundleID)
        }
        iconCache = iconCache.filter { appSet.contains($0.key) }
        syncPollingState()
    }

    /// Start the poll timer iff there's something to poll. With an empty
    /// monitored-apps list, pollDock exits immediately — so running the timer
    /// just wakes the main run loop for nothing.
    private func syncPollingState() {
        if monitoredApps.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
            badges.removeAll()
        } else {
            startPolling()
            pollDock()
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    deinit {
        MainActor.assumeIsolated {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Helpers

    /// Strip invisible Unicode format/control characters (e.g. U+200E LEFT-TO-RIGHT MARK)
    /// so that app names like "WhatsApp" (with embedded LRM) match their Dock tile titles.
    private func normalizeName(_ name: String) -> String {
        name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && !($0.properties.generalCategory == .format)
        }.map(String.init).joined()
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                PerfProbe.hit("NotificationService.pollTick@2s")
                self?.pollDock()
            }
        }
    }

    /// 只在授权状态**变化**时记一条。此前每轮轮询（2s）都写一条 "AX not
    /// trusted"，未授权时它占到日志总量的 96%，4 小时就把 1MB 的文件写满，
    /// 把真正有用的记录挤出了 7 个文件的保留窗口。
    private func logAXStateIfChanged(_ trusted: Bool) {
        guard loggedAXTrusted != trusted else { return }
        loggedAXTrusted = trusted
        if trusted {
            LogService.info("AX authorized — Dock badge polling active", category: "Notification")
        } else {
            LogService.warn(
                "AX not trusted — Dock badge polling inactive "
                    + "(System Settings → Privacy & Security → Accessibility)",
                category: "Notification"
            )
        }
    }

    private func pollDock() {
        let probe = PerfProbe.begin()
        defer { PerfProbe.end("NotificationService.pollDock@2s", probe) }
        isAXTrusted = AXIsProcessTrusted()
        guard !monitoredApps.isEmpty else { return }

        logAXStateIfChanged(isAXTrusted)
        guard isAXTrusted else { return }

        // Get Dock PID
        guard let dockPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).last?.processIdentifier else {
            LogService.warn("NotificationService: Dock not found", category: "Notification")
            return
        }

        let dockApp = AXUIElementCreateApplication(dockPID)
        // AX 是跨进程 IPC：这次递归遍历的每个元素都是一次往返，
        // 每 2s 全量重扫 Dock 的成本在这里量化。
        let axProbe = PerfProbe.begin()
        let allElements = getSubElements(root: dockApp)
        PerfProbe.end("NotificationService.getSubElements(Dock AX 全量遍历)", axProbe)
        PerfProbe.hit("NotificationService.axElementsVisited", count: allElements.count)
        LogService.debug(
            "NotificationService: found \(allElements.count) AX elements in Dock",
            category: "Notification"
        )

        // Build a map: normalized localizedName -> bundleID for monitored apps
        var nameToBundleID: [String: String] = [:]
        for bundleID in monitoredApps {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let name = app.localizedName {
                let normalized = normalizeName(name)
                nameToBundleID[normalized] = bundleID
                LogService.debug(
                    "NotificationService: mapped \"\(normalized)\" (from \"\(name)\") -> \(bundleID)",
                    category: "Notification"
                )
            } else {
                LogService.debug(
                    "NotificationService: \(bundleID) not running or no localizedName",
                    category: "Notification"
                )
            }
        }

        // If no monitored apps are running, clear stale entries
        guard !nameToBundleID.isEmpty else {
            if !badges.isEmpty {
                badges = [:]
            }
            return
        }

        // Match dock elements by title and read badges inline.
        // Some apps (e.g. WhatsApp) have duplicate Dock tiles after normalization;
        // prefer the tile that actually has a badge.
        var updatedBadges: [String: DockBadge] = [:]
        for element in allElements {
            var title: AnyObject?
            let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            guard err == .success, let titleStr = title as? String else { continue }
            let normalized = normalizeName(titleStr)
            guard let bundleID = nameToBundleID[normalized] else { continue }

            var statusLabel: AnyObject?
            AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &statusLabel)
            let label = statusLabel as? String ?? ""
            LogService.debug(
                "NotificationService: matched tile \"\(titleStr)\" (normalized: \"\(normalized)\") -> \(bundleID), statusLabel=\"\(label)\"",
                category: "Notification"
            )

            guard let count = Self.parseBadgeCount(label) else {
                continue
            }
            let icon = appIcon(for: bundleID)
            updatedBadges[bundleID] = DockBadge(bundleID: bundleID, count: count, icon: icon)
        }

        LogService.debug(
            "NotificationService: final badges = \(updatedBadges.mapValues { $0.count })",
            category: "Notification"
        )
        badges = updatedBadges
    }

    // MARK: - Badge Parsing

    /// Parse a Dock badge label into an integer count.
    /// - "3" -> 3, "12" -> 12, "•" -> 0 (dot indicator), "" or nil -> nil (no badge)
    nonisolated static func parseBadgeCount(_ label: String) -> Int? {
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
        if let cached = iconCache[bundleID] { return cached }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            iconCache[bundleID] = icon
            return icon
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
            root, "AXChildren" as CFString, 0, count, &children
        )
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
