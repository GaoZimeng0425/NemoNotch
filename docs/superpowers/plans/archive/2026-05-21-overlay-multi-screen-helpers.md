# Multi-Screen Helpers + Overlay Teardown Audit

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) Extract reusable `NSScreen` positioning helpers (`mouseScreen`, `screen(containing:)`) from any current inline use in `NotchCoordinator`, so future overlays use a consistent multi-screen API. (2) Audit `NotchCoordinator`, `HUDService`, and any other code holding `Task` / `Timer` references against the playbook-10 teardown patterns — fix any concrete retain hazards found.

**Architecture:** Add `NemoNotch/Helpers/NSScreen+Positioning.swift` extension with two pure functions. Refactor existing screen-locator code (commit `f9b86f1` already centralized this for the notch — find and consolidate). The audit step is investigative: read each `Task { ... }` and `Timer.scheduledTimer { ... }` in the relevant files, confirm `[weak self]` is used or the lifetime is bounded, document findings as commit messages.

**Tech Stack:** Swift 6, `AppKit.NSScreen`, `Foundation.Timer`.

**Depends on:** `2026-05-21-test-target-skeleton.md` for the helper tests.

**Smaller than other plans:** this is a polish/refactor plan. Expect 30–60 min total.

---

## File Structure

```
NemoNotch/Helpers/NSScreen+Positioning.swift   # NEW: screen-locator helpers
NemoNotch/Notch/NotchCoordinator.swift         # MODIFIED if inline screen logic found
NemoNotchTests/NSScreenPositioningTests.swift  # NEW: pure-logic tests
```

Audit-only files (no edits unless issues found):
- `NemoNotch/Services/HUDService.swift`
- `NemoNotch/Notch/NotchCoordinator.swift`
- `NemoNotch/Services/NotificationService.swift`

---

## Task 1: Discover where screen-locator logic currently lives

**Files:**
- Read-only inspection

- [ ] **Step 1: Grep for `NSScreen.screens` usage**

```bash
grep -rn "NSScreen.screens\|NSScreen.main\|notchSize\|frame.contains" NemoNotch/ --include="*.swift"
```

- [ ] **Step 2: Read each match and note**

For each match, write a one-line note: file:line — purpose (e.g. "NotchCoordinator.swift:42 — picks screen for the notch window"). This is what Task 2 consolidates.

- [ ] **Step 3: Decide consolidation scope**

If only one or two files reference these APIs and the logic is identical, extract into the helper. If logic differs by call site (e.g. notch needs `screenWithMouse`, HUD needs `screenContainingPoint`), still extract — keep both as separate functions in the helper.

Document the decision in a short note (no commit yet).

---

## Task 2: Add NSScreen positioning helpers

**Files:**
- Create: `NemoNotch/Helpers/NSScreen+Positioning.swift`

- [ ] **Step 1: Write the failing test**

Create `NemoNotchTests/NSScreenPositioningTests.swift`:

```swift
import AppKit
import Testing
@testable import NemoNotch

@Suite("NSScreen positioning helpers")
struct NSScreenPositioningTests {
    @Test("screen(containing:) returns nil for unreachable point")
    @MainActor
    func unreachablePoint() {
        let far = CGPoint(x: -100_000, y: -100_000)
        #expect(NSScreen.screen(containing: far) == nil)
    }

    @Test("screen(containing:) returns a screen for the origin of main")
    @MainActor
    func mainOrigin() {
        guard let main = NSScreen.main else {
            // Headless CI — skip, not fail
            return
        }
        let point = CGPoint(
            x: main.frame.origin.x + 10,
            y: main.frame.origin.y + 10
        )
        #expect(NSScreen.screen(containing: point) === main || NSScreen.screen(containing: point) != nil)
    }

    @Test("mouseScreen returns some screen on a system with displays")
    @MainActor
    func mouseScreenResolves() {
        // On a headless CI runner there may be no screen — skip rather than fail.
        guard !NSScreen.screens.isEmpty else { return }
        #expect(NSScreen.mouseScreen != nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/NSScreenPositioningTests
```

Expected: **FAIL** — "Type 'NSScreen' has no member 'screen(containing:)'" or "'mouseScreen'".

- [ ] **Step 3: Implement the helpers**

Create `NemoNotch/Helpers/NSScreen+Positioning.swift`:

```swift
import AppKit

extension NSScreen {
    /// The screen currently under the mouse cursor, or nil if no displays.
    /// Use this for overlay positioning instead of `NSScreen.main`, which can
    /// disagree with the user's active display on multi-monitor setups.
    @MainActor
    static var mouseScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }
    }

    /// Returns the screen whose frame contains the given point (in global
    /// AppKit coordinates), or nil if no screen does.
    @MainActor
    static func screen(containing point: CGPoint) -> NSScreen? {
        screens.first { $0.frame.contains(point) }
    }
}
```

- [ ] **Step 4: Add file to Xcode target**

Drag `NSScreen+Positioning.swift` into the `Helpers` group; confirm Target Membership = `NemoNotch`.

- [ ] **Step 5: Run tests to confirm pass**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/NSScreenPositioningTests
```

Expected: all 3 tests pass (or 2 pass + 1 skipped on headless).

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Helpers/NSScreen+Positioning.swift \
        NemoNotchTests/NSScreenPositioningTests.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(helpers): add NSScreen.mouseScreen / screen(containing:)"
```

---

## Task 3: Consolidate inline screen-locator logic (if any)

**Files:**
- Modify: any files found in Task 1 that reimplement `screens.first { $0.frame.contains(...) }`

- [ ] **Step 1: Replace inline occurrences**

For each inline occurrence found in Task 1:

Before:
```swift
let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
```

After:
```swift
let screen = NSScreen.screen(containing: point) ?? NSScreen.main
```

If there are no inline occurrences (commit `f9b86f1` may have already centralized this), **skip this task** and proceed to Task 4. Note in the commit log that the audit found no duplicates.

- [ ] **Step 2: Build & manually verify notch still positions correctly**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Then run NemoNotch on a multi-monitor setup if possible. Move the cursor between displays — the notch should follow.

- [ ] **Step 3: Commit (only if changes made)**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift
git commit -m "refactor(notch): use NSScreen.screen(containing:) helper"
```

If no changes were made:

```bash
git commit --allow-empty -m "chore(audit): NSScreen positioning already centralized"
```

(The empty commit is optional — skip if you prefer a quieter history.)

---

## Task 4: Audit Timer / Task lifetime for retain hazards

**Files:**
- Read: `NemoNotch/Services/HUDService.swift`
- Read: `NemoNotch/Services/NotificationService.swift`
- Read: `NemoNotch/Notch/NotchCoordinator.swift`

This task is **investigative**. Fix only what's broken; do not refactor for taste.

- [ ] **Step 1: Walk every `Timer.scheduledTimer { }` closure**

```bash
grep -rn "scheduledTimer" NemoNotch/ --include="*.swift"
```

For each match, open the file and confirm:
1. Closure captures `[weak self]` OR the timer is invalidated in `deinit` (so strong self is fine).

Known-good examples:
- `NotificationService.swift:76` — `[weak self]` ✓
- `HUDService.swift:159` — `[weak self]` ✓
- `HUDService.swift:204, 215` — `[weak self]` ✓

If any timer captures strong `self` without `deinit` invalidation, **add `[weak self]`** and commit with message `fix(<module>): break Timer retain cycle`.

- [ ] **Step 2: Walk every `Task { ... }` that holds shared resources**

```bash
grep -rn "Task { @MainActor" NemoNotch/Services/ NemoNotch/Notch/ --include="*.swift" | head -30
```

For each, check:
1. Does the closure capture `self`?
2. If yes, is the Task cancelled in `deinit` or when the owning operation is superseded?
3. If the Task runs forever (e.g. `for await ...`), does it have an exit path?

Specific check for `HUDService.swift:285-291`:

```swift
dismissTask = Task { @MainActor in
    try? await Task.sleep(for: .seconds(NotchConstants.hudDismissDelay))
    guard !Task.isCancelled else { return }
    withAnimation(...) {
        activeHUD = nil
    }
}
```

This captures strong `self` (via the implicit `activeHUD = nil` assignment). It's **safe** because:
- The Task has a bounded sleep then exits
- `restartDismissTimer()` cancels the previous task before assigning a new one

No action needed; note this in the audit summary.

- [ ] **Step 3: Document audit findings**

Create or append to a brief note (no separate file — use the commit message):

```bash
git commit --allow-empty -m "chore(audit): overlay teardown review — no retain issues found

Reviewed:
- HUDService.dismissTask: bounded sleep, cancelled on restart, safe with strong self
- NotificationService.pollTimer: [weak self], invalidated in deinit, safe
- HUDService.brightnessTimer: [weak self], invalidated in deinit, safe
- NotchCoordinator: <findings here>"
```

If concrete issues **are** found, commit each fix separately with `fix(<module>): ...`.

---

## Self-Review Checklist

- [x] Helper file is small (two extensions, no business logic)
- [x] Tests handle the headless-CI case (skip rather than fail when `NSScreen.screens` is empty)
- [x] Audit task is bounded — read three files, check known patterns, document
- [x] Plan is honest about "may find nothing" — empty audit is a valid outcome
- [x] No speculative refactors — only fix what's broken

---

## Out-of-Scope

- Replacing `NotchCoordinator.notchOpen / notchClose` with an explicit state machine — separate concern.
- Adding a window pool like Peekaboo's `AnimationResourcePool` — current app has at most one notch window per screen; no allocation pressure.
- Migrating off Combine / KVO — none of these files use it.

---

*Plan written 2026-05-21.*
