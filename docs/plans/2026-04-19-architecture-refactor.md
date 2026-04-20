# Architecture Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Decouple services from views via @Environment, extract duplicated code, split fat files, and slim NotchCoordinator to a pure state machine.

**Architecture:** Services are `@Observable` objects registered in SwiftUI's environment via `.environment()`. Views declare only what they need via `@Environment(Service.self)`. NotchCoordinator receives a content closure in init — zero service references. Shared logic (tool styles, tab sorting, view modifiers, constants) extracted to dedicated helpers.

**Tech Stack:** Swift 5, SwiftUI, macOS (AppKit). No third-party dependencies. Xcode auto-discovers new files (no pbxproj editing needed).

---

### Task 1: Extract Constants

**Files:**
- Create: `NemoNotch/Helpers/Constants.swift`

**Step 1: Create Constants.swift**

```swift
import Foundation

enum NotchConstants {
    // Notch geometry
    static let defaultNotchWidth: CGFloat = 200
    static let defaultNotchHeight: CGFloat = 32
    static let openedWidth: CGFloat = 500
    static let openedHeight: CGFloat = 260
    static let hitboxPadding: CGFloat = 10
    static let closeHitboxInset: CGFloat = 20
    static let clickHitboxInset: CGFloat = 10

    // Badge
    static let badgePadding: CGFloat = 36
    static let badgeSpread: CGFloat = 14

    // Animation durations
    static let openSpringDuration: Double = 0.314
    static let closeSpringDuration: Double = 0.236
    static let badgeSpringDuration: Double = 0.35
    static let badgeSpringBounce: Double = 0.15

    // Hook server
    static let hookBasePort: UInt16 = 49200
    static let hookMaxPortAttempts: UInt16 = 10

    // Tab content
    static let tabContentHorizontalPadding: CGFloat = 20
    static let tabContentTopPadding: CGFloat = 8
    static let tabBarTopPadding: CGFloat = 10
    static let cornerRadiusClosed: CGFloat = 8
    static let cornerRadiusOpened: CGFloat = 24
    static let notchBackgroundSpacing: CGFloat = 16
}
```

**Step 2: Replace magic numbers in source files**

In `NemoNotch/Notch/NotchCoordinator.swift`:
- `hitboxPadding: CGFloat = 10` → `hitboxPadding: CGFloat = NotchConstants.hitboxPadding`
- `openedWidth: CGFloat = 500` → `openedWidth: CGFloat = NotchConstants.openedWidth`
- `openedHeight: CGFloat = 260` → `openedHeight: CGFloat = NotchConstants.openedHeight`
- `NSSize(width: 200, height: 32)` (two occurrences) → `NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight)`
- `.interactiveSpring(duration: 0.314)` → `.interactiveSpring(duration: NotchConstants.openSpringDuration)`
- `.spring(duration: 0.236)` → `.spring(duration: NotchConstants.closeSpringDuration)`
- `contentRect.insetBy(dx: -20, dy: -20)` → `contentRect.insetBy(dx: -NotchConstants.closeHitboxInset, dy: -NotchConstants.closeHitboxInset)`
- `contentRect.insetBy(dx: -10, dy: -10)` → `contentRect.insetBy(dx: -NotchConstants.clickHitboxInset, dy: -NotchConstants.clickHitboxInset)`

In `NemoNotch/Notch/NotchView.swift`:
- `badgePadding: CGFloat = 36` → `badgePadding: CGFloat = NotchConstants.badgePadding`
- `let spread: CGFloat = hasActiveBadge ? 14 : 0` → `let spread: CGFloat = hasActiveBadge ? NotchConstants.badgeSpread : 0`
- `CGSize(width: 500, height: 260)` → `CGSize(width: NotchConstants.openedWidth, height: NotchConstants.openedHeight)`
- `8` in `cornerRadius: 8` → `NotchConstants.cornerRadiusClosed`
- `24` in `cornerRadius: 24` → `NotchConstants.cornerRadiusOpened`
- `.interactiveSpring(duration: 0.314)` → `.interactiveSpring(duration: NotchConstants.openSpringDuration)`
- `.spring(duration: 0.35, bounce: 0.15)` (two occurrences) → `.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce)`
- `.easeInOut(duration: 0.3)` → `.easeInOut(duration: 0.3)` (leave this one — it's a generic fade duration)
- `padding(.top, hardwareNotchSize.height + 10)` → `padding(.top, hardwareNotchSize.height + NotchConstants.tabBarTopPadding)`
- `.padding(.top, 8)` → `.padding(.top, NotchConstants.tabContentTopPadding)`
- `.padding(.horizontal, 20)` → `.padding(.horizontal, NotchConstants.tabContentHorizontalPadding)`
- `16` in `NotchBackgroundView(... spacing: 16)` → `NotchConstants.notchBackgroundSpacing`

In `NemoNotch/Services/HookServer.swift`:
- `port: UInt16 = 49200` → `port: UInt16 = NotchConstants.hookBasePort`
- `maxPortAttempts: UInt16 = 10` → `maxPortAttempts: UInt16 = NotchConstants.hookMaxPortAttempts`

**Step 3: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add NemoNotch/Helpers/Constants.swift NemoNotch/Notch/NotchCoordinator.swift NemoNotch/Notch/NotchView.swift NemoNotch/Services/HookServer.swift
git commit -m "refactor: extract magic numbers into NotchConstants"
```

---

### Task 2: Extract ToolStyles

**Files:**
- Create: `NemoNotch/Helpers/ToolStyles.swift`
- Modify: `NemoNotch/Notch/CompactBadge.swift`
- Modify: `NemoNotch/Tabs/ClaudeTab.swift`

**Step 1: Create ToolStyles.swift**

```swift
import SwiftUI

enum ToolStyle {
    static func icon(_ tool: String?) -> String {
        guard let tool else { return "gearshape.fill" }
        if tool.hasPrefix("Read") || tool.hasPrefix("Grep") || tool == "Glob" {
            return "doc.text.magnifyingglass"
        }
        if tool.hasPrefix("Write") || tool == "Edit" { return "pencil" }
        if tool == "Bash" { return "terminal" }
        if tool == "Agent" { return "person.wave.2" }
        if tool.hasPrefix("Web") { return "globe" }
        return "gearshape.fill"
    }

    static func color(_ tool: String?) -> Color {
        guard let tool else { return .orange }
        if tool.hasPrefix("Read") || tool.hasPrefix("Grep") || tool == "Glob" { return .cyan }
        if tool.hasPrefix("Write") || tool == "Edit" { return .red }
        if tool == "Bash" { return .green }
        if tool == "Agent" { return .purple }
        if tool.hasPrefix("Web") { return .teal }
        return .orange
    }
}
```

**Step 2: Replace in CompactBadge.swift**

Remove the three private methods `toolIcon(_:)`, `toolColor(_:)`, `claudeToolColor(_:_:)`. Replace call sites:

- `Image(systemName: toolIcon(tool))` → `Image(systemName: ToolStyle.icon(tool))`
- `claudeToolColor(status, tool: tool)` → `ToolStyle.color(tool)`
- `toolColor(tool)` → `ToolStyle.color(tool)`

Also update the `claudeColor` method to use ToolStyle:
- `claudeColor(_:)` stays (it maps ClaudeStatus, not tool name — different concern)

**Step 3: Replace in ClaudeTab.swift**

Remove the private methods `toolColor(_:)` and `toolIcon(_:)`. Replace call sites:

- `Image(systemName: toolIcon(session.currentTool))` → `Image(systemName: ToolStyle.icon(session.currentTool))`
- `.foregroundStyle(toolColor(session.currentTool))` → `.foregroundStyle(ToolStyle.color(session.currentTool))`
- `.foregroundStyle(toolColor(tool))` → `.foregroundStyle(ToolStyle.color(tool))`

**Step 4: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Commit**

```bash
git add NemoNotch/Helpers/ToolStyles.swift NemoNotch/Notch/CompactBadge.swift NemoNotch/Tabs/ClaudeTab.swift
git commit -m "refactor: extract ToolStyle to shared helper, deduplicate from CompactBadge and ClaudeTab"
```

---

### Task 3: Extract ViewModifiers

**Files:**
- Create: `NemoNotch/Helpers/ViewModifiers.swift`
- Modify: `NemoNotch/Tabs/ClaudeTab.swift`

**Step 1: Create ViewModifiers.swift**

Move `PulseModifier` and `GlowPulseModifier` from `ClaudeTab.swift` (lines 245-264) into this new file. Exact code, unchanged:

```swift
import SwiftUI

struct PulseModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 1 : 1)
            .animation(
                isActive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                value: isActive
            )
    }
}

struct GlowPulseModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .opacity(0.6)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: true)
    }
}
```

**Step 2: Remove from ClaudeTab.swift**

Delete the `PulseModifier` and `GlowPulseModifier` structs from `ClaudeTab.swift` (lines 245-264).

**Step 3: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add NemoNotch/Helpers/ViewModifiers.swift NemoNotch/Tabs/ClaudeTab.swift
git commit -m "refactor: move PulseModifier and GlowPulseModifier to shared helpers"
```

---

### Task 4: Add Tab.sorted() Extension

**Files:**
- Modify: `NemoNotch/Models/Tab.swift`
- Modify: `NemoNotch/Notch/TabBarView.swift`
- Modify: `NemoNotch/Notch/NotchView.swift`
- Modify: `NemoNotch/Settings/SettingsView.swift`

**Step 1: Add sorted() to Tab.swift**

Append to `Tab.swift`:

```swift
extension Tab {
    static func sorted(_ tabs: Set<Tab>) -> [Tab] {
        tabs.sorted { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
    }
}
```

**Step 2: Replace all occurrences**

In `TabBarView.swift` (line 9):
```swift
// Before:
ForEach(Array(enabledTabs.sorted { Tab.allCases.firstIndex(of: $0)! < Tab.allCases.firstIndex(of: $1)! })) { tab in
// After:
ForEach(Tab.sorted(enabledTabs)) { tab in
```

In `NotchView.swift` (line 113):
```swift
// Before:
enabledTabs.sorted { Tab.allCases.firstIndex(of: $0)! < Tab.allCases.firstIndex(of: $1)! }
// After:
Tab.sorted(enabledTabs)
```

In `SettingsView.swift` (line 57):
```swift
// Before:
ForEach(Array(appSettings.enabledTabs).sorted { Tab.allCases.firstIndex(of: $0)! < Tab.allCases.firstIndex(of: $1)! }) { tab in
// After:
ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
```

**Step 3: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add NemoNotch/Models/Tab.swift NemoNotch/Notch/TabBarView.swift NemoNotch/Notch/NotchView.swift NemoNotch/Settings/SettingsView.swift
git commit -m "refactor: add Tab.sorted() extension, deduplicate sorting logic"
```

---

### Task 5: Split MediaService.swift

**Files:**
- Create: `NemoNotch/Services/MediaRemote.swift`
- Create: `NemoNotch/Services/NowPlayingCLI.swift`
- Modify: `NemoNotch/Services/MediaService.swift`

**Step 1: Create MediaRemote.swift**

Extract the `MediaRemote` class (lines 142-349 of current MediaService.swift) into `NemoNotch/Services/MediaRemote.swift`. This is a straight move — the class is already self-contained. Add the necessary imports at the top:

```swift
import Foundation
import ObjectiveC.runtime
```

**Step 2: Create NowPlayingCLI.swift**

Extract the `NowPlayingCLI` class (lines 351-473 of current MediaService.swift) into `NemoNotch/Services/NowPlayingCLI.swift`. Change `private final class` to `final class` (internal access — MediaService.swift is in the same module). Add import:

```swift
import Foundation
```

**Step 3: Trim MediaService.swift**

Remove the `MediaRemote` class and `NowPlayingCLI` class from MediaService.swift. The file should now contain only the `MediaService` class (lines 1-131). It already references `MediaRemote.shared` and `NowPlayingCLI()` which are now in separate files within the same module.

Remove `import ObjectiveC.runtime` from MediaService.swift (only MediaRemote needs it).

**Step 4: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Commit**

```bash
git add NemoNotch/Services/MediaRemote.swift NemoNotch/Services/NowPlayingCLI.swift NemoNotch/Services/MediaService.swift
git commit -m "refactor: split MediaService into MediaService, MediaRemote, NowPlayingCLI"
```

---

### Task 6: Extract HookEvent

**Files:**
- Create: `NemoNotch/Models/HookEvent.swift`
- Modify: `NemoNotch/Services/HookServer.swift`

**Step 1: Create HookEvent.swift**

Move the `HookEvent` struct (lines 162-178 of current HookServer.swift) into `NemoNotch/Models/HookEvent.swift`:

```swift
import Foundation

struct HookEvent: Codable {
    let hookEventName: String
    let sessionId: String?
    let toolName: String?
    let message: String?
    let cwd: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case toolName = "tool_name"
        case message
        case cwd
        case source
    }
}
```

**Step 2: Remove from HookServer.swift**

Delete the `HookEvent` struct from HookServer.swift (lines 162-178).

**Step 3: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add NemoNotch/Models/HookEvent.swift NemoNotch/Services/HookServer.swift
git commit -m "refactor: move HookEvent to Models/"
```

---

### Task 7: Pre-inject Environment into NotchCoordinator's NSHostingController

This is the foundation step for the @Environment migration. We add `.environment()` to the NSHostingController's root view so services are available via environment. No view changes yet — views still use init params. This ensures the environment is ready before we convert views.

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`

**Step 1: Add environment injection in init**

In `NotchCoordinator.init`, after creating `NotchView`, apply `.environment()` to each service before wrapping in NSHostingController:

```swift
// In init, change:
let wrapper = NotchView(
    coordinator: self,
    enabledTabs: appSettings.enabledTabs,
    mediaService: mediaService,
    calendarService: calendarService,
    claudeService: claudeCodeService,
    notificationService: notificationService
)
let hosting = NSHostingController(rootView: wrapper)

// To:
let wrapper = NotchView(
    coordinator: self,
    enabledTabs: appSettings.enabledTabs,
    mediaService: mediaService,
    calendarService: calendarService,
    claudeService: claudeCodeService,
    notificationService: notificationService
)
    .environment(mediaService)
    .environment(calendarService)
    .environment(claudeCodeService)
    .environment(launcherService)
    .environment(notificationService)
    .environment(appSettings)
let hosting = NSHostingController(rootView: wrapper)
```

The views still use init params (which take precedence), so behavior is unchanged. But the environment is now populated for future migration.

**Step 2: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift
git commit -m "refactor: pre-inject environment into NotchView's NSHostingController"
```

---

### Task 8: Convert Leaf Tab Views to @Environment

Convert MediaTab, CalendarTab, ClaudeTab, and LauncherTab to use `@Environment` instead of init params. Update their callers in NotchView.

**Files:**
- Modify: `NemoNotch/Tabs/MediaTab.swift`
- Modify: `NemoNotch/Tabs/CalendarTab.swift`
- Modify: `NemoNotch/Tabs/ClaudeTab.swift`
- Modify: `NemoNotch/Tabs/LauncherTab.swift`
- Modify: `NemoNotch/Notch/NotchView.swift` (tabContent only)

**Step 1: Convert MediaTab**

Change `let mediaService: MediaService` to `@Environment(MediaService.self) var mediaService`.

Update NotchView's tabContent:
```swift
case .media:
    MediaTab()  // was: MediaTab(mediaService: coordinator.mediaService)
```

**Step 2: Convert CalendarTab**

Change `let calendarService: CalendarService` to `@Environment(CalendarService.self) var calendarService`.

Update NotchView's tabContent:
```swift
case .calendar:
    CalendarTab()  // was: CalendarTab(calendarService: coordinator.calendarService)
```

**Step 3: Convert ClaudeTab**

No init params (it only has `let claudeService: ClaudeCodeService`). Change to `@Environment(ClaudeCodeService.self) var claudeService`.

Update NotchView's tabContent:
```swift
case .claude:
    ClaudeTab()  // was: ClaudeTab(claudeService: coordinator.claudeCodeService)
```

**Step 4: Convert LauncherTab**

Change `let launcherService: LauncherService` to `@Environment(LauncherService.self) var launcherService`. Keep `let onLaunch: () -> Void` as init param (closure, not a service).

Update NotchView's tabContent:
```swift
case .launcher:
    LauncherTab(onLaunch: { coordinator.notchClose() })
    // was: LauncherTab(launcherService: coordinator.launcherService) { coordinator.notchClose() }
```

**Step 5: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 6: Commit**

```bash
git add NemoNotch/Tabs/MediaTab.swift NemoNotch/Tabs/CalendarTab.swift NemoNotch/Tabs/ClaudeTab.swift NemoNotch/Tabs/LauncherTab.swift NemoNotch/Notch/NotchView.swift
git commit -m "refactor: convert tab views to @Environment for service access"
```

---

### Task 9: Convert CompactBadge to @Environment

**Files:**
- Modify: `NemoNotch/Notch/CompactBadge.swift`
- Modify: `NemoNotch/Notch/NotchView.swift` (compactBadges section)

**Step 1: Update CompactBadge properties**

Replace all service `let` properties with `@Environment`:

```swift
struct CompactBadge: View {
    @Environment(MediaService.self) var mediaService
    @Environment(CalendarService.self) var calendarService
    @Environment(ClaudeCodeService.self) var claudeService
    @Environment(NotificationService.self) var notificationService
    let onTap: (Tab) -> Void
    let onOpenApp: (String) -> Void
    // ... rest unchanged
}
```

**Step 2: Update NotchView's compactBadges**

The `compactBadges` computed property currently creates `CompactBadge(...)` with service args. Remove them:

```swift
private var compactBadges: some View {
    let badge = CompactBadge(
        onTap: { tab in
            coordinator.notchOpen(tab: tab)
        },
        onOpenApp: { bundleID in
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        }
    )
    // ... rest unchanged
}
```

**Step 3: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add NemoNotch/Notch/CompactBadge.swift NemoNotch/Notch/NotchView.swift
git commit -m "refactor: convert CompactBadge to @Environment for services"
```

---

### Task 10: Convert NotchView to @Environment

**Files:**
- Modify: `NemoNotch/Notch/NotchView.swift`

**Step 1: Replace service init params with @Environment**

Change:
```swift
struct NotchView: View {
    let coordinator: NotchCoordinator
    let enabledTabs: Set<Tab>
    let mediaService: MediaService
    let calendarService: CalendarService
    let claudeService: ClaudeCodeService
    let notificationService: NotificationService
```

To:
```swift
struct NotchView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings

    var enabledTabs: Set<Tab> { appSettings.enabledTabs }
```

Remove `private let badgePadding` — it's now `NotchConstants.badgePadding`.

**Step 2: Update references**

- `coordinator.status` stays the same
- `coordinator.selectedTab` stays the same
- `coordinator.notchOpen(tab:)` and `coordinator.notchClose()` stay the same
- `mediaService.playbackState` → now from @Environment (was already used in `hasActiveBadge` and `compactBadges`)
- All services now accessed from `@Environment` — no more `self.mediaService` etc needed since `@Environment` vars are instance properties

**Step 3: Update NotchCoordinator init**

In NotchCoordinator, update where it creates NotchView:

```swift
// Before:
let wrapper = NotchView(
    coordinator: self,
    enabledTabs: appSettings.enabledTabs,
    mediaService: mediaService,
    calendarService: calendarService,
    claudeService: claudeCodeService,
    notificationService: notificationService
)
    .environment(mediaService)
    // etc.

// After:
let wrapper = NotchView()
    .environment(self)
    .environment(appSettings)
    .environment(mediaService)
    .environment(calendarService)
    .environment(claudeCodeService)
    .environment(launcherService)
    .environment(notificationService)
```

**Step 4: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Commit**

```bash
git add NemoNotch/Notch/NotchView.swift NemoNotch/Notch/NotchCoordinator.swift
git commit -m "refactor: convert NotchView to @Environment, remove service init params"
```

---

### Task 11: Convert TabBarView

**Files:**
- Modify: `NemoNotch/Notch/TabBarView.swift`

**Step 1: Use @Environment for coordinator**

Change:
```swift
struct TabBarView: View {
    @Bindable var coordinator: NotchCoordinator
    let enabledTabs: Set<Tab>
```

To:
```swift
struct TabBarView: View {
    @Environment(NotchCoordinator.self) var coordinator
```

Replace `enabledTabs` references with computed property:
```swift
private var enabledTabs: Set<Tab> {
    // Read from AppSettings in environment — but TabBarView doesn't have it yet
    // Actually, just pass enabledTabs from NotchView
}
```

Wait — TabBarView currently receives `enabledTabs` as a parameter. It needs to know which tabs to show. Two options:

**Option A:** Keep `let enabledTabs: Set<Tab>` as init param (it's data, not a service)
**Option B:** Add `@Environment(AppSettings.self)` and read from there

Go with **Option B** — full @Environment:

```swift
struct TabBarView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
                Button {
                    coordinator.selectedTab = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(coordinator.selectedTab == tab ? .white : .gray)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

Update NotchView's call site (in `openedContent`):
```swift
// Before:
TabBarView(coordinator: coordinator, enabledTabs: enabledTabs)
// After:
TabBarView()
```

**Step 2: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add NemoNotch/Notch/TabBarView.swift NemoNotch/Notch/NotchView.swift
git commit -m "refactor: convert TabBarView to @Environment"
```

---

### Task 12: Convert SettingsView to @Environment

**Files:**
- Modify: `NemoNotch/Settings/SettingsView.swift`
- Modify: `NemoNotch/Settings/SettingsWindow.swift`
- Modify: `NemoNotch/NemoNotchApp.swift` (AppDelegate.showSettings)

**Step 1: Update SettingsView properties**

Change:
```swift
struct SettingsView: View {
    let appSettings: AppSettings
    let claudeCodeService: ClaudeCodeService
    let launcherService: LauncherService
    let notificationService: NotificationService
```

To:
```swift
struct SettingsView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(ClaudeCodeService.self) var claudeCodeService
    @Environment(LauncherService.self) var launcherService
    @Environment(NotificationService.self) var notificationService
```

**Step 2: Update SettingsWindow to accept generic content**

Change:
```swift
class SettingsWindow: NSWindow {
    init(settingsView: SettingsView) {
        let hosting = NSHostingController(rootView: settingsView)
```

To:
```swift
class SettingsWindow<Content: View>: NSWindow {
    init(rootView: Content) {
        let hosting = NSHostingController(rootView: rootView)
```

**Step 3: Update AppDelegate.showSettings()**

Change:
```swift
let view = SettingsView(
    appSettings: settings,
    claudeCodeService: claude,
    launcherService: launcher,
    notificationService: notification
)
let window = SettingsWindow(settingsView: view)
```

To:
```swift
let view = SettingsView()
    .environment(settings)
    .environment(claude)
    .environment(launcher)
    .environment(notification)
let window = SettingsWindow(rootView: view)
```

**Step 4: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Commit**

```bash
git add NemoNotch/Settings/SettingsView.swift NemoNotch/Settings/SettingsWindow.swift NemoNotch/NemoNotchApp.swift
git commit -m "refactor: convert SettingsView to @Environment"
```

---

### Task 13: Slim NotchCoordinator — Remove Service Properties

Remove all service stored properties from NotchCoordinator. Change init to accept a content closure.

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`

**Step 1: Remove service properties and rework init**

New NotchCoordinator:
```swift
@Observable
final class NotchCoordinator {
    enum Status {
        case closed
        case opened
    }

    var status: Status = .closed
    var selectedTab: Tab = .media
    var autoSelectTab: (() -> Tab?)?

    let window: NotchWindow
    private var hostingController: NSHostingController<AnyView>?

    private(set) var notchSize: NSSize
    private(set) var screenFrame: NSRect

    private var previousApp: NSRunningApplication?
    private static let ourBundleIdentifier = Bundle.main.bundleIdentifier

    // MARK: - Computed Geometry

    private var deviceNotchRect: NSRect {
        let screen = NSScreen.main!
        return NSRect(
            x: screen.frame.midX - notchSize.width / 2,
            y: screen.frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    var contentSize: NSSize {
        switch status {
        case .closed: notchSize
        case .opened: NSSize(width: NotchConstants.openedWidth, height: NotchConstants.openedHeight)
        }
    }

    private var hitboxRect: NSRect {
        deviceNotchRect.insetBy(dx: -NotchConstants.hitboxPadding, dy: -NotchConstants.hitboxPadding)
    }

    // MARK: - Init

    init(@ViewBuilder content: @escaping (NotchCoordinator) -> some View) {
        let screen = NSScreen.main!
        self.screenFrame = screen.frame
        self.notchSize = screen.hasNotch
            ? (screen.notchSize ?? NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight))
            : NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight)

        self.window = NotchWindow(rect: screen.frame)

        let wrapper = content(self)
        let hosting = NSHostingController(rootView: AnyView(wrapper))
        hosting.view.frame = screen.frame
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        self.hostingController = hosting

        let passThrough = PassThroughView(frame: screen.frame)
        passThrough.wantsLayer = true
        passThrough.layer?.backgroundColor = .clear
        passThrough.addSubview(hosting.view)
        window.contentView = passThrough
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        setupEventMonitoring()
    }

    // MARK: - Open / Close

    func notchOpen(tab: Tab? = nil) {
        guard status == .closed else { return }
        captureFrontmostApp()
        if let tab {
            selectedTab = tab
        } else if let auto = autoSelectTab?() {
            selectedTab = auto
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        withAnimation(.interactiveSpring(duration: NotchConstants.openSpringDuration)) {
            status = .opened
        }
    }

    func notchClose() {
        withAnimation(.spring(duration: NotchConstants.closeSpringDuration)) {
            status = .closed
        }
        if window.isKeyWindow {
            window.resignKey()
        }
        restorePreviousApp()
    }

    // MARK: - App Focus Management

    private func captureFrontmostApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Self.ourBundleIdentifier {
            previousApp = frontmost
        }
    }

    private func restorePreviousApp() {
        guard let app = previousApp else { return }
        previousApp = nil
        let currentFront = NSWorkspace.shared.frontmostApplication
        let currentID = currentFront?.bundleIdentifier
        if currentFront == nil || currentID == Self.ourBundleIdentifier {
            app.activate()
        }
    }

    // MARK: - Screen Changes

    @objc private func screenParametersChanged() {
        let screen = NSScreen.main!
        screenFrame = screen.frame
        notchSize = screen.hasNotch
            ? (screen.notchSize ?? NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight))
            : NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight)
        window.setFrame(screen.frame, display: true)
        hostingController?.view.frame = screen.frame
    }

    // MARK: - Event Monitoring

    private func setupEventMonitoring() {
        let monitor = EventMonitor.shared
        monitor.onMouseMove = { [weak self] location in
            self?.handleMouseMove(location)
        }
        monitor.onMouseDown = { [weak self] in
            self?.handleMouseDown()
        }
    }

    private func handleMouseMove(_ location: NSPoint) {
        let hitbox = hitboxRect
        let isInHitbox = NSMouseInRect(location, hitbox, false)

        switch status {
        case .closed:
            if isInHitbox { notchOpen() }
        case .opened:
            let contentRect = NSRect(
                x: screenFrame.midX - contentSize.width / 2,
                y: screenFrame.maxY - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            if !NSMouseInRect(location, contentRect.insetBy(dx: -NotchConstants.closeHitboxInset, dy: -NotchConstants.closeHitboxInset), false) {
                notchClose()
            }
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation
        if status == .closed && NSMouseInRect(location, hitboxRect, false) {
            notchOpen()
        }
        if status == .opened {
            let contentRect = NSRect(
                x: screenFrame.midX - contentSize.width / 2,
                y: screenFrame.maxY - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            if !NSMouseInRect(location, contentRect.insetBy(dx: -NotchConstants.clickHitboxInset, dy: -NotchConstants.clickHitboxInset), false) {
                notchClose()
            }
        }
    }
}
```

Key changes:
- Removed all 6 service `let` properties and `appSettings`
- Init now takes a `@ViewBuilder content: (NotchCoordinator) -> some View` closure
- Uses `AnyView` wrapper for NSHostingController since the closure returns opaque `some View`
- Added `autoSelectTab` closure property for tab auto-selection logic
- All geometry constants use `NotchConstants`

**Step 2: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: FAILS — AppDelegate still calls old init. That's OK, fixed in Task 14.

**Step 3: Do NOT commit yet — wait for Task 14 to compile**

---

### Task 14: Update AppDelegate + NemoNotchApp — Final Wiring

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

**Step 1: Update AppDelegate**

Replace the entire `applicationDidFinishLaunching` and simplify service wiring:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settingsWindow: SettingsWindow<AnyView>?
    static var shared = AppDelegate()

    private(set) var coordinator: NotchCoordinator?
    private var appSettings: AppSettings?
    private var mediaService: MediaService?
    private var calendarService: CalendarService?
    private var claudeCodeService: ClaudeCodeService?
    private var launcherService: LauncherService?
    private var notificationService: NotificationService?
    private var hotkeyService: HotkeyService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        let settings = AppSettings()
        let media = MediaService()
        let calendar = CalendarService()
        let claude = ClaudeCodeService()
        let launcher = LauncherService(settings: settings)

        claude.startServer()

        self.appSettings = settings
        self.mediaService = media
        self.calendarService = calendar
        self.claudeCodeService = claude
        self.launcherService = launcher

        let notification = NotificationService(monitoredApps: settings.monitoredApps)
        self.notificationService = notification

        let notchCoordinator = NotchCoordinator { [weak self] coordinator in
            AnyView(
                NotchView()
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(calendar)
                    .environment(claude)
                    .environment(launcher)
                    .environment(notification)
            )
        }
        notchCoordinator.autoSelectTab = { [weak self] in
            guard let self else { return nil }
            if self.claudeCodeService?.activeSession?.status == .working { return .claude }
            if self.mediaService?.playbackState.isPlaying == true { return .media }
            return nil
        }
        self.coordinator = notchCoordinator

        setupHotkeys(coordinator: notchCoordinator, settings: settings)
    }

    @MainActor
    func showSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil,
           let settings = appSettings,
           let claude = claudeCodeService,
           let launcher = launcherService,
           let notification = notificationService {
            let view = SettingsView()
                .environment(settings)
                .environment(claude)
                .environment(launcher)
                .environment(notification)
            let window = SettingsWindow(rootView: view)
            window.delegate = self
            settingsWindow = window
        }

        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            settingsWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func setupHotkeys(coordinator: NotchCoordinator, settings: AppSettings) {
        let hotkeys = HotkeyService()
        self.hotkeyService = hotkeys

        hotkeys.register(keyCode: 45, modifiers: UInt32(optionKey | cmdKey)) {
            switch coordinator.status {
            case .closed: coordinator.notchOpen()
            case .opened: coordinator.notchClose()
            }
        }

        let tabs = Tab.sorted(settings.enabledTabs)
        for (i, tab) in tabs.enumerated() {
            let keyCode = UInt32(18 + i)
            hotkeys.register(keyCode: keyCode, modifiers: UInt32(optionKey | cmdKey)) {
                coordinator.notchOpen(tab: tab)
            }
        }
    }
}
```

**Step 2: Update NemoNotchApp and MenuContent**

Update `MenuContent` to use `@Environment`:

```swift
struct MenuContent: View {
    @Environment(ClaudeCodeService.self) var claudeCodeService
    let coordinator: NotchCoordinator?
    let onOpenSettings: () -> Void

    var body: some View {
        Button("展开 Notch") {
            coordinator?.notchOpen()
        }

        Divider()

        if claudeCodeService.isHookInstalled {
            Text("Claude Code Hooks: 已安装 ✓")
        } else {
            Button("安装 Claude Code Hooks...") {
                claudeCodeService.installHooks()
            }
        }

        Divider()

        Button("偏好设置...") {
            onOpenSettings()
        }

        Button("关于 NemoNotch") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button("退出 NemoNotch") {
            NSApplication.shared.terminate(nil)
        }
    }
}
```

Update `NemoNotchApp.body`:

```swift
var body: some Scene {
    MenuBarExtra {
        MenuContent(
            coordinator: appDelegate.coordinator,
            onOpenSettings: { appDelegate.showSettings() }
        )
    } label: {
        Image(systemName: appDelegate.claudeCodeService?.isHookInstalled == true
            ? "menubar.rectangle.fill"
            : "menubar.rectangle")
    }
    .environment(appDelegate.claudeCodeService!)
}
```

Note: We only inject `ClaudeCodeService` into MenuBarExtra's environment since that's the only service MenuContent needs. The label still references `appDelegate` directly since it's outside the content view.

**Step 3: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit Tasks 13 + 14 together**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift NemoNotch/NemoNotchApp.swift
git commit -m "refactor: slim NotchCoordinator to pure state machine, wire environment in AppDelegate"
```

---

### Task 15: Final Cleanup and Verification

**Files:**
- Review all modified files for dead code

**Step 1: Check for unused imports**

- `NemoNotch/Notch/NotchView.swift` — remove `import SwiftUI` if already present (it should stay), check for unused `let` properties
- `NemoNotch/Tabs/ClaudeTab.swift` — verify `import SwiftUI` is still needed
- `NemoNotch/Services/MediaService.swift` — remove `import ObjectiveC.runtime` if present

**Step 2: Full clean build**

Run: `xcodebuild clean build -scheme NemoNotch -configuration Debug -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Quick manual smoke test checklist**

- [ ] App launches without crash
- [ ] Notch opens on hover
- [ ] Media tab shows playback info
- [ ] Claude tab shows session info
- [ ] Calendar tab shows events
- [ ] Launcher tab shows apps
- [ ] CompactBadge shows correct active icon
- [ ] Settings window opens from menu bar
- [ ] Global hotkey ⌥⌘N toggles notch

**Step 4: Commit**

```bash
git add -A
git commit -m "refactor: final cleanup after architecture refactor"
```

---

## Summary of Changes

| Metric | Before | After |
|--------|--------|-------|
| Files touched per new service | 6 | 3 (AppDelegate + environment injection + new view) |
| Service init params on NotchCoordinator | 6 | 0 |
| Service init params on NotchView | 5 | 0 |
| Duplicated toolIcon/toolColor | 2 copies | 1 (ToolStyles) |
| Duplicated tab sorting | 3 copies | 1 (Tab.sorted) |
| MediaService.swift line count | 473 | ~130 |
| NotchCoordinator.swift line count | 217 | ~130 |
| Magic numbers | ~20 inline | 0 (all in NotchConstants) |
