# Permissions Button-Triggered + Hotkey-Aware Dismiss — Design

**Date:** 2026-05-23
**Status:** Approved (pending user review)

## Problem

Two unrelated annoyances surfaced together:

1. **Permissions auto-request on startup.** `CalendarService.init` calls `requestFullAccessToEvents`; `WeatherService.init` calls `requestAlwaysAuthorization`. Both trigger system dialogs on first launch, before the user has done anything that warrants them. The Automation banner (Music/Spotify) and AX status (notifications) also lack a consistent UI affordance — the calendar placeholder has no button at all.
2. **Notch retracts before mouse arrives after hotkey open.** `NotchCoordinator.handleMouseMove` (status==.opened branch) calls `notchClose()` as soon as any mouse-move event finds the cursor outside the content rect. When the user opens via global hotkey, the cursor is almost always elsewhere, so the very next mouse jitter slams the panel shut.

## Goals

- Replace startup auto-permission-requests with explicit, button-triggered requests.
- Provide a single visual+interaction pattern for all four permission types (Calendar, Location, Automation, AX) so the UI is consistent.
- Keep the mouse-hover open/close behavior of the notch unchanged.
- Make the hotkey-open path predictable: stay open until either (a) the mouse arrives then leaves, (b) 3 seconds pass with no mouse entry, or (c) user explicitly closes (hotkey/click-outside/ESC).
- Bonus: add ESC handling that works for both open paths (no current ESC handler exists).

## Non-Goals

- No changes to MediaService's reconcile / playback logic.
- No changes to `MediaAutomationPermissionMonitor`'s probing policy (it already only probes `.denied`, safe).
- No new "Permissions" tab in Settings. AX card stays in the existing Settings → Notifications tab; the other three live inline in their feature surfaces.
- No persistence of "user has dismissed the permission card" — the existing `mediaService.permissionDeniedPlayer` dismiss-banner concept is dropped (see Track A § Automation).

---

## Track A — Unified PermissionCard pattern

### Shared component

New file `NemoNotch/Helpers/PermissionCard.swift`:

```swift
enum PermissionStatus: Equatable {
    case notDetermined
    case denied
    case restricted   // rare; renders like .denied
}

enum PermissionRequestability {
    case programmatic(() -> Void)   // Button → call request API directly
    case settingsOnly               // Button → open System Settings only
}

struct PermissionCard: View {
    let icon: String                  // SF Symbol name
    let titleKey: LocalizedStringKey  // e.g. "permission.calendar.title"
    let detailKey: LocalizedStringKey // short explanation
    let status: PermissionStatus
    let primary: PermissionRequestability
    let openSettings: () -> Void      // shown as secondary CTA when .denied
}
```

Rendering rules:

- Status `.authorized` → parent should NOT render the card (display feature content instead). Card never sees `.authorized`.
- Status `.notDetermined`:
  - `.programmatic(action)`: primary CTA "授予 / Grant" → calls `action()`.
  - `.settingsOnly`: primary CTA "打开系统设置 / Open Settings" → calls `openSettings()`.
- Status `.denied` or `.restricted`:
  - Primary CTA "打开系统设置 / Open Settings" (regardless of `primary` field — once denied, the system dialog can't be re-triggered programmatically).
  - Secondary text explains why this is needed.

Visual style: reuse existing `notchCard(radius: 8, fill: NotchTheme.surface)` modifier; layout mirrors the existing Automation banner in `OverviewTab.swift:228-261` (icon → title → detail → CTA row).

Localization keys to add (`Localizable.xcstrings`):

- `permission.calendar.title`, `permission.calendar.detail`
- `permission.location.title`, `permission.location.detail`
- `permission.automation.title`, `permission.automation.detail` (with `\(player.displayName)` interpolation)
- `permission.accessibility.title`, `permission.accessibility.detail`
- `permission.grant`, `permission.open_settings`, `permission.denied_explanation`

### Track A.1 — Calendar

File: `NemoNotch/Services/CalendarService.swift`

**Remove:**
- Line 35: `requestAccessIfNeeded()` call in `init`.
- Lines 82-91: `requestAccessIfNeeded()` private method entirely (the polling-on-init concept dies).

**Keep:**
- Line 49 `requestAccess()` — now only called from UI button.
- `EKEventStoreChanged` observer — fires `fetchEvents()` automatically once auth flips to `.fullAccess`.

**Add:**
- Nothing. Existing API surface suffices.

File: `NemoNotch/Tabs/OverviewTab.swift`

**Change** `OverviewCalendarSection.body` (lines 51-70). Replace the existing `default:` placeholder with `PermissionCard`:

```swift
case .fullAccess:
    calendarContent
default:
    PermissionCard(
        icon: "calendar.badge.lock",
        titleKey: "permission.calendar.title",
        detailKey: "permission.calendar.detail",
        status: calendarService.authorizationStatus == .denied
            ? .denied
            : .notDetermined,
        primary: .programmatic { calendarService.requestAccess() },
        openSettings: { calendarService.openSystemSettings() }
    )
```

### Track A.2 — Location

File: `NemoNotch/Services/WeatherService.swift`

**Remove:**
- Line 27: `locationManager.requestAlwaysAuthorization()` from `init`.

**Add:**
- `var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined` (observable property).
- `func requestLocationAccess() { locationManager.requestAlwaysAuthorization() }`.
- In `locationManagerDidChangeAuthorization` (line 58), also update `locationAuthorizationStatus = manager.authorizationStatus` on main actor.
- `func openLocationSettings() { NSWorkspace.shared.open(URL(...)) }` — opens `x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices`.

**Keep:**
- All location-update delegate methods, `setActive`, polling timer, wttr.in fetch logic.

File: `NemoNotch/Tabs/OverviewTab.swift`

**Change** `OverviewWeatherSection`. Add a precondition: if `appSettings.weatherCity` is non-empty, weather doesn't need location → show normal content regardless of authorization. Otherwise check authorization and render `PermissionCard` when not authorized.

```swift
var body: some View {
    Group {
        // macOS only grants .authorizedAlways for desktop apps (no .authorizedWhenInUse).
        // If user typed a city, weather doesn't need location at all.
        if !appSettings.weatherCity.isEmpty || weatherService.locationAuthorizationStatus == .authorizedAlways {
            if !weatherService.isLoaded {
                ProgressView()...
            } else {
                weatherContent
            }
        } else {
            PermissionCard(
                icon: "location.slash",
                titleKey: "permission.location.title",
                detailKey: "permission.location.detail",
                status: weatherService.locationAuthorizationStatus == .denied
                    ? .denied
                    : .notDetermined,
                primary: .programmatic { weatherService.requestLocationAccess() },
                openSettings: { weatherService.openLocationSettings() }
            )
        }
    }
    .notchCard(radius: 8, fill: NotchTheme.surface)
    .activates(weatherService)
}
```

Note: `OverviewWeatherSection` needs to gain `@Environment(AppSettings.self) var appSettings`. Already injected at `NemoNotchApp.swift:164`, just declare the env var on the section view.

### Track A.3 — Automation

File: `NemoNotch/Services/MediaService.swift`

**Remove (audited — no remaining callers after Track A.3 lands):**
- Property `permissionDeniedPlayer` (line 15) and all its assignments (lines 49, 57, 62, 244).
- `func dismissPermissionBanner()` (lines 56-58).
- `func recheckPermissionIfBannerShown()` (lines 241-246) — redundant with `MediaAutomationPermissionMonitor`'s probe loop.
- `MediaBridge.permissionDeniedCallback` closure (lines 45-50): drop the `permissionDeniedPlayer = player` assignment but **keep** the `permissionDeniedHandler?(bundleID)` forwarder — `MediaAutomationPermissionMonitor` still subscribes via `recordDenied`.
- In `NemoNotchApp.swift:111-115`: the `permissionMonitor.onAuthorized` closure that cleared `media.permissionDeniedPlayer` becomes obsolete. The `onAuthorized` callback wiring itself can be removed (no remaining consumers); if a future feature needs it, re-add it then.

**Keep:**
- `var permissionDeniedHandler: ((String) -> Void)?` (line 20) and its invocation site — this is the bridge from `MediaBridge.permissionDeniedCallback` to `MediaAutomationPermissionMonitor.recordDenied`. Loadbearing.
- `func openAutomationSettings()` (lines 60-63) but simplify to just `MediaBridge.openAutomationSettings()` (drop the `permissionDeniedPlayer = nil` line).

**Add:**
- `func requestAutomationAccess(for player: KnownPlayer)`:
  ```swift
  func requestAutomationAccess(for player: KnownPlayer) {
      // Probing IS the request — sending an AppleEvent triggers the system dialog
      // if state is .notDetermined; if .denied the dialog won't re-show, but the
      // probe is harmless and idempotent.
      _ = MediaBridge.hasAutomationAccess(bundleID: player.rawValue)
  }
  ```

File: `NemoNotch/Services/MediaAutomationPermissionMonitor.swift`

**Keep as-is.** It already exposes `state(for: bundleID)`, `recordDenied`, `recordAuthorized`. Per-bundle `PermissionState` is `.unknown / .authorized / .denied`, which maps to PermissionCard's `.notDetermined / (omit) / .denied`.

File: `NemoNotch/Tabs/OverviewTab.swift`

**Inject** `MediaAutomationPermissionMonitor` into the section. AppDelegate already creates it (`NemoNotchApp.swift:104`). Wire it through `NotchView` env (currently the registry/services list at line 164-174 — add `.environment(automationMonitor)`).

**Change** `OverviewMediaSection`. Determine card visibility from the current track's bundle ID + monitor state:

```swift
private var automationCardPlayer: KnownPlayer? {
    guard let bundleID = mediaService.playbackState.appBundleIdentifier,
          let player = KnownPlayer(bundleID: bundleID) else { return nil }
    let state = automationMonitor.state(for: bundleID)
    return state == .authorized ? nil : player
}

var body: some View {
    VStack(spacing: 6) {
        if let player = automationCardPlayer {
            PermissionCard(
                icon: "lock.shield",
                titleKey: "permission.automation.title",   // "\(player.displayName) Automation"
                detailKey: "permission.automation.detail",
                status: automationMonitor.state(for: player.rawValue) == .denied
                    ? .denied
                    : .notDetermined,
                primary: .programmatic { mediaService.requestAutomationAccess(for: player) },
                openSettings: { MediaBridge.openAutomationSettings() }
            )
        } else {
            artwork
            trackInfo
            progressBar
            controls
        }
    }
    ...
}
```

This replaces the existing `permissionDeniedPlayer` banner (lines 214-261). The card now shows for `.unknown` state too, matching the user's intent.

### Track A.4 — Accessibility (AX)

File: `NemoNotch/Services/NotificationService.swift`

**No changes needed.** Existing `isAXTrusted` + `openAccessibilitySettings()` already match the card's `.settingsOnly` contract.

File: `NemoNotch/Settings/SettingsView.swift`

**Change** `notificationListView` (lines 333-348). Replace the existing accessibility warning Section with `PermissionCard`:

```swift
if !notificationService.isAXTrusted {
    Section {
        PermissionCard(
            icon: "exclamationmark.triangle.fill",
            titleKey: "permission.accessibility.title",
            detailKey: "permission.accessibility.detail",
            status: .notDetermined,  // AX has no .denied — either trusted or not
            primary: .settingsOnly,
            openSettings: { notificationService.openAccessibilitySettings() }
        )
        .padding(.vertical, 4)
    }
}
```

AX card is **not** shown inside the notch's notification tab (per user decision). Only in Settings.

### Logging

Each service-level state change must emit a log line per CLAUDE.md's logging conventions:

- `LogService.info("Calendar permission requested by user", category: "Permission")` on `CalendarService.requestAccess`.
- Same pattern for `WeatherService.requestLocationAccess`, `MediaService.requestAutomationAccess(for:)`.
- Authorization callback transitions (already partially covered in `MediaAutomationPermissionMonitor`) should log at `.info` when transitioning to `.authorized`, `.warn` on `.denied`.

---

## Track B — Hotkey-aware dismiss

### New state on `NotchCoordinator`

```swift
private var openedViaHotkey: Bool = false
private var mouseHasEnteredContent: Bool = false
private var hotkeyAutoCloseTimer: Timer?
private var escMonitor: Any?
```

### New constant in `NotchConstants`

```swift
static let hotkeyAutoCloseDelay: TimeInterval = 3.0
```

### Modified `notchOpen` (`NotchCoordinator.swift:172`)

Add a `viaHotkey: Bool = false` parameter. Inside, after the existing setup:

```swift
openedViaHotkey = viaHotkey
mouseHasEnteredContent = !viaHotkey  // mouse path: cursor is already in hitbox
if viaHotkey {
    startHotkeyAutoCloseTimer()
}
installEscMonitor()
```

The `mouseHasEnteredContent = !viaHotkey` initializer is the critical invariant: for the mouse-hover open path, the existing close-on-leave behavior must work unchanged from frame 1.

### Modified `handleMouseMove` (`NotchCoordinator.swift:269-283`)

Replace the `.opened` branch:

```swift
case .opened:
    guard let active = activeScreen else { return }
    let contentHit = contentRect(for: active, hitInset: NotchConstants.closeHitboxInset)
    if NSMouseInRect(location, contentHit, false) {
        if !mouseHasEnteredContent {
            mouseHasEnteredContent = true
            cancelHotkeyAutoCloseTimer()
        }
    } else if mouseHasEnteredContent {
        notchClose()
    }
    // else: hotkey-opened, mouse not yet entered, mouse is outside → wait for timer / explicit close
```

### Modified `notchClose`

Prepend cleanup:

```swift
func notchClose() {
    cancelHotkeyAutoCloseTimer()
    uninstallEscMonitor()
    openedViaHotkey = false
    mouseHasEnteredContent = false
    // existing animation + state-machine logic unchanged
    ...
}
```

### Timer helpers

```swift
private func startHotkeyAutoCloseTimer() {
    cancelHotkeyAutoCloseTimer()
    hotkeyAutoCloseTimer = Timer.scheduledTimer(
        withTimeInterval: NotchConstants.hotkeyAutoCloseDelay,
        repeats: false
    ) { [weak self] _ in
        Task { @MainActor [weak self] in
            self?.notchClose()
        }
    }
}

private func cancelHotkeyAutoCloseTimer() {
    hotkeyAutoCloseTimer?.invalidate()
    hotkeyAutoCloseTimer = nil
}

/// Public so AppDelegate can call it when the user switches tab via hotkey
/// while still in the no-mouse-yet phase.
func bumpHotkeyAutoCloseTimerIfActive() {
    guard openedViaHotkey, !mouseHasEnteredContent else { return }
    startHotkeyAutoCloseTimer()
}
```

### ESC monitor

```swift
private func installEscMonitor() {
    guard escMonitor == nil else { return }
    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        if event.keyCode == 53 {  // kVK_Escape
            Task { @MainActor [weak self] in self?.notchClose() }
            return nil  // swallow event
        }
        return event
    }
}

private func uninstallEscMonitor() {
    if let monitor = escMonitor {
        NSEvent.removeMonitor(monitor)
        escMonitor = nil
    }
}
```

ESC capture relies on `NSEvent.addLocalMonitor`, which only fires when our app is key. `notchOpen` already calls `slot.window.makeKeyAndOrderFront(nil)` + `NSApp.activate`, so this is reliable.

### AppDelegate hotkey wiring (`NemoNotchApp.swift:212-236`)

```swift
KeyboardShortcuts.onKeyDown(for: .toggleNotch) { [weak coordinator] in
    guard let c = coordinator else { return }
    switch c.status {
    case .closed: c.notchOpen(viaHotkey: true)
    case .opened: c.notchClose()
    }
}

for tab in Tab.allCases {
    KeyboardShortcuts.onKeyDown(for: tab.hotkeyName) { [weak coordinator] in
        guard let c = coordinator else { return }
        switch c.status {
        case .closed:
            c.notchOpen(tab: tab, viaHotkey: true)
        case .opened:
            if c.selectedTab == tab {
                c.notchClose()
            } else {
                c.selectedTab = tab
                c.bumpHotkeyAutoCloseTimerIfActive()  // ← keyboard-driven tab switch resets the 3s grace
            }
        }
    }
}
```

### Behavioral matrix

| Scenario | Outcome |
|---|---|
| Hotkey open → no mouse motion → 3s | auto-close via timer |
| Hotkey open → mouse enters content rect | timer cancelled; subsequent leave → close (existing logic) |
| Hotkey open → mouse moves but never enters content | timer still pending; fires at 3s |
| Hotkey open → user presses ESC | immediate close (new) |
| Hotkey open → user clicks outside notch | close (existing `handleMouseDown`) |
| Hotkey open → user presses same hotkey | close (existing toggle) |
| Hotkey open → user presses tab hotkey to switch tab | tab changes; timer resets if mouse hasn't entered yet |
| Mouse-hover open → mouse leaves content | close immediately (existing; `mouseHasEnteredContent` starts true so gate is open) |
| Mouse-hover open → user presses ESC | immediate close (new) |

---

## Risk & Rollback

- **Permission card breaking calendar/weather first-launch UX**: users who used to see the system dialog immediately now see a card asking them to grant. Mitigation: card copy explicitly says "click to grant" with the system-dialog screenshot mental model — no behavioral surprise once they click. Rollback: re-add the `init` call.
- **ESC monitor swallowing ESC when notch is opened but user has another app frontmost**: shouldn't happen because `addLocalMonitor` is scoped to our app and we always `NSApp.activate` on open. If it does, we explicitly check `status == .opened` inside the monitor as defense in depth.
- **3-second timer firing during an active animation**: `notchClose()` is idempotent (the `withAnimation` is safe to call from a closed state). Worst case is a no-op animation tick.
- **`mouseHasEnteredContent` getting stuck true across open sessions**: reset to its initial value in `notchClose()` (already in the cleanup block). Verified by the matrix above.

## Testing

Unit tests (Swift Testing, in `NemoNotchTests/`):

- `NotchCoordinatorTests`:
  - Hotkey open, no mouse → after timer interval, status == .closed.
  - Hotkey open, mouse-move into content rect → `mouseHasEnteredContent` flips true; subsequent move outside → status == .closed.
  - Mouse-hover open path: `viaHotkey = false`, status changes to opened then immediately to closed when mouse moves out (i.e., the new gate doesn't break existing path).
  - `bumpHotkeyAutoCloseTimerIfActive()` is a no-op when `mouseHasEnteredContent` is true.

Manual checks:
- Calendar/Location/Automation/AX cards render correctly in their three states (notDetermined / denied / authorized-hidden).
- ESC closes the notch in both open paths.
- After granting Calendar/Location via card button, content appears within 1-2s without a relaunch.

## Files Touched

- New: `NemoNotch/Helpers/PermissionCard.swift`
- New: `NemoNotchTests/NotchCoordinatorHotkeyDismissTests.swift`
- Modified: `NemoNotch/Services/CalendarService.swift`
- Modified: `NemoNotch/Services/WeatherService.swift`
- Modified: `NemoNotch/Services/MediaService.swift`
- Modified: `NemoNotch/Tabs/OverviewTab.swift`
- Modified: `NemoNotch/Settings/SettingsView.swift`
- Modified: `NemoNotch/Notch/NotchCoordinator.swift`
- Modified: `NemoNotch/Notch/NotchView.swift` (env injection for `MediaAutomationPermissionMonitor`)
- Modified: `NemoNotch/NemoNotchApp.swift` (hotkey wiring updates + monitor injection)
- Modified: `NemoNotch/Resources/Localizable.xcstrings` (new permission keys)
- Modified: `README.md`, `README_CN.md`, `CLAUDE.md` (per coding convention — describe the new permission flow + ESC handler)
