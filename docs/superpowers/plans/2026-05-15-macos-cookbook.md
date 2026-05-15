# macOS Cookbook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce `docs/macos-cookbook.md` — a single English, subsystem-organized, `file:line`-anchored reference for every macOS technique used in this codebase, plus a 4-line addition to `CLAUDE.md` pointing to it. Final size target: 1500-2200 lines.

**Architecture:** One markdown file with 19 sections, written by appending one section per task (Section 2 inserted at position 2 in the final pass since it cross-references all deep sections). Each section follows the convention from the spec: 1-sentence "what / why" → `file_path:line_range  function_name` anchor → 5-15 line code skeleton copied verbatim from source with `// …` ellipsis for trimmed branches → `**Gotcha:**` callouts where applicable → cross-links via `[§N]` markers. No intermediate commits; one final commit on `develop` bundles the cookbook + CLAUDE.md edit (per spec acceptance criterion #5 and `[[feedback_git-workflow]]`).

**Tech Stack:** Markdown only. Verification uses `grep`, `sed`, `wc`, and `swift -frontend -parse` (already on the user's machine because the project builds) to confirm code skeletons are syntactically real Swift, not paraphrased.

**Source-of-truth for file paths:** Repo root is `/Users/gaozimeng/Learn/macOS/NemoNotch`. All Swift files live under `NemoNotch/` (e.g. `NemoNotch/Services/MediaRemote.swift`). Use this prefix consistently in every anchor.

**Source-of-truth for evidence:** The brainstorming session's scout-agent reports already mapped ~50 techniques to `file:line` ranges; those ranges are the starting point for each task but **must be re-verified by reading the file before writing** — scout reports drift. The convention `Open → Verify → Copy → Write` appears in every section task below.

---

## Task 1: Create cookbook file + Section 1 (How to use)

**Files:**
- Create: `docs/macos-cookbook.md`

**Why this task is small:** Section 1 has no source-code citations — it's just doc conventions. Sets up the file structure for all subsequent tasks.

- [ ] **Step 1: Create the file with header, table of contents, and Section 1.**

Write `docs/macos-cookbook.md` with this content:

````markdown
# macOS Cookbook — NemoNotch

> A reference map of every macOS technique used in this codebase. Optimized for AI grep, not human prose. Each technique includes a `file:line` anchor + minimal real-code skeleton + gotcha.

## Table of Contents

1. [How to use this doc](#1-how-to-use-this-doc)
2. [Critical pitfalls (read first)](#2-critical-pitfalls-read-first)
3. [Build & release configuration](#3-build--release-configuration)
4. [Private API loading](#4-private-api-loading)
5. [Notch & window management](#5-notch--window-management)
6. [Event capture & hotkeys](#6-event-capture--hotkeys)
7. [Media subsystem](#7-media-subsystem)
8. [System sensing](#8-system-sensing)
9. [ScriptingBridge & AppleScript](#9-scriptingbridge--applescript)
10. [Accessibility & Dock badges](#10-accessibility--dock-badges)
11. [Permissions playbook](#11-permissions-playbook)
12. [IPC & subprocess](#12-ipc--subprocess)
13. [Hook installers](#13-hook-installers)
14. [Keychain](#14-keychain)
15. [Swift 6 concurrency conventions](#15-swift-6-concurrency-conventions)
16. [SwiftUI patterns in this codebase](#16-swiftui-patterns-in-this-codebase)
17. [Architecture patterns](#17-architecture-patterns)
18. [Logging conventions](#18-logging-conventions)
19. [Reference-projects index](#19-reference-projects-index)

---

## 1. How to use this doc

**Audience:** AI collaborators (Claude Code, Cursor, etc.) and the human author returning after time away.

**Search strategy for AI:**
1. Map your task to a subsystem (e.g. "add a hotkey" → §6, "read system memory" → §8).
2. Jump to that section heading.
3. Use the `file_path:line_range  function_name` anchor under each technique to read the real implementation.
4. Trust the **Gotcha:** lines — they encode bugs we already paid for.

**Citation convention:** Every technique line has the shape
```
**Technique name** — `NemoNotch/Path/File.swift:LINE_START-LINE_END  funcName()`
```
The function name is part of the anchor so references survive line-number drift.

**Code-skeleton convention:** 5-15 lines, copied verbatim from the source file. Trimmed sections use a `// …` line so the elision is visible. Never silently delete code.

**Cross-references:** `[§N]` points at section N. `[§7 reconcile]` points at the named anchor inside §7.

**When to update this doc:** If you add a new private API call, a new system-framework integration, or a new pattern (e.g. a new `@unchecked Sendable` bridge), add a technique entry in the same commit. If you move or rename a function this doc references, update the anchor in the same commit.

**Reference projects:** Many techniques here were learned from other open-source projects sitting next to this one. Section 19 indexes them. The CLAUDE.md "Reference Projects" table is the same data, kept in sync.

---
````

- [ ] **Step 2: Verify file is well-formed.**

Run: `wc -l docs/macos-cookbook.md`
Expected: ~55 lines.

Run: `grep -c "^## " docs/macos-cookbook.md`
Expected: `1` (only Section 1 written so far).

---

## Section task template (read once, applied to Tasks 2-15)

Every section-writing task that follows has the same five steps. The substance — which techniques, which files, which gotchas — differs per task. The steps stay constant:

1. **Re-verify scout anchors.** For each `file:line` cited in the task's technique list, run `sed -n 'X,Yp' NemoNotch/Path.swift` (or use the Read tool) to confirm the lines contain the claimed code. If they don't, search for the function name and update the anchor.
2. **Draft the section locally.** For each technique: write the heading + 1-sentence "what / why" + anchor line + 5-15 line code skeleton copied verbatim (use `// …` for elision) + any `**Gotcha:**` lines + cross-links.
3. **Append to `docs/macos-cookbook.md`** using the Edit tool (find the last line of the previous section and Edit to append; do NOT use Write or you'll truncate the file).
4. **Verify no placeholders sneaked in.** Run: `grep -n "TBD\|TODO\|FIXME\|<placeholder>\|XXX" docs/macos-cookbook.md` — should return nothing.
5. **Verify Swift snippets parse.** For each Swift code block added in this section, save it to a temp file and run `swift -frontend -parse` against it. Snippets that reference symbols defined elsewhere in the codebase will fail at type-check but should *parse* — if `swift -frontend -parse` reports a syntax error, the snippet was paraphrased somewhere; fix it.

```bash
# Verification helper — re-usable across all section tasks
verify_section_added() {
  local section_num="$1"
  local expected_heading="$2"
  grep -q "^## ${section_num}\. ${expected_heading}" docs/macos-cookbook.md \
    && echo "✓ §${section_num} added" \
    || { echo "✗ §${section_num} missing"; exit 1; }
  grep -n "TBD\|TODO\|FIXME\|<placeholder>\|XXX" docs/macos-cookbook.md \
    && { echo "✗ placeholders found"; exit 1; } \
    || echo "✓ no placeholders"
}
```

**No intermediate commits.** Sections accumulate in the working tree; one final commit at Task 17.

---

## Task 2: Section 3 — Build & release configuration

**Files:**
- Modify: `docs/macos-cookbook.md` (append Section 3)
- Reads: `NemoNotch.xcodeproj/project.pbxproj`, `NemoNotch/NemoNotch.entitlements`, `build.sh`, `.github/workflows/release.yml`

**Note:** Section 3 comes before Section 2 in writing order because Section 2 (Critical pitfalls) is written last to cross-link everything.

- [ ] **Step 1: Re-verify anchors and gather evidence.**

```bash
# Confirm INFOPLIST_KEY entries exist in pbxproj
grep "INFOPLIST_KEY_" NemoNotch.xcodeproj/project.pbxproj | sort -u

# Confirm entitlements state (sandbox should be FALSE)
cat NemoNotch/NemoNotch.entitlements

# Confirm build.sh signing approach
grep -n "CODE_SIGN_IDENTITY\|HARDENED_RUNTIME" build.sh

# Confirm GH Actions runner + Xcode version
grep -n "macos\|xcode-select\|MACOSX_DEPLOYMENT" .github/workflows/release.yml
```

- [ ] **Step 2: Draft Section 3 with these techniques.**

Each technique below is a separate `###` sub-heading in the section. For each, write the anchor line + skeleton + gotcha as specified.

- **`INFOPLIST_KEY_*` pattern** — `NemoNotch.xcodeproj/project.pbxproj`. Show the actual `INFOPLIST_KEY_NSAppleEventsUsageDescription` and `INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription` lines (with Chinese strings preserved verbatim — they're real source). **Gotcha:** `GENERATE_INFOPLIST_FILE = YES` means the source `Info.plist` is **ignored**; only `INFOPLIST_KEY_*` in pbxproj ends up in the built `.app`. Verify with `/usr/libexec/PlistBuddy -c "Print" build/.../Info.plist`. Cross-link to [§11].
- **`LSUIElement = YES` for menubar-only app** — pbxproj. **Gotcha:** without this the app shows a Dock icon.
- **Entitlements: sandbox disabled** — `NemoNotch.entitlements`. Show the 5-6 line plist. **Gotcha:** the project intentionally disables sandbox (`com.apple.security.app-sandbox = false`) because the hooks/IPC and private-API usage don't work under sandbox. Enabling sandbox is a multi-week migration.
- **`build.sh` ad-hoc signing** — `build.sh`. 10-line skeleton showing `xcodebuild archive` + `exportArchive` + `hdiutil create UDZO`. **Gotcha:** `CODE_SIGN_IDENTITY="-"` produces an ad-hoc-signed app that Gatekeeper will block; users have to right-click → Open. Official distribution needs Developer ID + notarization, not yet set up.
- **GitHub Actions release workflow** — `.github/workflows/release.yml`. 8-line skeleton showing the macos-15 runner, `xcode-select -s /Applications/Xcode_26.3.app`, `MACOSX_DEPLOYMENT_TARGET=26.2`, `softprops/action-gh-release@v2`. **Gotcha:** Xcode 26.3 must be pinned because Xcode auto-update will break the runner image; `macos-15` ≠ `macos-latest`.

- [ ] **Step 3: Append Section 3 to cookbook.**

Use the Edit tool to insert after the existing `---` divider at end of Section 1. Begin with `## 3. Build & release configuration` heading and a 1-sentence section intro.

- [ ] **Step 4: Run verification.**

```bash
grep -q "^## 3\. Build & release configuration" docs/macos-cookbook.md && echo "✓ §3 added"
grep -n "TBD\|TODO\|FIXME\|<placeholder>" docs/macos-cookbook.md
wc -l docs/macos-cookbook.md  # should be ~150-200
```

- [ ] **Step 5: Sanity check Swift/bash snippets parse.**

```bash
# bash snippets — manually inspect for `$(...)` errors, unclosed quotes
grep -A 20 '```bash' docs/macos-cookbook.md | head -30
# plist snippets — manually inspect for matching <key>/<value> pairs
```

No commit yet.

---

## Task 3: Section 4 — Private API loading

**Files:**
- Modify: `docs/macos-cookbook.md` (append Section 4)
- Reads: `NemoNotch/Services/MediaRemote.swift`, `NemoNotch/Services/HUDService.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '38,61p' NemoNotch/Services/MediaRemote.swift   # dlopen + CFBundleGetFunctionPointerForName
sed -n '160,184p' NemoNotch/Services/HUDService.swift  # dlsym DisplayServicesGetBrightness
sed -n '176,240p' NemoNotch/Services/MediaRemote.swift # MRNowPlayingController reflective fallback
```

- [ ] **Step 2: Draft Section 4 with three patterns side-by-side.**

- **Pattern A: `dlopen` + `dlsym` (single symbol)** — `NemoNotch/Services/HUDService.swift:160-184  setupBrightnessMonitor()`. Show ~12-line skeleton: open `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`, `dlsym(handle, "DisplayServicesGetBrightness")`, cast to `@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32`. **Gotcha:** `dlsym` returns `nil` silently if the symbol is missing; check + log.
- **Pattern B: `dlopen` + `CFBundleCreate` + `CFBundleGetFunctionPointerForName` (multiple symbols)** — `NemoNotch/Services/MediaRemote.swift:38-61  initialize()`. Show ~15-line skeleton: build CFURL to framework, `CFBundleCreate`, then a loop of `CFBundleGetFunctionPointerForName` calls, each cast to a `@convention(c)` typealias. List the 6 symbols loaded (`MRMediaRemoteGetNowPlayingInfo`, `MRMediaRemoteSendCommand`, etc.). **Gotcha:** the framework path is `/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote` (no `.dylib` suffix); `dlopen` will succeed even on broken paths, only `CFBundleGetFunctionPointerForName` returns nil.
- **Pattern C: Reflective fallback via `NSClassFromString` + `class_createInstance` + KVC** — `NemoNotch/Services/MediaRemote.swift:176-240  fetchViaController()`. Show ~12-line skeleton: `NSClassFromString("MRNowPlayingController")`, `class_createInstance`, `setValue(forKey: "delegate")`, poll `value(forKey: "playbackQueue")` up to 25× at 100ms. **Gotcha:** macOS 15.4+ only; before 15.4 the class doesn't exist and `NSClassFromString` returns nil — the legacy callback path is mandatory.
- **Common gotcha across all three:** Private APIs can break on every macOS minor release. Log dlerror() and provide a graceful fallback path. State each pattern's OS-version bound up front.

- [ ] **Step 3: Append Section 4 to cookbook.** (Edit tool, append after Section 3)

- [ ] **Step 4: Verify.**

```bash
grep -q "^## 4\. Private API loading" docs/macos-cookbook.md && echo "✓ §4 added"
grep -n "TBD\|TODO\|FIXME" docs/macos-cookbook.md
```

- [ ] **Step 5: Parse Swift snippets.**

Extract each ` ```swift ` block from Section 4, save to `/tmp/section4_snippet_N.swift`, run:
```bash
swift -frontend -parse /tmp/section4_snippet_N.swift 2>&1 | grep -v "use of unresolved\|cannot find" | head
```
Ignore unresolved-symbol errors (they reference codebase types); fail on real syntax errors.

No commit.

---

## Task 4: Section 5 — Notch & window management

**Files:**
- Modify: `docs/macos-cookbook.md` (append Section 5)
- Reads: `NemoNotch/Notch/NotchWindow.swift`, `NemoNotch/Notch/NotchCoordinator.swift`, `NemoNotch/Helpers/ScreenExtensions.swift`, `NemoNotch/Helpers/Constants.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '1,40p' NemoNotch/Notch/NotchWindow.swift            # NSPanel subclass + collectionBehavior
sed -n '28,40p' NemoNotch/Notch/NotchWindow.swift            # PassThroughView hitTest
sed -n '127,160p' NemoNotch/Notch/NotchCoordinator.swift     # per-screen NSHostingController
sed -n '1,50p' NemoNotch/Helpers/ScreenExtensions.swift      # notch geometry helpers
sed -n '80,90p' NemoNotch/Notch/NotchCoordinator.swift       # didChangeScreenParameters observer
```

- [ ] **Step 2: Draft Section 5 with these techniques.**

- **`NSPanel` subclass at `.statusBar + 8`** — `NemoNotch/Notch/NotchWindow.swift:1-26  init()`. Show ~12-line skeleton: `super.init(contentRect:styleMask:[.borderless, .nonactivatingPanel], backing:.buffered, defer:false)`, then `self.level = .init(rawValue: Int(CGWindowLevelForKey(.statusBarWindow)) + 8)`, then transparency flags. **Gotcha:** `.statusBar + 8` puts it above standard menubar UI; `+ 8` is empirical, found by trial.
- **`collectionBehavior` flag set** — same file. One line of code, 4 flags: `.fullScreenAuxiliary`, `.stationary`, `.canJoinAllSpaces`, `.ignoresCycle`. **Gotcha:** without `.stationary` the window drifts during Mission Control; without `.ignoresCycle` it appears in Cmd-Tab.
- **`PassThroughView` hitTest toggle** — `NemoNotch/Notch/NotchWindow.swift:28-36  hitTest(_:)`. ~6-line skeleton. **Gotcha:** must set `isBlocking = true` when opening (intercept clicks) and `= false` when closing (let clicks pass through to the app below). Look at `NotchCoordinator.swift:191, 202` for the toggle points.
- **Per-screen `NSHostingController` + frame offset** — `NemoNotch/Notch/NotchCoordinator.swift:127-155  buildSlot(for:)`. ~14-line skeleton. **Gotcha:** the hosting view's frame must be offset by `screen.frame.origin - window.frame.origin` because the window spans all screens; if you skip this, content lands on the wrong display. Cross-link to `[[2026-05-07-multi-screen-design]]` in `docs/plans/`.
- **NSScreen notch geometry** — `NemoNotch/Helpers/ScreenExtensions.swift:9-48  hasNotch, notchSize, displayID`. Show the `hasNotch = safeAreaInsets.top > 0 && auxiliaryTopLeftArea.width > 0` check and the `notchWidth = frame.width - leftAux.width - rightAux.width` derivation. **Gotcha:** non-notch Macs and external displays return `safeAreaInsets.top == 0`; must fall back to `NotchConstants.defaultNotchWidth/Height`.
- **`CGDisplayIsBuiltin` for built-in detection** — `ScreenExtensions.swift`, displayID computed from `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`. **Gotcha:** HUD only renders on built-in display to avoid flash on external monitors.
- **`didChangeScreenParametersNotification` rebuild** — `NotchCoordinator.swift:81-86, 244-252`. ~8-line skeleton. **Gotcha:** fires on screen plug/unplug; if the active screen disappears, set `activeScreen = nil` and `status = .closed` to avoid dangling references.
- Inline reference-project pointer: *see NotchDrop for the original `NSPanel` subclass pattern; Peninsula for the tri-state machine; DynamicNotchKit for the spring animation choice*.

- [ ] **Steps 3-5:** Append, verify (template), parse Swift snippets.

No commit.

---

## Task 5: Section 6 — Event capture & hotkeys

**Files:**
- Modify: `docs/macos-cookbook.md` (append Section 6)
- Reads: `NemoNotch/Notch/EventMonitor.swift`, `NemoNotch/Services/HotkeyService.swift`, `NemoNotch/NemoNotchApp.swift`, `NemoNotch/Notch/NotchCoordinator.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '17,52p' NemoNotch/Notch/EventMonitor.swift           # global + local NSEvent monitors
sed -n '12,80p' NemoNotch/Services/HotkeyService.swift       # Carbon RegisterEventHotKey
sed -n '238,251p' NemoNotch/NemoNotchApp.swift               # hotkey bindings (Cmd+Opt+N etc.)
sed -n '275,351p' NemoNotch/Notch/NotchCoordinator.swift     # NSMenu.popUp + hitbox math
```

- [ ] **Step 2: Draft Section 6.**

- **Paired global + local NSEvent monitors** — `NemoNotch/Notch/EventMonitor.swift:17-52  start()`. Show ~12 lines: three `addGlobalMonitorForEvents(matching: [.mouseMoved])` calls + three matching `addLocalMonitorForEvents` calls. **Gotcha:** *both* are needed — `Global` fires when your app isn't focused (the normal case for a notch app); `Local` fires when it is, and returns the event (or `nil` to swallow it).
- **`NSEvent.mouseLocation` for hit-testing** — same file. One-line query. **Gotcha:** returns screen coordinates in the "primary screen origin at bottom-left" coordinate system; convert via `screen.frame` math.
- **Hitbox math with hysteresis** — `NotchCoordinator.swift:275-290  handleMouseMoved()`. ~10-line skeleton. **Gotcha:** open-hitbox = notch frame + 10pt padding; close-hitbox = opened-content frame + 20pt inset for hover (closeHitboxInset) or 10pt for click (clickHitboxInset). Different insets prevent accidental dismissal during interaction.
- **Carbon `RegisterEventHotKey` global hotkeys** — `NemoNotch/Services/HotkeyService.swift:12-80  register/installHandler`. Show ~15 lines: `EventHotKeyID(signature: fourCharCode("nemo"), id: ...)`, `RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)`, plus `InstallEventHandler` with an `Unmanaged.passUnretained(self).toOpaque()` userdata for callback dispatch. **Gotcha:** all hotkeys must share the same `FourCharCode` signature; the callback receives a raw `EventHotKeyID` and must look up the action via an internal map. **Gotcha:** `Unmanaged.passUnretained` is the standard bridge — never `passRetained`, you'd leak.
- **Hotkey bindings (Cmd+Opt+N, Cmd+Opt+1-5)** — `NemoNotch/NemoNotchApp.swift:238-251`. ~8-line skeleton. **Gotcha:** Carbon uses ANSI keycodes, not Unicode; keyCode 45 = N, 18..22 = 1..5.
- **Right-click context menu via `NSMenu.popUp`** — `NotchCoordinator.swift:313-351  showContextMenu(at:)`. ~10-line skeleton showing menu items, `popUp(positioning:nil, at:point, in:nil)`, and `ContextMenuDelegate` to clear `isContextMenuVisible` flag on close. **Gotcha:** without the delegate flag, mouse-leave logic fires while the menu is up and closes the notch.
- **`NSHapticFeedbackManager.levelChange`** — `NotchCoordinator.swift:186`. One line: `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)`. **Gotcha:** only fires on hardware with a Force Touch trackpad; silent on others — fine.
- Reference-project pointers: *NotchDrop for global NSEvent monitors; Peninsula for Carbon hotkey registration*.

- [ ] **Steps 3-5:** Append, verify, parse.

No commit.

---

## Task 6: Section 7 — Media subsystem

**Files:**
- Modify: `docs/macos-cookbook.md` (append Section 7 — this will be the **longest** section, ~250 lines)
- Reads: `NemoNotch/Services/NowPlayingCLI.swift`, `NemoNotch/Services/MediaService.swift`, `NemoNotch/Services/MediaRemote.swift`, `NemoNotch/Services/MediaBridge.swift`, `NemoNotch/Services/ScriptingBridge/MusicApplication.swift`, `NemoNotch/Services/ScriptingBridge/SpotifyApplication.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '40,118p' NemoNotch/Services/NowPlayingCLI.swift     # daemon spawn + dylib extraction
sed -n '141,200p' NemoNotch/Services/NowPlayingCLI.swift    # JSON protocol on stdin/stdout
sed -n '253,300p' NemoNotch/Services/NowPlayingCLI.swift    # one-shot fallback with semaphore
sed -n '4,75p' NemoNotch/Services/MediaService.swift        # @MainActor service + reconcile guard
sed -n '56,135p' NemoNotch/Services/MediaService.swift      # togglePlayPause + reconcilePlayState
sed -n '280,310p' NemoNotch/Services/MediaService.swift     # applyInfo respecting the guard
sed -n '40,170p' NemoNotch/Services/MediaRemote.swift       # sendCommand + skip + setElapsedTime
sed -n '22,108p' NemoNotch/Services/MediaBridge.swift       # SBApplication + delegate
sed -n '142,165p' NemoNotch/Services/MediaBridge.swift      # automation permission check
```

- [ ] **Step 2: Draft Section 7 with five sub-sections.**

Use these `###` sub-headings inside Section 7:

#### 7.1 NowPlayingCLI daemon
- **Bundled perl + extracted dylib** — `NowPlayingCLI.swift:40-54`. ~10-line skeleton showing `Bundle.main.url(forResource:withExtension:"pl")`, the dylib gunzip path under `~/Library/Application Support/NemoNotch/MediaRemoteMini.dylib`, and the fallback chain (bundled → system → external). **Gotcha:** the dylib **must** be writable so we can extract it from the gzipped resource on first run; `FileManager.default.fileExists` then `copyItem` if missing.
- **`Process` + `Pipe` daemon spawn** — `NowPlayingCLI.swift:80-118  startDaemon()`. ~14-line skeleton showing `Process()` with `launchPath = "/usr/bin/perl"`, `arguments = [scriptPath, dylibPath]`, stdin/stdout/stderr `Pipe()`. **Gotcha:** retain the `Process` instance — losing the reference kills the daemon. **Gotcha:** `signal(SIGPIPE, SIG_IGN)` at app startup (`NemoNotchApp.swift:26`) is required, otherwise daemon-side pipe closes will crash the parent.
- **Line-delimited JSON protocol** — `NowPlayingCLI.swift:141-169  sendRequest()`. ~12-line skeleton: write JSON to stdin + `\n`, read from stdout until newline, decode. **Gotcha:** single pending completion tracked per daemon — concurrent requests must be serialized via a queue.
- **One-shot fallback with semaphore** — `NowPlayingCLI.swift:253-298  fetchOneShot()`. ~14-line skeleton with `DispatchSemaphore` + `wait(timeout: .now() + 3.5)` + `process.terminate()` on timeout. **Gotcha:** used when the daemon hangs; recreate the daemon afterward.

#### 7.2 MediaRemote private framework
- Already-loaded private framework reference — see [§4 Pattern B].
- **`sendCommand` / `skip(interval:)`** — `MediaRemote.swift:142-174`. ~10-line skeleton showing `SendCommandFn` cast + `["kMRMediaRemoteOptionSkipInterval": interval]` options dict. **Gotcha:** **DON'T** call `sendCommand(.skipForward)` on Spotify or Music — system returns "never supported". Use AppleScript via MediaBridge instead. Cross-link to [§7.3] and [§9].
- **`setElapsedTime` for seek** — same file. **Gotcha:** works for some apps (e.g. Podcasts) but **silently fails** for Music/Spotify; always pair with a MediaBridge fallback.
- **15.4+ `MRNowPlayingController` fallback** — already covered in [§4 Pattern C]; cross-link.

#### 7.3 MediaBridge (ScriptingBridge)
- **`SBApplication(bundleIdentifier:)`** — `MediaBridge.swift:56-62  PlayerHandle.resolve()`. ~8-line skeleton. **Gotcha:** calling `SBApplication.application(withBundleIdentifier:)` *launches* the app if not running. Always guard with `NSRunningApplication.runningApplications(withBundleIdentifier:)` first.
- **`SBApplicationDelegate` for async error capture** — `MediaBridge.swift:24-44  PlayerEventDelegate`. ~12-line skeleton showing `eventDidFail` callback + AE error `-1743` (`errAEEventNotPermitted`) detection + NotificationCenter post. **Gotcha:** this is the only way to detect automation failures asynchronously; without it, `SBApplication` methods silently no-op. **Gotcha:** the delegate is set per-`SBApplication` instance and must be retained (delegate property is `unowned`).
- **`isPlaying` via `playerState` enum** — same file. ~6-line skeleton mapping `kPSP`/`kPSp`/`kPSS`/`kPSF`/`kPSR` (`MusicEPlS` raw values 0x6b505350 etc.) to `Bool`. **Gotcha:** Music has 5 states (adds fastForwarding/rewinding), Spotify has 3.
- **`setPlayerPosition` for seek** — `MediaBridge.swift:103-108`. ~6-line skeleton showing `a.setPlayerPosition?(newPos)` (optional because the generated protocol marks it `optional`). **Gotcha:** AppleScript `set player position` is the **only** way to seek Spotify; MediaRemote refuses. Music accepts both but AppleScript is more reliable.

#### 7.4 Reconcile pattern (optimistic UI + authoritative SB)
- **The pattern at a glance** — flow diagram in prose:
  1. User taps play/pause → `togglePlayPause()` sets `isPlaying = !currentValue` **optimistically** + sets `reconcileExpectedIsPlaying = newValue`.
  2. After 0.5s, `reconcilePlayState()` queries `MediaBridge.isPlaying(bundleID:)` (synchronous via ScriptingBridge), uses **that** as truth.
  3. Meanwhile, `applyInfo()` (called every CLI tick) compares `reconcileExpectedIsPlaying` vs `cliInfo.isPlaying` — if they disagree, **keeps the expected value**; once they agree, clears the guard.
- **Why all three pieces are needed:** CLI is ~0.5s laggy (good for metadata), SB is instant but expensive to poll on every tick, optimistic UI is needed for snappy feel. The guard is the "merge boundary".
- **Code anchors:**
  - `MediaService.swift:9-31  isPlaying + reconcileExpectedIsPlaying` (properties)
  - `MediaService.swift:56-69  togglePlayPause()` (sets optimistic + guard)
  - `MediaService.swift:113-132  reconcilePlayState()` (queries SB authoritative)
  - `MediaService.swift:287-306  applyInfo()` (respects guard)
- **Gotcha:** if `reconcilePlayState` is removed or skipped, the guard never clears → UI gets stuck in optimistic state forever. The 0.5s delay is empirical.

#### 7.5 Media seek decision tree
A 5-row table:
| Player | MediaRemote `skip` | `setElapsedTime` | AppleScript `set player position` | Use |
|---|---|---|---|---|
| Music | ✓ accepts | ✓ accepts | ✓ accepts | AppleScript (most reliable) |
| Spotify | ✗ rejects | ✗ silent fail | ✓ accepts | **AppleScript only** |
| Podcasts | ✓ accepts | ✓ accepts | ✗ no AS verb | MediaRemote |
| Safari/Chrome video | ✓ accepts | partial | ✗ no AS verb | MediaRemote |
| Unknown | try MR first | — | — | MediaRemote with fallback log |

Reference-project pointers: *nowplaying-cli for the dylib extraction + daemon pattern; PlayStatus for MediaRemote private API and media key interception; Tuneful for ScriptingBridge approach*.

- [ ] **Steps 3-5:** Append, verify (template). Section is large — expect line count to jump by ~250.

```bash
wc -l docs/macos-cookbook.md  # expect ~600-700 after Section 7
```

No commit.

---

## Task 7: Section 8 — System sensing

**Files:**
- Modify: `docs/macos-cookbook.md` (append Section 8)
- Reads: `NemoNotch/Services/SystemService.swift`, `NemoNotch/Services/HUDService.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '80,130p' NemoNotch/Services/SystemService.swift    # CPU host_processor_info + vm_deallocate
sed -n '115,135p' NemoNotch/Services/SystemService.swift   # memory host_statistics64
sed -n '225,300p' NemoNotch/Services/SystemService.swift   # libproc proc_listpids etc.
sed -n '160,195p' NemoNotch/Services/SystemService.swift   # network getifaddrs
sed -n '139,155p' NemoNotch/Services/SystemService.swift   # battery IOPSCopyPowerSourcesInfo
sed -n '60,125p' NemoNotch/Services/HUDService.swift       # Core Audio volume listener
sed -n '150,220p' NemoNotch/Services/HUDService.swift      # DisplayServices brightness polling
sed -n '220,250p' NemoNotch/Services/HUDService.swift      # battery IOPSNotificationCreateRunLoopSource
```

- [ ] **Step 2: Draft Section 8 with six sub-sections.**

#### 8.1 CPU (Mach)
- **`host_processor_info`** — `SystemService.swift:80-130`. ~14-line skeleton: declare `processor_info_array_t?`, call `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numProcessors, &cpuInfo, &numCpuInfo)`, iterate `numProcessors`, extract `CPU_STATE_USER/SYSTEM/IDLE/NICE` indices, **then `vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<Int32>.stride))`** to free the buffer. **Gotcha:** if you forget `vm_deallocate`, you leak kernel buffers every tick; the leak is invisible to Instruments' default views.

#### 8.2 Memory (Mach)
- **`host_statistics64(HOST_VM_INFO64)`** — `SystemService.swift:115-135`. ~10-line skeleton. **Gotcha:** the count parameter must be cast from `MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride`; using `MemoryLayout.size` is subtly wrong (off-by-1 on some struct paddings).

#### 8.3 Process enumeration (libproc)
- **`proc_listpids` + `proc_pidinfo` + `proc_pidpath`** — `SystemService.swift:225-300`. ~16-line skeleton: `proc_listpids(PROC_ALL_PIDS, 0, nil, 0)` first to get buffer size, allocate, call again with buffer, then per-PID `proc_pidinfo(pid, PROC_PIDTASKINFO, ...)` for `pti_total_user/system` ticks and `pti_resident_size`. **Gotcha:** `proc_pidinfo` returns 0 on permission denied (not all PIDs are readable); never assume success.

#### 8.4 Battery (IOPS)
- **Polling path** — `SystemService.swift:139-155`. ~10-line skeleton: `IOPSCopyPowerSourcesInfo` → `IOPSCopyPowerSourcesList` → `IOPSGetPowerSourceDescription` → read `kIOPSCurrentCapacityKey`, `kIOPSIsChargingKey`, `kIOPSTimeToEmptyKey`. **Gotcha:** all three values are `CFTypeRef`; cast carefully.
- **Notification runloop source** — `HUDService.swift:220-250  setupBatteryMonitor()`. ~12-line skeleton: `IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(self).toOpaque())`, `CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)`. **Gotcha:** the callback runs on the runloop where you added the source — manually `DispatchQueue.main.async` if your `@MainActor` state needs updating.

#### 8.5 Brightness (DisplayServices)
- Already loaded via [§4 Pattern A]; here's how it's *used*.
- **Adaptive polling** — `HUDService.swift:150-220  pollBrightness()`. ~14-line skeleton. **Gotcha:** **no interrupt mechanism exists** — DisplayServices doesn't post a notification. We poll at 1.0s when idle, 0.1s after detecting a change, reset to 1.0s after 2s of stability. Constant polling at 0.1s drains battery.

#### 8.6 Volume (Core Audio)
- **`AudioObjectAddPropertyListenerBlock`** — `HUDService.swift:60-125  setupVolumeMonitor()`. ~16-line skeleton showing two paths: (a) `AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, ...)` for the system-wide property, (b) per-device fallback via `kAudioDevicePropertyVolumeScalar`. **Gotcha:** when the default output device changes (e.g. AirPods connect), the listener attached to the old device stops firing — must observe `kAudioHardwarePropertyDefaultOutputDevice` and rebind. Code at lines 90-110.

#### 8.7 Network counters (BSD)
- **`getifaddrs` walk** — `SystemService.swift:160-195`. ~12-line skeleton: `getifaddrs(&ifaddrs)`, loop linked list, filter `AF_LINK`, cast `ifa_data` to `if_data*`, sum `ifi_ibytes` / `ifi_obytes`. **Always** `freeifaddrs(ifaddrs)` afterward. **Gotcha:** counters are cumulative since boot; compute delta per-tick yourself.

Reference-project pointers: *eul for `host_processor_info` / `host_statistics64` reference; MonitorControl for `DisplayServicesGetBrightness` discovery*.

- [ ] **Steps 3-5:** Append, verify, parse.

```bash
wc -l docs/macos-cookbook.md  # expect ~800-900 after Section 8
```

No commit. **Decision point:** if cookbook is on track to exceed 2500 lines by end, split Section 8 to `docs/macos-cookbook/system-sensing.md` and replace this section with a one-paragraph pointer. Decide at end of Task 13.

---

## Task 8: Section 9 — ScriptingBridge & AppleScript

**Files:**
- Modify: `docs/macos-cookbook.md`
- Reads: `NemoNotch/Services/ScriptingBridge/MusicApplication.swift`, `NemoNotch/Services/ScriptingBridge/SpotifyApplication.swift`, `NemoNotch/Services/MediaBridge.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '1,60p' NemoNotch/Services/ScriptingBridge/MusicApplication.swift
sed -n '1,60p' NemoNotch/Services/ScriptingBridge/SpotifyApplication.swift
sed -n '22-44p' NemoNotch/Services/MediaBridge.swift
```

- [ ] **Step 2: Draft Section 9.**

- **How generated headers were produced** — the `MusicApplication.swift` and `SpotifyApplication.swift` files were generated from `sdef Music.app | sdp -fh --basename MusicApplication` then ported to Swift protocols. **Gotcha:** Apple no longer ships these for every app; some need hand-porting. Cite the gist comments at top of each file if present.
- **Protocol structure** — `MusicApplication.swift:1-60`. ~14-line skeleton showing the `@objc protocol MusicApplication` with `playpause()`, `nextTrack()`, `previousTrack()`, `setPlayerPosition(_:)` (optional), and the `MusicEPlS` raw enum with `kPSS = 0x6b505350`. **Gotcha:** AE keyword codes are 4-byte big-endian ASCII (`'kPSP'` = `0x6b505350` = "kPSP" = playing); look them up via `string -e -a /System/Library/CoreServices/...` if you need to add new ones.
- **`SBApplication(bundleIdentifier:)` resolution** — [§7.3 cross-link]. Don't duplicate, just reference.
- **`SBApplicationDelegate` for async error capture** — [§7.3 cross-link].
- **AE error -1743 detection** — [§7.3 cross-link]. Repeat the **Gotcha:** here because it's load-bearing for permissions [§11].
- **When AppleScript wins over MediaRemote** — decision table from [§7.5 cross-link]; one-sentence rule: "If the app implements an AppleScript verb (sdef), use AppleScript via SB; only fall back to MediaRemote if the verb is missing."
- **Why not `osascript` subprocess?** Brief comparison: SB has compile-time type checking via generated headers; `osascript` is opaque string runtime. SB is also faster (no fork/exec). The codebase doesn't use `osascript` anywhere — confirm by `grep -r osascript NemoNotch/`.

- [ ] **Steps 3-5:** Append, verify, parse.

No commit.

---

## Task 9: Section 10 — Accessibility & Dock badges

**Files:**
- Modify: `docs/macos-cookbook.md`
- Reads: `NemoNotch/Services/NotificationService.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '14,200p' NemoNotch/Services/NotificationService.swift | head -100
sed -n '95,150p' NemoNotch/Services/NotificationService.swift   # AXUIElementCreateApplication
sed -n '130,200p' NemoNotch/Services/NotificationService.swift  # attribute walk + normalization
```

- [ ] **Step 2: Draft Section 10.**

- **`AXIsProcessTrusted` gate** — `NotificationService.swift:14, 84`. ~6-line skeleton showing the check + early return when not trusted, plus `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` for the one-time prompt. **Gotcha:** the prompt only appears **once per app version**; subsequent denials must be recovered manually via System Settings → Privacy & Security → Accessibility.
- **`AXUIElementCreateApplication(dockPID)`** — `NotificationService.swift:100-102`. ~5-line skeleton including how Dock's PID is found (`NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier`). **Gotcha:** Dock may briefly have no PID during respawns; handle nil.
- **Recursive `AXChildren` walk** — `NotificationService.swift:187-200`. ~14-line skeleton: `AXUIElementGetAttributeValueCount(elem, kAXChildrenAttribute as CFString, &count)`, then `AXUIElementCopyAttributeValues(elem, kAXChildrenAttribute as CFString, 0, count, &values)`, recurse into each child. **Gotcha:** `AXUIElementCopyAttributeValues` returns `kAXErrorNoValue` for empty branches — bail early.
- **`kAXTitleAttribute` and `"AXStatusLabel"` for badge text** — `NotificationService.swift:131, 137`. ~6-line skeleton: read `kAXTitleAttribute` to find the dock tile matching a bundle ID, then `AXUIElementCopyAttributeValue(elem, "AXStatusLabel" as CFString, &value)` for the badge string. **Gotcha:** `"AXStatusLabel"` is not in the public enum — pass it as a literal string. It returns nil for tiles without badges.
- **Unicode LRM normalization** — `NotificationService.swift:131-140`. ~8-line skeleton showing `string.replacingOccurrences(of: "\u{200E}", with: "")` and `"\u{200F}"`, and a unicodeScalars filter for general category `Cf` (Format). **Gotcha:** WhatsApp's app name in the Dock contains a hidden Left-to-Right Mark (`U+200E`) — string equality fails without normalization. Some Chinese-locale apps also embed `\u{FEFF}` (ZWNBSP).

Reference-project pointers: *DockDoor for SCWindow + Dock interaction patterns*.

- [ ] **Steps 3-5:** Append, verify, parse.

No commit.

---

## Task 10: Section 11 — Permissions playbook

**Files:**
- Modify: `docs/macos-cookbook.md`
- Reads: `NemoNotch/Services/CalendarService.swift`, `NemoNotch/Services/MediaBridge.swift`, `NemoNotch/Services/NotificationService.swift`, `NemoNotch.xcodeproj/project.pbxproj`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '34,60p' NemoNotch/Services/CalendarService.swift   # authorizationStatus + requestFullAccessToEvents
sed -n '24,44p' NemoNotch/Services/MediaBridge.swift       # AE error -1743
grep -n "INFOPLIST_KEY_NS" NemoNotch.xcodeproj/project.pbxproj | head
```

- [ ] **Step 2: Draft Section 11 with four sub-sections.**

#### 11.1 Calendar (EventKit)
- **Request flow** — `CalendarService.swift:34-60  requestAccess()`. ~10-line skeleton: `EKEventStore.authorizationStatus(for: .event)` → switch on `.notDetermined` → `await eventStore.requestFullAccessToEvents()` → switch on result. **Gotcha:** macOS 14+ uses `.fullAccess`/`.writeOnly`/`.denied` enum cases; older code using `.authorized` deprecated.
- **`EKEventStoreChanged` re-sync** — `CalendarService.swift:37-42`. ~6-line skeleton observing `NSNotification.Name.EKEventStoreChanged`. **Gotcha:** fires on any change anywhere — including iCloud-pushed edits while user is in Calendar.app. Debounce.
- **Required Info.plist key:** `INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription` — see [§3].

#### 11.2 Apple Events / Automation
- **Required Info.plist key:** `INFOPLIST_KEY_NSAppleEventsUsageDescription`. **Gotcha** (the big one): **without this key, macOS silently refuses to show the automation prompt**. System Settings → Privacy & Security → Automation will not even list your app. The first time we hit this it took a full day of debugging because the failure mode is invisible. Verify with `/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" build/.../Info.plist`.
- **Detect denial post-call** — `MediaBridge.swift:24-44`. Cross-link to [§7.3] but repeat the `errAEEventNotPermitted = -1743` constant here.
- **Recovery** — direct user to *System Settings → Privacy & Security → Automation → [Your app] → enable [Target app]*. Code in `MediaBridge.swift:159` shows the trigger path. The exact `x-apple.systempreferences:` URL (if used) is in the source; cite that line.

#### 11.3 Accessibility
- **`AXIsProcessTrusted` + prompt option** — see [§10]. Cross-link.
- **Recovery** — run `grep -n "x-apple.systempreferences\|Privacy_Accessibility" NemoNotch/` first. If the codebase already opens a settings URL, cite that line + URL verbatim. Otherwise, document the recovery as a manual instruction: *System Settings → Privacy & Security → Accessibility → enable NemoNotch* (no URL claim).
- **Gotcha:** quitting and relaunching after granting is required — granted state isn't picked up by a running process. Either poll `AXIsProcessTrusted` every few seconds, or instruct the user to relaunch.

#### 11.4 Notifications
- **`UNUserNotificationCenter.current().requestAuthorization`** — if not used yet, note that and explain the standard pattern in 4 lines. **Gotcha:** options must be requested up-front — adding `.sound` later requires a fresh request and re-prompt.

#### Cross-cutting summary table
| Permission | Info.plist key | Async request API | Recovery URL pattern |
|---|---|---|---|
| Calendar | NSCalendarsFullAccessUsageDescription | EKEventStore.requestFullAccessToEvents | …Privacy_Calendars |
| Automation | NSAppleEventsUsageDescription | (none — first SB call triggers) | …Privacy_Automation |
| Accessibility | (no key needed) | AXIsProcessTrustedWithOptions | …Privacy_Accessibility |
| Notifications | (no key needed) | UNUserNotificationCenter.requestAuthorization | …Privacy_Notifications |

- [ ] **Steps 3-5:** Append, verify, parse.

No commit.

---

## Task 11: Section 12 — IPC & subprocess

**Files:**
- Modify: `docs/macos-cookbook.md`
- Reads: `NemoNotch/Services/HookServer.swift`, `NemoNotch/Services/AgentFileWatcher.swift`, `NemoNotch/Services/ConversationParser.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '16,90p' NemoNotch/Services/HookServer.swift       # socket setup
sed -n '84,165p' NemoNotch/Services/HookServer.swift      # accept + readRequest + responseWaiters
sed -n '74,164p' NemoNotch/Services/AgentFileWatcher.swift  # DispatchSourceFileSystemObject + incremental parse
sed -n '46,99p' NemoNotch/Services/ConversationParser.swift  # parseIncremental
```

- [ ] **Step 2: Draft Section 12 with three sub-sections.**

#### 12.1 Unix-socket server
- **Socket setup** — `HookServer.swift:16-70  setup()`. ~16-line skeleton: `socket(AF_UNIX, SOCK_STREAM, 0)`, `unlink(NotchConstants.hookSocketPath)` (clear stale), populate `sockaddr_un` with `sun_path` (be careful with the buffer size!), `bind`, `listen(2)`, set `SO_REUSEADDR`. **Gotcha:** `sockaddr_un.sun_path` is a fixed-size 104-byte buffer; path must fit. Use `/tmp/com.nemonotch.hook`, not a long path in `~/Library/...`.
- **`DispatchSourceRead` accept loop** — `HookServer.swift:51-67`. ~10-line skeleton: `DispatchSource.makeReadSource(fileDescriptor: socketFd, queue: socketQueue)`, handler accepts → spawns nested read source. **Gotcha:** `socketFd` and `acceptSource` are stored as `nonisolated(unsafe)` because they're accessed from `socketQueue`, not MainActor. Re-dispatch back to MainActor on every event via `DispatchQueue.main.async { Task { @MainActor in ... } }`.
- **Line-delimited JSON read** — `HookServer.swift:84-137  readRequest()`. ~12-line skeleton: read 4KB into buffer, scan for newline, JSON-decode `HookEvent`, dispatch. **Gotcha:** partial messages straddling buffer boundaries need accumulation; the codebase reads until newline-or-EOF in a loop.
- **Permission-request waiter pattern** — `HookServer.swift:139-165`. ~10-line skeleton: `responseWaiters[sessionId:toolUseId] = continuation`, 120s `Task.sleep` timeout, on timeout resolve as denial. **Gotcha:** continuation must be resolved exactly once — guard with a `Set<String>` of completed IDs.

#### 12.2 Subprocess (Process + Pipe)
- See [§7.1 NowPlayingCLI] for the canonical example. Cross-link rather than duplicate.

#### 12.3 File-watching for incremental parse
- **`DispatchSourceFileSystemObject`** — `AgentFileWatcher.swift:74-114  startWatching()`. ~14-line skeleton: `open(path, O_EVTONLY)`, `DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd, eventMask:[.write, .extend], queue:queue)`. **Gotcha:** `O_EVTONLY` won't keep the file open against unlink; if the file is replaced, you'll miss events — re-open on `.delete`.
- **Incremental offset + `pendingTail`** — `AgentFileWatcher.swift:77-107  processNewBytes()`. ~12-line skeleton: seek to `readOffset`, read appended bytes, split on `\n`, last fragment goes into `pendingTail` for next round. **Gotcha:** if the file is *truncated or replaced* (e.g. log rotation), `readOffset` is stale; check `fileSize < readOffset` and reset.
- **JSONL extraction** — `ConversationParser.swift:46-99  parseIncremental()`. ~12-line skeleton. **Gotcha:** Claude JSONL distinguishes `assistant` from `user` events; only `assistant` has the `usage` block with token counts. `cache_read_input_tokens` and `cache_creation_input_tokens` are optional — default to 0.

- [ ] **Steps 3-5:** Append, verify, parse.

No commit.

---

## Task 12: Section 13 — Hook installers

**Files:**
- Modify: `docs/macos-cookbook.md`
- Reads: `NemoNotch/Services/HookInstaller.swift`, `NemoNotch/Services/HermesHookInstaller.swift`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '7,12p' NemoNotch/Services/HookInstaller.swift     # settingsPath per target
sed -n '54,94p' NemoNotch/Services/HookInstaller.swift    # install() flow
sed -n '139,197p' NemoNotch/Services/HookInstaller.swift  # script writer
sed -n '3,67p' NemoNotch/Services/HermesHookInstaller.swift
```

- [ ] **Step 2: Draft Section 13.**

- **Idempotent install pattern (the load-bearing idea)** — pseudocode:
  ```
  read existing JSON/YAML config
  for each event-array in config:
      remove all entries whose command path is under ~/.nemonotch/hooks/
  for each currently-enabled event in our settings:
      append a fresh entry
  write back
  ```
  **Gotcha:** the "remove all nemonotch entries first" step is what makes re-install safe across versions. If you only append, every install duplicates.

- **Claude target** — `HookInstaller.swift:54-94  install()`, with `settingsPath = ~/.claude/settings.json`. ~14-line skeleton showing `JSONSerialization.jsonObject` read, mutation, `.prettyPrinted` write.
- **Gemini target** — same function, `target = .gemini`, path `~/.gemini/settings.json`. Different event names (`onToolStart` etc.).
- **Hermes target** — `HermesHookInstaller.swift:3-67`. **Different config format (YAML)**, plus a multi-profile scan: `~/.hermes/config.yaml` + `~/.hermes/profiles/*/config.yaml`. ~14-line skeleton showing the profile enumeration. **Gotcha:** isInstalled check is currently a string `contains("nemonotch/hooks/hermes-hook-sender.sh")` — fragile if you rename the script.

- **Sender script generation** — `HookInstaller.swift:139-197  writeHookScript()`. ~14-line skeleton showing `try script.write(to: ~/.nemonotch/hooks/hook-sender.sh, atomically: true)` then `FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath:)`. **Gotcha:** the script reads `CLI_SOURCE` from env first, then argv — needed because Claude Code and Gemini pass it differently.

Reference-project pointers: *masko-code for the Unix Socket event delivery + HookInstaller writing to `~/.claude/settings.json` originator pattern*.

- [ ] **Steps 3-5:** Append, verify, parse.

No commit.

---

## Task 13: Sections 14, 18, 19 — Keychain + Logging + Reference index (grouped)

These three sections are short (~30-60 lines each); grouping them into one task keeps the plan from inflating.

**Files:**
- Modify: `docs/macos-cookbook.md`
- Reads: `NemoNotch/Services/OpenClawService.swift`, `NemoNotch/Services/LogService.swift`, `CLAUDE.md`

- [ ] **Step 1: Re-verify anchors.**

```bash
sed -n '77,108p' NemoNotch/Services/OpenClawService.swift   # SecItemCopyMatching + SecItemAdd
sed -n '1,55p' NemoNotch/Services/LogService.swift          # DDFileLogger setup
grep -A 100 "## Reference Projects" CLAUDE.md | head -120
```

- [ ] **Step 2: Draft Section 14 (Keychain).**

- **`SecItemCopyMatching` load** — `OpenClawService.swift:77-89  loadOrGenerateKey()`. ~10-line skeleton: build query dict with `kSecClass: kSecClassGenericPassword`, `kSecAttrService: "com.nemonotch.openclaw"`, `kSecReturnData: true`, call `SecItemCopyMatching`. **Gotcha:** returns `errSecItemNotFound` (`-25300`) when missing — that's the "generate new" trigger, not a real error.
- **`SecItemAdd` save** — `OpenClawService.swift:99-108`. ~8-line skeleton. **Gotcha:** include `kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked` (the default is more permissive than you want for a long-lived identity key).

- [ ] **Step 3: Draft Section 18 (Logging conventions).**

- **CocoaLumberjack `DDFileLogger`** — `LogService.swift:3-28  init()`. ~10-line skeleton: `DDFileLogger()`, `rollingFrequency = 86400` (daily), `logFileManager.maximumNumberOfLogFiles = 7`, `DDLog.add(fileLogger)`. Default log path: `~/.NemoNotch/logs/`. **Gotcha:** path is in user home, not `~/Library/Logs/` (which would be the macOS convention) — intentional, makes logs easy to `tail` and ship.
- **Static API** — `LogService.swift:36-50  debug/info/warn/error`. ~6-line skeleton showing the static `nonisolated` methods with category param. **Gotcha:** uses `nonisolated(unsafe) static let shared` for the singleton — DDLog is thread-safe internally so this is OK.
- **Log levels** — `LogService.swift:23-27`. DEBUG builds: `.all`. Release: `.info`. **Gotcha:** `.debug` and below are stripped in release; don't put load-bearing logic in a `.debug` call's argument expression (the expression still evaluates).
- **Category naming** — module name (e.g. `"MediaService"`, `"HookServer"`, `"NotchCoordinator"`). Used for filtering in log search.

- [ ] **Step 4: Draft Section 19 (Reference-projects index).**

Copy the "Reference Projects" table from CLAUDE.md into Section 19, **as-is**. Add a header note: "Mirror of CLAUDE.md's Reference Projects table — kept here so the cookbook is greppable without opening CLAUDE.md. If you update one, update the other in the same commit." **Gotcha:** every external project mentioned is under `/Users/gaozimeng/Learn/macOS/`.

- [ ] **Step 5: Append all three sections, verify, parse.**

```bash
wc -l docs/macos-cookbook.md  # expect ~1100-1300
```

**Decision point on Section 8 split:** if current line count + estimated remaining (Tasks 14-16: ~300 lines) puts the doc over 2500, return here and split Section 8 out to a separate file. Otherwise continue.

No commit.

---

## Task 14: Sections 15, 16, 17 — Swift 6 + SwiftUI + Architecture (grouped)

**Files:**
- Modify: `docs/macos-cookbook.md`
- Reads: multiple — `NemoNotch/Services/MediaService.swift`, `NemoNotch/Services/HookServer.swift`, `NemoNotch/Services/NowPlayingCLI.swift`, `NemoNotch/Services/LogService.swift`, `NemoNotch/Notch/NotchView.swift`, `NemoNotch/Helpers/ViewModifiers.swift`, `NemoNotch/NemoNotchApp.swift` (AppDelegate)

- [ ] **Step 1: Re-verify anchors.**

```bash
grep -n "@MainActor @Observable\|@unchecked Sendable\|nonisolated(unsafe)" NemoNotch/Services/*.swift | head -30
grep -n "@Environment\|@Observable" NemoNotch/Notch/NotchView.swift | head
git log --oneline --grep="remove-shared"  # confirm refactor commit hashes
```

- [ ] **Step 2: Draft Section 15 (Swift 6 concurrency conventions).**

- **Default service shape:** `@MainActor @Observable final class XService` — applied to all 16 services (list them in a one-line bullet). **Gotcha:** `@Observable` macro requires `final`; without it you get a compile error pointing at the macro expansion, not the class.
- **`@unchecked Sendable` bridge structs** — show two examples:
  - `NowPlayingCLI.swift:438-440  InfoBox`. ~6-line skeleton.
  - `MediaService.swift:4  NowPlayingInfoBox`. ~6-line skeleton.
  **Gotcha:** the wrapped type is `[String: Any]?`, which is NOT Sendable; we mark the wrapper `@unchecked Sendable` because we *only* read it after the queue transition, never share mutation. Misuse leaks data races silently. Document the invariant in a comment on every such wrapper.
- **`nonisolated(unsafe)` for queue-owned state** — `HookServer.swift:7-8`. ~4-line skeleton showing `nonisolated(unsafe) private var socketFd: Int32 = -1`. **Gotcha:** only safe if the state is *only* touched on a specific queue (here, `socketQueue`); `deinit` uses `socketQueue.sync` to drain before releasing.
- **`Task { @MainActor [weak self] in }` re-dispatch** — `MediaService.swift:201` (or similar). ~6-line skeleton. **Gotcha:** when a DispatchSource or NotificationCenter observer is `nonisolated`, you can't just call `self.foo = bar`; wrap the body in `Task { @MainActor in }`.
- **`nonisolated(unsafe) static let shared`** — `LogService.swift:4`. **Gotcha:** appropriate only when the singleton is internally thread-safe (DDLog) — don't use this for `@Observable` services.

- [ ] **Step 3: Draft Section 16 (SwiftUI patterns).**

- **`@Environment` + `@Observable` service injection** — `NotchView.swift:8-15  @Environment(MediaService.self) ...`. ~10-line skeleton listing the 8 services injected. **Gotcha:** services must be set via `.environment(serviceInstance)` on a parent view in `AppDelegate.applicationDidFinishLaunching`. If a service is missing at runtime SwiftUI crashes; protect with optional environment lookups during transitions.
- **`effectiveStatus` per-screen flicker suppression** — `NotchView.swift:36-38`. ~4-line skeleton: `private var effectiveStatus: NotchStatus { isActiveScreen ? coordinator.status : .closed }`. **Gotcha:** without this computed property, secondary displays animate-expand in sync with the primary — visible flash on plug/unplug.
- **Animation pair** — `interactiveSpring(duration: 0.314)` open + `spring(duration: 0.24)` close. **Gotcha:** open uses *interactive* spring so animations don't stack when the user re-hovers mid-animation; close uses regular spring because we want it to finish even if the user moves back.
- **Shared decorators** — `Helpers/ViewModifiers.swift`, `Helpers/ToolStyles.swift`. List 3-4 key modifiers each defines (e.g. `.notchCardStyle()`, `.toolBlockStyle()`). **Gotcha:** these encode the design system — adding new ad-hoc styling in a tab view is a code smell; extend the shared modifier instead.

- [ ] **Step 4: Draft Section 17 (Architecture patterns).**

- **Service ownership in AppDelegate** — `NemoNotchApp.swift  applicationDidFinishLaunching()`. ~12-line skeleton showing services instantiated in order, then `NotchCoordinator` built with a `contentBuilder` closure that captures them. **Gotcha:** order matters — `HotkeyService` depends on `NotchCoordinator`, but the coordinator's `contentBuilder` is captured *by value*, so wire the coordinator first, then attach hotkeys.
- **Closure injection over singletons** — refactor `91dc446 → aff5663` removed `AppDelegate.shared`. Show before/after in a 6-line example: before `AppDelegate.shared.mediaService.toggle()`, after `coordinator.onToggleMedia()` (closure passed at init). **Gotcha:** the refactor took several commits because every consumer had to be reworked; new code should follow this pattern, not regress to a global.
- **Protocol-first multi-provider design** — `Models/AIProvider.swift`, `Models/AIProviderRegistry.swift` (if these exist; verify via `grep -rn "protocol AIProvider"`). One-line summary: `AIProvider` declares only common interface (`messages`, `tokens`, `findSessionFile`); `ClaudeCodeService` and `GeminiProvider` keep their own Result types and parsing logic. Same pattern for `ConversationParser` and `MultiAgentMonitor`. **Gotcha:** don't force provider-specific fields (e.g. Claude's `cache_read_input_tokens`) into the shared protocol — keep them on the concrete type and access via downcast where needed.
- **`LifecycleAware` helper** — `Helpers/LifecycleAware.swift`. ~6-line skeleton.

- [ ] **Step 5: Append all three sections, verify, parse.**

```bash
wc -l docs/macos-cookbook.md  # expect ~1400-1700
```

No commit.

---

## Task 15: Section 2 — Critical pitfalls (read first), inserted at position 2

**Files:**
- Modify: `docs/macos-cookbook.md` — **insert at top, after Section 1's `---` divider**

This task is written last because Section 2's value is in cross-linking the deep sections; those have to exist first.

- [ ] **Step 1: Locate insertion point.**

Find the line `---` that closes Section 1 (between Section 1 and the next `## ` heading). Section 2 inserts immediately after it.

```bash
grep -n "^---$" docs/macos-cookbook.md | head -2
# The first `---` after the TOC is the end of Section 1.
```

- [ ] **Step 2: Draft Section 2 — ~8 pitfalls as one-liner each, each pointing to a deep section.**

````markdown
## 2. Critical pitfalls (read first)

The 8 silent-failure traps in this codebase that cost the most debug time. Each links to the deep section with the recovery.

1. **`Info.plist` keys must use `INFOPLIST_KEY_*` in pbxproj, not the source `Info.plist` file.** The project has `GENERATE_INFOPLIST_FILE = YES`; the source file is ignored at build. → [§3].
2. **Missing `NSAppleEventsUsageDescription` ⇒ silent automation denial.** No dialog. System Settings won't even *list* your app. → [§11.2].
3. **Spotify ignores `MediaRemote` skip/seek commands** — system returns "never supported" with no recovery. Must use AppleScript `set player position` via ScriptingBridge. → [§7.5].
4. **Stale Unix socket at `/tmp/com.nemonotch.hook` ⇒ `bind` fails with EADDRINUSE.** Must `unlink` at startup. → [§12.1].
5. **AE error `-1743` ⇒ automation permission denied.** Detect via `SBApplicationDelegate.eventDidFail`; this is the only async-safe denial signal. → [§7.3], [§11.2].
6. **Dock badge text contains hidden Unicode marks (LRM `U+200E`, ZWNBSP `U+FEFF`).** String equality fails without normalization. WhatsApp ships LRM in its tile name. → [§10].
7. **Multi-screen `NSHostingController.view.frame` must be offset by `screen.frame.origin - window.frame.origin`.** Without this, content renders on the wrong display. → [§5].
8. **Secondary-screen expansion flash:** per-screen views need `effectiveStatus = isActiveScreen ? coordinator.status : .closed`, otherwise all displays animate in sync. → [§16].

If you hit a silent failure not listed here, check **§3 (Build)**, **§4 (Private APIs)**, and **§11 (Permissions)** in that order before assuming it's a real bug — the load-bearing pitfalls cluster there.

---
````

- [ ] **Step 3: Insert via Edit tool.**

Use the Edit tool with `old_string` = the closing `---` of Section 1 (uniqueness check: there's only one `---` between line ~55 and ~60), and `new_string` = same `---` followed by the entire Section 2 block above.

- [ ] **Step 4: Verify section count and ordering.**

```bash
grep -n "^## " docs/macos-cookbook.md
# Expected output (in order):
#   ## Table of Contents     (no number)
#   ## 1. How to use this doc
#   ## 2. Critical pitfalls (read first)
#   ## 3. Build & release configuration
#   ...
#   ## 19. Reference-projects index
```

If the numbering is wrong or Section 2 landed in the wrong place, fix the Edit and re-run.

```bash
wc -l docs/macos-cookbook.md  # expect ~1500-2200 (the target range)
```

If line count is **>2500**, return to Task 7 and split Section 8 to `docs/macos-cookbook/system-sensing.md`, then replace Section 8 in the cookbook with a one-paragraph pointer.

- [ ] **Step 5: No commit yet — one more task.**

---

## Task 16: CLAUDE.md addition — pointer to the cookbook

**Files:**
- Modify: `CLAUDE.md` (add a new section, or extend an existing one)
- Modify: `README.md`, `README_CN.md` if they index the docs/ directory

- [ ] **Step 1: Decide insertion point.**

CLAUDE.md current sections relevant for this addition:
- "Development Conventions" → "Coding Conventions" (mentions docs/plans/ archiving)
- "Reference Projects" (table — already mirrored in cookbook §19)

Insert a new section between "Development Conventions" and "Reference Projects", titled `## macOS Cookbook`. ~10 lines.

- [ ] **Step 2: Write the addition.**

````markdown
## macOS Cookbook

A consolidated reference of every macOS-specific technique used in this codebase lives at `docs/macos-cookbook.md`. Organized by subsystem, anchored to `file:line` in real source. Use it before re-deriving how to do `dlopen`, MediaRemote, Carbon hotkeys, AX, IPC, etc.

**Top-level sections:** 1) How to use · 2) Critical pitfalls · 3) Build & release · 4) Private API loading · 5) Notch & window · 6) Event capture & hotkeys · 7) Media · 8) System sensing · 9) ScriptingBridge & AppleScript · 10) Accessibility & Dock badges · 11) Permissions · 12) IPC & subprocess · 13) Hook installers · 14) Keychain · 15) Swift 6 concurrency · 16) SwiftUI patterns · 17) Architecture · 18) Logging · 19) Reference projects index.

**When to update:** Any commit that adds a new private API call, a new system-framework integration, or a new `@unchecked Sendable` / `nonisolated(unsafe)` boundary must add a matching technique entry in the same commit.
````

- [ ] **Step 3: Verify the insertion.**

```bash
grep -A 5 "^## macOS Cookbook" CLAUDE.md
```

- [ ] **Step 4: Check whether `README.md` / `README_CN.md` need a one-line pointer.**

```bash
grep -n "docs/" README.md README_CN.md | head
```

If the READMEs list `docs/` contents, add one line each pointing to the cookbook. Otherwise skip.

- [ ] **Step 5: No commit yet — final verification in next task.**

---

## Task 17: Final verification + single commit

**Files:**
- All previous changes staged.

- [ ] **Step 1: Full verification pass.**

```bash
# Section count
test "$(grep -c '^## [0-9]' docs/macos-cookbook.md)" = 19 \
  && echo "✓ 19 numbered sections" \
  || { echo "✗ wrong section count"; grep -n '^## ' docs/macos-cookbook.md; exit 1; }

# Placeholder scan
! grep -n 'TBD\|TODO\|FIXME\|<placeholder>\|XXX' docs/macos-cookbook.md \
  && echo "✓ no placeholders" \
  || { echo "✗ placeholders found"; exit 1; }

# Line budget (1500-2200 ideal, 2500 hard ceiling per spec)
LINES=$(wc -l < docs/macos-cookbook.md)
echo "Cookbook: $LINES lines"
test "$LINES" -ge 1500 -a "$LINES" -le 2500 \
  && echo "✓ within budget" \
  || echo "⚠ outside 1500-2500 range; review before commit"

# Anchor sanity — every file:line ref should point to an existing file
grep -oE 'NemoNotch/[A-Za-z/]+\.swift:[0-9]+-[0-9]+' docs/macos-cookbook.md \
  | sort -u \
  | while read ref; do
      file="${ref%:*}"
      test -f "$file" || echo "✗ missing: $ref"
    done
echo "✓ all referenced files exist"

# CLAUDE.md addition present
grep -q "^## macOS Cookbook" CLAUDE.md \
  && echo "✓ CLAUDE.md updated" \
  || { echo "✗ CLAUDE.md missing addition"; exit 1; }

# Gotcha count — spec said ≥15 documented gotchas
GOTCHAS=$(grep -c '\*\*Gotcha:\*\*' docs/macos-cookbook.md)
echo "Gotchas: $GOTCHAS"
test "$GOTCHAS" -ge 15 \
  && echo "✓ ≥15 gotchas" \
  || { echo "✗ too few gotchas"; exit 1; }
```

- [ ] **Step 2: Swift parse sanity on the whole doc.**

```bash
# Extract every swift code block, parse each
python3 - <<'PY'
import re, subprocess, tempfile, os, sys
text = open("docs/macos-cookbook.md").read()
blocks = re.findall(r"```swift\n(.*?)```", text, re.DOTALL)
fails = 0
for i, b in enumerate(blocks):
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
        f.write(b); path = f.name
    r = subprocess.run(["swift", "-frontend", "-parse", path],
                       capture_output=True, text=True)
    # Allow unresolved-identifier errors; only fail on real syntax errors
    if r.returncode and "error: " in r.stderr and "cannot find" not in r.stderr and "unresolved" not in r.stderr:
        print(f"Block #{i} syntax error in:\n{b}\n---\nstderr:\n{r.stderr}")
        fails += 1
    os.unlink(path)
print(f"Parsed {len(blocks)} swift blocks, {fails} real syntax errors")
sys.exit(1 if fails else 0)
PY
```

If any block fails: fix the corresponding section, re-run.

- [ ] **Step 3: Confirm working tree is clean of unrelated changes.**

```bash
git status --short
# Expected:
#  M NemoNotch/Notch/Badge/BadgeItem.swift   (pre-existing, leave alone)
#  M CLAUDE.md
# ?? docs/macos-cookbook.md
# (and maybe M README.md / README_CN.md if updated)
```

Confirm that the pre-existing `BadgeItem.swift` modification is **NOT staged** in our commit.

- [ ] **Step 4: Stage only our files and commit.**

```bash
# Stage only the cookbook + CLAUDE.md (+ READMEs if modified)
git add docs/macos-cookbook.md CLAUDE.md
# Conditionally
if git diff --quiet README.md; then echo "README.md unchanged"; else git add README.md; fi
if git diff --quiet README_CN.md; then echo "README_CN.md unchanged"; else git add README_CN.md; fi

# Verify staged set
git diff --cached --stat
```

- [ ] **Step 5: Commit.**

```bash
git commit -m "$(cat <<'EOF'
docs: add macos-cookbook — file:line-anchored reference for every macOS technique used in this codebase

Subsystem-organized (19 sections) so AI can grep one heading and jump to
real source. Each technique includes a file:line + function-name anchor,
a 5-15 line code skeleton copied verbatim from the source, and explicit
Gotcha callouts for silent-failure traps (Info.plist + GENERATE_INFOPLIST_FILE,
NSAppleEventsUsageDescription, Spotify MR rejection, AE error -1743,
Dock LRM normalization, multi-screen frame offset, etc.). CLAUDE.md gets
a short pointer with the section list so the index stays greppable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git log --oneline -3
```

- [ ] **Step 6: Final smoke test.**

```bash
# Cookbook is in the commit
git show --stat HEAD | grep -E 'docs/macos-cookbook|CLAUDE\.md'

# Pre-existing BadgeItem.swift modification is NOT in the commit
! git show HEAD --name-only | grep -q 'BadgeItem\.swift' \
  && echo "✓ BadgeItem.swift correctly left out" \
  || { echo "✗ accidentally committed BadgeItem.swift"; exit 1; }
```

Done.

---

## Self-review checklist

Plan author (me) ran this against the spec at `docs/superpowers/specs/2026-05-15-macos-cookbook-design.md`:

**Spec coverage:**
- §1 (How to use) → Task 1 ✓
- §2 (Critical pitfalls) → Task 15 ✓ (deferred to last so cross-links exist)
- §3 (Build & release) → Task 2 ✓
- §4 (Private API loading) → Task 3 ✓
- §5 (Notch & window) → Task 4 ✓
- §6 (Event capture & hotkeys) → Task 5 ✓
- §7 (Media subsystem) → Task 6 ✓
- §8 (System sensing) → Task 7 ✓
- §9 (ScriptingBridge & AppleScript) → Task 8 ✓
- §10 (Accessibility & Dock badges) → Task 9 ✓
- §11 (Permissions playbook) → Task 10 ✓
- §12 (IPC & subprocess) → Task 11 ✓
- §13 (Hook installers) → Task 12 ✓
- §14 (Keychain) → Task 13 ✓ (grouped)
- §15 (Swift 6 concurrency) → Task 14 ✓ (grouped)
- §16 (SwiftUI patterns) → Task 14 ✓ (grouped)
- §17 (Architecture patterns) → Task 14 ✓ (grouped)
- §18 (Logging conventions) → Task 13 ✓ (grouped)
- §19 (Reference-projects index) → Task 13 ✓ (grouped)
- Acceptance: 19 sections present → verified in Task 17 ✓
- Acceptance: no placeholders → verified in Task 17 ✓
- Acceptance: ≥15 Gotchas → verified in Task 17 ✓
- Acceptance: CLAUDE.md addition → Task 16 ✓
- Acceptance: single commit on develop → Task 17 ✓
- Acceptance: 1500-2200 line budget + 2500 split trigger → Task 13 (decision point) + Task 17 (verification) ✓

**Placeholder scan:** plan body uses concrete technique names, file paths, line ranges, and gotcha summaries throughout. No "TBD" / "implement later" / "appropriate error handling". `(verify via grep)` calls are concrete instructions, not deferred decisions.

**Type consistency:** all referenced types (`HookEvent`, `PlayerHandle`, `MusicEPlS`, `InfoBox`, `NowPlayingInfoBox`, `PlayerEventDelegate`, `EventHotKeyID`, `NotchStatus`, etc.) are introduced in the task that first cites them. The `effectiveStatus` computed property is named consistently in §5 and §16. `reconcileExpectedIsPlaying` is named consistently across §7.4 and the spec.
