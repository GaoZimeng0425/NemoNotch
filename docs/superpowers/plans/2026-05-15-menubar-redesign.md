# Menubar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the static menubar icon + menu with a state-driven icon, restructured menu (Now Playing controls + Open Notch submenu), and migrate all global hotkeys from Carbon to user-customizable `KeyboardShortcuts`.

**Architecture:** Three independent slices stitched together in `NemoNotchApp.MenuBarExtra`:
1. `MenuBarLabel` View computes its SF Symbol from injected `AICLIMonitorService` / `AgentMonitorRegistry` / `MediaService` state, priority-ordered.
2. `MenuContent` decomposes into four sub-Views (NowPlaying / OpenNotch / Hooks / App) under `Notch/MenuBar/`.
3. `KeyboardShortcuts` library owns every global hotkey; `HotkeyService.swift` is deleted; settings get a new "Hotkeys" tab with a Recorder per binding.

**Tech Stack:** Swift 6 + SwiftUI, macOS 26.0 deployment target, `sindresorhus/KeyboardShortcuts` (SPM, `from: "2.0.0"`), existing `@Observable` services.

**Spec:** `docs/superpowers/specs/2026-05-15-menubar-redesign-design.md`

**Branch:** Create `feature/menubar-redesign` from `develop` (this is large work per the project's Git Flow + memory note).

**Testing note:** This project has no automated test target. Verification per task = `xcodebuild build` succeeds + manual smoke check listed in each task. The user runs the smoke step; do not skip it.

---

## Task 0: Create feature branch

**Files:**
- None

- [ ] **Step 1: Confirm on develop with no in-flight menubar work**

Run:
```bash
git status
git branch --show-current
```
Expected: branch is `develop`. (The unrelated `BadgeItem.swift` modification may be present — leave it alone.)

- [ ] **Step 2: Branch off**

Run:
```bash
git checkout -b feature/menubar-redesign
```
Expected: `Switched to a new branch 'feature/menubar-redesign'`

---

## Task 1: Add KeyboardShortcuts SPM dependency

**Files:**
- Modify: `NemoNotch.xcodeproj/project.pbxproj` (add SPM ref + product dependency)
- Modify: `NemoNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

- [ ] **Step 1: Add the package via Xcode CLI**

The simplest, safe way is to open Xcode UI: `File → Add Package Dependencies → https://github.com/sindresorhus/KeyboardShortcuts → "Up to Next Major Version" from 2.0.0 → Add Package → tick the `KeyboardShortcuts` library for the `NemoNotch` target → Add Package`.

If editing pbxproj by hand is preferred (matches the two existing SPM deps — CocoaLumberjack + swift-log), look up their `XCRemoteSwiftPackageReference` and `XCSwiftPackageProductDependency` blocks and clone the pattern:

Run:
```bash
grep -n "XCRemoteSwiftPackageReference\|XCSwiftPackageProductDependency\|CocoaLumberjack" NemoNotch.xcodeproj/project.pbxproj | head -30
```
Use the result to add three blocks: (1) `XCRemoteSwiftPackageReference` with `repositoryURL = "https://github.com/sindresorhus/KeyboardShortcuts"; requirement = { kind = upToNextMajorVersion; minimumVersion = 2.0.0; };`, (2) `XCSwiftPackageProductDependency` with `productName = KeyboardShortcuts;` referencing the SPMRef UUID, (3) add the product dependency UUID to the `packageProductDependencies` array of the `NemoNotch` PBXNativeTarget.

- [ ] **Step 2: Verify resolution**

Run:
```bash
xcodebuild -resolvePackageDependencies -project NemoNotch.xcodeproj -scheme NemoNotch 2>&1 | tail -10
```
Expected: `Resolved source packages:` lists `KeyboardShortcuts`.

- [ ] **Step 3: Verify it links by building**

Run:
```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (No source changes yet, just verifying the dep doesn't break the build.)

- [ ] **Step 4: Commit**

```bash
git add NemoNotch.xcodeproj/project.pbxproj NemoNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "$(cat <<'EOF'
build: add KeyboardShortcuts SPM dependency

Adds sindresorhus/KeyboardShortcuts ^2.0.0 to support user-customizable
global hotkeys.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Define hotkey Names + Tab→Name mapping

**Files:**
- Create: `NemoNotch/Services/Hotkeys.swift`

- [ ] **Step 1: Write the file**

Create `NemoNotch/Services/Hotkeys.swift`:

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

The default numeric mapping (1=overview, 2=AI, 3=agents, 4=launcher, 5=system) matches the order from `Tab.allCases` in `NemoNotch/Models/Tab.swift:4-8`, which preserves what users currently get from Carbon hotkeys.

- [ ] **Step 2: Add to Xcode target**

Open Xcode → drag `Hotkeys.swift` into the `Services` group → ensure `NemoNotch` target checkbox is ticked.

Or via CLI: grep an existing Services file in pbxproj (e.g. `HotkeyService.swift`) and clone its `PBXBuildFile` + `PBXFileReference` + `PBXGroup` member entries with a new UUID.

- [ ] **Step 3: Build to verify it compiles**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`. The new file is not yet referenced, just needs to compile.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Services/Hotkeys.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(hotkeys): define KeyboardShortcuts names for notch + tabs

Defines six KeyboardShortcuts.Name entries (toggle + per-tab) with
default bindings matching the current Carbon defaults so users see no
behavior change. Adds Tab.hotkeyName for ergonomic lookup.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Migrate hotkey registration, delete HotkeyService

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift:1-3` (imports), `:96` (property), `:187` and `:234-252` (setupHotkeys)
- Delete: `NemoNotch/Services/HotkeyService.swift`

- [ ] **Step 1: Replace imports in NemoNotchApp.swift**

Open `NemoNotch/NemoNotchApp.swift`. Change line 1-3:

From:
```swift
import Carbon
import Darwin
import SwiftUI
```

To:
```swift
import Darwin
import KeyboardShortcuts
import SwiftUI
```

(Removes `Carbon` — no longer used after this task.)

- [ ] **Step 2: Remove hotkeyService property**

Delete line `private var hotkeyService: HotkeyService?` (around line 96).

- [ ] **Step 3: Replace setupHotkeys body**

Replace the entire `setupHotkeys` function (lines 234-252) with:

```swift
private func setupHotkeys(coordinator: NotchCoordinator, settings: AppSettings) {
    KeyboardShortcuts.onKeyDown(for: .toggleNotch) { [weak coordinator] in
        guard let c = coordinator else { return }
        switch c.status {
        case .closed: c.notchOpen()
        case .opened: c.notchClose()
        }
    }

    for tab in Tab.allCases {
        KeyboardShortcuts.onKeyDown(for: tab.hotkeyName) { [weak coordinator] in
            coordinator?.notchOpen(tab: tab)
        }
    }
}
```

Note: signature unchanged (still takes `coordinator` and `settings`) so the call site at line 187 keeps working. `settings` becomes unused inside the function but is retained for now — Task 5 will reuse it.

- [ ] **Step 4: Delete HotkeyService**

```bash
git rm NemoNotch/Services/HotkeyService.swift
```

Then remove its `PBXBuildFile` + `PBXFileReference` + group member entries from `NemoNotch.xcodeproj/project.pbxproj`. Quickest path: open in Xcode, select the (now-red) `HotkeyService.swift` row, press Delete → "Move to Trash". Xcode strips the pbxproj entries automatically.

- [ ] **Step 5: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. If a remaining reference to `HotkeyService` errors, grep for it: `grep -rn "HotkeyService\|hotkeyService" NemoNotch/`.

- [ ] **Step 6: Smoke test — defaults still work**

Run the app from Xcode (`⌘R`). Verify:
- `⌥⌘ Space` toggles notch open/close
- `⌥⌘ 1` opens Overview tab
- `⌥⌘ 2` opens AI tab
- `⌥⌘ 3` opens Agents tab (or whichever Tab.allCases[2] is in current settings)

If any binding misfires, double-check Task 2's `Tab.hotkeyName` switch matches `Tab.allCases` order.

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
refactor(hotkeys): migrate global hotkeys to KeyboardShortcuts

Replaces Carbon RegisterEventHotKey path with KeyboardShortcuts. Deletes
HotkeyService.swift. Defaults preserve the previous bindings.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add Hotkeys settings tab

**Files:**
- Create: `NemoNotch/Settings/HotkeysSettingsView.swift`
- Modify: `NemoNotch/Settings/SettingsView.swift:17-33` (add new TabView tag)
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

- [ ] **Step 1: Create HotkeysSettingsView**

Create `NemoNotch/Settings/HotkeysSettingsView.swift`:

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
                KeyboardShortcuts.Recorder("models.tab.overview", name: .openOverview)
                KeyboardShortcuts.Recorder("models.tab.ai",       name: .openAI)
                KeyboardShortcuts.Recorder("models.tab.agents",   name: .openAgents)
                KeyboardShortcuts.Recorder("models.tab.launcher", name: .openLauncher)
                KeyboardShortcuts.Recorder("models.tab.system",   name: .openSystem)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 2: Wire into SettingsView**

In `NemoNotch/Settings/SettingsView.swift`, inside `TabView(selection: $selectedTab)`, after the `.tag(3)` notification block (around line 32), insert:

```swift
HotkeysSettingsView()
    .tabItem { Label("settings.hotkeys", systemImage: "keyboard") }
    .tag(4)
```

- [ ] **Step 3: Add localization keys**

Open `NemoNotch/Resources/Localizable.xcstrings` (it's a JSON catalog). Add entries for each new key. Match the existing pattern — every key has both English (`en`) and Simplified Chinese (`zh-Hans`) translations.

Keys to add (English → 简体中文):
- `settings.hotkeys` → `Hotkeys` / `快捷键`
- `settings.hotkeys.notch` → `Notch` / `灵动岛`
- `settings.hotkeys.tabs` → `Tabs` / `标签页`
- `settings.hotkeys.toggle_notch` → `Toggle Notch` / `打开/关闭灵动岛`

(Per-tab labels reuse the existing `models.tab.*` keys already defined in `Localizable.xcstrings` — no new tab strings needed.)

Easiest path: open the .xcstrings in Xcode, click `+`, paste the key, fill both locales.

- [ ] **Step 4: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Smoke test — rebind a hotkey**

Run the app, open Preferences via the existing menubar item, click the new "Hotkeys" tab. Verify:
- All six Recorders show their current bindings (default values)
- Click the "Toggle Notch" Recorder, press `⌃⌘ N`, verify the displayed shortcut updates
- Close Preferences, press `⌃⌘ N` from any app → notch toggles
- Press `⌥⌘ Space` → should no longer fire toggle (because we just rebound it)
- Re-enter Preferences, clear the binding (click the X), press `⌥⌘ Space` again — verify nothing fires, then re-record `⌥⌘ Space` to restore default

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Settings/HotkeysSettingsView.swift NemoNotch/Settings/SettingsView.swift NemoNotch/Resources/Localizable.xcstrings NemoNotch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(settings): add Hotkeys settings tab

New Settings → Hotkeys pane lets users rebind toggle-notch and the five
tab-open shortcuts via KeyboardShortcuts.Recorder. Adds matching
localization keys for en/zh-Hans.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Create MenuBarLabel for dynamic icon

**Files:**
- Create: `NemoNotch/Notch/MenuBar/MenuBarLabel.swift`

- [ ] **Step 1: Create the directory + file**

Create folder `NemoNotch/Notch/MenuBar/` (in Xcode, right-click `Notch` group → New Group → name `MenuBar`).

Create `NemoNotch/Notch/MenuBar/MenuBarLabel.swift`:

```swift
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AICLIMonitorService.self) private var aiService
    @Environment(AgentMonitorRegistry.self) private var agentRegistry
    @Environment(MediaService.self) private var mediaService

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        let sessions = aiService.store.sortedSessions
        if sessions.contains(where: { $0.phase.isWaitingForApproval }) {
            return "exclamationmark.bubble.fill"
        }
        if agentRegistry.hasAnyActiveAgent {
            return "ant.fill"
        }
        if sessions.contains(where: { $0.status == .working }) {
            return "sparkle"
        }
        if mediaService.playbackState.isPlaying {
            return "play.circle.fill"
        }
        return "menubar.rectangle"
    }
}
```

- [ ] **Step 2: Build (won't be wired in yet — just verifying compile)**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`. (File compiles on its own; Task 6 wires it into MenuBarExtra.)

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Notch/MenuBar/MenuBarLabel.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(menubar): add state-driven MenuBarLabel view

Computes the menubar SF Symbol from AI / agent / media state in the
Notch's badge priority order. Not yet wired into MenuBarExtra.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire MenuBarLabel into MenuBarExtra (with env injection)

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift:9-23` (MenuBarExtra body)

- [ ] **Step 1: Replace the MenuBarExtra block**

In `NemoNotch/NemoNotchApp.swift`, replace the entire `var body: some Scene { ... }` block (lines 9-23) with:

```swift
var body: some Scene {
    MenuBarExtra {
        MenuContent(
            coordinator: appDelegate.coordinator,
            appSettings: appDelegate.appSettings,
            onOpenSettings: { appDelegate.showSettings() }
        )
        .environment(appDelegate.aiMonitorService ?? AICLIMonitorService())
        .environment(appDelegate.agentRegistry ?? AgentMonitorRegistry())
        .environment(appDelegate.mediaService ?? MediaService())
    } label: {
        MenuBarLabel()
            .environment(appDelegate.aiMonitorService ?? AICLIMonitorService())
            .environment(appDelegate.agentRegistry ?? AgentMonitorRegistry())
            .environment(appDelegate.mediaService ?? MediaService())
    }
    .menuBarExtraStyle(.menu)
}
```

- [ ] **Step 2: Expose mediaService + agentRegistry on AppDelegate**

In the same file, find the `AppDelegate` class. Change:
```swift
private var mediaService: MediaService?
```
to:
```swift
private(set) var mediaService: MediaService?
```

And change:
```swift
private var agentRegistry: AgentMonitorRegistry?
```
to:
```swift
private(set) var agentRegistry: AgentMonitorRegistry?
```

(Match the existing `private(set) var coordinator` / `appSettings` / `aiMonitorService` access pattern.)

- [ ] **Step 3: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke test — icon reacts to state**

Run the app. With nothing happening, the menubar icon should be `menubar.rectangle`.

Trigger each state and verify the icon switches:
1. Play music in Music.app → expect `play.circle.fill`
2. Pause music → expect back to `menubar.rectangle`
3. Run `claude` in a terminal, ask it to do something that takes a few seconds → expect `sparkle` while working
4. Have Claude attempt a tool that requires approval → expect `exclamationmark.bubble.fill`
5. Approve / cancel → expect back to `sparkle` then `menubar.rectangle`

If an agent monitor (OpenClaw / Hermes) is set up and reachable, also trigger an active agent and confirm `ant.fill`.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "$(cat <<'EOF'
feat(menubar): make menubar icon state-driven

Uses MenuBarLabel to pick the SF Symbol based on AI / agent / media
state. Drops the old static .fill / non-.fill hook-installed
distinction. Injects MediaService and AgentMonitorRegistry into the
MenuBarExtra environment.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Create NowPlayingSection

**Files:**
- Create: `NemoNotch/Notch/MenuBar/NowPlayingSection.swift`
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

- [ ] **Step 1: Write the file**

Create `NemoNotch/Notch/MenuBar/NowPlayingSection.swift`:

```swift
import SwiftUI

struct NowPlayingSection: View {
    @Environment(MediaService.self) private var mediaService

    var body: some View {
        if mediaService.playbackState.isPlaying {
            Text(nowPlayingTitle)
                .disabled(true)
            Button("menu.previous_track") {
                mediaService.previousTrack()
            }
            Button("menu.play_pause") {
                mediaService.togglePlayPause()
            }
            Button("menu.next_track") {
                mediaService.nextTrack()
            }
            Divider()
        }
    }

    private var nowPlayingTitle: String {
        let state = mediaService.playbackState
        if state.artist.isEmpty {
            return "♫ \(state.title)"
        }
        return "♫ \(state.title) — \(state.artist)"
    }
}
```

- [ ] **Step 2: Add localization keys**

Add to `Localizable.xcstrings`:
- `menu.previous_track` → `Previous Track` / `上一曲`
- `menu.play_pause` → `Play / Pause` / `播放 / 暂停`
- `menu.next_track` → `Next Track` / `下一曲`

(`menu.now_playing` is not needed — the section uses a dynamically composed `Text(nowPlayingTitle)` with the actual song info, not a localized header.)

- [ ] **Step 3: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/MenuBar/NowPlayingSection.swift NemoNotch/Resources/Localizable.xcstrings NemoNotch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(menubar): add NowPlayingSection view

New section renders song title + Prev/PlayPause/Next when media is
playing. Not yet composed into MenuContent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Create OpenNotchSubmenu with shortcut hints

**Files:**
- Create: `NemoNotch/Notch/MenuBar/OpenNotchSubmenu.swift`
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

- [ ] **Step 1: Write the file**

Create `NemoNotch/Notch/MenuBar/OpenNotchSubmenu.swift`:

```swift
import KeyboardShortcuts
import SwiftUI

struct OpenNotchSubmenu: View {
    let coordinator: NotchCoordinator?
    let appSettings: AppSettings?

    var body: some View {
        Menu("menu.open_notch_submenu") {
            ForEach(Tab.sorted(enabledTabs), id: \.self) { tab in
                Button(action: { coordinator?.notchOpen(tab: tab) }) {
                    Text(menuLabel(for: tab))
                }
            }
        }
    }

    private var enabledTabs: Set<Tab> {
        appSettings?.enabledTabs ?? Set(Tab.allCases)
    }

    private func menuLabel(for tab: Tab) -> String {
        let title = tab.title
        let hint = KeyboardShortcuts.getShortcut(for: tab.hotkeyName)?.description ?? ""
        if hint.isEmpty { return title }
        return "\(title)  \(hint)"
    }
}
```

- [ ] **Step 2: Add localization key**

Add to `Localizable.xcstrings`:
- `menu.open_notch_submenu` → `Open Notch` / `打开灵动岛`

- [ ] **Step 3: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`. If `Tab.sorted` or `tab.title` errors, grep the codebase to confirm those APIs exist (they're used today in `NemoNotchApp.swift:245` and `Settings/SettingsView.swift:44`).

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/MenuBar/OpenNotchSubmenu.swift NemoNotch/Resources/Localizable.xcstrings NemoNotch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(menubar): add OpenNotchSubmenu with shortcut hints

New submenu lists enabled tabs and shows their current hotkey binding
to the right of each label.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Extract HooksSection + AppSection

**Files:**
- Create: `NemoNotch/Notch/MenuBar/HooksSection.swift`
- Create: `NemoNotch/Notch/MenuBar/AppSection.swift`

- [ ] **Step 1: Create HooksSection**

```swift
// NemoNotch/Notch/MenuBar/HooksSection.swift
import SwiftUI

struct HooksSection: View {
    @Environment(AICLIMonitorService.self) private var aiService

    var body: some View {
        if !aiService.claudeProvider.isHookInstalled {
            Button("menu.install_claude_hooks") {
                aiService.claudeProvider.installHooks()
            }
        }
        if !aiService.geminiProvider.isHookInstalled {
            Button("menu.install_gemini_hooks") {
                aiService.geminiProvider.installHooks()
            }
        }
        if showsAnyHook {
            Divider()
        }
    }

    private var showsAnyHook: Bool {
        !aiService.claudeProvider.isHookInstalled || !aiService.geminiProvider.isHookInstalled
    }
}
```

(Behavior change vs. current: once a hook is installed it disappears entirely from the menu, instead of showing "✓ Installed". Spec section 2 confirms this is desired.)

- [ ] **Step 2: Create AppSection**

```swift
// NemoNotch/Notch/MenuBar/AppSection.swift
import SwiftUI

struct AppSection: View {
    let onOpenSettings: () -> Void

    var body: some View {
        Button("menu.preferences") {
            onOpenSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("menu.about") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }

        Button("menu.quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/MenuBar/HooksSection.swift NemoNotch/Notch/MenuBar/AppSection.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(menubar): extract HooksSection + AppSection

Splits the hook-install buttons and Preferences/About/Quit triple into
focused sub-views in preparation for MenuContent recomposition.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Recompose MenuContent + drop obsolete keys

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift:30-75` (rewrite `MenuContent`)
- Modify: `NemoNotch/Resources/Localizable.xcstrings` (remove obsolete keys)

- [ ] **Step 1: Rewrite MenuContent**

In `NemoNotch/NemoNotchApp.swift`, replace the entire `struct MenuContent: View { ... }` (lines 30-75) with:

```swift
struct MenuContent: View {
    @Environment(AICLIMonitorService.self) var aiService
    let coordinator: NotchCoordinator?
    let appSettings: AppSettings?
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            NowPlayingSection()
            OpenNotchSubmenu(coordinator: coordinator, appSettings: appSettings)
            Divider()
            HooksSection()
            AppSection(onOpenSettings: onOpenSettings)
        }
        .environment(\.locale, appSettings?.currentLocale ?? Locale.current)
    }
}
```

- [ ] **Step 2: Remove obsolete localization keys**

In `NemoNotch/Resources/Localizable.xcstrings`, delete these keys:
- `menu.open_notch`
- `menu.claude_hooks_installed`
- `menu.gemini_hooks_installed`

(The remaining hook keys `menu.install_claude_hooks` / `menu.install_gemini_hooks` stay — they're still used by `HooksSection`.)

- [ ] **Step 3: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. If the build fails with "unused" or "missing key" warnings, that's the xcstrings linter — verify the listed keys are actually unused via grep before fixing.

- [ ] **Step 4: Smoke test — full menu**

Run the app. Open the menubar menu and verify:
- **No** "Open Notch" top-level item (deleted)
- "Open Notch" **submenu** present; hover it, see all enabled tabs; click "Overview" → notch opens to Overview
- Each tab in the submenu shows its current hotkey hint (e.g. `Overview  ⌥⌘1`)
- With music paused: no Now Playing section
- Start music: refresh the menu (close and reopen), Now Playing section appears with song title; Prev/PlayPause/Next buttons work
- With both hooks installed: no install buttons visible, no divider above Preferences
- Uninstall one hook (`rm ~/.claude/settings.json`-ish, or relevant Gemini equivalent), reopen menu: that install button reappears
- Preferences (`⌘,`) opens Settings window; Quit (`⌘Q`) terminates the app

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift NemoNotch/Resources/Localizable.xcstrings
git commit -m "$(cat <<'EOF'
feat(menubar): recompose menu with NowPlaying + Open Notch submenu

Drops the redundant top-level Open Notch item, replaces it with a
submenu of enabled tabs. Adds Now Playing controls when media is active.
Removes three now-unused localization keys.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Documentation updates

**Files:**
- Modify: `README.md`
- Modify: `README_CN.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update README.md**

Find the menubar / features section. Edit to mention:
- Dynamic state-driven menubar icon (AI approval / agent / AI work / media / idle)
- Now Playing controls in the menubar menu
- Open Notch submenu for direct tab access
- All global hotkeys are user-customizable in Preferences → Hotkeys

If a "Tech Stack" or "Dependencies" section exists, add `KeyboardShortcuts` to it.

- [ ] **Step 2: Update README_CN.md**

Mirror the README.md changes in Simplified Chinese.

- [ ] **Step 3: Update CLAUDE.md**

In the **Tech Stack** section (currently line ~12 of CLAUDE.md), add `KeyboardShortcuts` to the dependency list:

From:
```
- Swift 6 + SwiftUI, macOS only, depends on CocoaLumberjack
```

To:
```
- Swift 6 + SwiftUI, macOS only, depends on CocoaLumberjack, KeyboardShortcuts
```

In the **Reference Projects** table or a relevant architecture note, mention that hotkeys are managed by `Hotkeys.swift` (KeyboardShortcuts `Name` definitions) and registered in `AppDelegate.setupHotkeys`. Remove any prior reference to `HotkeyService`.

In the **macOS Cookbook** anchor list (section 6 "Event capture & hotkeys"), the upstream `docs/macos-cookbook.md` should be updated separately — add a note in CLAUDE.md if the cookbook section is invalidated by this change.

- [ ] **Step 4: Commit**

```bash
git add README.md README_CN.md CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: reflect menubar redesign

Updates README + CLAUDE.md for: state-driven menubar icon, new menu
items (Now Playing, Open Notch submenu), KeyboardShortcuts dependency,
user-customizable hotkeys via the new Settings tab.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Merge to develop

**Files:**
- None (git-only)

- [ ] **Step 1: Final full smoke test on the feature branch**

Run the app one more time and confirm:
- Icon cycles through all five states (idle / media / AI working / AI approval / agent)
- Menu shows correct content + hotkey hints
- Preferences → Hotkeys: each Recorder works, defaults are correct
- After rebinding, the new hotkey works, the menu hint updates the next time the menu is opened

- [ ] **Step 2: Merge**

```bash
git checkout develop
git merge --no-ff feature/menubar-redesign
```

Use the default merge commit message or a brief summary.

- [ ] **Step 3: Verify clean**

```bash
git status
```
Expected: `On branch develop`, clean working tree (other than the pre-existing `BadgeItem.swift` mod if it hasn't been committed elsewhere).

- [ ] **Step 4: Delete feature branch (optional)**

```bash
git branch -d feature/menubar-redesign
```

Do not push to origin unless the user explicitly asks.

---

## Spec Coverage Self-Review

| Spec Section | Tasks |
|---|---|
| §1 Icon priority + sources + MenuBarLabel View | Tasks 5, 6 |
| §2 Menu structure: Now Playing, Open Notch submenu, hide installed hooks, ⌘, / ⌘Q on Prefs/Quit | Tasks 7, 8, 9, 10 |
| §2 Component breakdown (4 sub-views) | Tasks 5, 7, 8, 9, 10 |
| §2 Localization adds/removes | Tasks 4, 7, 8, 10 |
| §3 SPM dependency | Task 1 |
| §3 Hotkeys.swift Names + Tab extension | Task 2 |
| §3 Delete HotkeyService, replace registration | Task 3 |
| §3 HotkeysSettingsView + SettingsView wiring | Task 4 |
| §3 Menu shortcut hints | Task 8 (`menuLabel(for:)`) |
| §3 Migration notes (defaults preserved) | Tasks 2, 3 (smoke step) |
| Project convention: README / CLAUDE.md update | Task 11 |
| Project convention: Git Flow feature branch | Tasks 0, 12 |
