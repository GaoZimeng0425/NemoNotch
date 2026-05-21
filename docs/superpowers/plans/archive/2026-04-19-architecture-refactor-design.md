# Architecture Refactor Design

## Problem

Adding any new service requires touching 6 files (AppDelegate → NotchCoordinator → NotchView → CompactBadge → SettingsView + the new service). Duplicated logic (toolIcon/toolColor, tab sorting, badge priority) is scattered across files. Large files mix multiple responsibilities.

## Design

### 1. @Environment for Services

Register all `@Observable` services in the app's SwiftUI environment. Views declare only what they need via `@Environment`.

- `NemoNotchApp` / `AppDelegate` creates services and registers them via `.environment()`
- Views use `@Environment(MediaService.self) var mediaService`
- `NotchCoordinator` drops all service storage — pure state machine

### 2. File Decomposition

Split `MediaService.swift` (473 lines, 3 classes) into:
- `Services/Media/MediaService.swift`
- `Services/Media/MediaRemote.swift`
- `Services/Media/NowPlayingCLI.swift`

Move `HookEvent` from `HookServer.swift` to `Models/`.

Move `PulseModifier` + `GlowPulseModifier` from `ClaudeTab.swift` to `Helpers/ViewModifiers.swift`.

Add `Helpers/Constants.swift` for magic numbers.

### 3. Deduplication

- `ToolStyle.icon(_:)` / `ToolStyle.color(_:)` in `Helpers/ToolStyles.swift` — shared by CompactBadge and ClaudeTab
- `Tab.sorted(_:)` extension — replaces 3 identical sorting closures
- Badge priority logic unified in one place

### 4. Slim NotchCoordinator

Coordinator becomes ~120 lines of pure state machine: open/close/selectedTab, window positioning, hit-testing, app focus management. No service references.
