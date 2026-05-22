# AppleEvents Permission Polling State Machine

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect AppleEvents (Automation) permission changes for known media players (Music, Spotify) without requiring an app restart, by introducing a periodic re-probe + `@Observable` per-bundle state surface.

**Architecture:** `MediaBridge` is a static enum and cannot be `@Observable`. Introduce a new `@MainActor @Observable` service `MediaAutomationPermissionMonitor` that probes each known player every 5 seconds, holds per-bundle `PermissionState` (`.unknown / .denied / .authorized / .notRunning`), and exposes the state to SwiftUI. Wire `MediaBridge.permissionDeniedCallback` and `MediaService` to feed events to the monitor for low-latency reactions.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, `ScriptingBridge` (existing `MediaBridge` infra).

**Depends on:** `2026-05-21-test-target-skeleton.md` (for unit tests). If that plan isn't done, run Task 1 manually instead of via tests.

---

## File Structure

```
NemoNotch/Services/MediaAutomationPermissionMonitor.swift   # NEW: observable monitor
NemoNotch/Services/MediaBridge.swift                        # MODIFIED: expose probe hook
NemoNotch/Services/MediaService.swift                       # MODIFIED: wire callback to monitor
NemoNotch/NemoNotchApp.swift                                # MODIFIED: instantiate monitor in AppDelegate
NemoNotch/Tabs/OverviewTab.swift                            # MODIFIED: show "Grant Automation" banner when state == .denied
NemoNotchTests/MediaAutomationPermissionMonitorTests.swift  # NEW: state transition tests
```

---

## Task 1: Define `PermissionState` and monitor scaffold

**Files:**
- Create: `NemoNotch/Services/MediaAutomationPermissionMonitor.swift`

- [ ] **Step 1: Write the failing test**

Create `NemoNotchTests/MediaAutomationPermissionMonitorTests.swift`:

```swift
import Testing
@testable import NemoNotch

@Suite("MediaAutomationPermissionMonitor")
struct MediaAutomationPermissionMonitorTests {
    @Test("Initial state is .unknown for every monitored bundle")
    @MainActor
    func initialState() {
        let monitor = MediaAutomationPermissionMonitor(
            monitoredBundles: ["com.apple.Music", "com.spotify.client"]
        )
        #expect(monitor.state(for: "com.apple.Music") == .unknown)
        #expect(monitor.state(for: "com.spotify.client") == .unknown)
        #expect(monitor.state(for: "com.example.unknown") == .unknown)
    }

    @Test("recordDenied flips bundle state to .denied")
    @MainActor
    func recordDenied() {
        let monitor = MediaAutomationPermissionMonitor(monitoredBundles: ["com.apple.Music"])
        monitor.recordDenied(bundleID: "com.apple.Music")
        #expect(monitor.state(for: "com.apple.Music") == .denied)
    }

    @Test("recordAuthorized flips bundle state to .authorized")
    @MainActor
    func recordAuthorized() {
        let monitor = MediaAutomationPermissionMonitor(monitoredBundles: ["com.apple.Music"])
        monitor.recordDenied(bundleID: "com.apple.Music")
        monitor.recordAuthorized(bundleID: "com.apple.Music")
        #expect(monitor.state(for: "com.apple.Music") == .authorized)
    }

    @Test("hasAnyDenied reflects aggregate state")
    @MainActor
    func aggregate() {
        let monitor = MediaAutomationPermissionMonitor(
            monitoredBundles: ["com.apple.Music", "com.spotify.client"]
        )
        #expect(monitor.hasAnyDenied == false)
        monitor.recordDenied(bundleID: "com.spotify.client")
        #expect(monitor.hasAnyDenied == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/MediaAutomationPermissionMonitorTests
```

Expected: **FAIL** — compiler error "Cannot find 'MediaAutomationPermissionMonitor' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `NemoNotch/Services/MediaAutomationPermissionMonitor.swift`:

```swift
import AppKit
import Foundation

/// Tracks AppleEvents (Automation) permission per-bundle for known media players.
/// Updates via two paths:
/// 1. Periodic probe (5 s) of `MediaBridge.hasAutomationAccess` for running players.
/// 2. Push notifications from `MediaBridge.permissionDeniedCallback` (delegate-driven).
@MainActor
@Observable
final class MediaAutomationPermissionMonitor {
    enum PermissionState: Equatable {
        case unknown      // never probed (or app not running)
        case authorized
        case denied
    }

    private(set) var states: [String: PermissionState] = [:]

    private let monitoredBundles: [String]
    private var probeTimer: Timer?

    init(monitoredBundles: [String]) {
        self.monitoredBundles = monitoredBundles
        for bundle in monitoredBundles {
            states[bundle] = .unknown
        }
    }

    deinit {
        MainActor.assumeIsolated {
            probeTimer?.invalidate()
        }
    }

    func state(for bundleID: String) -> PermissionState {
        states[bundleID] ?? .unknown
    }

    var hasAnyDenied: Bool {
        states.values.contains(.denied)
    }

    func recordDenied(bundleID: String) {
        guard monitoredBundles.contains(bundleID) else { return }
        if states[bundleID] != .denied {
            LogService.warn(
                "AutomationPermissionMonitor: \(bundleID) -> denied",
                category: "Permission"
            )
            states[bundleID] = .denied
        }
    }

    func recordAuthorized(bundleID: String) {
        guard monitoredBundles.contains(bundleID) else { return }
        if states[bundleID] != .authorized {
            LogService.info(
                "AutomationPermissionMonitor: \(bundleID) -> authorized",
                category: "Permission"
            )
            states[bundleID] = .authorized
        }
    }

    func startProbing() {
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeAll()
            }
        }
        probeAll()
    }

    func stopProbing() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    private func probeAll() {
        for bundleID in monitoredBundles {
            // Only probe running apps — probing a not-running app launches it.
            guard MediaBridge.isRunning(bundleID: bundleID) else {
                states[bundleID] = .unknown
                continue
            }
            if MediaBridge.hasAutomationAccess(bundleID: bundleID) {
                recordAuthorized(bundleID: bundleID)
            } else {
                recordDenied(bundleID: bundleID)
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify pass**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/MediaAutomationPermissionMonitorTests
```

Expected: all 4 tests pass.

- [ ] **Step 5: Add new file to Xcode target**

If Xcode didn't auto-pick up `MediaAutomationPermissionMonitor.swift`:
1. Drag the file into the **NemoNotch** group in the Project Navigator
2. Confirm **Target Membership** includes `NemoNotch` (not `NemoNotchTests`)

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Services/MediaAutomationPermissionMonitor.swift \
        NemoNotchTests/MediaAutomationPermissionMonitorTests.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(media): add MediaAutomationPermissionMonitor scaffold"
```

---

## Task 2: Wire delegate callback into the monitor

**Files:**
- Modify: `NemoNotch/Services/MediaBridge.swift:125` (the `permissionDeniedCallback`)
- Modify: `NemoNotch/Services/MediaService.swift` (find where `MediaBridge.permissionDeniedCallback` is set; if not set, set it from AppDelegate)
- Modify: `NemoNotch/NemoNotchApp.swift` (instantiate monitor + bridge callback)

- [ ] **Step 1: Locate existing `permissionDeniedCallback` consumer**

```bash
grep -n "permissionDeniedCallback" NemoNotch -r
```

Expected output (existing): one or two call sites in `MediaService` or `NemoNotchApp`.

- [ ] **Step 2: Add monitor to AppDelegate**

In `NemoNotch/NemoNotchApp.swift`, find the `AppDelegate` class (search for `class AppDelegate`). Add a stored property after the existing services (look for `MediaService` and `HUDService` declarations):

```swift
let automationPermissionMonitor = MediaAutomationPermissionMonitor(
    monitoredBundles: ["com.apple.Music", "com.spotify.client"]
)
```

In `applicationDidFinishLaunching(_:)` (or wherever services start), call:

```swift
automationPermissionMonitor.startProbing()
MediaBridge.permissionDeniedCallback = { [weak self] bundleID in
    self?.automationPermissionMonitor.recordDenied(bundleID: bundleID)
}
```

If `permissionDeniedCallback` is already set elsewhere (e.g. inside `MediaService.init`), **change** that call site instead — don't overwrite from two places. Add a small forwarder method to `MediaService`:

```swift
// In MediaService
var permissionDeniedHandler: ((String) -> Void)?

// In MediaService init, after `MediaBridge.permissionDeniedCallback = ...`:
MediaBridge.permissionDeniedCallback = { [weak self] bundleID in
    self?.permissionDeniedHandler?(bundleID)
    // ... existing handling
}
```

Then in AppDelegate:

```swift
mediaService.permissionDeniedHandler = { [weak self] bundleID in
    self?.automationPermissionMonitor.recordDenied(bundleID: bundleID)
}
```

(Choose the cleaner of the two patterns based on what `MediaService` already does — investigate before editing.)

- [ ] **Step 3: Inject monitor into the SwiftUI environment**

In `NemoNotchApp.swift`, in the `body: some Scene` block, find where existing services are injected via `.environment(...)`. Add:

```swift
.environment(appDelegate.automationPermissionMonitor)
```

- [ ] **Step 4: Build and run manually to verify probing**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Expected: build succeeds, no warnings about the new injection.

Run the app, then check Console.app filter `category=Permission` — within 5 seconds you should see one of:
- `AutomationPermissionMonitor: com.apple.Music -> authorized` (if Music is running and granted)
- `AutomationPermissionMonitor: com.spotify.client -> denied` (if Spotify is running and denied)
- Nothing (if neither app is running — that's correct)

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift NemoNotch/Services/MediaService.swift
git commit -m "feat(media): wire AppleEvents permission monitor into AppDelegate"
```

---

## Task 3: Surface "Grant Automation" banner in OverviewTab

**Files:**
- Modify: `NemoNotch/Tabs/OverviewTab.swift` (add banner when `monitor.hasAnyDenied == true`)

- [ ] **Step 1: Locate OverviewTab**

```bash
find NemoNotch/Tabs -name "OverviewTab*"
```

Open the file. Locate the SwiftUI `var body: some View`.

- [ ] **Step 2: Add monitor to view environment**

At the top of the view struct, add:

```swift
@Environment(MediaAutomationPermissionMonitor.self) private var permissionMonitor
```

- [ ] **Step 3: Add banner at the top of the body**

Wrap the existing body content so the banner appears above it. Replace:

```swift
var body: some View {
    VStack {
        // ... existing content
    }
}
```

with:

```swift
var body: some View {
    VStack(spacing: 8) {
        if permissionMonitor.hasAnyDenied {
            automationPermissionBanner
        }
        // ... existing content
    }
}

private var automationPermissionBanner: some View {
    HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.yellow)
        Text("Allow media control")
            .font(.caption)
        Spacer()
        Button("Open Settings") {
            MediaBridge.openAutomationSettings()
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.yellow.opacity(0.15))
    .clipShape(RoundedRectangle(cornerRadius: 6))
}
```

- [ ] **Step 4: Build and manually verify**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Then:
1. Run NemoNotch
2. Open Spotify (or Music)
3. Try seeking (the existing media seek code calls `MediaBridge.setPlayerPosition`)
4. macOS shows the Automation prompt — **deny** it
5. Within 5s the OverviewTab banner appears
6. `tccutil reset AppleEvents com.GaoZimeng.NemoNotch` (or whatever the bundle ID is) to clear and re-grant
7. Within 5s the banner disappears

If the banner does not auto-disappear, the probe is failing — check Console logs for `Permission` category.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Tabs/OverviewTab.swift
git commit -m "feat(media): show 'Allow media control' banner when AppleEvents denied"
```

---

## Self-Review Checklist

- [x] State enum has minimal cases — no speculative `.requesting` etc.
- [x] Probe runs only for running apps (avoid launching apps for permission check)
- [x] `[weak self]` in Timer closure prevents retain cycle
- [x] Banner uses existing `MediaBridge.openAutomationSettings()` — no new deep link
- [x] Self-clearing recovery: probe flips back to `.authorized` without app restart
- [x] Test target dependency noted at top
- [x] Manual verification steps include `tccutil reset` for cleanup

---

## Out-of-Scope (deliberately not in this plan)

- Generalizing to AX / Screen Recording permissions — NotificationService already polls AX; ScreenRecording isn't used.
- Persisting per-bundle state across launches — current `MediaBridge.permissionRequested` UserDefaults already handles "did we show the prompt once".
- Auto-retry of the failed seek after recovery — separate UX decision, can be added later.

---

*Plan written 2026-05-21.*
