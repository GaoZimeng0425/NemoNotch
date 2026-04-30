# Media App Icon Display Design

## Goal

Show which application is playing media in both the expanded MediaTab and the collapsed CompactBadge. All playback apps display their own icon (Music, Spotify, Chrome, Safari, Firefox, Edge, etc.).

## Data Model Changes

### PlaybackState (Models/PlaybackState.swift)

Add two optional fields:

```swift
var appBundleIdentifier: String?
var appName: String?
```

## Data Acquisition

### MediaService (Services/MediaService.swift)

In `updateNowPlaying()` flow:

1. Call existing `MediaRemote.getNowPlayingApplicationPID()` to get PID
2. Use `NSRunningApplication(processIdentifier:)` to get bundle ID and app name
3. Write to `PlaybackState.appBundleIdentifier` / `appName`

Data flow: `MediaRemote PID` -> `NSRunningApplication` -> `PlaybackState` -> SwiftUI auto-refresh

## UI Changes

### MediaTab (Tabs/MediaTab.swift)

- Overlay a 16x16 app icon on the bottom-right corner of the album artwork (50x50)
- Circular clip with thin border, matching macOS notification center style
- Fallback to music.note SF Symbol if no app icon available

### CompactBadge (Notch/NotchView.swift)

- Replace hardcoded `music.note` SF Symbol with actual app icon (16x16)
- Fallback to music.note if no app icon available

### Icon Retrieval Strategy

1. Primary: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` -> icon
2. Fallback: `NSRunningApplication(processIdentifier:)`?.icon
3. Final fallback: music.note SF Symbol

## Files to Modify

| File | Change |
|------|--------|
| `Models/PlaybackState.swift` | Add appBundleIdentifier, appName fields |
| `Services/MediaService.swift` | Fetch app info via PID in updateNowPlaying() |
| `Services/MediaRemote.swift` | Ensure getNowPlayingApplicationPID is callable |
| `Tabs/MediaTab.swift` | Overlay app icon on artwork |
| `Notch/NotchView.swift` | Replace music.note with app icon in badge |

## Out of Scope

- App-specific media controls (beyond play/pause/next/prev)
- Distinguishing between tabs within a browser
- App filtering or prioritization
