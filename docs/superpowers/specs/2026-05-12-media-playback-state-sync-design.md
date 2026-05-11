# Media Playback State Sync Design

## Problem

When using Spotify, NemoNotch frequently shows incorrect play/pause state:
- Spotify is playing but NemoNotch shows paused
- Spotify is paused but NemoNotch shows playing

## Root Cause

The play/pause state (`isPlaying`) is determined solely from `playbackRate` returned by the NowPlayingCLI perl daemon. Three issues cause stale state:

1. **Daemon cache lag**: After Spotify changes state, the daemon may still return the previous `playbackRate` because its internal MediaRemote cache hasn't refreshed yet.

2. **Serialized update guard**: Multiple notifications (MediaRemote + Spotify-specific) fire near-simultaneously, but `isUpdatingNowPlaying` serializes them. The first query may return stale data, and the follow-up query (`needsFollowupUpdate`) may also get stale data if it runs too soon.

3. **Poll gap**: If notification-driven queries return stale state, the next correction opportunity is the 2-second poll timer.

## Solution: A+B Combined Approach

### Part A: Notification-Driven Delayed Re-query + Debounce

**File**: `MediaService.swift`

1. **Classify notifications** into two categories in `setupNotifications()`:
   - **State change notifications** (`com.spotify.client.PlaybackStateChanged`, `kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification`) → call `updateNowPlayingWithValidation()` which does immediate query + 250ms delayed re-query
   - **Metadata change notifications** (`kMRMediaRemoteNowPlayingInfoDidChangeNotification`, `kMRMediaRemoteNowPlayingApplicationDidChangeNotification`, `com.apple.Music.playerInfo`) → call existing `updateNowPlaying()` + 600ms reconcile (unchanged)

2. **Debounce logic** in `applyInfo()`:
   - If new `isPlaying` differs from current state, store as `pendingPlayState` without applying
   - On the 250ms re-query, if the result confirms the pending state, apply it
   - If the re-query result matches current state instead, discard the pending change
   - This prevents flickering when the first query returns stale data but the second is correct

### Part B: MediaRemote Direct Callback Cross-Validation

**File**: `MediaService.swift`

1. **New method** `updateNowPlayingWithValidation()`:
   - Fires both NowPlayingCLI query and `MediaRemote.getNowPlayingInfo` in parallel
   - NowPlayingCLI provides full metadata (title, artist, artwork, duration, position, playbackRate)
   - MediaRemote provides authoritative `playbackRate` directly from the framework

2. **Cross-validation rules** in a new `mergePlaybackState()` helper:
   - Both agree on `isPlaying` → use as-is
   - Disagree → prefer MediaRemote's `playbackRate` for `isPlaying`, keep NowPlayingCLI data for everything else
   - MediaRemote query fails/times out (1 second) → use NowPlayingCLI result alone

3. **Timeout**: MediaRemote direct query gets a 1-second timeout to avoid blocking UI updates. If it times out, we proceed with NowPlayingCLI data only.

### Data Flow Changes

```
Before:
  Any Notification → updateNowPlaying() → NowPlayingCLI daemon → applyInfo()

After:
  State Notification → updateNowPlayingWithValidation()
                      ├─ NowPlayingCLI → cliInfo (full metadata)
                      └─ MediaRemote.getNowPlayingInfo → mrInfo (authoritative playbackRate)
                      → mergePlaybackState(cliInfo, mrInfo) → applyInfo()

  Metadata Notification → updateNowPlaying() (unchanged)

  250ms later → updateNowPlayingWithValidation() again to confirm state
```

### Files to Modify

| File | Changes |
|------|---------|
| `MediaService.swift` | Add `updateNowPlayingWithValidation()`, `mergePlaybackState()`, debounce logic; modify `setupNotifications()` to classify notifications |
| `NowPlayingCLI.swift` | No changes |
| `MediaRemote.swift` | No changes (already has `getNowPlayingInfo`) |

### Key Implementation Details

#### New state properties on MediaService

```swift
private var pendingPlayState: Bool?  // nil = no pending state change
private var validationTask: Task<Void, Never>?
```

#### Notification classification

```swift
private func setupNotifications() {
    let nc = DistributedNotificationCenter.default()

    // State change notifications → validation path
    let stateNotifications = [
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "com.spotify.client.PlaybackStateChanged",
    ]
    for name in stateNotifications {
        nc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlayingWithValidation()
            }
        }
    }

    // Metadata change notifications → simple poll path
    let metadataNotifications = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "com.apple.Music.playerInfo",
    ]
    for name in metadataNotifications {
        nc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }
    }
}
```

#### updateNowPlayingWithValidation

```swift
private func updateNowPlayingWithValidation() {
    if isUpdatingNowPlaying {
        needsFollowupValidation = true
        return
    }
    isUpdatingNowPlaying = true

    let cliCallback = nowPlayingCLI.fetchNowPlayingInfo { ... }
    let mrCallback = remote.getNowPlayingInfo { ... }

    // When both complete, call mergePlaybackState() then applyInfo()
    // Schedule 250ms re-query via validationTask
}
```

#### mergePlaybackState logic

```swift
private func mergePlaybackState(cliInfo: [String: Any]?, mrInfo: [String: Any]?) -> [String: Any]? {
    guard var result = cliInfo else { return mrInfo }
    guard let mrInfo else { return cliInfo }

    let cliRate = (result["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
    let mrRate = (mrInfo["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0

    let cliPlaying = cliRate > 0
    let mrPlaying = mrRate > 0

    if cliPlaying != mrPlaying {
        // Disagree: prefer MediaRemote for playback state
        result["kMRMediaRemoteNowPlayingInfoPlaybackRate"] = NSNumber(value: mrRate)
    }

    return result
}
```

### Testing Approach

- Manual testing with Spotify: play → pause → play transitions, verify state syncs within 500ms
- Test with Apple Music as regression check
- Test with no media playing (should still show empty state)
- Test rapid play/pause toggling (debounce should prevent flickering)
