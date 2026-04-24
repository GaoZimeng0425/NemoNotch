# System HUD Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add notch-native HUD flash bars for volume, brightness, and battery/power events, appearing below the notch with spring animation and auto-dismiss.

**Architecture:** New `HUDService` monitors system value changes via CoreAudio (volume), CoreDisplay polling (brightness), and IOKit (battery). A `HUDOverlayView` capsule appears below the notch in the existing `NotchView` ZStack, driven by `HUDService`'s `@Observable` state. No separate window needed — the HUD lives inside the existing notch window.

**Tech Stack:** Swift, SwiftUI, CoreAudio, CoreDisplay (private), IOKit.ps

---

### Task 1: Create HUDService with volume monitoring

**Files:**
- Create: `NemoNotch/Services/HUDService.swift`
- Modify: `NemoNotch/Helpers/Constants.swift`

**Step 1: Add HUD constants**

In `NemoNotch/Helpers/Constants.swift`, add inside `enum NotchConstants { }` before the closing brace:

```swift
// HUD overlay
static let hudHeight: CGFloat = 28
static let hudCornerRadius: CGFloat = 14
static let hudIconSize: CGFloat = 14
static let hudProgressBarHeight: CGFloat = 6
static let hudHorizontalPadding: CGFloat = 12
static let hudTopPadding: CGFloat = 4
static let hudDismissDelay: Double = 2.0
static let hudAppearDuration: Double = 0.3
static let hudDismissDuration: Double = 0.2
static let hudValueTransitionDuration: Double = 0.15
static let hudBrightnessPollInterval: Double = 0.5
```

**Step 2: Create HUDService**

Create `NemoNotch/Services/HUDService.swift`:

```swift
import Foundation
import CoreAudio

@Observable
final class HUDService {
    enum HUDType: Equatable {
        case volume
        case brightness
        case battery(charging: Bool)
    }

    var activeHUD: HUDType?
    var hudValue: Float = 0

    private var dismissTask: Task<Void, Never>?
    private var volumeListener: AudioObjectPropertyListenerBlock?

    // Brightness polling
    private var brightnessPollTimer: Timer?
    private var lastBrightness: Float = 0

    // Battery
    private var powerSourceNotifier: Unmanaged<io_object_t>?

    init() {
        setupVolumeListener()
        setupBrightnessPolling()
        setupBatteryMonitoring()
    }

    deinit {
        brightnessPollTimer?.invalidate()
        if let notifier = powerSourceNotifier {
            notifier.release()
        }
    }

    // MARK: - Volume

    private func setupVolumeListener() {
        let deviceID = AudioObjectID(kAudioObjectSystemObject)
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMasterVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize = UInt32(MemoryLayout<Float>.size)
        var currentVolume: Float = 0
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, &currentVolume)

        volumeListener = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.readVolume()
            }
        }

        AudioObjectAddPropertyBlockListener(deviceID, &address, volumeListener)
    }

    private func readVolume() {
        let deviceID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMasterVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return }

        showHUD(.volume, value: volume)
    }

    // MARK: - Brightness

    private func setupBrightnessPolling() {
        lastBrightness = currentSystemBrightness
        brightnessPollTimer = Timer.scheduledTimer(
            withTimeInterval: NotchConstants.hudBrightnessPollInterval,
            repeats: true
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.pollBrightness()
            }
        }
    }

    private var currentSystemBrightness: Float {
        guard let screen = NSScreen.main else { return 0 }
        // Use CoreDisplay private API (widely used in notch apps)
        let screenID = screen.displayID
        if screenID != 0 {
            return CoreDisplay_GetBrightness(screenID)
        }
        return 0
    }

    private func pollBrightness() {
        let brightness = currentSystemBrightness
        guard abs(brightness - lastBrightness) > 0.01 else { return }
        lastBrightness = brightness
        showHUD(.brightness, value: brightness)
    }

    // MARK: - Battery

    private func setupBatteryMonitoring() {
        let loop = IOPSNotificationCreateRunLoopSource(
            { [weak self] context in
                DispatchQueue.main.async {
                    self?.readBattery()
                }
            },
            nil
        ).takeRetainedValue() as CFRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
        readBattery()
    }

    private func readBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeRetainedValue() as? [String: Any] else { continue }
            let capacity = (info[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            showHUD(.battery(charging: charging), value: Float(capacity) / 100.0)
        }
    }

    // MARK: - Common

    private func showHUD(_ type: HUDType, value: Float) {
        activeHUD = type
        hudValue = value
        restartDismissTimer()
    }

    private func restartDismissTimer() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NotchConstants.hudDismissDelay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: NotchConstants.hudDismissDuration)) {
                activeHUD = nil
            }
        }
    }
}

// MARK: - CoreDisplay private API

@_silgen_name("CoreDisplay_GetBrightness")
private func CoreDisplay_GetBrightness(_ displayID: UInt32) -> Float

// MARK: - NSScreen displayID

extension NSScreen {
    var displayID: UInt32 {
        guard let key = "NSScreenNumber" as CFString,
              let screenNumber = deviceDescription[key] as? NSNumber else { return 0 }
        return screenNumber.uint32Value
    }
}
```

**Step 3: Build to verify compilation**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (may have warnings about CoreDisplay private API)

**Step 4: Commit**

```bash
git add NemoNotch/Services/HUDService.swift NemoNotch/Helpers/Constants.swift
git commit -m "feat: add HUDService with volume/brightness/battery monitoring"
```

---

### Task 2: Create HUDOverlayView

**Files:**
- Create: `NemoNotch/Notch/HUDOverlayView.swift`

**Step 1: Create the overlay view**

Create `NemoNotch/Notch/HUDOverlayView.swift`:

```swift
import SwiftUI

struct HUDOverlayView: View {
    let type: HUDService.HUDType
    let value: Float

    private var icon: String {
        switch type {
        case .volume: value < 0.01 ? "speaker.slash.fill" : "speaker.waveforms.fill"
        case .brightness: "sun.max.fill"
        case .battery(let charging):
            charging ? "battery.100.bolt" : batteryIconName
        }
    }

    private var batteryIconName: String {
        switch value {
        case ..<0.13: "battery.0"
        case 0.13..<0.38: "battery.25"
        case 0.38..<0.63: "battery.50"
        case 0.63..<0.88: "battery.75"
        default: "battery.100"
        }
    }

    private var percentageText: String {
        switch type {
        case .battery: "\(Int(value * 100))%"
        default: "\(Int(value * 100))%"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: NotchConstants.hudIconSize, alignment: .center)

            progressBar

            Text(percentageText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, NotchConstants.hudHorizontalPadding)
        .frame(height: NotchConstants.hudHeight)
        .background(.black.opacity(0.85))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))

                Capsule()
                    .fill(.white.opacity(0.8))
                    .frame(width: max(0, geo.size.width * CGFloat(value)))
            }
        }
        .frame(height: NotchConstants.hudProgressBarHeight)
        .frame(maxWidth: .infinity)
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add NemoNotch/Notch/HUDOverlayView.swift
git commit -m "feat: add HUDOverlayView capsule with icon, progress bar, percentage"
```

---

### Task 3: Integrate HUD into NotchView

**Files:**
- Modify: `NemoNotch/Notch/NotchView.swift`
- Modify: `NemoNotch/NemoNotchApp.swift`

**Step 1: Add HUDService environment to NotchView**

In `NemoNotch/Notch/NotchView.swift`, add after line 10 (`@Environment(OpenClawService.self) var openClawService`):

```swift
@Environment(HUDService.self) var hudService
```

**Step 2: Add HUD overlay state**

In `NotchView.swift`, add after line 27 (`@State private var slideForward: Bool = true`):

```swift
@State private var showHUD: Bool = false
```

**Step 3: Add HUD overlay to the body ZStack**

In `NotchView.swift`, in the `body` computed property, add after the closing of the `if coordinator.status == .opened { contentPanel ... }` block (after line 113), before the closing of the outer ZStack:

```swift
// HUD overlay - appears below the notch
if let hudType = hudService.activeHUD {
    HUDOverlayView(type: hudType, value: hudService.hudValue)
        .zIndex(3)
        .position(
            x: notchCenterX,
            y: hardwareNotchSize.height + NotchConstants.hudTopPadding + NotchConstants.hudHeight / 2
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
}
```

**Step 4: Add HUD animation modifier**

In `NotchView.swift`, add `.onChange` for HUD after the existing `.onChange(of: coordinator.selectedTab)` block (after line 157):

```swift
.onChange(of: hudService.activeHUD) { _, newValue in
    withAnimation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.15)) {
        showHUD = newValue != nil
    }
}
```

**Step 5: Add HUDService to AppDelegate**

In `NemoNotch/NemoNotchApp.swift`, add a new property to `AppDelegate` after line 81 (`private var weatherService: WeatherService?`):

```swift
private var hudService: HUDService?
```

In `applicationDidFinishLaunching`, after line 111 (`self.weatherService = weather`), add:

```swift
let hud = HUDService()
self.hudService = hud
```

In the `NotchCoordinator` closure (around line 124, after `.environment(weather)`), add:

```swift
.environment(hud)
```

**Step 6: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add NemoNotch/Notch/NotchView.swift NemoNotch/NemoNotchApp.swift
git commit -m "feat: integrate HUD overlay into NotchView with environment injection"
```

---

### Task 4: Test and polish

**Step 1: Run the app and test volume**

1. Build and run NemoNotch
2. Press F11/F12 (volume keys) or change volume via Touch Bar / Settings
3. Verify: capsule appears below the notch showing speaker icon + progress bar + percentage
4. Verify: auto-dismisses after ~2 seconds

**Step 2: Test brightness**

1. Press F1/F2 (brightness keys) or adjust in Display settings
2. Verify: sun icon + progress bar appears below notch
3. Verify: auto-dismisses after ~2 seconds

**Step 3: Test battery**

1. Plug/unplug power adapter
2. Verify: battery icon (with bolt for charging) + percentage appears
3. Verify: auto-dismisses after ~2 seconds

**Step 4: Test edge cases**

1. Rapid consecutive volume changes → timer resets, no flicker
2. Switch between HUD types rapidly → latest replaces previous
3. HUD while notch is opened → HUD appears below opened panel (may overlap badges, acceptable for v1)

**Step 5: Visual polish if needed**

Adjust in `Constants.swift` if timing/spacing feels off:
- `hudDismissDelay`: increase if too fast (default 2.0s)
- `hudHeight`: increase if capsule too small (default 28px)
- `hudProgressBarHeight`: adjust progress bar thickness (default 6px)

**Step 6: Final commit**

```bash
git add -A
git commit -m "feat: complete system HUD — volume, brightness, battery notch overlay"
```
