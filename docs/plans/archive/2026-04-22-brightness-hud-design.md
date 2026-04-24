# Brightness HUD Design

## Goal

Add built-in display brightness monitoring to NemoNotch's HUD system. When the user changes screen brightness, show a brightness HUD capsule below the notch (same pattern as volume/battery).

## Approach: DisplayServices Polling

Use `DisplayServicesGetBrightness()` private API (same as MonitorControl) via `dlopen` dynamic loading. This is different from the previously removed CoreDisplay approach and is not affected by macOS 26's IOKit restrictions.

**Polling strategy:**
- Default interval: 1.0s
- Active interval (during changes): 0.1s
- Change detection threshold: delta > 0.01
- Resume default interval after HUD dismisses

## Changes

### 1. HUDService.swift

- Add `brightness` case to `HUDType` enum
- Add `brightnessTimer: Timer?`, `lastBrightness: Float`, `isBrightnessChanging: Bool`
- Add `setupBrightnessMonitoring()` — starts polling timer
- Add `getBrightness() -> Float?` — dlopen DisplayServices, call `DisplayServicesGetBrightness`
- Add `readBrightness()` — compare with lastBrightness, trigger HUD on change
- Modify `init()` to call `setupBrightnessMonitoring()`
- Modify `deinit` to invalidate timer

### 2. HUDOverlayView.swift

- Add brightness icon mapping in `icon` computed property:
  - 0: `sun.min.fill`
  - <0.5: `sun.and.horizon.fill`
  - default: `sun.max.fill`

## Files Modified

- `NemoNotch/Services/HUDService.swift`
- `NemoNotch/Notch/HUDOverlayView.swift`

## Risk

`DisplayServicesGetBrightness` is a private API. Apple may change or remove it in future macOS versions. This is the same risk MonitorControl accepts, and the community actively maintains workarounds.
