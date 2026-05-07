# Multi-Screen Support Design

## Goal

Display NemoNotch on all connected screens simultaneously, with mirrored content and single-screen expansion.

## Requirements

1. **All screens display notch**: Every connected screen shows a notch panel at the top
2. **Simulated notch shape**: External monitors without a physical notch display a simulated notch shape (using default dimensions)
3. **Mirrored content**: All screens show identical content (same tab, same state)
4. **Single-screen expansion**: Only the screen where the mouse hovers expands the notch; others remain collapsed
5. **Unified notchSize**: The notch size is the same across all screens (based on built-in display's physical notch, or default values)

## Architecture

### Core Change: Single Coordinator, Multiple Windows

`NotchCoordinator` currently holds one `NotchWindow`. Change to holding a dictionary of `NotchWindowSlot` per screen:

```
NotchCoordinator
├── status: .closed / .opened          // shared global state
├── selectedTab: Tab                   // shared global state
├── notchSize: NSSize                  // unified across all screens
├── activeScreen: NSScreen?            // screen with mouse hover
├── windows: [NSScreen: NotchWindowSlot]
└── deviceNotchRect(for:) -> NSRect    // per-screen position
```

`NotchWindowSlot` contains:
- `window: NotchWindow` — the NSPanel positioned on that screen
- `passThrough: PassThroughView` — click-through control
- `hostingController: NSHostingController<AnyView>` — SwiftUI content host

All slots share the same SwiftUI view hierarchy closure, so content is automatically mirrored.

### notchSize Determination

- **Primary source**: Built-in display's physical notch size (`NSScreen.screens.first(where: { $0.isBuiltInDisplay })?.notchSize`)
- **Fallback**: `NotchConstants.defaultNotchWidth / defaultNotchHeight`
- Determined once at init, updated only if the built-in display's notch size changes (rare)
- All screens use this same value regardless of their own notch capabilities

### Per-Screen Positioning

Each window covers the top area of its screen:

```
windowFrame = NSRect(
    x: screen.frame.midX - windowWidth / 2,
    y: screen.frame.maxY - windowHeight,
    width: windowWidth,
    height: windowHeight
)
```

`deviceNotchRect(for screen)` returns the notch hitbox position relative to each screen's frame.

## Window Lifecycle

### Initialization

In `NotchCoordinator.init`, iterate `NSScreen.screens` and create a `NotchWindowSlot` for each screen.

### Screen Parameters Changed

On `NSApplication.didChangeScreenParametersNotification`:

1. Diff `NSScreen.screens` against current `windows` dictionary (match by `displayID`)
2. **Added screens**: Create new `NotchWindowSlot` with the shared content closure
3. **Removed screens**: Close and remove the slot
4. **Existing screens**: Update window frame if position/size changed

### Screen Matching

Use `NSScreen.displayID` (already in `ScreenExtensions.swift`) to identify screens across notification callbacks, since `NSScreen` object identity may change.

## Event Handling

### EventMonitor

No changes. Still uses global + local monitors for mouse events.

### NotchCoordinator Event Routing

`handleMouseMove` / `handleMouseDown` / `handleRightMouseDown` change:

1. Determine `activeScreen` via `NSScreen.screenWithMouse`
2. Calculate hitbox using `deviceNotchRect(for: activeScreen)`
3. `notchOpen()`: only expand the window on `activeScreen` (`isBlocking = true`, `makeKeyAndOrderFront`)
4. `notchClose()`: only collapse the window on `activeScreen` (`isBlocking = false`, `resignKey`)
5. Other screens' windows remain collapsed with CompactBadge visible

### deviceNotchRect

Change from computed property to method:

```swift
func deviceNotchRect(for screen: NSScreen) -> NSRect {
    NSRect(
        x: screen.frame.midX - notchSize.width / 2,
        y: screen.frame.maxY - notchSize.height,
        width: notchSize.width,
        height: notchSize.height
    )
}
```

## NotchView Adaptation

### Problem

`NotchView` currently uses `NSScreen.main` for `hasNotch`, `notchCenterX`, `notchLeftEdge`, `notchRightEdge`. In multi-screen, each window renders on a different screen.

### Solution

1. Add a `currentScreen: NSScreen` parameter to `NotchView` (passed via Environment or init)
2. Replace all `NSScreen.main` references with `currentScreen`
3. `hasNotch` uses `currentScreen.hasNotch` for rendering the notch shape (physical notch vs simulated)
4. `notchSize` remains unified (from coordinator)
5. Layout calculations (centerX, leftEdge, rightEdge) use `currentScreen.frame`

### Per-Window View Instantiation

Each `NotchWindowSlot`'s hosting controller gets:

```swift
NotchView(screen: screen)
    .environment(coordinator)
    .environment(settings)
    // ... all other services
```

## HUD Overlay

HUD (volume/brightness/battery) only appears on `activeScreen` to avoid flashing on all screens simultaneously. Implement by passing `isActiveScreen` flag to each NotchView.

## Edge Cases

| Case | Behavior |
|------|----------|
| No physical notch Mac (Mac Pro, Mac mini) | All screens use default notchSize |
| Clamshell mode (built-in display closed) | Built-in screen removed from windows dict; external screens use default notchSize |
| Hot-plug monitor | screenParametersChanged adds/removes windows incrementally |
| Main screen switch | No effect; each window is bound to its own screen |
| Built-in display notch size change | notchSize updated from built-in display if available |

## Files to Modify

| File | Change |
|------|--------|
| `NotchCoordinator.swift` | Multi-window dictionary, activeScreen, per-screen event routing |
| `NotchView.swift` | Accept screen parameter, replace NSScreen.main |
| `NemoNotchApp.swift` | Pass screen to NotchView per window |
| `ScreenExtensions.swift` | Add screen comparison helpers (by displayID) |

## Files Unchanged

| File | Reason |
|------|--------|
| `NotchWindow.swift` | No structural changes needed |
| `EventMonitor.swift` | Already works across all screens |
| `PassThroughView` | Per-instance, works as-is |
| All Tab views | Content is screen-agnostic |
| All Services | Screen-independent |
