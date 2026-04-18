# Notification Badge Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Show Dock badge unread counts (Slack, WeChat, etc.) as icons on the notch sides, using Accessibility API polling.

**Architecture:** New `NotificationService` polls Dock icon `AXStatusLabel` every 2s for user-configured apps. Results feed into `CompactBadge` as the highest-priority badge. Settings tab lets users add/remove monitored apps.

**Tech Stack:** Swift, Accessibility API (AXUIElement), SwiftUI, UserDefaults

---

### Task 1: Create NotificationService

**Files:**
- Create: `NemoNotch/Services/NotificationService.swift`

**Step 1: Create the service file**

```swift
import AppKit
import Foundation

@Observable
final class NotificationService {
    struct BadgeItem {
        let bundleID: String
        let count: Int  // 0 = dot, >0 = number
        let icon: NSImage
    }

    var badges: [String: BadgeItem] = [:]

    private var timer: Timer?
    private var monitoredApps: [String]  // bundle IDs
    private var dockElements: [String: AXUIElement] = [:]  // app name → element

    init(monitoredApps: [String]) {
        self.monitoredApps = monitoredApps
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    func updateMonitoredApps(_ apps: [String]) {
        monitoredApps = apps
        dockElements.removeAll()
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollBadges()
        }
        timer?.fire()
    }

    private func pollBadges() {
        reloadDockElements()
        var updated: [String: BadgeItem] = [:]
        for bundleID in monitoredApps {
            guard let element = dockElements[bundleID] else { continue }
            var statusLabel: AnyObject?
            AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &statusLabel)
            guard let label = statusLabel as? String, !label.isEmpty else { continue }
            let count = parseBadgeCount(label)
            let icon = appIcon(for: bundleID)
            updated[bundleID] = BadgeItem(bundleID: bundleID, count: count, icon: icon)
        }
        badges = updated
    }

    private func parseBadgeCount(_ label: String) -> Int {
        if let num = Int(label) { return num }
        return 0  // dot or other non-numeric badge
    }

    private func appIcon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let icon = NSWorkspace.shared.icon(forFile: url.path) {
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
        return NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    }

    private func reloadDockElements() {
        dockElements.removeAll()
        guard let dockPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).last?.processIdentifier else { return }

        let dock = AXUIElementCreateApplication(dockPID)
        guard let children = getSubElements(of: dock) else { return }

        for child in children {
            var title: AnyObject?
            AXUIElementCopyAttributeValue(child, "AXTitle" as CFString, &title)
            guard let appName = title as? String else { continue }

            // Match appName to a monitored bundleID via NSRunningApplication
            for bundleID in monitoredApps {
                if dockElements[bundleID] != nil { continue }
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .contains(where: { $0.localizedName == appName }) {
                    dockElements[bundleID] = child
                }
            }
        }
    }

    private func getSubElements(of element: AXUIElement) -> [AXUIElement]? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, "AXChildren" as CFString, &count) == .success else { return nil }
        var children: CFArray?
        guard AXUIElementCopyAttributeValues(element, "AXChildren" as CFString, 0, count, &children) == .success else { return nil }
        return children as? [AXUIElement]
    }
}
```

**Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (no references to it yet, so no errors)

**Step 3: Commit**

```bash
git add NemoNotch/Services/NotificationService.swift
git commit -m "feat: add NotificationService with Dock AX polling"
```

---

### Task 2: Add monitoredApps to AppSettings

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift:16-22` (add new property)

**Step 1: Add the property**

Add after `launcherApps` (line 22):

```swift
var monitoredApps: [String] {
    didSet {
        UserDefaults.standard.set(monitoredApps, forKey: "monitoredApps")
    }
}
```

In `init()` (after line 37), add:

```swift
self.monitoredApps = UserDefaults.standard.stringArray(forKey: "monitoredApps") ?? []
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Models/AppSettings.swift
git commit -m "feat: add monitoredApps to AppSettings"
```

---

### Task 3: Wire NotificationService into the app

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift:68-108` (AppDelegate)

**Step 1: Add property and create service**

In `AppDelegate`, add property:

```swift
private(set) var notificationService: NotificationService?
```

In `applicationDidFinishLaunching`, after `self.launcherService = launcher` (line 96), add:

```swift
let notification = NotificationService(monitoredApps: settings.monitoredApps)
self.notificationService = notification
```

**Step 2: Pass to NotchCoordinator**

Update `NotchCoordinator.init` to accept `notificationService` parameter. Store it as a property.

**Step 3: Update NotchCoordinator init call**

```swift
let notchCoordinator = NotchCoordinator(
    mediaService: media,
    calendarService: calendar,
    claudeCodeService: claude,
    launcherService: launcher,
    notificationService: notification,
    appSettings: settings
)
```

**Step 4: Update NotchView to receive notificationService**

Add `let notificationService: NotificationService` to `NotchView`. Pass it through from `NotchCoordinator`.

**Step 5: Build to verify**

**Step 6: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift NemoNotch/Notch/NotchCoordinator.swift NemoNotch/Notch/NotchView.swift
git commit -m "feat: wire NotificationService into app and coordinator"
```

---

### Task 4: Update CompactBadge with notification priority

**Files:**
- Modify: `NemoNotch/Notch/CompactBadge.swift`
- Modify: `NemoNotch/Notch/NotchView.swift`

**Step 1: Add notification case to BadgeInfo**

In `CompactBadge.swift`, add `.notification(String)` case to `BadgeInfo` enum and add `let notificationService: NotificationService` property.

**Step 2: Update activeBadge priority**

```swift
private var activeBadge: BadgeInfo? {
    // 1. Notification (highest)
    if let top = notificationService.badges.values.max(by: { $0.count < $1.count }) {
        return .notification(top.bundleID)
    }
    // 2. Claude Code
    if claudeService.activeSession?.status == .working {
        return .claude
    }
    // 3. Media
    if mediaService.playbackState.isPlaying {
        return .media
    }
    // 4. Calendar
    if let next = calendarService.nextEvent, !next.isPast {
        let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
        if minutes >= 0, minutes < 60 {
            return .calendar
        }
    }
    return nil
}
```

**Step 3: Add notification UI to leftIcon**

For `.notification(bundleID)` case:
- Show app icon (from `notificationService.badges[bundleID]?.icon`)
- Overlay a red circle with count on the bottom-right corner

**Step 4: Clicking notification badge opens the app**

```swift
private func openApp(_ bundleID: String) {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
```

**Step 5: Update hasActiveBadge in NotchView**

Add notification check to `hasActiveBadge`.

**Step 6: Pass notificationService to CompactBadge in NotchView.compactBadges**

**Step 7: Build and verify**

**Step 8: Commit**

```bash
git add NemoNotch/Notch/CompactBadge.swift NemoNotch/Notch/NotchView.swift
git commit -m "feat: notification badge in CompactBadge with top priority"
```

---

### Task 5: Add notification tab to Settings

**Files:**
- Modify: `NemoNotch/Settings/SettingsView.swift`
- Modify: `NemoNotch/NemoNotchApp.swift` (pass notificationService to SettingsView)

**Step 1: Add notificationService to SettingsView**

Add `let notificationService: NotificationService` and `let appSettings: AppSettings` (already have this).

**Step 2: Add notification tab to TabView**

```swift
notificationListView
    .tabItem { Label("通知", systemImage: "bell.badge") }
    .tag(3)
```

**Step 3: Build notificationListView**

- List showing monitored apps with icon, name, bundle ID
- "+" button opens NSOpenPanel filtered to .app
- On select, extract bundle ID from Info.plist and add to monitoredApps
- Swipe to delete removes from list
- Call `notificationService.updateMonitoredApps(appSettings.monitoredApps)` on changes

**Step 4: Update showSettings in NemoNotchApp.swift**

Pass `notificationService` to `SettingsView`.

**Step 5: Build and verify**

**Step 6: Commit**

```bash
git add NemoNotch/Settings/SettingsView.swift NemoNotch/NemoNotchApp.swift
git commit -m "feat: notification settings tab with add/remove apps"
```

---

### Task 6: Final integration and polish

**Step 1: Add animation for notification badges**

In `NotchView.compactBadges`, add:
```swift
.animation(.easeInOut(duration: 0.3), value: notificationService.badges)
```

**Step 2: Verify end-to-end**

1. Launch NemoNotch
2. Open Settings → Notification tab
3. Add Slack (or any running app with badge)
4. Verify badge appears on notch left side with correct count
5. Click badge → app opens
6. Remove app → badge disappears

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: polish notification badge animations"
```
