# Notification Badge Design

## Overview

Monitor Dock icon badges via Accessibility API to show unread notification counts for configured apps (Slack, WeChat, etc.) on the notch sides.

## Architecture

### NotificationService (`Services/NotificationService.swift`)

- `@Observable` class
- Polls Dock icons every 2s via `AXUIElementCopyAttributeValue` reading `AXStatusLabel`
- Only monitors user-configured apps (not full Dock scan)
- Exposes `badges: [String: BadgeItem]` keyed by bundle ID

```
struct BadgeItem {
    let bundleID: String
    let count: Int      // 0 = red dot, >0 = count
    let icon: NSImage
}
```

### CompactBadge Integration

Priority (highest first):

1. **Unread notification** — app icon + count badge on notch left side
2. **Claude Code working** — cpu icon + gear
3. **Media playing** — album art + play icon
4. **Calendar upcoming** — calendar + clock

Layout: notification badge on left of notch, status badge on right.

Clicking the notification badge activates the corresponding app via `NSWorkspace.shared.open`.

### Settings

New "Notification" tab in SettingsView:

- Add apps via file picker (.app), auto-extract bundle ID and icon
- Remove apps via swipe or button
- App list persisted in `AppSettings.monitoredApps: [String]` via UserDefaults

## Files to Create/Modify

| File | Action |
|------|--------|
| `Services/NotificationService.swift` | New — AX polling service |
| `Notch/CompactBadge.swift` | Modify — add notification as top priority |
| `Notch/NotchCoordinator.swift` | Modify — inject NotificationService |
| `Notch/NotchView.swift` | Modify — pass service to CompactBadge |
| `Settings/SettingsView.swift` | Modify — add notification tab |
| `Models/AppSettings.swift` | Modify — add monitoredApps |
| `NemoNotchApp.swift` | Modify — create and wire NotificationService |

## Reference

Peninsula's `BadgeMonitor.swift` reads `AXStatusLabel` from Dock's `AXList` children every 0.3s. We use the same AXUIElement approach but at 2s intervals and only for configured apps.
