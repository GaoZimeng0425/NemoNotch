# Remove AppDelegate.shared Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate `nonisolated(unsafe) static var shared = AppDelegate()` by deleting dead code that exists only to support it, and replacing the 3 real external callsites with closure injection (NotchCoordinator) and a constructor arg (MenuContent). Zero `AppDelegate.shared` references after.

**Architecture:** Pure structural refactor; no behavior change. Strategy: add the new injection points first (additive, build-green), wire AppDelegate to populate them (still additive), switch consumer reads to use them (now both old and new paths exist; build-green), then delete the dead code and the static var in one step. If anything was missed, the build at the last step catches it.

**Tech Stack:** Swift 6, SwiftUI. Verification: `xcodebuild` per step + final user smoke test (no unit test infrastructure).

**Spec:** `docs/superpowers/specs/2026-05-15-remove-appdelegate-shared-design.md`

---

## Verification Conventions

- **Build gate** (after every code change):
  ```
  xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
  ```
  Expected: `** BUILD SUCCEEDED **`

- **Smoke test gate**: consolidated to a single user UAT at the end (intermediate "launch the app" steps cannot be automated).

- **Commit hook**: pre-commit hook blocks commits on `main` and runs swiftformat. Both expected.

---

## Task 0: Create Feature Branch

**Files:** none

- [ ] **Step 1: Verify clean working tree on develop**

```bash
git status
```

Expected: `On branch develop` and `nothing to commit, working tree clean`. If not clean, stop.

- [ ] **Step 2: Create and switch to feature branch**

```bash
git checkout -b feature/remove-appdelegate-shared
```

Expected: `Switched to a new branch 'feature/remove-appdelegate-shared'`

---

## Task 1: Add Injection Points and Wire Them

Add the new closure properties on `NotchCoordinator`, add the new constructor arg on `MenuContent`, and have `AppDelegate` populate them. This task is purely additive — the old `AppDelegate.shared` reads still work; nothing has switched over yet.

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: Add closure properties to NotchCoordinator**

In `NemoNotch/Notch/NotchCoordinator.swift`, find the existing `autoSelectTab` declaration (around line 19):

```swift
var autoSelectTab: (() -> Tab?)?
var appSettings: AppSettings?
```

Add two new lines immediately after `var appSettings: AppSettings?`:

```swift
var autoSelectTab: (() -> Tab?)?
var appSettings: AppSettings?
var restoreSuppressionCheck: (() -> Bool)?
var onShowSettings: (() -> Void)?
```

- [ ] **Step 2: Add `appSettings` parameter to MenuContent**

In `NemoNotch/NemoNotchApp.swift`, find the `MenuContent` struct (around lines 32–36):

```swift
struct MenuContent: View {
    @Environment(AICLIMonitorService.self) var aiService
    let coordinator: NotchCoordinator?
    let onOpenSettings: () -> Void
```

Add a new `let` between `coordinator` and `onOpenSettings`:

```swift
struct MenuContent: View {
    @Environment(AICLIMonitorService.self) var aiService
    let coordinator: NotchCoordinator?
    let appSettings: AppSettings?
    let onOpenSettings: () -> Void
```

- [ ] **Step 3: Update the MenuContent construction site**

Same file, find the `MenuContent(...)` call in `NemoNotchApp.body` (around lines 12–16):

```swift
MenuContent(
    coordinator: appDelegate.coordinator,
    onOpenSettings: { appDelegate.showSettings() }
)
```

Add the `appSettings:` argument between `coordinator:` and `onOpenSettings:`:

```swift
MenuContent(
    coordinator: appDelegate.coordinator,
    appSettings: appDelegate.appSettings,
    onOpenSettings: { appDelegate.showSettings() }
)
```

- [ ] **Step 4: Wire AppDelegate to populate the closures**

Same file. Find the block in `applicationDidFinishLaunching` where `autoSelectTab` and `appSettings` are assigned to `notchCoordinator` (around lines 165–176):

```swift
notchCoordinator.autoSelectTab = { [weak self] in
    guard let self else { return nil }
    if let session = aiMonitorService?.activeSession, session.status == .working {
        return .claude
    }
    if agentRegistry?.hasAnyActiveAgent == true { return .agents }
    if mediaService?.playbackState.isPlaying == true { return .overview }
    return nil
}
notchCoordinator.appSettings = settings
coordinator = notchCoordinator
```

Insert two new closure assignments **between** `notchCoordinator.appSettings = settings` and `coordinator = notchCoordinator`:

```swift
notchCoordinator.autoSelectTab = { [weak self] in
    guard let self else { return nil }
    if let session = aiMonitorService?.activeSession, session.status == .working {
        return .claude
    }
    if agentRegistry?.hasAnyActiveAgent == true { return .agents }
    if mediaService?.playbackState.isPlaying == true { return .overview }
    return nil
}
notchCoordinator.appSettings = settings
notchCoordinator.restoreSuppressionCheck = { [weak self] in
    self?.shouldSuppressPreviousAppRestore ?? false
}
notchCoordinator.onShowSettings = { [weak self] in
    self?.showSettings()
}
coordinator = notchCoordinator
```

- [ ] **Step 5: Build**

```
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift NemoNotch/NemoNotchApp.swift
git commit -m "$(cat <<'EOF'
feat(remove-shared): add closure/arg injection points

Adds restoreSuppressionCheck and onShowSettings closure properties
on NotchCoordinator (matching the existing autoSelectTab pattern),
and an appSettings constructor arg on MenuContent. AppDelegate
populates the closures after coordinator construction. Nothing
reads them yet — switchover happens in the next commit.
EOF
)"
```

---

## Task 2: Switch Consumer Reads to Use Injected Values

All three real callsites swap `AppDelegate.shared.X` for the injected value/closure. Build still green because the static var is still alive; nothing has been deleted.

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: Switch NotchCoordinator.restorePreviousApp**

In `NemoNotch/Notch/NotchCoordinator.swift`, find `restorePreviousApp()` (around lines 228–240):

```swift
private func restorePreviousApp() {
    if AppDelegate.shared.shouldSuppressPreviousAppRestore {
        previousApp = nil
        return
    }
    // ... rest unchanged
}
```

Change only that one line:

```swift
private func restorePreviousApp() {
    if restoreSuppressionCheck?() == true {
        previousApp = nil
        return
    }
    // ... rest unchanged
}
```

- [ ] **Step 2: Switch NotchCoordinator's right-click menu Settings handler**

Same file. Find the `ContextMenuDelegate(...)` construction inside `handleRightMouseDown(...)` (around line 326–330):

```swift
let delegate = ContextMenuDelegate(
    onClose: { [weak self] in self?.isContextMenuVisible = false },
    onSettings: { @MainActor in AppDelegate.shared.showSettings() },
    onQuit: { NSApp.terminate(nil) }
)
```

Replace the `onSettings:` line:

```swift
let delegate = ContextMenuDelegate(
    onClose: { [weak self] in self?.isContextMenuVisible = false },
    onSettings: { @MainActor [weak self] in self?.onShowSettings?() },
    onQuit: { NSApp.terminate(nil) }
)
```

(`@MainActor` and `[weak self]` both apply to the closure.)

- [ ] **Step 3: Switch MenuContent locale lookup**

In `NemoNotch/NemoNotchApp.swift`, find the `.environment(\.locale, ...)` modifier on the Quit button (around line 72):

```swift
Button("menu.quit") {
    NSApplication.shared.terminate(nil)
}
.environment(\.locale, AppDelegate.shared.appSettings?.currentLocale ?? Locale.current)
```

Change the `.environment(...)` line to use the local `appSettings` property:

```swift
Button("menu.quit") {
    NSApplication.shared.terminate(nil)
}
.environment(\.locale, appSettings?.currentLocale ?? Locale.current)
```

- [ ] **Step 4: Build**

```
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Verify no consumer still reads AppDelegate.shared**

```bash
grep -rn "AppDelegate\.shared\." NemoNotch/
```

Expected: Only the **assignment** in `applicationDidFinishLaunching` (`AppDelegate.shared = self`) and the **read** in `NemoNotchApp.init()` (`let delegate = AppDelegate.shared`) should remain. The 3 consumer reads (locale, restore suppression, show settings) should all be gone. If any consumer read remains, stop and audit.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift NemoNotch/NemoNotchApp.swift
git commit -m "$(cat <<'EOF'
refactor(remove-shared): consumers read from injected values

Switches the 3 real AppDelegate.shared callsites (locale lookup in
MenuContent, restore-suppression check + showSettings in
NotchCoordinator) to use the closures/arg added in the previous
commit. Static var still exists but is no longer read by consumers.
EOF
)"
```

---

## Task 3: Delete the Dead Code

Remove the `static var shared` declaration, the dead `@State` property, and the lines that exist only to support them. Build catches any missed reference at compile time.

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: Delete the dead @State property**

In `NemoNotch/NemoNotchApp.swift`, line 8:

```swift
@State private var appDelegateRef: AppDelegate?
```

Delete this line.

- [ ] **Step 2: Delete the dead init body lines**

Same file, find `NemoNotchApp.init()` (around lines 25–29):

```swift
init() {
    signal(SIGPIPE, SIG_IGN)
    let delegate = AppDelegate.shared
    _appDelegateRef = State(initialValue: delegate)
}
```

Delete the two middle lines so it becomes:

```swift
init() {
    signal(SIGPIPE, SIG_IGN)
}
```

- [ ] **Step 3: Delete the static var declaration**

Same file, find line 80:

```swift
nonisolated(unsafe) static var shared = AppDelegate()
```

Delete this line.

- [ ] **Step 4: Delete the assignment in applicationDidFinishLaunching**

Same file, find inside `applicationDidFinishLaunching(_:)` (around line 106):

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    AppDelegate.shared = self
    NSApp.setActivationPolicy(.accessory)
    // ...
}
```

Delete the `AppDelegate.shared = self` line:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    // ...
}
```

- [ ] **Step 5: Build**

```
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

If build fails with "type 'AppDelegate' has no member 'shared'": some reference was missed. Run `grep -rn "AppDelegate\.shared" NemoNotch/` and fix the leftover before continuing.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "$(cat <<'EOF'
refactor(remove-shared): delete AppDelegate.shared and supporting dead code

Removes:
- nonisolated(unsafe) static var shared = AppDelegate()
- The @State appDelegateRef property (never read)
- The init lines that captured .shared into appDelegateRef
- The .shared = self assignment in applicationDidFinishLaunching

@NSApplicationDelegateAdaptor remains the sole instance source. No
behavior change.
EOF
)"
```

---

## Task 4: Completion Audit + UAT Handoff

**Files:** none (verification only)

- [ ] **Step 1: Verify completion criteria from the spec**

```bash
grep -rn "AppDelegate\.shared\|appDelegateRef" NemoNotch/
```

Expected: **zero matches**.

```bash
grep -n "static var shared" NemoNotch/NemoNotchApp.swift
```

Expected: **zero matches**.

Note: project-wide `nonisolated(unsafe)` survives — it's used legitimately in `HookServer.swift`, `NowPlayingCLI.swift`, `CalendarService.swift`, and `LogService.swift`. That's expected and per the spec.

- [ ] **Step 2: Hand off the smoke test to the user**

The user runs these checks manually (cannot be automated):

1. **Launch**: app launches without crash; menu bar icon appears.
2. **Menu bar locale**: right-click menu items render in the configured locale. (If app locale = zh-Hans, items show in Chinese; English otherwise.)
3. **Open notch + right-click → Settings**: Settings window opens correctly.
4. **Previous-app restore**: focus another app (e.g., Safari); open notch via menu bar; click outside the notch to close; Safari (the previous app) regains focus.
5. **Restore suppression after Settings**: open notch; right-click → Settings; close Settings; focus back to the original app (not jumping to some other previous app due to the 1.2s suppression window).

If any check fails, capture what happened and report — the most likely failure is a missed callsite, but Task 3 Step 5's build would have caught that.

- [ ] **Step 3: Push branch and open PR (optional)**

```bash
git push -u origin feature/remove-appdelegate-shared
gh pr create --title "refactor: remove AppDelegate.shared singleton" --body "$(cat <<'EOF'
## Summary

- Removes `nonisolated(unsafe) static var shared = AppDelegate()` and the dead `@State appDelegateRef` property that existed only to support it
- 3 real callsites (locale lookup in MenuContent, restore-suppression + showSettings in NotchCoordinator) switch to closure injection (matching the existing `autoSelectTab` pattern) and a constructor argument
- `@NSApplicationDelegateAdaptor` becomes the sole AppDelegate instance source

## Test plan

- [x] `xcodebuild` succeeds at every commit
- [ ] App launches; menu locale correct
- [ ] Right-click notch → Settings opens
- [ ] Previous-app restore works after closing notch
- [ ] Restore-suppression works after closing Settings

Spec: docs/superpowers/specs/2026-05-15-remove-appdelegate-shared-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Skip if merging directly to develop is preferred.

---

## Rollback Notes

Each task is a single revertable commit:
- Task 3 revert → restores the static var + dead code (consumer reads still use closures, harmless)
- Task 2 revert → restores `AppDelegate.shared.X` reads (static var still alive, closures still set, both paths work)
- Task 1 revert → removes the injection points (only safe if Task 2 has also been reverted)
