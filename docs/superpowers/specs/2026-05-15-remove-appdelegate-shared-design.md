# Remove AppDelegate.shared Design

## Overview

Eliminate `AppDelegate.shared` — a `nonisolated(unsafe) static var` singleton — by deleting dead code that exists only to support it and replacing the 3 real external callsites with closure injection (NotchCoordinator) and a constructor argument (MenuContent). Final state: zero `AppDelegate.shared` references, zero `nonisolated(unsafe)` declarations, no behavior change.

Follow-up to Proposal 3 of `2026-05-14-architecture-optimization-roadmap.md`.

## Problem

```swift
nonisolated(unsafe) static var shared = AppDelegate()
```

Swift 6 strict-concurrency wart. The `unsafe` marker is needed because the static var is mutable (it gets reassigned in `applicationDidFinishLaunching`). The mutation exists because `@NSApplicationDelegateAdaptor` instantiates its own `AppDelegate` — different from the one created by the static initializer — so the code overwrites the static to point to the "real" instance.

Grep shows 5 callsites; classification:

| Site | File:line | Real or dead? |
|---|---|---|
| `let delegate = AppDelegate.shared` | NemoNotchApp.swift:27 | Dead — feeds `appDelegateRef` |
| `_appDelegateRef = State(initialValue: delegate)` | NemoNotchApp.swift:28 | Dead — `appDelegateRef` never read |
| `AppDelegate.shared = self` | NemoNotchApp.swift:106 | Dead — only exists to fix the kludge above |
| `AppDelegate.shared.appSettings?.currentLocale` | NemoNotchApp.swift:72 (MenuContent.body) | **Real** |
| `AppDelegate.shared.shouldSuppressPreviousAppRestore` | NotchCoordinator.swift:229 | **Real** |
| `AppDelegate.shared.showSettings()` | NotchCoordinator.swift:328 (right-click menu) | **Real** |

The dead `@State var appDelegateRef` (NemoNotchApp.swift:8) is declared but never read anywhere. Once `.shared` is gone, the only reason it exists vanishes too.

## Approach

### 1. Delete the dead code

Remove:
- `NemoNotchApp.swift:8` — `@State private var appDelegateRef: AppDelegate?`
- `NemoNotchApp.swift:27-28` — the `let delegate = AppDelegate.shared` + `_appDelegateRef = ...` lines
- `NemoNotchApp.swift:106` — `AppDelegate.shared = self`
- `NemoNotchApp.swift:80` — `nonisolated(unsafe) static var shared = AppDelegate()`

### 2. MenuContent: locale via constructor argument

Add a parameter alongside the existing `coordinator` and `onOpenSettings`:

```swift
struct MenuContent: View {
    @Environment(AICLIMonitorService.self) var aiService
    let coordinator: NotchCoordinator?
    let appSettings: AppSettings?
    let onOpenSettings: () -> Void
    // ...
}
```

Construction site in `NemoNotchApp.body`:

```swift
MenuContent(
    coordinator: appDelegate.coordinator,
    appSettings: appDelegate.appSettings,
    onOpenSettings: { appDelegate.showSettings() }
)
```

Inside MenuContent, replace `AppDelegate.shared.appSettings?.currentLocale ?? Locale.current` with `appSettings?.currentLocale ?? Locale.current`. Same nil-handling, no behavior change.

### 3. NotchCoordinator: closure injection for the 2 host calls

Mirror the existing `autoSelectTab: (() -> Tab?)?` / `appSettings: AppSettings?` injection pattern. Add two properties:

```swift
var restoreSuppressionCheck: (() -> Bool)?
var onShowSettings: (() -> Void)?
```

In `restorePreviousApp()`, replace:
```swift
if AppDelegate.shared.shouldSuppressPreviousAppRestore { ... }
```
with:
```swift
if restoreSuppressionCheck?() == true { ... }
```

In `handleRightMouseDown(...)`, replace the ContextMenuDelegate's `onSettings` closure:
```swift
onSettings: { @MainActor in AppDelegate.shared.showSettings() },
```
with:
```swift
onSettings: { @MainActor [weak self] in self?.onShowSettings?() },
```

In `AppDelegate.applicationDidFinishLaunching`, after constructing `notchCoordinator` and assigning `autoSelectTab` (line 165 area), add:

```swift
notchCoordinator.restoreSuppressionCheck = { [weak self] in
    self?.shouldSuppressPreviousAppRestore ?? false
}
notchCoordinator.onShowSettings = { [weak self] in
    self?.showSettings()
}
```

Both closures capture `self` weakly, matching the `autoSelectTab` closure's `[weak self]` pattern.

## Behavior equivalence

| Call | Old behavior | New behavior |
|---|---|---|
| Locale lookup | `.shared.appSettings?.currentLocale ?? .current` | Same expression, value sourced from injected arg |
| Restore suppression | `.shared.shouldSuppressPreviousAppRestore` (Bool) | `restoreSuppressionCheck?() == true`: if closure is set, identical; if unset, treats as `false` (safer than crash) |
| Show Settings | `.shared.showSettings()` | `onShowSettings?()`: if closure is set, identical; if unset, no-op (safer than crash) |

The "if unset" branches never fire in practice — AppDelegate sets both closures during `applicationDidFinishLaunching`, before the notch can become interactive.

## Out of Scope

- AppDelegate's other 10 service properties (covered by Proposal 1 — ServiceContainer)
- NotchCoordinator internal decomposition (covered by Proposal 2)
- Any change to MenuContent's existing `@Environment(AICLIMonitorService.self)` pattern

## Verification

No unit test infrastructure exists. Per-step gate is `xcodebuild`. Final smoke test:

1. App launches; menu bar icon visible; right-click → all menu items render in the configured locale.
2. Open notch from menu bar; right-click on notch → Settings opens.
3. Open notch over another app (e.g., Safari); close it via clicking outside → previous app is correctly restored.
4. Open Settings via menu bar → close Settings → notch's "restore suppression" path prevents an extra app jump (within the 1.2s suppression window).

## Completion Criteria

- `grep -rn "AppDelegate\.shared\|appDelegateRef" NemoNotch/` returns zero matches.
- `grep -n "static var shared" NemoNotch/NemoNotchApp.swift` returns zero matches. (Project-wide `nonisolated(unsafe)` survives — it's used legitimately in HookServer, NowPlayingCLI, CalendarService, LogService — so it cannot be the criterion.)
- All build gates pass.
- All smoke tests pass.
