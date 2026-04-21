# Three-State Animation System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade the notch from 2-state (closed/opened) to 3-state (closed/breathing/opened) with mouse proximity detection and haptic feedback.

**Architecture:** Add a `breathing` state to `NotchCoordinator.Status`. When the mouse enters a proximity zone (20px around the notch), the notch slightly expands and shows a preview. Moving closer opens fully; moving away reverts to closed. All state transitions use spring animations with haptic feedback on breathing and opened states.

**Tech Stack:** Swift 5, SwiftUI, AppKit (NSEvent mouse monitoring, NSHapticFeedbackManager)

---

### Task 1: Add breathing state constants

**Files:**
- Modify: `NemoNotch/Helpers/Constants.swift`

**Step 1: Add new constants to NotchConstants**

Add after the existing `closeSpringDuration` constant (line ~26):

```swift
// Breathing state
static let breathingHeightExtra: CGFloat = 6
static let breathingCornerRadius: CGFloat = 12
static let breathingProximityRange: CGFloat = 20
static let breathingSpringDuration: Double = 0.3
static let breathingSpringBounce: Double = 0.15
static let breathingBackgroundBrightness: CGFloat = 0.16 // #252528
```

**Step 2: Commit**

```bash
git add NemoNotch/Helpers/Constants.swift
git commit -m "feat: add breathing state constants for three-state animation"
```

---

### Task 2: Update NotchCoordinator with three-state status

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`

**Step 1: Add breathing case to Status enum**

Change the Status enum from:

```swift
enum Status {
    case closed
    case opened
}
```

To:

```swift
enum Status {
    case closed
    case breathing
    case opened
}
```

**Step 2: Add notchBreathing() method**

Add after `notchOpen()` method (after line ~124):

```swift
func notchBreathing() {
    guard status == .closed else { return }
    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    withAnimation(.interactiveSpring(duration: NotchConstants.breathingSpringDuration, extraBounce: NotchConstants.breathingSpringBounce)) {
        status = .breathing
    }
}

func notchCloseFromBreathing() {
    guard status == .breathing else { return }
    withAnimation(.spring(duration: NotchConstants.closeSpringDuration)) {
        status = .closed
    }
}
```

**Step 3: Update contentSize to handle breathing**

Change `contentSize` computed property to:

```swift
var contentSize: NSSize {
    switch status {
    case .closed: notchSize
    case .breathing: NSSize(width: notchSize.width, height: notchSize.height + NotchConstants.breathingHeightExtra)
    case .opened: NSSize(width: NotchConstants.openedWidth, height: NotchConstants.openedHeight)
    }
}
```

**Step 4: Update handleMouseMove for three states**

Replace the `handleMouseMove` method with:

```swift
private func handleMouseMove(_ location: NSPoint) {
    let hitbox = hitboxRect
    let isInHitbox = NSMouseInRect(location, hitbox, false)

    // Proximity zone: larger area around the hitbox
    let proximityRect = hitbox.insetBy(dx: -NotchConstants.breathingProximityRange, dy: -NotchConstants.breathingProximityRange)
    let isInProximity = NSMouseInRect(location, proximityRect, false)

    switch status {
    case .closed:
        if isInHitbox {
            notchOpen()
        } else if isInProximity {
            notchBreathing()
        }
        window.ignoresMouseEvents = !isInHitbox && !isInProximity
    case .breathing:
        if isInHitbox {
            notchOpen()
        } else if !isInProximity {
            notchCloseFromBreathing()
        }
        window.ignoresMouseEvents = false
    case .opened:
        let contentRect = NSRect(
            x: screenFrame.midX - contentSize.width / 2,
            y: screenFrame.maxY - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
        let isInContent = NSMouseInRect(location, contentRect.insetBy(dx: -NotchConstants.closeHitboxInset, dy: -NotchConstants.closeHitboxInset), false)
        window.ignoresMouseEvents = !isInContent
        if !isInContent {
            notchClose()
        }
    }
}
```

**Step 5: Update handleMouseDown for breathing state**

Add a breathing case to `handleMouseDown`:

```swift
private func handleMouseDown() {
    let location = NSEvent.mouseLocation
    switch status {
    case .closed:
        if NSMouseInRect(location, hitboxRect, false) {
            notchOpen()
        }
    case .breathing:
        if NSMouseInRect(location, hitboxRect, false) {
            notchOpen()
        }
    case .opened:
        let contentRect = NSRect(
            x: screenFrame.midX - contentSize.width / 2,
            y: screenFrame.maxY - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
        let isInContent = NSMouseInRect(location, contentRect.insetBy(dx: -NotchConstants.clickHitboxInset, dy: -NotchConstants.clickHitboxInset), false)
        window.ignoresMouseEvents = !isInContent
        if !isInContent {
            notchClose()
        }
    }
}
```

**Step 6: Commit**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift
git commit -m "feat: add breathing state to NotchCoordinator with proximity detection"
```

---

### Task 3: Update NotchView for breathing state visuals

**Files:**
- Modify: `NemoNotch/Notch/NotchView.swift`

**Step 1: Update notchSize for breathing**

Change the `notchSize` computed property to handle breathing:

```swift
private var notchSize: CGSize {
    switch coordinator.status {
    case .closed:
        let extraWidth: CGFloat = shownHasActiveBadge ? NotchConstants.badgePadding * 2 : 0
        return CGSize(width: hardwareNotchSize.width - NotchConstants.closedWidthInset + extraWidth, height: hardwareNotchSize.height)
    case .breathing:
        let extraWidth: CGFloat = shownHasActiveBadge ? NotchConstants.badgePadding * 2 : 0
        return CGSize(width: hardwareNotchSize.width - NotchConstants.closedWidthInset + extraWidth, height: hardwareNotchSize.height + NotchConstants.breathingHeightExtra)
    case .opened:
        return CGSize(width: NotchConstants.openedWidth, height: NotchConstants.openedHeight)
    }
}
```

**Step 2: Update corner radius for breathing**

```swift
private var notchCornerRadius: CGFloat {
    switch coordinator.status {
    case .closed: NotchConstants.cornerRadiusClosed
    case .breathing: NotchConstants.breathingCornerRadius
    case .opened: NotchConstants.cornerRadiusOpened
    }
}
```

**Step 3: Show compact badges during breathing state (with slight opacity)**

Change the compact badges visibility condition from:

```swift
if coordinator.status == .closed {
    compactBadges
        .zIndex(1)
        .transition(.opacity)
}
```

To:

```swift
if coordinator.status == .closed || coordinator.status == .breathing {
    compactBadges
        .zIndex(1)
        .transition(.opacity)
        .opacity(coordinator.status == .breathing ? 0.7 : 1.0)
}
```

**Step 4: Build and verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build`
Expected: Build succeeds, no errors

**Step 5: Commit**

```bash
git add NemoNotch/Notch/NotchView.swift
git commit -m "feat: update NotchView visuals for breathing state"
```

---

### Task 4: Update NotchBackgroundView for breathing background

**Files:**
- Modify: `NemoNotch/Notch/NotchBackgroundView.swift`

**Step 1: Adjust background color for breathing state**

The breathing state should show a slightly brighter background (`#252528` vs the normal `#1C1C1E`). Read the current file to understand how background color is set, then add a conditional:

```swift
// In the background fill, use a slightly lighter color when breathing:
let bgColor: Color = coordinator.status == .breathing
    ? Color(red: 0.15, green: 0.15, blue: 0.16)  // #252528
    : Color(red: 0.11, green: 0.11, blue: 0.12)  // #1C1C1E
```

**Step 2: Commit**

```bash
git add NemoNotch/Notch/NotchBackgroundView.swift
git commit -m "feat: breathing state uses subtly brighter background"
```

---

### Task 5: Update CompactBadge for breathing state compatibility

**Files:**
- Modify: `NemoNotch/Notch/CompactBadge.swift`

**Step 1: Ensure CompactBadge reads coordinator status**

CompactBadge currently has no reference to coordinator status. It may need to adjust its own opacity or scale when breathing. Read the current file to check if any changes are needed — the opacity handling was already done in NotchView's compactBadges view, so this step may be a no-op.

**Step 2: Commit if changed, otherwise skip**

---

### Task 6: Manual testing and polish

**Step 1: Build and run**

```bash
xcodebuild -scheme NemoNotch -configuration Debug build
```

**Step 2: Verify the following behaviors:**

1. Mouse far from notch → notch is closed (200×32)
2. Mouse enters ~20px proximity → notch breathes (200×38), badges slightly visible, haptic feedback
3. Mouse moves closer into hitbox → notch fully opens (500×260), haptic feedback
4. Mouse moves away from breathing range → notch closes smoothly
5. Mouse moves away from opened content → notch closes smoothly
6. Clicking outside opened content → notch closes
7. Clicking notch in breathing state → notch opens

**Step 3: Fix any animation glitches found during testing**

**Step 4: Commit any fixes**

```bash
git add -A
git commit -m "fix: polish three-state animation transitions"
```

---

## File Change Summary

| File | Change |
|------|--------|
| `NemoNotch/Helpers/Constants.swift` | Add breathing state constants |
| `NemoNotch/Notch/NotchCoordinator.swift` | Add `breathing` status, `notchBreathing()`, `notchCloseFromBreathing()`, update mouse handlers |
| `NemoNotch/Notch/NotchView.swift` | Update `notchSize`, `notchCornerRadius`, badge visibility for breathing |
| `NemoNotch/Notch/NotchBackgroundView.swift` | Subtle background brightness change for breathing |

## Reference Implementations

| Aspect | Source | Key Pattern |
|--------|--------|-------------|
| Three-state enum | NotchDrop `NotchViewModel.swift:29-33` | `closed / popping / opened` |
| Proximity detection | NotchDrop `NotchViewModel+Events.swift:56-65` | `insetBy(dx:dy:)` containment check |
| Spring animation | NotchDrop `NotchViewModel.swift:21-25` | `interactiveSpring(duration:extraBounce:blendDuration:)` |
| Haptic feedback | NotchDrop `NotchViewModel+Events.swift:76-93` | `NSHapticFeedbackManager` with throttle |
