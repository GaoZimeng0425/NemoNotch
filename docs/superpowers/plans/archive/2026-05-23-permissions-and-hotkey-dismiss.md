# Permissions Button-Triggered + Hotkey-Aware Dismiss — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two decoupled UX improvements: (1) replace startup auto-permission-prompts with explicit, button-triggered requests via a unified PermissionCard, covering Calendar/Location/Automation/AX; (2) make hotkey-opened notch survive until the mouse arrives (or 3s grace) with ESC handling as a bonus.

**Architecture:** Phase 1 lands Track B (small, self-contained NotchCoordinator state-machine change) so it can ship and bake. Phase 2 lands Track A (new shared `PermissionCard` SwiftUI component + per-service surgical removal of init-time `requestAccess` calls). The two tracks are independent — Phase 2 can start even if Phase 1 isn't merged. Each task ends with a commit so the branch can be cut at any task boundary.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSEvent` local monitor, `Timer`), Swift Testing (`import Testing`, `@Test`, `#expect`), CocoaLumberjack via `LogService`. macOS only.

**Spec:** [`2026-05-23-permissions-and-hotkey-dismiss-design.md`](../specs/2026-05-23-permissions-and-hotkey-dismiss-design.md)

---

## File Structure

### Phase 1 — Track B (Hotkey dismiss)

| File | Action | Responsibility |
|---|---|---|
| `NemoNotch/Notch/HotkeyDismissState.swift` | **Create** | Pure state-machine struct for "mouse entered yet?" logic, isolated for unit testing |
| `NemoNotch/Helpers/Constants.swift` | Modify | Add `hotkeyAutoCloseDelay` |
| `NemoNotch/Notch/NotchCoordinator.swift` | Modify | Adopt `HotkeyDismissState`; add `viaHotkey` to `notchOpen`; ESC monitor; timer; cleanup in `notchClose` |
| `NemoNotch/NemoNotchApp.swift` | Modify | Pass `viaHotkey: true` in hotkey handlers; bump timer on tab switch |
| `NemoNotchTests/HotkeyDismissStateTests.swift` | **Create** | Unit tests for the pure state-machine struct |

### Phase 2 — Track A (PermissionCard)

| File | Action | Responsibility |
|---|---|---|
| `NemoNotch/Helpers/PermissionCard.swift` | **Create** | Shared SwiftUI component + `PermissionStatus` enum |
| `NemoNotch/Resources/Localizable.xcstrings` | Modify | Add `permission.*` keys (en + zh-Hans) |
| `NemoNotch/Services/CalendarService.swift` | Modify | Remove `requestAccessIfNeeded()` from init |
| `NemoNotch/Services/WeatherService.swift` | Modify | Remove `requestAlwaysAuthorization()` from init; expose `locationAuthorizationStatus`; add `requestLocationAccess()` + `openLocationSettings()` |
| `NemoNotch/Services/MediaService.swift` | Modify | Remove `permissionDeniedPlayer` property + related methods; add `requestAutomationAccess(for:)`; simplify `openAutomationSettings()` |
| `NemoNotch/Tabs/OverviewTab.swift` | Modify | Replace inline placeholders/banner with `PermissionCard` (Calendar, Weather, Media sections) |
| `NemoNotch/Settings/SettingsView.swift` | Modify | Replace existing AX warning Section with `PermissionCard` |
| `NemoNotch/Notch/NotchView.swift` | Modify | Inject `MediaAutomationPermissionMonitor` into env |
| `NemoNotch/NemoNotchApp.swift` | Modify | Inject monitor into NotchView env; drop dead `permissionMonitor.onAuthorized` wiring |
| `README.md`, `README_CN.md`, `CLAUDE.md` | Modify | Document new permission flow + ESC handler |

---

# Phase 1 — Track B: Hotkey-Aware Dismiss

## Task 1: Extract pure state-machine struct + tests

**Files:**
- Create: `NemoNotch/Notch/HotkeyDismissState.swift`
- Test: `NemoNotchTests/HotkeyDismissStateTests.swift`

The state-machine has 4 outcomes and 2 inputs — small enough to be tested in isolation, well-bounded enough that NotchCoordinator can stay focused on AppKit glue.

- [ ] **Step 1: Write the failing test file**

Create `NemoNotchTests/HotkeyDismissStateTests.swift`:

```swift
@testable import NemoNotch
import Testing

@Suite("HotkeyDismissState")
struct HotkeyDismissStateTests {
    @Test("Mouse-hover open marks entered immediately so first mouse-leave closes")
    func mouseHoverOpen() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: false)

        #expect(state.mouseHasEnteredContent == true)
        #expect(state.observe(mouseInside: false) == .shouldClose)
    }

    @Test("Hotkey open keeps mouseHasEnteredContent false until mouse enters")
    func hotkeyOpenStartsUnentered() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)

        #expect(state.mouseHasEnteredContent == false)
        #expect(state.observe(mouseInside: false) == .ignore)
    }

    @Test("First mouse-inside event flips flag to entered and reports markedEntered")
    func mouseEnterMarksEntered() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)

        #expect(state.observe(mouseInside: true) == .markedEntered)
        #expect(state.mouseHasEnteredContent == true)
    }

    @Test("After entering, subsequent inside events are ignored")
    func subsequentInsideIgnored() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)
        _ = state.observe(mouseInside: true)

        #expect(state.observe(mouseInside: true) == .ignore)
    }

    @Test("After entering, going outside reports shouldClose")
    func leavingAfterEnterCloses() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)
        _ = state.observe(mouseInside: true)

        #expect(state.observe(mouseInside: false) == .shouldClose)
    }

    @Test("reset clears both flags")
    func resetClears() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)
        _ = state.observe(mouseInside: true)
        state.reset()

        #expect(state.openedViaHotkey == false)
        #expect(state.mouseHasEnteredContent == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/HotkeyDismissStateTests 2>&1 | tail -30`
Expected: compile failure — `HotkeyDismissState` not defined.

- [ ] **Step 3: Implement the struct**

Create `NemoNotch/Notch/HotkeyDismissState.swift`:

```swift
import Foundation

/// Pure state machine for the "should we auto-close when mouse moves outside?"
/// decision. Separated from `NotchCoordinator` so the logic can be unit-tested
/// without instantiating NSPanels.
///
/// Lifecycle: `didOpen(viaHotkey:)` on each open, `observe(mouseInside:)` per
/// mouse-move tick while opened, `reset()` on close.
struct HotkeyDismissState: Equatable {
    enum MoveOutcome: Equatable {
        /// No state change; coordinator should do nothing.
        case ignore
        /// Mouse just entered for the first time. Coordinator should cancel
        /// the hotkey-auto-close timer.
        case markedEntered
        /// Mouse left after having entered. Coordinator should close the notch.
        case shouldClose
    }

    private(set) var openedViaHotkey: Bool = false
    private(set) var mouseHasEnteredContent: Bool = false

    mutating func didOpen(viaHotkey: Bool) {
        openedViaHotkey = viaHotkey
        // Mouse-hover open: cursor is already in the hitbox, so existing
        // "close on leave" semantics apply from frame 1. Hotkey open: cursor
        // is somewhere else, so don't trigger close until it actually arrives.
        mouseHasEnteredContent = !viaHotkey
    }

    mutating func observe(mouseInside: Bool) -> MoveOutcome {
        if mouseInside {
            if mouseHasEnteredContent { return .ignore }
            mouseHasEnteredContent = true
            return .markedEntered
        }
        return mouseHasEnteredContent ? .shouldClose : .ignore
    }

    mutating func reset() {
        openedViaHotkey = false
        mouseHasEnteredContent = false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/HotkeyDismissStateTests 2>&1 | tail -20`
Expected: 6 tests passed.

**Note on adding new files to the Xcode target:** `HotkeyDismissState.swift` and `HotkeyDismissStateTests.swift` must be added to the `NemoNotch` and `NemoNotchTests` targets respectively. If the build fails with "cannot find HotkeyDismissState in scope," open `NemoNotch.xcodeproj`, drag the files into their respective target folders, ensure target membership is checked.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Notch/HotkeyDismissState.swift NemoNotchTests/HotkeyDismissStateTests.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(notch): extract HotkeyDismissState pure state-machine for testability"
```

---

## Task 2: Add `hotkeyAutoCloseDelay` constant

**Files:**
- Modify: `NemoNotch/Helpers/Constants.swift`

- [ ] **Step 1: Add the constant**

In `NemoNotch/Helpers/Constants.swift`, find the "Animation durations" block (around line 26) and add at the end of that block:

```swift
    /// How long the notch stays open after a hotkey-open with no mouse motion
    /// before auto-collapsing. Cancelled the moment the mouse enters content.
    static let hotkeyAutoCloseDelay: TimeInterval = 3.0
```

Place it right after `static let pulseDuration: Double = 1.05` (line 38).

- [ ] **Step 2: Verify build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Helpers/Constants.swift
git commit -m "feat(notch): add hotkeyAutoCloseDelay constant"
```

---

## Task 3: Wire `HotkeyDismissState` into `NotchCoordinator`

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`

This task does NOT add the Timer or ESC monitor yet — just the state struct integration. Splitting these out keeps each diff small.

- [ ] **Step 1: Add the state field**

In `NotchCoordinator.swift`, find the property block around line 11-30 and add after `private(set) var activeScreen: NSScreen?` (around line 16):

```swift
    private var dismissState = HotkeyDismissState()
```

- [ ] **Step 2: Modify `notchOpen` signature and body**

Find the `notchOpen` function (line 172). Change its signature to:

```swift
    func notchOpen(tab: Tab? = nil, on screen: NSScreen? = nil, viaHotkey: Bool = false) {
```

Inside the body, after the line `status = .opened` (currently inside the `withAnimation` block at line 186), and BEFORE `slot.passThrough.isBlocking = true`, add:

```swift
        dismissState.didOpen(viaHotkey: viaHotkey)
```

The full opened block should now look like:

```swift
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        withAnimation(.interactiveSpring(duration: NotchConstants.openSpringDuration)) {
            activeScreen = target
            status = .opened
        }
        dismissState.didOpen(viaHotkey: viaHotkey)
        slot.passThrough.isBlocking = true
        slot.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
```

- [ ] **Step 3: Rewrite the `.opened` branch of `handleMouseMove`**

Find `handleMouseMove` (line 269). Replace the `.opened` branch (lines 276-282):

```swift
        case .opened:
            guard let active = activeScreen else { return }
            let contentHit = contentRect(for: active, hitInset: NotchConstants.closeHitboxInset)
            let mouseInside = NSMouseInRect(location, contentHit, false)
            switch dismissState.observe(mouseInside: mouseInside) {
            case .ignore: break
            case .markedEntered: break  // Timer cancel wired in Task 4
            case .shouldClose: notchClose()
            }
        }
```

- [ ] **Step 4: Add reset to `notchClose`**

Find `notchClose` (line 193). Add at the very top of the function body:

```swift
        dismissState.reset()
```

The full top of the function should now look like:

```swift
    func notchClose() {
        dismissState.reset()
        let openedScreen = activeScreen
        withAnimation(.spring(duration: NotchConstants.closeSpringDuration)) {
```

- [ ] **Step 5: Build and verify**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual smoke test**

Run the app: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -derivedDataPath /tmp/NemoNotch-derived run 2>&1 | tail` — or open in Xcode and Run.

Verify:
- Hover the notch with mouse → it opens and close-on-leave still works (no regression).
- Press the configured global hotkey while mouse is far from notch → notch opens; **moving mouse should NOT close it yet** (because `viaHotkey` defaults to false in app delegate until Task 5, so this won't change until then; but make sure mouse-hover path still works).

Note: Task 5 is required to actually exercise the hotkey-open new behavior.

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift
git commit -m "feat(notch): adopt HotkeyDismissState in NotchCoordinator (no behavior change yet)"
```

---

## Task 4: Add the 3-second auto-close timer

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`

- [ ] **Step 1: Add timer field**

In `NotchCoordinator.swift`, after `private var dismissState = HotkeyDismissState()` (added in Task 3), add:

```swift
    private var hotkeyAutoCloseTimer: Timer?
```

- [ ] **Step 2: Add timer helper methods**

Add these methods at the end of the class (just before the final closing `}`):

```swift
    // MARK: - Hotkey auto-close timer

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

    /// Restart the 3-second grace period. Called when the user uses the
    /// keyboard to switch tabs while the notch is still in its "no-mouse-yet"
    /// phase — treated as continued keyboard engagement.
    func bumpHotkeyAutoCloseTimerIfActive() {
        guard dismissState.openedViaHotkey, !dismissState.mouseHasEnteredContent else { return }
        startHotkeyAutoCloseTimer()
    }
```

- [ ] **Step 3: Schedule timer on hotkey open**

In `notchOpen`, after the line `dismissState.didOpen(viaHotkey: viaHotkey)` (added in Task 3), add:

```swift
        if viaHotkey {
            startHotkeyAutoCloseTimer()
        }
```

- [ ] **Step 4: Cancel timer on mouse enter**

In the `handleMouseMove` `.opened` switch (modified in Task 3), update the `.markedEntered` case:

```swift
            case .markedEntered: cancelHotkeyAutoCloseTimer()
```

- [ ] **Step 5: Cancel timer on close**

In `notchClose`, add right after `dismissState.reset()`:

```swift
        cancelHotkeyAutoCloseTimer()
```

The top of `notchClose` should now be:

```swift
    func notchClose() {
        dismissState.reset()
        cancelHotkeyAutoCloseTimer()
        let openedScreen = activeScreen
```

- [ ] **Step 6: Add logging**

Per CLAUDE.md's logging convention, log timer lifecycle. In `startHotkeyAutoCloseTimer()`, after assigning the timer:

```swift
        LogService.debug(
            "NotchCoordinator: hotkey auto-close armed (\(NotchConstants.hotkeyAutoCloseDelay)s)",
            category: "NotchCoordinator"
        )
```

In `cancelHotkeyAutoCloseTimer()`, gate the log behind a non-nil check:

```swift
    private func cancelHotkeyAutoCloseTimer() {
        guard hotkeyAutoCloseTimer != nil else { return }
        hotkeyAutoCloseTimer?.invalidate()
        hotkeyAutoCloseTimer = nil
        LogService.debug(
            "NotchCoordinator: hotkey auto-close cancelled",
            category: "NotchCoordinator"
        )
    }
```

- [ ] **Step 7: Build and verify**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift
git commit -m "feat(notch): add 3s auto-close timer for hotkey-opened notch"
```

---

## Task 5: Add ESC monitor

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`

- [ ] **Step 1: Add monitor field**

Near the timer field added in Task 4:

```swift
    private var escMonitor: Any?
```

- [ ] **Step 2: Add install/uninstall methods**

Below the timer helpers added in Task 4:

```swift
    // MARK: - ESC monitor

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // kVK_Escape = 53
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    guard let self, self.status == .opened else { return }
                    self.notchClose()
                }
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

- [ ] **Step 3: Install on open**

In `notchOpen`, after the existing `NSApp.activate(ignoringOtherApps: true)` line:

```swift
        installEscMonitor()
```

- [ ] **Step 4: Uninstall on close**

In `notchClose`, after `cancelHotkeyAutoCloseTimer()`:

```swift
        uninstallEscMonitor()
```

Top of `notchClose` should now be:

```swift
    func notchClose() {
        dismissState.reset()
        cancelHotkeyAutoCloseTimer()
        uninstallEscMonitor()
        let openedScreen = activeScreen
```

- [ ] **Step 5: Build and verify**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift
git commit -m "feat(notch): close notch on ESC keypress when opened"
```

---

## Task 6: Update AppDelegate hotkey wiring

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: Pass `viaHotkey: true` for toggleNotch**

In `NemoNotchApp.swift`, find `setupHotkeys` (line 212). Update the `.toggleNotch` handler (lines 213-219):

```swift
        KeyboardShortcuts.onKeyDown(for: .toggleNotch) { [weak coordinator] in
            guard let c = coordinator else { return }
            switch c.status {
            case .closed: c.notchOpen(viaHotkey: true)
            case .opened: c.notchClose()
            }
        }
```

- [ ] **Step 2: Pass `viaHotkey: true` and bump on tab switch**

Update the per-tab hotkey block (lines 221-235):

```swift
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
                        c.bumpHotkeyAutoCloseTimerIfActive()
                    }
                }
            }
        }
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual verification (the real Phase 1 acceptance gate)**

Launch the app and verify each row of the behavioral matrix:

| Scenario | Expected |
|---|---|
| 1. Hotkey-open the notch, do not move mouse | Notch auto-closes after ~3s |
| 2. Hotkey-open, move mouse INTO the notch within 3s | Notch stays open; subsequent mouse-leave closes it |
| 3. Hotkey-open, move mouse around but never into the notch | Notch auto-closes at 3s |
| 4. Hotkey-open, press ESC | Notch closes immediately |
| 5. Hotkey-open, click somewhere outside the notch | Notch closes (existing `handleMouseDown` path) |
| 6. Hotkey-open, press toggle hotkey again | Notch closes |
| 7. Hotkey-open tab A, press tab-B hotkey before mouse arrives | Tab changes to B; timer restarts (have ~3s again) |
| 8. Hover-open (mouse already in notch hitbox) | Existing behavior — moving mouse out closes immediately |
| 9. Hover-open, press ESC | Notch closes immediately (new) |

If any scenario fails, do NOT commit; fix the issue first. Watch `~/.NemoNotch/logs/` for the "hotkey auto-close armed/cancelled" debug lines to confirm the timer is firing correctly.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "feat(notch): hotkey-opened notch survives until mouse arrives or 3s elapses"
```

---

# Phase 2 — Track A: Unified PermissionCard

## Task 7: Add localization keys

**Files:**
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

The xcstrings file is JSON-shaped. Editing it by hand is reasonable for small additions; Xcode will regenerate the file on next clean build but the entries we add will survive.

- [ ] **Step 1: Add the new keys**

Open `NemoNotch/Resources/Localizable.xcstrings`. The top-level shape is `{"sourceLanguage":"en","strings":{...},"version":"1.0"}`. Inside the `strings` dictionary, add the following entries. Insertion order doesn't matter (xcstrings is unordered semantically); convenient location is alphabetical with neighbors `permission.*`.

```json
    "permission.accessibility.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Accessibility Permission Required" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "需要辅助功能权限" } }
      }
    },
    "permission.accessibility.detail" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Used to read Dock badge counts for monitored apps. Enable in System Settings → Privacy & Security → Accessibility." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "用于读取被监控 App 的 Dock 角标。请在 系统设置 → 隐私与安全 → 辅助功能 中开启。" } }
      }
    },
    "permission.automation.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Automation Permission Required" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "需要自动化权限" } }
      }
    },
    "permission.automation.detail" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Used for real playback state and 15-second seek. Click to grant." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "用于真实播放状态读取和 15 秒快进快退。点击授权。" } }
      }
    },
    "permission.calendar.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Calendar Access" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "日历访问权限" } }
      }
    },
    "permission.calendar.detail" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Used to show today's events. Click to grant." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "用于显示日历事件。点击授权。" } }
      }
    },
    "permission.location.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Location Access" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "位置访问权限" } }
      }
    },
    "permission.location.detail" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Used for automatic weather at your location. You can also type a city manually in Settings." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "用于按当前位置自动获取天气。也可以在设置中手动输入城市。" } }
      }
    },
    "permission.grant" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Grant" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "授权" } }
      }
    },
    "permission.open_settings" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Open Settings" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "打开设置" } }
      }
    },
    "permission.denied_explanation" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Permission denied. Open System Settings to change." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "权限被拒绝。打开系统设置修改。" } }
      }
    },
```

- [ ] **Step 2: Verify file is still valid JSON**

Run: `python3 -m json.tool /Users/gaozimeng/Learn/macOS/NemoNotch/NemoNotch/Resources/Localizable.xcstrings > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Resources/Localizable.xcstrings
git commit -m "i18n: add permission.* keys for unified PermissionCard"
```

---

## Task 8: Create the `PermissionCard` component

**Files:**
- Create: `NemoNotch/Helpers/PermissionCard.swift`

- [ ] **Step 1: Implement the component**

Create `NemoNotch/Helpers/PermissionCard.swift`:

```swift
import SwiftUI

/// Three-state representation of any kind of permission this app cares about.
/// `.authorized` is intentionally absent — the parent view is expected to NOT
/// render a `PermissionCard` when the underlying permission is granted, and
/// to render normal feature content instead.
enum PermissionStatus: Equatable {
    case notDetermined
    case denied
    case restricted   // rare; treated like .denied
}

/// How the primary CTA should behave when the permission is in
/// `.notDetermined`. Once `.denied`, the card always falls back to "open
/// System Settings" regardless of this value, because the system dialog
/// can't be re-triggered programmatically.
enum PermissionRequestability {
    case programmatic(() -> Void)
    case settingsOnly
}

struct PermissionCard: View {
    let icon: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
    let status: PermissionStatus
    let primary: PermissionRequestability
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(NotchTheme.accent)
            Text(titleKey)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(detailKey)
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            ctaRow
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var ctaRow: some View {
        switch (status, primary) {
        case (.notDetermined, .programmatic(let action)):
            HStack(spacing: 6) {
                primaryButton(labelKey: "permission.grant", action: action)
                secondaryButton(labelKey: "permission.open_settings", action: openSettings)
            }
        case (.notDetermined, .settingsOnly):
            primaryButton(labelKey: "permission.open_settings", action: openSettings)
        case (.denied, _), (.restricted, _):
            primaryButton(labelKey: "permission.open_settings", action: openSettings)
        }
    }

    private func primaryButton(labelKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(labelKey)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(NotchTheme.accent))
                .foregroundStyle(Color.black.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(labelKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(labelKey)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

If you see "Cannot find 'NotchTheme' in scope": confirm the file's target membership includes `NemoNotch` (Xcode → File inspector → Target Membership).

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Helpers/PermissionCard.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(ui): add shared PermissionCard component"
```

---

## Task 9: Remove Calendar auto-request and wire card

**Files:**
- Modify: `NemoNotch/Services/CalendarService.swift`
- Modify: `NemoNotch/Tabs/OverviewTab.swift`

- [ ] **Step 1: Remove auto-request from CalendarService.init**

In `CalendarService.swift`, find `init()` (line 33). Delete the line `requestAccessIfNeeded()` (line 35). The init should now be:

```swift
    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventsChanged),
            name: .EKEventStoreChanged,
            object: nil
        )
    }
```

- [ ] **Step 2: Delete `requestAccessIfNeeded` private method**

In the same file, delete the entire `requestAccessIfNeeded()` method (lines 82-91):

```swift
    private func requestAccessIfNeeded() {
        switch authorizationStatus {
        case .notDetermined:
            requestAccess()
        case .fullAccess:
            fetchEvents()
        default:
            break
        }
    }
```

- [ ] **Step 3: Ensure `requestAccess` fetches on grant**

Verify the existing `requestAccess()` method (lines 49-61) calls `fetchEvents()` when granted. It does. But if the app starts already-authorized (e.g. user re-launches after a prior grant), nobody calls `fetchEvents()` now that init's `requestAccessIfNeeded` is gone. Fix this — in `init`, after setting `authorizationStatus`, add:

```swift
        if authorizationStatus == .fullAccess {
            fetchEvents()
        }
```

So the full init is:

```swift
    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .fullAccess {
            fetchEvents()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventsChanged),
            name: .EKEventStoreChanged,
            object: nil
        )
    }
```

- [ ] **Step 4: Add request logging**

In `requestAccess()` (line 49), add at the top:

```swift
    func requestAccess() {
        LogService.info("Calendar permission requested by user", category: "Permission")
        Task { @MainActor in
            ...
        }
    }
```

- [ ] **Step 5: Replace OverviewTab calendar placeholder with PermissionCard**

In `OverviewTab.swift`, find `OverviewCalendarSection.body` (line 51). Replace the entire body:

```swift
    var body: some View {
        Group {
            switch calendarService.authorizationStatus {
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
            }
        }
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }
```

- [ ] **Step 6: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Manual verification**

- Reset Calendar permission for NemoNotch: `tccutil reset Calendar com.GaoZimeng.NemoNotch` (replace bundle ID if different — check `Bundle.main.bundleIdentifier`).
- Launch the app. The system **must not** show a Calendar permission dialog automatically.
- Open the notch, switch to Overview tab. The Calendar section shows the PermissionCard with "Grant" button.
- Click "Grant" → system dialog appears → grant → card disappears, calendar shows up.

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Services/CalendarService.swift NemoNotch/Tabs/OverviewTab.swift
git commit -m "feat(calendar): replace startup auto-request with PermissionCard button"
```

---

## Task 10: Remove Location auto-request and wire card

**Files:**
- Modify: `NemoNotch/Services/WeatherService.swift`
- Modify: `NemoNotch/Tabs/OverviewTab.swift`

- [ ] **Step 1: Remove auto-request from WeatherService.init**

In `WeatherService.swift`, find `init()` (line 23). Delete line 27 (`locationManager.requestAlwaysAuthorization()`). Init should now be:

```swift
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationAuthorizationStatus = locationManager.authorizationStatus
        // Defer location monitoring + refresh timer until a view becomes
        // visible — see setActive(_:). The first activation triggers the
        // initial fetch.
    }
```

(The new line `locationAuthorizationStatus = locationManager.authorizationStatus` captures the current state at init.)

- [ ] **Step 2: Add observable status property**

Near the other observable properties (lines 7-16), add:

```swift
    var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
```

- [ ] **Step 3: Add `requestLocationAccess` + `openLocationSettings`**

After `updateCity(_:)` (line 50-54), add:

```swift
    func requestLocationAccess() {
        LogService.info("Location permission requested by user", category: "Permission")
        locationManager.requestAlwaysAuthorization()
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
```

You'll also need `import AppKit` at the top of the file if it's not already imported — check the existing imports. If only `Foundation` and `CoreLocation` are imported, add:

```swift
import AppKit
```

- [ ] **Step 4: Mirror auth status updates into the observable**

In `locationManagerDidChangeAuthorization` (line 58), update the body:

```swift
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            self.locationAuthorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
```

- [ ] **Step 5: Wire the PermissionCard in OverviewTab**

In `OverviewTab.swift`, find `OverviewWeatherSection` (around line 440). Add an env injection at the top of the struct (just below `@Environment(WeatherService.self) var weatherService`):

```swift
    @Environment(AppSettings.self) var appSettings
```

Replace the body:

```swift
    var body: some View {
        Group {
            if !appSettings.weatherCity.isEmpty || weatherService.locationAuthorizationStatus == .authorizedAlways {
                if !weatherService.isLoaded {
                    ProgressView()
                        .controlSize(.small)
                        .tint(NotchTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

- [ ] **Step 6: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Manual verification**

- Reset Location permission: `tccutil reset CoreLocationAgent com.GaoZimeng.NemoNotch` (or use System Settings → Privacy → Location to revoke).
- Make sure no `weatherCity` is set in Settings.
- Launch app. **No** Location dialog appears.
- Open notch → Weather section shows PermissionCard.
- Click "Grant" → dialog appears → grant → card hides, weather loads.
- Set a weatherCity in Settings → card hides immediately regardless of location status.

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Services/WeatherService.swift NemoNotch/Tabs/OverviewTab.swift
git commit -m "feat(weather): replace startup location auto-request with PermissionCard button"
```

---

## Task 11: Clean up MediaService permission-banner state

**Files:**
- Modify: `NemoNotch/Services/MediaService.swift`

This task only removes dead state — the UI swap happens in Task 12.

- [ ] **Step 1: Drop `permissionDeniedPlayer` property**

In `MediaService.swift`, delete lines 13-15:

```swift
    /// When non-nil, UI surfaces a banner prompting the user to grant
    /// Automation permission for this player in System Settings.
    var permissionDeniedPlayer: KnownPlayer?
```

- [ ] **Step 2: Update `permissionDeniedCallback` closure**

In `init()` (line 42), the existing closure at lines 45-50 has:

```swift
        MediaBridge.permissionDeniedCallback = { [weak self] bundleID in
            guard let self else { return }
            permissionDeniedHandler?(bundleID)
            guard let player = KnownPlayer(bundleID: bundleID) else { return }
            permissionDeniedPlayer = player
        }
```

Simplify it to just forward to the handler:

```swift
        MediaBridge.permissionDeniedCallback = { [weak self] bundleID in
            self?.permissionDeniedHandler?(bundleID)
        }
```

- [ ] **Step 3: Delete `dismissPermissionBanner`**

Delete the entire function (lines 56-58):

```swift
    func dismissPermissionBanner() {
        permissionDeniedPlayer = nil
    }
```

- [ ] **Step 4: Simplify `openAutomationSettings`**

Find `openAutomationSettings()` (lines 60-63). Replace with:

```swift
    func openAutomationSettings() {
        MediaBridge.openAutomationSettings()
    }
```

- [ ] **Step 5: Add `requestAutomationAccess(for:)`**

Right after `openAutomationSettings()`, add:

```swift
    /// Probe the bundle's Automation permission. The probe IS the request —
    /// sending an AppleEvent (which `hasAutomationAccess` does internally) is
    /// what triggers the system permission dialog when the state is
    /// `.notDetermined`. If already `.denied`, the system won't re-show the
    /// dialog; the user must open Settings.
    func requestAutomationAccess(for player: KnownPlayer) {
        LogService.info(
            "Automation permission requested for \(player.rawValue)",
            category: "Permission"
        )
        _ = MediaBridge.hasAutomationAccess(bundleID: player.rawValue)
    }
```

- [ ] **Step 6: Delete `recheckPermissionIfBannerShown`**

Find it (lines 241-246). Delete the function entirely:

```swift
    private func recheckPermissionIfBannerShown() {
        guard let player = permissionDeniedPlayer else { return }
        if MediaBridge.hasAutomationAccess(bundleID: player.rawValue) {
            permissionDeniedPlayer = nil
        }
    }
```

Also delete the call site — find line 236: `self?.recheckPermissionIfBannerShown()` and remove it. Look at the surrounding context (lines 233-238) which should be inside a notification handler:

```swift
        nowPlayingObserver = NotificationCenter.default.addObserver(
            forName: ...,
            ...
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateNowPlaying()
                self?.recheckPermissionIfBannerShown()  // ← delete this line
            }
        }
```

- [ ] **Step 7: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

If you see "use of unresolved identifier 'permissionDeniedPlayer'" or similar, search for any remaining references — Task 12 will swap the UI, but the compilation step here must not depend on any UI changes:

```bash
grep -rn "permissionDeniedPlayer\|dismissPermissionBanner\|recheckPermissionIfBannerShown" NemoNotch/
```

The only matches should be in `OverviewTab.swift` — those get removed in Task 12.

**Important:** This task by itself will fail to build because `OverviewTab.swift:214` still references `mediaService.permissionDeniedPlayer`. To avoid an intermediate broken state, **do not commit until Task 12 is done**. Squash these into one logical change at the end of Task 12.

- [ ] **Step 8: (No commit yet — proceed to Task 12)**

---

## Task 12: Wire Automation PermissionCard in OverviewTab

**Files:**
- Modify: `NemoNotch/Notch/NotchView.swift`
- Modify: `NemoNotch/NemoNotchApp.swift`
- Modify: `NemoNotch/Tabs/OverviewTab.swift`

- [ ] **Step 1: Inject monitor into NotchView env in AppDelegate**

In `NemoNotchApp.swift`, find the `notchCoordinator` setup (line 160-175). Update the content closure to inject `permissionMonitor`:

```swift
        let notchCoordinator = NotchCoordinator { coordinator, screen in
            AnyView(
                NotchView(screen: screen)
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(permissionMonitor)
                    .environment(calendar)
                    .environment(aiMonitor)
                    .environment(registry)
                    .environment(launcher)
                    .environment(notification)
                    .environment(weather)
                    .environment(hud)
                    .environment(system)
            )
        }
```

(The new line is `.environment(permissionMonitor)`. Variable `permissionMonitor` already exists at line 104.)

- [ ] **Step 2: Add monitor accessor to OverviewMediaSection**

In `OverviewTab.swift`, find `OverviewMediaSection` (around line 205). Add a new environment injection at the top:

```swift
private struct OverviewMediaSection: View {
    @Environment(MediaService.self) var mediaService
    @Environment(MediaAutomationPermissionMonitor.self) var automationMonitor
```

- [ ] **Step 3: Compute card visibility**

Inside `OverviewMediaSection`, add a computed property:

```swift
    private var automationCardPlayer: KnownPlayer? {
        guard let bundleID = mediaService.playbackState.appBundleIdentifier,
              let player = KnownPlayer(bundleID: bundleID) else { return nil }
        return automationMonitor.state(for: bundleID) == .authorized ? nil : player
    }
```

- [ ] **Step 4: Replace body to use PermissionCard**

Replace the existing body (lines 212-226):

```swift
    var body: some View {
        VStack(spacing: 6) {
            if let player = automationCardPlayer {
                PermissionCard(
                    icon: "lock.shield",
                    titleKey: "permission.automation.title",
                    detailKey: "permission.automation.detail",
                    status: automationMonitor.state(for: player.rawValue) == .denied
                        ? .denied
                        : .notDetermined,
                    primary: .programmatic {
                        mediaService.requestAutomationAccess(for: player)
                    },
                    openSettings: { mediaService.openAutomationSettings() }
                )
            } else {
                artwork
                trackInfo
                progressBar
                controls
            }
        }
        .padding(6)
        .frame(maxHeight: .infinity, alignment: .center)
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }
```

- [ ] **Step 5: Delete the old `permissionBanner` helper**

Find the `permissionBanner(player:)` function (lines 228-261) in `OverviewMediaSection` and delete it entirely.

- [ ] **Step 6: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Manual verification**

- Reset Automation permission: `tccutil reset AppleEvents com.GaoZimeng.NemoNotch`.
- Launch app, start playing music in Apple Music.
- Open notch → Overview → Media section shows PermissionCard with "Grant" button (state is `.notDetermined` / `.unknown` in monitor).
- Click "Grant" → system Automation dialog appears for Music → grant → card hides, full media controls render.
- Repeat with Spotify if installed.

- [ ] **Step 8: Drop the now-dead `permissionMonitor.onAuthorized` wiring**

In `NemoNotchApp.swift` (line 110-116), the existing block:

```swift
        permissionMonitor.onAuthorized = { [weak media] bundleID in
            guard let media,
                  let player = KnownPlayer(bundleID: bundleID),
                  media.permissionDeniedPlayer == player
            else { return }
            media.permissionDeniedPlayer = nil
        }
```

This references the now-deleted `permissionDeniedPlayer`. Delete the entire `permissionMonitor.onAuthorized = { ... }` assignment.

The `onAuthorized` property on `MediaAutomationPermissionMonitor` becomes orphaned. Decide:
- **Keep it** in `MediaAutomationPermissionMonitor.swift` since it's API surface and harmless (no callers).
- Or, delete it to keep code tight.

For YAGNI, delete it. In `MediaAutomationPermissionMonitor.swift`, remove the `var onAuthorized: ((String) -> Void)?` declaration (line 25) and its invocation (line 70 `onAuthorized?(bundleID)`).

- [ ] **Step 9: Commit (squashing Tasks 11 + 12)**

```bash
git add NemoNotch/Services/MediaService.swift \
        NemoNotch/Services/MediaAutomationPermissionMonitor.swift \
        NemoNotch/Tabs/OverviewTab.swift \
        NemoNotch/Notch/NotchView.swift \
        NemoNotch/NemoNotchApp.swift \
        NemoNotch/Resources/Localizable.xcstrings
git commit -m "feat(media): replace permissionDeniedPlayer banner with PermissionCard"
```

---

## Task 13: AX PermissionCard in Settings

**Files:**
- Modify: `NemoNotch/Settings/SettingsView.swift`

- [ ] **Step 1: Replace the AX warning section**

In `SettingsView.swift`, find `notificationListView` (line 331). Replace the `if !notificationService.isAXTrusted { Section {...} }` block (lines 333-349):

```swift
            if !notificationService.isAXTrusted {
                Section {
                    PermissionCard(
                        icon: "exclamationmark.triangle.fill",
                        titleKey: "permission.accessibility.title",
                        detailKey: "permission.accessibility.detail",
                        status: .notDetermined,
                        primary: .settingsOnly,
                        openSettings: { notificationService.openAccessibilitySettings() }
                    )
                    .padding(.vertical, 4)
                }
            }
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual verification**

- If AX is currently granted, revoke it in System Settings → Privacy & Security → Accessibility → uncheck NemoNotch.
- Restart NemoNotch.
- Open Settings → Notifications tab → AX card renders with "Open Settings" CTA.
- Click → System Settings opens to the right pane.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Settings/SettingsView.swift
git commit -m "feat(notifications): adopt PermissionCard for AX prompt in Settings"
```

---

## Task 14: Sweep dead localization keys

**Files:**
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

The old `calendar.permission_required`, `calendar.request_access`, `settings.accessibility_required`, `settings.accessibility_description`, `settings.open_system_settings` (if no longer used elsewhere) keys are now orphans. Sweep them.

- [ ] **Step 1: Find usage of old keys**

```bash
grep -rn 'calendar.permission_required\|calendar.request_access\|settings.accessibility_required\|settings.accessibility_description' NemoNotch/
```

Expected: zero matches (because Tasks 9 and 13 removed the call sites).

- [ ] **Step 2: Check `settings.open_system_settings`**

```bash
grep -rn 'settings.open_system_settings' NemoNotch/
```

If non-empty, leave the key. If empty, sweep it too.

- [ ] **Step 3: Mark unused keys as stale in xcstrings**

For each unused key, change its `extractionState` to `"stale"` (or delete the entry). Per the existing convention in this file (e.g. `calendar.request_access` already shows `"extractionState" : "stale"`), prefer marking stale over deletion — Xcode will auto-prune them on next clean string-extraction run.

Add to each unused entry:

```json
    "calendar.permission_required" : {
      "extractionState" : "stale",
      "localizations" : { ... }
    },
```

- [ ] **Step 4: Verify JSON**

Run: `python3 -m json.tool /Users/gaozimeng/Learn/macOS/NemoNotch/NemoNotch/Resources/Localizable.xcstrings > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 5: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Resources/Localizable.xcstrings
git commit -m "i18n: mark superseded permission-prompt keys stale"
```

---

## Task 15: Run the full test suite

**Files:**
- None.

- [ ] **Step 1: Run all tests**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -40`

Expected:
- All `HotkeyDismissStateTests` pass (Phase 1).
- All pre-existing tests still pass (no regressions).
- TEST SUCCEEDED at the bottom.

If a pre-existing test fails, investigate before continuing. Do not "fix" by deleting tests.

---

## Task 16: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `README_CN.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md**

In `CLAUDE.md`, the Architecture Overview's "Notch Event Flow" sequence should mention ESC and the 3s grace. Find the section after the existing sequence diagram and add a paragraph in plain prose, OR amend the diagram. Minimal approach — add a bullet under "Notch UI Layer" describing the new gates:

After the "## Architecture" → "### Notch Event Flow" section, append:

```markdown
**Hotkey-aware dismiss:** When the notch is opened via global hotkey, it does NOT close on mouse-move-outside until either (a) the mouse enters the content area at least once, (b) 3 seconds elapse with no mouse entry (`NotchConstants.hotkeyAutoCloseDelay`), or (c) the user presses ESC / hotkey / clicks outside. Mouse-hover open path is unchanged. State machine lives in `HotkeyDismissState`.

**Permission UI pattern:** Calendar, Location, and Automation permissions are NOT auto-requested on launch. Instead the relevant Tab section renders a `PermissionCard` with a "Grant" button. AX uses the same card but only links to System Settings (no programmatic request API). Card lives at `NemoNotch/Helpers/PermissionCard.swift`.
```

- [ ] **Step 2: Update README.md**

In the features section, find the description of permissions / setup. Add or update a line describing the user flow:

```markdown
- **Explicit permission requests.** NemoNotch does not auto-request permissions on launch. Each feature surfaces a "Grant Access" button (Calendar in the Overview tab, Location in the Weather card, Automation in the Media card when controlling Music/Spotify) — click to invoke the system dialog.
- **ESC closes the notch.** Press ESC any time the notch is opened.
```

- [ ] **Step 3: Update README_CN.md**

Mirror the README.md changes in Chinese:

```markdown
- **显式权限请求。** NemoNotch 启动时不会自动申请系统权限。每个需要权限的功能会在对应 Tab 中显示「授权」按钮(Overview 的日历、Weather 卡片的定位、Media 卡片控制 Music/Spotify 时的自动化)— 点击触发系统弹窗。
- **ESC 关闭 Notch。** notch 打开时按 ESC 即可关闭。
```

- [ ] **Step 4: Commit**

```bash
git add README.md README_CN.md CLAUDE.md
git commit -m "docs: document PermissionCard pattern and hotkey-aware dismiss"
```

---

## Final Verification

Run the full behavioral matrix from the spec one more time:

- [ ] Cold-start with all four permissions revoked: **no** system dialogs appear automatically.
- [ ] Calendar PermissionCard → Grant → calendar shows up.
- [ ] Location PermissionCard → Grant → weather loads.
- [ ] Automation card shows for unauthorized known player; Grant → system dialog → controls render.
- [ ] AX card in Settings → Notifications opens Settings to the right pane.
- [ ] Hotkey-open + no mouse motion → closes at ~3s.
- [ ] Hotkey-open + mouse arrives → stays; leave → closes.
- [ ] Hotkey-open + ESC → closes.
- [ ] Hotkey-open + tab hotkey to switch tab → timer resets, ~3 more seconds.
- [ ] Mouse-hover open path: regression-free.

All checks green → branch is ready for review / merge to `develop`.

---

## Notes for the Implementer

- **Logging is mandatory** for service-level state changes per CLAUDE.md's logging conventions. The plan calls out the key sites (Calendar/Location/Automation request invocation, hotkey timer arm/cancel). If you add other side-effect code, add corresponding `LogService.debug/info/warn` calls with sensible categories.
- **Adding new files to the Xcode target**: every `Create:` file must be added to the appropriate target. If you forget, the build will fail with "cannot find ... in scope." Fix via Xcode → Add Files (or drag), and check target membership.
- **TCC reset commands**: `tccutil reset Calendar com.GaoZimeng.NemoNotch`, `tccutil reset AppleEvents com.GaoZimeng.NemoNotch`. For Location and AX you must revoke via System Settings (no `tccutil` service name for those that reliably works across macOS versions).
- **Bundle ID**: confirm via `defaults read /Users/gaozimeng/Learn/macOS/NemoNotch/build/<derived>/NemoNotch.app/Contents/Info.plist CFBundleIdentifier` if the resets don't seem to take effect.
- **No `--no-verify`**: if a pre-commit hook fails, fix the underlying issue. Don't bypass.
