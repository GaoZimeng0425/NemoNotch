# Menubar Redesign — Design Spec

Date: 2026-05-15
Status: Draft (pending user review)
Scope: `NemoNotchApp.swift` MenuBarExtra, `HotkeyService` removal, new Hotkeys settings pane

## Background

Current menubar implementation (`NemoNotch/NemoNotchApp.swift:10-23`):

- Icon: `menubar.rectangle` / `menubar.rectangle.fill` — only toggles on AI hook installation state, nothing else
- Menu (`.menu` style): six static items — `Open Notch`, `Install Claude Hooks`, `Install Gemini Hooks`, `Preferences`, `About`, `Quit`
- Global hotkeys: `HotkeyService` (Carbon `RegisterEventHotKey`), hard-coded `⌥⌘ Space` + `⌥⌘ 1..N` for tabs, not user-configurable

Pain points:

- Icon ignores rich runtime state (AI working, agent active, media playing)
- "Open Notch" menu item is redundant with the global hotkey
- Hotkeys can't be changed without recompiling

## Goals

1. Menubar icon reflects current activity, prioritized like the Notch's collapsed badge
2. Menu surfaces useful actions: media controls, direct tab jumps; drop the redundant "Open Notch" top-level item
3. All global hotkeys become user-customizable via `sindresorhus/KeyboardShortcuts`

Non-goals:

- Changing menu visual style from `.menu` to `.window` (out of scope; existing system menu is fine)
- Adding hooks status indicator beyond the install actions
- Adding notification or calendar state to the menubar icon

## Section 1 — Dynamic Icon

### State priority (highest first)

```
1. AI waiting for approval   → "exclamationmark.bubble.fill"
2. Agent active              → "ant.fill"
3. AI working                → "sparkle"
4. Media playing             → "play.circle.fill"
5. Idle (default)            → "menubar.rectangle"
```

Priority matches the Notch's collapsed badge order minus the states the user opted out of (notification, hook-not-installed, calendar).

### State sources (all verified to exist)

| State | Source |
|---|---|
| AI waiting for approval | `aiService.store.sortedSessions.contains { $0.phase.isWaitingForApproval }` |
| AI working | `aiService.store.sortedSessions.contains { $0.status == .working }` |
| Agent active | `agentRegistry.hasAnyActiveAgent` |
| Media playing | `mediaService.playbackState.isPlaying` |

### Implementation

Add a computed property on the view that owns the `MenuBarExtra` label (currently `NemoNotchApp`, but with `@Environment` injection requires moving to a small `MenuBarLabel` View). The label View consumes `AICLIMonitorService`, `AgentMonitorRegistry`, `MediaService` from environment, recomputes icon on any `@Observable` change.

```swift
struct MenuBarLabel: View {
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(AgentMonitorRegistry.self) var agentRegistry
    @Environment(MediaService.self) var mediaService

    var body: some View { Image(systemName: symbol) }

    private var symbol: String {
        let sessions = aiService.store.sortedSessions
        if sessions.contains(where: { $0.phase.isWaitingForApproval }) {
            return "exclamationmark.bubble.fill"
        }
        if agentRegistry.hasAnyActiveAgent { return "ant.fill" }
        if sessions.contains(where: { $0.status == .working }) { return "sparkle" }
        if mediaService.playbackState.isPlaying { return "play.circle.fill" }
        return "menubar.rectangle"
    }
}
```

Drop the existing `.fill` vs non-`.fill` distinction for hook installation.

## Section 2 — Menu Content

### New menu structure

```
Now Playing                                  (only when isPlaying)
  ♫ Song Title — Artist                      (disabled, info-only)
  Previous Track                              (uses MediaService.previous())
  Play / Pause                                (uses MediaService.togglePlayPause())
  Next Track                                  (uses MediaService.next())
─────────
Open Notch ›                                 (submenu, generated from Tab.sorted(enabledTabs))
  Overview                   ⌥⌘ 1
  AI                         ⌥⌘ 2
  Agents                     ⌥⌘ 3
  Launcher                   ⌥⌘ 4
  System                     ⌥⌘ 5
─────────
Install Claude Hooks                         (only when !claudeProvider.isHookInstalled)
Install Gemini Hooks                         (only when !geminiProvider.isHookInstalled)
─────────
Preferences…                  ⌘,
About NemoNotch
Quit                          ⌘Q
```

### Key decisions

- Media controls rendered as three separate vertical menu items (not horizontal), to keep `.menu` style intact. Horizontal layout would require switching to `.window` style — out of scope.
- Media controls do not get global hotkeys in this iteration — they're menu-only. (Adding `nextTrack` / `prevTrack` / `playPause` hotkeys is a logical follow-up but stays out of this scope.)
- "Open Notch" top-level item removed (user feedback: redundant with global hotkey)
- Tab submenu uses `Tab.sorted(settings.enabledTabs)`, so disabled tabs are hidden
- Hook items hide once installed (current behavior: show "✓ Installed" text). Reduces noise once setup is complete.
- The shortcut hint to the right of each item shows the user's currently-bound key combo (see Section 3 — manual string composition required for `.menu` style)

### Component breakdown

Refactor `MenuContent` (currently one 40-line View) into 4 small Views:

| View | Responsibility | Visibility |
|---|---|---|
| `NowPlayingSection` | Song info + 3 media buttons | `mediaService.playbackState.isPlaying` |
| `OpenNotchSubmenu` | One submenu listing all enabled tabs | always |
| `HooksSection` | Install Claude / Gemini buttons | when either is not installed |
| `AppSection` | Preferences / About / Quit | always |

Each becomes a separate file or sub-struct under `NemoNotch/Notch/MenuBar/`. Existing `MenuContent` becomes a thin composition root.

### Localization

Add to `NemoNotch/Resources/Localizable.xcstrings`:

- `menu.now_playing`
- `menu.previous_track`
- `menu.play_pause`
- `menu.next_track`
- `menu.open_notch_submenu`
- `menu.tab.overview` / `menu.tab.ai` / `menu.tab.launcher` / `menu.tab.agents` / `menu.tab.system`

Remove:

- `menu.open_notch`
- `menu.claude_hooks_installed`
- `menu.gemini_hooks_installed`

## Section 3 — Hotkey Migration (Carbon → KeyboardShortcuts)

### Dependency

Add SPM dependency to `NemoNotch.xcodeproj`:

- URL: `https://github.com/sindresorhus/KeyboardShortcuts`
- Version: `from: "2.0.0"`
- Deployment target: project is already on `macOS 26.0`, far above the library's minimum

### Hotkey names

New file `NemoNotch/Services/Hotkeys.swift`:

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleNotch  = Self("toggleNotch",  default: .init(.space, modifiers: [.option, .command]))
    static let openOverview = Self("openOverview", default: .init(.one,   modifiers: [.option, .command]))
    static let openAI       = Self("openAI",       default: .init(.two,   modifiers: [.option, .command]))
    static let openAgents   = Self("openAgents",   default: .init(.three, modifiers: [.option, .command]))
    static let openLauncher = Self("openLauncher", default: .init(.four,  modifiers: [.option, .command]))
    static let openSystem   = Self("openSystem",   default: .init(.five,  modifiers: [.option, .command]))
}

extension Tab {
    var hotkeyName: KeyboardShortcuts.Name {
        switch self {
        case .overview: return .openOverview
        case .claude:   return .openAI
        case .agents:   return .openAgents
        case .launcher: return .openLauncher
        case .system:   return .openSystem
        }
    }
}
```

Default order matches `Tab.allCases` (overview, claude, agents, launcher, system) — same numeric mapping users have today.

### Behavior change

Old: tab hotkey was assigned by `Tab.sorted(enabledTabs)` index, so disabling a tab shifted the others' shortcuts.

New: each tab owns a fixed `KeyboardShortcuts.Name`. Disabling a tab leaves the binding idle. Users can rebind freely; "which numeric slot" is no longer a concept.

### Replacements

| File | Change |
|---|---|
| `NemoNotch/Services/HotkeyService.swift` | **Delete** |
| `NemoNotch/NemoNotchApp.swift` | Remove `import Carbon`, remove `hotkeyService` property, replace `setupHotkeys(...)` body with KeyboardShortcuts registrations below |
| `NemoNotch/Services/Hotkeys.swift` | **New** — Names + Tab extension |
| `NemoNotch/Settings/HotkeysSettingsView.swift` | **New** — Recorder UI |
| `NemoNotch/Settings/SettingsView.swift` | Add "Hotkeys" tab pointing at the new view |

### Registration

In `AppDelegate.applicationDidFinishLaunching`, replacing `setupHotkeys`:

```swift
KeyboardShortcuts.onKeyDown(for: .toggleNotch) { [weak notchCoordinator] in
    guard let c = notchCoordinator else { return }
    switch c.status {
    case .closed: c.notchOpen()
    case .opened: c.notchClose()
    }
}

for tab in Tab.allCases {
    KeyboardShortcuts.onKeyDown(for: tab.hotkeyName) { [weak notchCoordinator] in
        notchCoordinator?.notchOpen(tab: tab)
    }
}
```

### Settings UI

`NemoNotch/Settings/HotkeysSettingsView.swift`:

```swift
import KeyboardShortcuts
import SwiftUI

struct HotkeysSettingsView: View {
    var body: some View {
        Form {
            Section("settings.hotkeys.notch") {
                KeyboardShortcuts.Recorder("settings.hotkeys.toggle_notch", name: .toggleNotch)
            }
            Section("settings.hotkeys.tabs") {
                KeyboardShortcuts.Recorder("settings.hotkeys.overview", name: .openOverview)
                KeyboardShortcuts.Recorder("settings.hotkeys.ai",       name: .openAI)
                KeyboardShortcuts.Recorder("settings.hotkeys.agents",   name: .openAgents)
                KeyboardShortcuts.Recorder("settings.hotkeys.launcher", name: .openLauncher)
                KeyboardShortcuts.Recorder("settings.hotkeys.system",   name: .openSystem)
            }
        }
        .padding()
    }
}
```

Wire into `SettingsView` as a new `Tab` alongside existing settings tabs.

### Menu shortcut hints

Under `.menu` style, SwiftUI does not auto-render KeyboardShortcuts' bindings on MenuBarExtra items. Manual composition is needed:

```swift
@MainActor
func shortcutHint(_ name: KeyboardShortcuts.Name) -> String {
    KeyboardShortcuts.getShortcut(for: name)?.description ?? ""
}
```

Render via `Text("\(label)  \(shortcutHint(name))")`. Place hint in trailing position via `HStack` or string concatenation. The hint updates when the user changes the binding (Recorder writes to UserDefaults, which `KeyboardShortcuts.getShortcut` reads on next menu open — acceptable freshness).

### Migration notes

- Default bindings match current Carbon defaults exactly → users experience no behavior change on upgrade unless they choose to remap
- KeyboardShortcuts persists to UserDefaults under keys prefixed `KeyboardShortcuts_*`; first launch after upgrade writes the defaults
- Carbon framework remains linked (other modules may still need it); deleting `HotkeyService.swift` removes the last NemoNotch-side Carbon import

## File Change Summary

### New files

- `NemoNotch/Services/Hotkeys.swift`
- `NemoNotch/Settings/HotkeysSettingsView.swift`
- `NemoNotch/Notch/MenuBar/MenuBarLabel.swift`
- `NemoNotch/Notch/MenuBar/NowPlayingSection.swift`
- `NemoNotch/Notch/MenuBar/OpenNotchSubmenu.swift`
- `NemoNotch/Notch/MenuBar/HooksSection.swift`
- `NemoNotch/Notch/MenuBar/AppSection.swift`

### Modified files

- `NemoNotch/NemoNotchApp.swift` — MenuBarExtra label + content rewrite, hotkey registration migration, environment injection (MediaService, AgentMonitorRegistry)
- `NemoNotch/Settings/SettingsView.swift` — new Hotkeys tab
- `NemoNotch/Resources/Localizable.xcstrings` — string adds/removes per Section 2
- `NemoNotch.xcodeproj/project.pbxproj` — KeyboardShortcuts SPM dependency

### Deleted files

- `NemoNotch/Services/HotkeyService.swift`

## Testing

Manual verification only (no automated UI tests exist for menubar):

1. **Icon state**: Trigger each priority level in isolation
   - Start a Claude session → expect `sparkle`
   - Trigger a tool approval → expect `exclamationmark.bubble.fill` overriding `sparkle`
   - Stop AI, start an OpenClaw/Hermes agent → expect `ant.fill`
   - Stop agent, play music → expect `play.circle.fill`
   - Stop everything → expect `menubar.rectangle`
2. **Menu content**:
   - Toggle media playing on/off, verify Now Playing section appears/disappears
   - Open each tab via submenu, verify correct tab opens
   - Uninstall hooks via shell, restart app, verify install buttons reappear
3. **Hotkeys**:
   - Default bindings still work (`⌥⌘ Space`, `⌥⌘ 1..5`)
   - In Settings → Hotkeys, rebind one tab to a new combo, verify only that one changes
   - Disable a tab in Tabs settings, verify its hotkey becomes idle (no longer opens anything)
   - Set a binding to empty (clear it), verify nothing fires for that action

## Risks

- **`.menu` style shortcut hints stale until menu reopens** — acceptable; users typically don't rebind and immediately reopen the menu in the same second
- **KeyboardShortcuts conflict detection** — library handles same-app conflicts; system-wide conflicts (e.g. Spotlight) still possible, library shows warning in Recorder
- **First-run after upgrade writes UserDefaults** — non-issue, defaults match prior Carbon defaults
