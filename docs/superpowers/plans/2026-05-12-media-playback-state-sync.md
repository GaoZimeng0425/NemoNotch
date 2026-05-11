# Media Playback State Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix Spotify play/pause state inconsistency by cross-validating NowPlayingCLI data with MediaRemote direct API and adding notification-driven delayed re-queries.

**Architecture:** Split notification handlers into two paths — state changes go through a new `updateNowPlayingWithValidation()` that queries both NowPlayingCLI and MediaRemote in parallel, merges results preferring MediaRemote for `isPlaying`, then schedules a 250ms confirmatory re-query. Metadata changes keep the existing `updateNowPlaying()` path.

**Tech Stack:** Swift 6, SwiftUI `@Observable`, MediaRemote private API, NowPlayingCLI daemon

---

## File Structure

| File | Responsibility |
|------|---------------|
| `NemoNotch/Services/MediaService.swift` | All changes — new validation method, merge logic, notification classification, debounce |

No new files needed. `NowPlayingCLI.swift` and `MediaRemote.swift` are unchanged.

---

### Task 1: Add new private properties for validation state

**Files:**
- Modify: `NemoNotch/Services/MediaService.swift` — add properties after line 23 (existing private properties)

- [ ] **Step 1: Add validation state properties**

Add these two properties to `MediaService`, after the existing `private var isUpdatingNowPlaying = false` and `private var needsFollowupUpdate = false` (around line 21-22):

```swift
private var needsFollowupValidation = false
private var validationTask: Task<Void, Never>?
```

- [ ] **Step 2: Verify the build compiles**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (unused properties are fine, they compile)

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/MediaService.swift
git commit -m "wip: add validation state properties for media playback sync"
```

---

### Task 2: Add `mergePlaybackState()` helper method

**Files:**
- Modify: `NemoNotch/Services/MediaService.swift` — add new private method before `applyInfo()`

- [ ] **Step 1: Add the merge method**

Insert this method into `MediaService`, right before the existing `private func applyInfo(_ info: [String: Any]?)` (currently at line 242):

```swift
/// Cross-validate NowPlayingCLI data with MediaRemote's direct API result.
/// When they disagree on playback state, prefer MediaRemote (it's closer to
/// the source). Metadata (title, artwork, etc.) always comes from CLI.
private func mergePlaybackState(cliInfo: [String: Any]?, mrInfo: [String: Any]?) -> [String: Any]? {
    guard var result = cliInfo else { return mrInfo }
    guard let mrInfo else { return cliInfo }

    let cliRate = (result["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
    let mrRate = (mrInfo["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0

    if (cliRate > 0) != (mrRate > 0) {
        result["kMRMediaRemoteNowPlayingInfoPlaybackRate"] = NSNumber(value: mrRate)
    }

    return result
}
```

- [ ] **Step 2: Verify the build compiles**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/MediaService.swift
git commit -m "feat(media): add mergePlaybackState helper for cross-validation"
```

---

### Task 3: Add `updateNowPlayingWithValidation()` method

**Files:**
- Modify: `NemoNotch/Services/MediaService.swift` — add new method after existing `updateNowPlaying()`

- [ ] **Step 1: Add the validation query method**

Insert this method into `MediaService`, right after the existing `updateNowPlaying()` method (which ends around line 234):

```swift
/// State-change notification path: query both NowPlayingCLI and MediaRemote
/// in parallel, cross-validate playback state, then apply. Schedules a
/// 250ms confirmatory re-query to catch stale data.
private func updateNowPlayingWithValidation() {
    if isUpdatingNowPlaying {
        needsFollowupValidation = true
        return
    }
    isUpdatingNowPlaying = true

    var cliResult: [String: Any]?
    var mrResult: [String: Any]?
    var cliDone = false
    var mrDone = false
    let finishMerge = { [weak self] in
        guard let self else { return }
        let merged = self.mergePlaybackState(cliInfo: cliResult, mrInfo: mrResult)
        self.applyInfo(merged)
        self.isUpdatingNowPlaying = false

        if self.needsFollowupValidation {
            self.needsFollowupValidation = false
            self.updateNowPlayingWithValidation()
        } else {
            self.scheduleValidationFollowup()
        }
    }

    nowPlayingCLI.fetchNowPlayingInfo { [weak self] info in
        guard let self else { return }
        self.remote.getNowPlayingInfo { mrInfo in
            cliResult = info
            mrResult = mrInfo
            DispatchQueue.main.async { finishMerge() }
        }
    }
}

/// After a state-change validation query, re-query once more after a short
/// delay to confirm the state has settled.
private func scheduleValidationFollowup() {
    validationTask?.cancel()
    validationTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        self?.updateNowPlaying()
    }
}
```

**Design note:** The `updateNowPlayingWithValidation` fires `getNowPlayingInfo` *inside* the NowPlayingCLI callback to avoid a race — both queries run concurrently, but we merge as soon as both arrive. The MediaRemote callback is the inner one because `getNowPlayingInfo` dispatches to main queue (it's `@MainActor`), and we're already on main, so it fires synchronously or near-immediately after the CLI data lands. This ensures we always have both results before merging.

- [ ] **Step 2: Verify the build compiles**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/MediaService.swift
git commit -m "feat(media): add updateNowPlayingWithValidation with cross-validation"
```

---

### Task 4: Rewrite `setupNotifications()` to classify notification types

**Files:**
- Modify: `NemoNotch/Services/MediaService.swift` — replace existing `setupNotifications()` method

- [ ] **Step 1: Replace the setupNotifications method**

Replace the entire `setupNotifications()` method (currently lines 142-179) with this:

```swift
private func setupNotifications() {
    let nc = DistributedNotificationCenter.default()

    // State change notifications → validation path (CLI + MediaRemote cross-check)
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

    // Metadata change notifications → simple poll path (unchanged behavior)
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

- [ ] **Step 2: Verify the build compiles**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/MediaService.swift
git commit -m "feat(media): classify notifications into state-change vs metadata paths"
```

---

### Task 5: Cancel validation task on deinit

**Files:**
- Modify: `NemoNotch/Services/MediaService.swift` — update `deinit`

- [ ] **Step 1: Add validationTask cancellation to deinit**

Replace the existing `deinit` block (currently around lines 134-140):

```swift
deinit {
    MainActor.assumeIsolated {
        pollTimer?.invalidate()
        progressTimer?.invalidate()
        reconcileTask?.cancel()
        validationTask?.cancel()
    }
}
```

- [ ] **Step 2: Verify the build compiles**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/MediaService.swift
git commit -m "fix(media): cancel validation task in deinit"
```

---

### Task 6: Manual testing with Spotify

- [ ] **Step 1: Build and run the app**

Run: `open build/NemoNotch.app` or run from Xcode

- [ ] **Step 2: Test play → pause transition**

1. Play a song in Spotify
2. Verify NemoNotch shows playing state (progress bar moving)
3. Press pause in Spotify
4. Verify NemoNotch shows paused state within 500ms (progress bar stops, play button appears)
5. Check console logs for any `NowPlayingCLI` timeout errors

- [ ] **Step 3: Test pause → play transition**

1. With Spotify paused, press play in Spotify
2. Verify NemoNotch shows playing state within 500ms

- [ ] **Step 4: Test rapid toggling**

1. Rapidly toggle play/pause 5-6 times in Spotify
2. Verify NemoNotch settles to the correct final state within 1 second
3. No UI flickering between states

- [ ] **Step 5: Test Apple Music regression**

1. Play a song in Apple Music
2. Verify state displays correctly (playing/paused)
3. Test play → pause → play transitions

- [ ] **Step 6: Test idle state**

1. Stop playback in all media players
2. Verify NemoNotch shows empty/idle media state

---

### Task 7: Squash WIP commits and finalize

- [ ] **Step 1: Squash the WIP commits into a clean commit history**

```bash
# Interactive rebase to squash wip commits into the feature commits
# Keep the first feature commit, squash the wip into it
git rebase -i HEAD~5
# In the editor: pick the first commit, fixup the wip commit into it
```

Or if you prefer to keep individual commits, just ensure they're clean:

```bash
git log --oneline -5
# Verify commit messages are descriptive
```

- [ ] **Step 2: Update README if needed**

Check if the README mentions media playback behavior that should be updated.

- [ ] **Step 3: Final commit with spec reference**

```bash
git add -A
git commit -m "feat(media): cross-validate playback state with MediaRemote API

Fixes Spotify play/pause state inconsistency by:
- Classifying notifications into state-change vs metadata paths
- Cross-validating NowPlayingCLI data with MediaRemote.getNowPlayingInfo
- Preferring MediaRemote's playbackRate when sources disagree
- Adding 250ms confirmatory re-query after state changes

Spec: docs/superpowers/specs/2026-05-12-media-playback-state-sync-design.md"
```
