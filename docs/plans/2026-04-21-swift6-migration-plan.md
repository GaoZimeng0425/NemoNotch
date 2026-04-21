# Swift 6 Migration Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate NemoNotch from Swift 5 language mode to Swift 6 with strict concurrency safety.

**Architecture:** Incremental migration — first enable strict concurrency warnings, then fix each category of issues across the codebase, and finally flip the Swift version. NowPlayingCLI and MediaRemote use `@preconcurrency` bridge to preserve their stable Dispatch/Semaphore patterns unchanged. All `@Observable` services already get MainActor isolation from the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting.

**Tech Stack:** Swift 6, Xcode 26+, CocoaLumberjack 3.9.1, swift-log 1.12.0

---

## Migration Strategy

The project already has two Swift 6-ready settings:
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all types default to MainActor
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` — relaxed Sendable checking

This means most `@Observable` services are already implicitly MainActor-isolated. The migration is lighter than a typical Swift 5→6 jump.

**What we do NOT change:**
- `NowPlayingCLI` — Process + DispatchSemaphore pattern is correct for system process interaction; bridge with `@preconcurrency`
- `MediaRemote` — MediaRemote framework callbacks use legacy patterns; bridge with `@preconcurrency`

---

### Task 1: Enable Strict Concurrency Warnings

**Files:**
- Modify: `NemoNotch.xcodeproj/project.pbxproj` (Debug and Release sections)

**Step 1: Add strict concurrency build setting**

In the pbxproj, add `SWIFT_STRICT_CONCURRENCY = minimal;` to both Debug and Release build configurations. This is the least strict level — it only warns about sendability issues that are definite problems, not speculative ones.

Find the Debug section (~line 304) and add after `SWIFT_VERSION = 5.0;`:
```
SWIFT_STRICT_CONCURRENCY = minimal;
```

Do the same for the Release section (~line 359).

**Step 2: Build and count warnings**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | grep -c "warning:"`

Record the warning count as baseline. Expect 0-5 new concurrency warnings at `minimal` level given the existing `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting.

**Step 3: Commit**

```bash
git add NemoNotch.xcodeproj/project.pbxproj
git commit -m "build: enable SWIFT_STRICT_CONCURRENCY = minimal"
```

---

### Task 2: Bridge NowPlayingCLI and MediaRemote with @preconcurrency

These two files have stable, debugged Dispatch/Semaphore patterns that should not be refactored. We use `@preconcurrency` to suppress Sendable warnings.

**Files:**
- Modify: `NemoNotch/Services/NowPlayingCLI.swift:1`
- Modify: `NemoNotch/Services/MediaRemote.swift:1`

**Step 1: Add @preconcurrency import to NowPlayingCLI**

At `NowPlayingCLI.swift:1`, change:
```swift
import Foundation
```
to:
```swift
@preconcurrency import Foundation
```

This tells the compiler that Foundation APIs used in this file may not be fully Sendable-safe, and that's acceptable.

**Step 2: Add @preconcurrency import to MediaRemote**

At `MediaRemote.swift:1`, change:
```swift
import Foundation
```
to:
```swift
@preconcurrency import Foundation
```

**Step 3: Mark closures as @Sendable where needed**

In `NowPlayingCLI.swift`, the `@escaping` closures in `fetchNowPlayingInfo`, `fetchUsingHelpers`, `runPerl`, and `runExternal` may need `@Sendable` annotation if the compiler warns. Check after building — at `minimal` strictness these may not warn.

In `MediaRemote.swift`, same approach — check build warnings first, annotate only if needed.

**Step 4: Build and verify**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add NemoNotch/Services/NowPlayingCLI.swift NemoNotch/Services/MediaRemote.swift
git commit -m "swift6: bridge NowPlayingCLI and MediaRemote with @preconcurrency"
```

---

### Task 3: Add @preconcurrency to EventMonitor

**Files:**
- Modify: `NemoNotch/Notch/EventMonitor.swift:1`

**Step 1: Bridge EventMonitor imports**

At `EventMonitor.swift:1`, change:
```swift
import Cocoa
```
to:
```swift
@preconcurrency import Cocoa
```

The `MainActor.assumeIsolated` calls (lines 18, 23, 28, 33, 39, 45) are actually correct — `NSEvent.addGlobalMonitorForEvents` callbacks run on the main thread. With the default MainActor isolation, `assumeIsolated` is the right pattern here. No further changes needed.

**Step 2: Build and verify**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | tail -5`

**Step 3: Commit**

```bash
git add NemoNotch/Notch/EventMonitor.swift
git commit -m "swift6: bridge EventMonitor with @preconcurrency import"
```

---

### Task 4: Fix Singletons for Swift 6

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift:68` (AppDelegate)
- Modify: `NemoNotch/Services/LogService.swift:4`
- Modify: `NemoNotch/Notch/EventMonitor.swift:4`

MediaRemote singleton was already handled in Task 2.

**Step 1: Fix AppDelegate mutable singleton**

At `NemoNotchApp.swift:68`, change:
```swift
static var shared = AppDelegate()
```
to:
```swift
nonisolated(unsafe) static var shared = AppDelegate()
```

`AppDelegate` is created once in `@main` and never reassigned, but it's a `static var` (needed for access from App struct). `nonisolated(unsafe)` is the correct annotation for this pattern — it tells Swift 6 "I know this is technically not Sendable-safe, but it's fine."

**Step 2: Fix LogService singleton**

At `LogService.swift`, the singleton is already `static let` (immutable reference), which is Sendable-safe. No change needed unless the compiler warns. Check after build.

If it warns, add `@MainActor` to the class:
```swift
@MainActor
final class LogService {
```

**Step 3: Fix EventMonitor singleton**

At `EventMonitor.swift:4`, same as LogService — `static let` should be fine. If the compiler warns about the mutable `onMouseMove`/`onMouseDown` properties not being Sendable, wrap them:

```swift
nonisolated(unsafe) var onMouseMove: ((NSPoint) -> Void)?
nonisolated(unsafe) var onMouseDown: (() -> Void)?
nonisolated(unsafe) var onRightMouseDown: ((NSPoint) -> Void)?
```

**Step 4: Build and verify**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | tail -5`

**Step 5: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift NemoNotch/Services/LogService.swift NemoNotch/Notch/EventMonitor.swift
git commit -m "swift6: fix singletons with nonisolated(unsafe) and @MainActor"
```

---

### Task 5: Fix @escaping Closures with @Sendable

**Files:**
- Modify: `NemoNotch/Services/HookServer.swift` (lines 31, 132)
- Modify: `NemoNotch/Notch/NotchCoordinator.swift:283` (MenuHandler)
- Modify: `NemoNotch/Services/HotkeyService.swift:11`

NowPlayingCLI and MediaRemote were handled in Task 2.

**Step 1: Annotate HookServer closures**

At `HookServer.swift:31`, the `stateUpdateHandler` closure crosses isolation boundaries. If the compiler warns, wrap the DispatchQueue.main.async block:

```swift
listener?.stateUpdateHandler = { @Sendable [weak self] state in
    DispatchQueue.main.async {
        guard let self else { return }
```

At `HookServer.swift:132`, same pattern:
```swift
DispatchQueue.main.async { @Sendable [weak self] in
    self?.onEventReceived?(event)
}
```

If `onEventReceived` itself is a closure property, it may need `nonisolated(unsafe)`:
```swift
nonisolated(unsafe) var onEventReceived: ((HookEvent) -> Void)?
```

**Step 2: Annotate HotkeyService closures**

At `HotkeyService.swift`, the `register` callback crosses from C callback context to Swift. Add `@Sendable` to the callback type if the compiler warns.

**Step 3: Annotate NotchCoordinator.MenuHandler**

At `NotchCoordinator.swift:283`, if `MenuHandler` has closure properties, they may need `@Sendable` or `nonisolated(unsafe)`.

**Step 4: Build and verify**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | tail -5`

**Step 5: Commit**

```bash
git add NemoNotch/Services/HookServer.swift NemoNotch/Services/HotkeyService.swift NemoNotch/Notch/NotchCoordinator.swift
git commit -m "swift6: annotate cross-isolation closures with @Sendable"
```

---

### Task 6: Convert WeatherService to async/await

**Files:**
- Modify: `NemoNotch/Services/WeatherService.swift` (lines 31, 64-70)

This is a clean example where converting to async/await actually simplifies the code.

**Step 1: Replace URLSession callback with async**

At `WeatherService.swift:64`, replace:
```swift
URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
    guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    DispatchQueue.main.async {
        self?.parseWeather(json)
    }
}.resume()
```
with:
```swift
Task {
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        parseWeather(json)
    } catch {
        LogService.warn("Weather fetch failed: \(error.localizedDescription)", category: "Weather")
    }
}
```

The `DispatchQueue.main.async` is no longer needed because the service is already MainActor-isolated (via `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so `parseWeather` runs on MainActor automatically.

**Step 2: Build and verify**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | tail -5`

**Step 3: Commit**

```bash
git add NemoNotch/Services/WeatherService.swift
git commit -m "swift6: convert WeatherService URLSession to async/await"
```

---

### Task 7: Fix ClaudeCodeService DispatchQueue usage

**Files:**
- Modify: `NemoNotch/Services/ClaudeCodeService.swift` (lines 150, 169-176)

**Step 1: Replace DispatchQueue.global + DispatchQueue.main.async pattern**

At `ClaudeCodeService.swift:169`, replace:
```swift
DispatchQueue.global(qos: .utility).async { [weak self] in
    let messages = Self.parseTranscriptMessages(sessionId: sessionId, cwd: cwd)
    guard let self, let messages, !messages.firstUser.isEmpty || !messages.lastUser.isEmpty else { return }
    DispatchQueue.main.async {
        guard self.sessions[sessionId] != nil else { return }
```
with:
```swift
Task.detached(priority: .utility) { [weak self] in
    let messages = Self.parseTranscriptMessages(sessionId: sessionId, cwd: cwd)
    guard let self, let messages, !messages.firstUser.isEmpty || !messages.lastUser.isEmpty else { return }
    await MainActor.run {
        guard self.sessions[sessionId] != nil else { return }
```

Since the service is MainActor-isolated, after the detached work, we explicitly return to MainActor with `await MainActor.run`.

**Step 2: Verify the timeout timer**

At `ClaudeCodeService.swift:150`, the `Timer.scheduledTimer` is fine — timers schedule on the current run loop, which is the main run loop for MainActor-isolated types. No change needed.

**Step 3: Build and verify**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | tail -5`

**Step 4: Commit**

```bash
git add NemoNotch/Services/ClaudeCodeService.swift
git commit -m "swift6: replace DispatchQueue.global with Task.detached in ClaudeCodeService"
```

---

### Task 8: Fix MediaService DispatchQueue.asyncAfter

**Files:**
- Modify: `NemoNotch/Services/MediaService.swift` (lines 26, 31, 36)

**Step 1: Replace DispatchQueue.main.asyncAfter with Task.sleep**

At `MediaService.swift:26`, replace:
```swift
func togglePlayPause() {
    remote.sendCommand(.togglePlayPause)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateNowPlaying() }
}
```
with:
```swift
func togglePlayPause() {
    remote.sendCommand(.togglePlayPause)
    Task { [weak self] in
        try? await Task.sleep(for: .seconds(0.3))
        self?.updateNowPlaying()
    }
}
```

Repeat the same pattern for `nextTrack()` (line 31) and `previousTrack()` (line 36).

Since the class is MainActor-isolated, the `Task { }` runs on MainActor, so `self?.updateNowPlaying()` is safe without explicit `DispatchQueue.main.async`.

**Step 2: Verify Timer patterns**

At `MediaService.swift:64,70`, the `Timer.scheduledTimer` calls are fine on MainActor — they schedule on the main run loop. No change needed.

**Step 3: Build and verify**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | tail -5`

**Step 4: Commit**

```bash
git add NemoNotch/Services/MediaService.swift
git commit -m "swift6: replace DispatchQueue.asyncAfter with Task.sleep in MediaService"
```

---

### Task 9: Fix HookServer DispatchQueue.main.async

**Files:**
- Modify: `NemoNotch/Services/HookServer.swift` (lines 31, 132)

**Step 1: Replace DispatchQueue.main.async with MainActor.run**

At `HookServer.swift:31`, the `stateUpdateHandler` is a NWListener callback that runs off the main thread. Replace:
```swift
DispatchQueue.main.async {
    guard let self else { return }
    switch state {
```
with:
```swift
await MainActor.run { [weak self] in
    guard let self else { return }
    switch state {
```

Wait — `stateUpdateHandler` is not async. So this needs to stay as a closure. The correct Swift 6 pattern is to keep `DispatchQueue.main.async` but ensure the closure is `@Sendable`:

```swift
listener?.stateUpdateHandler = { @Sendable [weak self] state in
    DispatchQueue.main.async {
        guard let self else { return }
```

Actually, since the class is MainActor-isolated, accessing `self` inside `DispatchQueue.main.async` should be fine. The `@Sendable` on the outer closure is the key change.

Same pattern at line 132 — add `@Sendable` to the inner closure if the compiler warns.

**Step 2: Build and verify**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | tail -5`

**Step 3: Commit**

```bash
git add NemoNotch/Services/HookServer.swift
git commit -m "swift6: add @Sendable to HookServer cross-isolation closures"
```

---

### Task 10: Bump to SWIFT_STRICT_CONCURRENCY = targeted

**Files:**
- Modify: `NemoNotch.xcodeproj/project.pbxproj`

**Step 1: Upgrade strictness level**

In the pbxproj, change `SWIFT_STRICT_CONCURRENCY = minimal;` to `SWIFT_STRICT_CONCURRENCY = targeted;` in both Debug and Release configurations.

**Step 2: Build and fix remaining warnings**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | grep "warning:" | head -30`

Fix any new warnings. At `targeted` level, the compiler checks more thoroughly but still allows escape hatches. Common fixes:
- Add `@preconcurrency` to more imports (e.g., `MediaPlayer`, `Network`)
- Add `nonisolated(unsafe)` to closure properties that cross boundaries
- Add `@Sendable` to remaining escaping closures

**Step 3: Commit**

```bash
git add -A
git commit -m "build: upgrade to SWIFT_STRICT_CONCURRENCY = targeted"
```

---

### Task 11: Flip to Swift 6 Language Mode

**Files:**
- Modify: `NemoNotch.xcodeproj/project.pbxproj`

**Step 1: Update SWIFT_VERSION**

In the pbxproj, change `SWIFT_VERSION = 5.0;` to `SWIFT_VERSION = 6.0;` in both Debug and Release configurations.

**Step 2: Remove redundant settings**

Since Swift 6 mode implies strict concurrency, you can remove `SWIFT_STRICT_CONCURRENCY` (it's ignored in Swift 6 mode). Keep `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` as they still have effect.

**Step 3: Build and fix final issues**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch build 2>&1 | grep "error:" | head -20`

Fix any remaining errors. If there are issues in files we haven't touched, use `@preconcurrency import` as the bridge.

**Step 4: Manual testing**

Run the app and verify:
1. Media controls work (play/pause, next/prev, progress bar)
2. Calendar events display correctly
3. Weather widget updates
4. Claude Code tab shows sessions
5. OpenClaw connection works
6. Notch animations and swipe gestures
7. Badge notifications appear
8. App launcher opens apps

**Step 5: Commit**

```bash
git add NemoNotch.xcodeproj/project.pbxproj
git commit -m "build: migrate to Swift 6 language mode"
```

---

### Task 12: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update tech stack section**

Change:
```markdown
- Swift 5 + SwiftUI，仅 macOS，依赖 CocoaLumberjack
```
to:
```markdown
- Swift 6 + SwiftUI，仅 macOS，依赖 CocoaLumberjack
- 默认 MainActor 隔离（SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for Swift 6 migration"
```

---

## Task Dependency Graph

```
Task 1 (strict concurrency minimal)
  → Task 2 (bridge NowPlayingCLI/MediaRemote)
  → Task 3 (bridge EventMonitor)
  → Task 4 (fix singletons)
  → Task 5 (fix @escaping closures)
  → Task 6 (WeatherService async)
  → Task 7 (ClaudeCodeService async)
  → Task 8 (MediaService asyncAfter)
  → Task 9 (HookServer closures)
  → Task 10 (strict concurrency targeted)
  → Task 11 (Swift 6 mode)
  → Task 12 (update docs)
```

Tasks 2-9 are independent of each other and can be done in any order after Task 1. They must all complete before Task 10.

## Estimated Effort

| Task | Time | Risk |
|------|------|------|
| Task 1: Enable warnings | 5 min | Low |
| Task 2: Bridge NowPlayingCLI/MediaRemote | 15 min | Low |
| Task 3: Bridge EventMonitor | 5 min | Low |
| Task 4: Fix singletons | 15 min | Low |
| Task 5: Fix @escaping closures | 20 min | Medium |
| Task 6: WeatherService async | 10 min | Low |
| Task 7: ClaudeCodeService async | 15 min | Medium |
| Task 8: MediaService asyncAfter | 10 min | Low |
| Task 9: HookServer closures | 10 min | Medium |
| Task 10: Upgrade to targeted | 30 min | Medium |
| Task 11: Swift 6 mode | 30 min | High |
| Task 12: Update docs | 5 min | Low |
| **Total** | **~3 hours** | |
