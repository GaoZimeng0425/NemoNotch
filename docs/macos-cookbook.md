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
20. [UI-test screenshot harness (`--uitest`)](#20-ui-test-screenshot-harness---uitest)

---

## 1. How to use this doc

**Audience:** AI collaborators (Claude Code, Cursor, etc.) and the human author returning after time away.

**Search strategy for AI:**
1. Map your task to a subsystem (e.g. "add a hotkey" → §6, "read system memory" → §8).
2. Jump to that section heading.
3. Use the `file_path:line_range  function_name` anchor under each technique to read the real implementation.
4. Trust the **Gotcha:** lines — they encode bugs we already paid for.

**Citation convention:** Every technique line has the shape

    **Technique name** — `NemoNotch/Path/File.swift:LINE_START-LINE_END  funcName()`

The function name is part of the anchor so references survive line-number drift.

**Code-skeleton convention:** 5-15 lines, copied verbatim from the source file. Trimmed sections use a `// …` line so the elision is visible. Never silently delete code.

**Cross-references:** `[§N]` points at section N. `[§7 reconcile]` points at the named anchor inside §7.

**When to update this doc:** If you add a new private API call, a new system-framework integration, or a new pattern (e.g. a new `@unchecked Sendable` bridge), add a technique entry in the same commit. If you move or rename a function this doc references, update the anchor in the same commit.

**Reference projects:** Many techniques here were learned from other open-source projects sitting next to this one. Section 19 indexes them. The CLAUDE.md "Reference Projects" table is the same data, kept in sync.

---

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

## 3. Build & release configuration

How NemoNotch's `.app` and DMG are produced, plus the Info.plist trap that's caused the most lost time.

### `INFOPLIST_KEY_*` pattern

What/why: Info.plist keys (permission descriptions, app category, UIElement flag) live in the **pbxproj build settings**, not in `NemoNotch/Info.plist`. Adding a key requires editing both Debug and Release configurations.

**INFOPLIST_KEY entries (Debug config)** — `NemoNotch.xcodeproj/project.pbxproj:301-306  (build settings — no function)`

```
GENERATE_INFOPLIST_FILE = YES;
INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
INFOPLIST_KEY_LSUIElement = YES;
INFOPLIST_KEY_NSAppleEventsUsageDescription = "NemoNotch 需要控制音乐播放器以实现快进、快退等播放控制功能。";
INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = "NemoNotch 需要访问您的日历，以便在灵动岛中显示今日日程和下一个事件提醒。";
INFOPLIST_KEY_NSHumanReadableCopyright = "";
```

The identical block is duplicated at `project.pbxproj:355-360` for the Release configuration. **Both must be edited together** or the built `.app` will be missing the key in one configuration.

**Gotcha:** `GENERATE_INFOPLIST_FILE = YES` means the source `NemoNotch/Info.plist` is **ignored**; only `INFOPLIST_KEY_*` entries in pbxproj end up in the built `.app`. Verify with `/usr/libexec/PlistBuddy -c "Print" "$APP/Contents/Info.plist"`.

**Gotcha:** Missing `NSAppleEventsUsageDescription` causes macOS to **silently** refuse the automation authorization dialog — and the Automation pane in System Settings cannot manually add the app. The app appears to "not need" automation when in fact it can't request it. See [§11].

### `LSUIElement = YES` for menubar-only app

What/why: Suppresses the Dock icon so NemoNotch lives only in the menu bar.

**LSUIElement flag** — `NemoNotch.xcodeproj/project.pbxproj:303,357  (build settings — no function)`

```
INFOPLIST_KEY_LSUIElement = YES;
```

**Gotcha:** Without this the app shows a Dock icon, which defeats the menubar-only design and breaks the notch UX (clicking the Dock icon brings up an empty window).

### Entitlements: sandbox disabled

What/why: NemoNotch intentionally runs **unsandboxed** because hooks, private-API dlopen, and IPC subprocess control cannot work under App Sandbox.

**Full entitlements file** — `NemoNotch/NemoNotch.entitlements:1-8`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
</dict>
</plist>
```

**Gotcha:** Enabling sandbox (`com.apple.security.app-sandbox = true`) would break MediaRemote dlopen [§4], `~/.claude/settings.json` hook installation [§13], NowPlayingCLI subprocess [§12], and AppleScript control of Music/Spotify [§9]. Migrating to sandbox is a multi-week effort, not a flag flip.

### `build.sh` ad-hoc signing

What/why: One-shot local build that archives, exports, ad-hoc-signs, and packages a DMG.

**Archive + export + DMG** — `build.sh:14-44  (no function — shell script)`

```bash
echo "==> Archiving..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  | tail -1
// …
echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$BUILD_DIR/export/$APP_NAME.app"

echo "==> Creating DMG..."
// …
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$BUILD_DIR/$DMG_NAME.dmg"
```

**Gotcha:** `CODE_SIGN_IDENTITY="-"` produces an **ad-hoc-signed** app. Gatekeeper will block first-launch with "app is damaged"; end users must right-click → Open, or run `xattr -dr com.apple.quarantine NemoNotch.app`. Official distribution requires Developer ID + notarization, **not yet set up**.

**Gotcha:** `ENABLE_HARDENED_RUNTIME=NO` is required for the dlopen of MediaRemote private framework [§4] — hardened runtime would block it without a `com.apple.security.cs.allow-dyld-environment-variables` entitlement.

### GitHub Actions release workflow

What/why: Tag-triggered (`v*`) workflow that builds on a pinned Xcode + macOS runner and uploads the DMG to GitHub Releases.

**Runner + Xcode pin + release upload** — `.github/workflows/release.yml:12-57  (no function — workflow)`

```yaml
jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode 26.3
        run: sudo xcode-select -s /Applications/Xcode_26.3.app
      - name: Build archive
        run: |
          xcodebuild archive \
// …
            MACOSX_DEPLOYMENT_TARGET=26.2 \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            ENABLE_HARDENED_RUNTIME=NO
// …
      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: build/NemoNotch.dmg
          generate_release_notes: true
```

**Gotcha:** Xcode 26.3 must be pinned via `xcode-select -s /Applications/Xcode_26.3.app` because GitHub auto-updates the runner image and a newer Xcode can break Swift 6 strict-concurrency compile output. `macos-15` ≠ `macos-latest`; using `macos-latest` floats to the newest image and silently breaks builds.

**Gotcha:** `MACOSX_DEPLOYMENT_TARGET=26.2` must match the project's minimum; if the workflow value is older than the project setting, the archive links against newer-SDK symbols and fails at runtime on the deployment-target OS.

### SwiftFormat build phase

What/why: Source is auto-formatted on every Xcode build via a Run Script phase. The script degrades gracefully — missing `swiftformat` becomes a warning, not a build failure.

**Run Script body** — `NemoNotch.xcodeproj/project.pbxproj:148  (build phase — no function)`

```bash
if which swiftformat >/dev/null;
  then swiftformat "$SRCROOT" --cache quiet 2>/dev/null || true
else
  echo "warning: swiftformat not installed, run: brew install swiftformat"
fi
```

Rules live in `.swiftformat` at the repo root: `--swiftversion 6.0`, 4-space indent, 120-col max, `--self remove`, `--importgrouping alpha`, `--stripunusedargs closure-only`, plus disables for `redundantReturn`, `trailingClosures`, `wrapMultilineStatementBraces`.

**Gotcha:** The `2>/dev/null` suffix is **load-bearing**. Without it, Xcode parses SwiftFormat's normal progress output on stderr as build errors and the build fails with a red banner full of misleading "errors". The trailing `|| true` covers SwiftFormat's exit code 1 (no-op runs) for the same reason. Removing either causes flaky CI that's hard to diagnose because the formatting itself succeeded.

**Gotcha:** `which swiftformat` gates the call so contributors without `brew install swiftformat` still build — they just skip auto-formatting. CI installs it explicitly. Don't replace this with a hard error: it makes first-time clones miserable.

---

## 4. Private API loading

NemoNotch calls three macOS private frameworks (`MediaRemote.framework`, `DisplayServices.framework`, plus the 15.4+ `MRNowPlayingController` class). The loading approach differs by symbol count and OS version. Use the matching pattern below.

### 4.1 `dlopen` + `dlsym` (single symbol)

Cheapest path when you only need **one** C function from a private framework — open the binary directly and resolve the symbol by name.

**Brightness read via DisplayServices** — `NemoNotch/Services/HUDService.swift:161-184  getBrightness()`

```swift
private func getBrightness() -> Float? {
    if displayServicesHandle == nil {
        displayServicesHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_NOW)
    }
    guard let handle = displayServicesHandle else {
        LogService.warn("Failed to load DisplayServices framework", category: "HUD")
        return nil
    }

    typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else {
        LogService.warn("DisplayServicesGetBrightness symbol not found", category: "HUD")
        return nil
    }
    let funcPtr = unsafeBitCast(sym, to: GetBrightnessFunc.self)

    var brightness: Float = 0
    let result = funcPtr(CGMainDisplayID(), &brightness)
    guard result == 0 else { /* … */ return nil }
    return brightness
}
```

**Gotcha:** `dlsym` returns `nil` silently when the symbol is missing or renamed across macOS versions — always nil-check the result and log; do not force-unwrap.

**Gotcha:** Once `dlopen`'d, never call `dlclose`. The dylib stays mapped for the process lifetime, which is fine for a long-running menubar app but leaks across repeated test runs — cache the handle (as `displayServicesHandle` does) and reuse it.

### 4.2 `dlopen` + `CFBundleCreate` + `CFBundleGetFunctionPointerForName` (multiple symbols)

When you need several symbols from one framework, `CFBundle` gives a tidier loop than repeated `dlsym` calls. NemoNotch binds **6** `MRMediaRemote*` C functions in one initializer.

**MediaRemote function binding** — `NemoNotch/Services/MediaRemote.swift:38-61  init()`

```swift
private init() {
    let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_GLOBAL)
    if handle == nil {
        LogService.error("dlopen MediaRemote failed: \(String(cString: dlerror()))", category: "MediaRemote")
    }

    let bundleURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
    let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL as CFURL)

    func loadFn<T>(_ name: String, as _: T.Type) -> T? {
        guard let bundle, let ptr = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
            return nil
        }
        return unsafeBitCast(ptr, to: T.self)
    }

    self.getNowPlayingInfoFn = loadFn("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfoFn.self)
    self.sendCommandFn = loadFn("MRMediaRemoteSendCommand", as: SendCommandFn.self)
    // … 4 more: GetNowPlayingApplicationPID, RegisterForNowPlayingNotifications,
    //          SetCanBeNowPlayingApplication, SetElapsedTime
}
```

Symbols bound (all `@convention(c)` typealiases declared at top of file, lines 22-27):

- `MRMediaRemoteGetNowPlayingInfo` — async fetch of the current Now Playing info dict (legacy path; see [§4.3] for 15.4+ fallback).
- `MRMediaRemoteGetNowPlayingApplicationPID` — PID of the foreground media app, used for bundle-ID lookup.
- `MRMediaRemoteSendCommand` — issues play/pause/skip/seek commands; integer command IDs declared in `Command` enum (lines 8-20).
- `MRMediaRemoteRegisterForNowPlayingNotifications` — opt this process into `NSNotificationCenter` Now Playing change broadcasts.
- `MRMediaRemoteSetCanBeNowPlayingApplication` — flips a per-process bit so NemoNotch is not itself treated as a Now Playing source.
- `MRMediaRemoteSetElapsedTime` — sets elapsed-time hint for seek; consumed by Music/Spotify scripting bridge path (see [§11] for the AppleScript fallback).

**Gotcha:** The path passed to `dlopen` is `/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote` — the **binary inside the bundle**, no `.dylib` suffix. Passing the `.framework` directory path to `dlopen` fails silently in some macOS versions; pass the bundle directory to `CFBundleCreate` and the binary path to `dlopen`.

**Gotcha:** A `@convention(c)` typealias must match the C signature **exactly**, including pointer ownership and block vs. closure semantics. A wrong signature does not fail at `unsafeBitCast` time — it crashes (often `EXC_BAD_ACCESS`) at the first call site, which makes the bug hard to trace.

### 4.3 Reflective fallback via `NSClassFromString` + `class_createInstance` + KVC

macOS 15.4 moved Now Playing info behind a new Objective-C class (`MRNowPlayingController`). The legacy [§4.2] callback returns an empty dict on 15.4+, so a reflective construct-and-poll fallback is required.

**MRNowPlayingController query** — `NemoNotch/Services/MediaRemote.swift:180-238  queryViaNewControllerAPI()`

```swift
func queryViaNewControllerAPI(completion: @escaping ([String: Any]?) -> Void) {
    guard let destClass = NSClassFromString("MRDestination") as? NSObject.Type,
          let configClass = NSClassFromString("MRNowPlayingControllerConfiguration") as? NSObject.Type,
          let controllerClass = NSClassFromString("MRNowPlayingController") as? NSObject.Type else {
        completion(nil); return
    }
    // … fetch userSelectedDestination, build configuration via initWithDestination:
    guard let controllerInstance = class_createInstance(controllerClass, 0) as? NSObject else {
        completion(nil); return
    }
    let initCtlSel = NSSelectorFromString("initWithConfiguration:")
    guard let ctl = controllerInstance.perform(initCtlSel, with: configObj)?.takeUnretainedValue() as? NSObject else {
        completion(nil); return
    }
    ctl.perform(NSSelectorFromString("beginLoadingUpdates"))

    // poll up to 25 × 100ms for response.playbackQueue.contentItems[*].metadata
    let timer = DispatchSource.makeTimerSource(queue: .main)
    var pollCount = 0; let maxPolls = 25
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in
        pollCount += 1
        let response = ctl.value(forKey: "response") as? NSObject
        let info = MediaRemote.buildInfoDict(from: response)
        if (info != nil && !(info?.isEmpty ?? true)) || pollCount >= maxPolls {
            timer.cancel(); self?.pollTimer = nil
            ctl.perform(NSSelectorFromString("endLoadingUpdates"))
            completion(info)
        }
    }
    pollTimer = timer; timer.resume()
}
```

**Gotcha:** macOS 15.4+ **only**. On <15.4, `NSClassFromString("MRNowPlayingController")` returns `nil` and the legacy [§4.2] callback path is mandatory. Always nil-check the class lookup (a runtime check is more robust than `if #available` because Apple has historically backported and removed reflective classes within point releases).

**Gotcha:** The poll loop has a hard cap of `25 × 100ms = 2.5s`. If `playbackQueue.contentItems` is still empty after 2.5s, give up and treat as "no Now Playing app active" — the controller never fires a delegate callback for the empty case, so an unbounded wait would hang the UI.

---

**Cross-cutting:** all three patterns are subject to breaking on macOS minor releases — Apple renames, relocates, or deletes private symbols without notice. Always (1) log the failure point (`dlerror()` for [§4.1]/[§4.2], the specific `NSClassFromString` nil for [§4.3]), (2) return `nil`/early so the caller can degrade gracefully, and (3) state each pattern's OS-version bound up front in any code using it. The [§4.3] reflective path is `macOS 15.4+`; the [§4.1] and [§4.2] paths have held since macOS 10.12 but assume nothing about 16.x.

---

## 5. Notch & window management

The notch-area floating window is an `NSPanel`-style window subclass with carefully chosen level / collectionBehavior / transparency flags, a custom hit-test view for click-through control, one `NSHostingController` per screen, and an observer for display reconfiguration.

### 5.1 — Borderless `NSWindow` at `.statusBar + 8`

**Window construction** — `NemoNotch/Notch/NotchWindow.swift:3-22  init(rect:)`

```swift
class NotchWindow: NSWindow {
    init(rect: NSRect) {
        super.init(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        alphaValue = 1
        level = .statusBar + 8
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        acceptsMouseMovedEvents = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // …
    }
```

The window sits above all standard application chrome but below modal system UI. Transparency flags (`isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`) let the SwiftUI content render the notch silhouette itself rather than the window frame.

**Gotcha:** `level = .statusBar + 8` is **empirical** — discovered by trial. `.statusBar + 0` sits under standard menubar UI on some macOS versions; `+ 8` clears it. Different macOS major versions may need re-tuning — if the window ever renders behind menu-extras, this is the line to bump.

**Gotcha:** The styleMask is `[.borderless]` only. There is no `.titled`, no traffic-light buttons, no resizing — the window is purely a render surface. `canBecomeKey` / `canBecomeMain` are overridden to return `true` so keyboard focus can still land here when opened (needed for the search field in the launcher tab).

### 5.2 — `collectionBehavior` flag set

**Spaces / Mission Control behavior** — `NotchWindow.swift:21  init(rect:)`

```swift
collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
```

- `.fullScreenAuxiliary` — window remains visible when another app enters fullscreen; without it, the notch disappears the moment any app fullscreens.
- `.stationary` — Mission Control / Spaces transitions don't slide the window with the desktop. The notch stays pinned to the physical display.
- `.canJoinAllSpaces` — same window instance is visible across every Space, so the user doesn't need a per-Space copy.
- `.ignoresCycle` — exclude from Cmd-Tab and Cmd-` window cycling.

**Gotcha:** Without `.stationary` the window drifts visibly during Mission Control / Spaces swipe — it animates with the desktop background instead of staying at the menubar.

**Gotcha:** Without `.ignoresCycle` the notch window appears in Cmd-Tab as a focusable target. That breaks the menubar-only design — users can accidentally "activate" a window that has no UI when closed.

### 5.3 — `PassThroughView` hit-test toggle

**Click-through control** — `NemoNotch/Notch/NotchWindow.swift:28-36  PassThroughView.hitTest(_:)`

```swift
final class PassThroughView: NSView {
    var isBlocking = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if view !== self { return view }
        return isBlocking ? self : nil
    }
}
```

The window is sized to span the entire screen (so SwiftUI can render badges anywhere along the menubar strip), but most of that area must let clicks fall through to the underlying app. Returning `nil` from `hitTest` makes AppKit treat the point as transparent to mouse events; returning a real view captures the click.

**Gotcha:** `isBlocking` must be `true` while the notch is **open** (capture clicks for tab buttons, scroll, drag) and `false` while **closed** (let clicks pass through the dead area around the badges). The toggle happens at `NotchCoordinator.swift:191` on open and `NotchCoordinator.swift:202` on close. Leaving it `true` while closed makes the menubar area "swallow" clicks, breaking any app whose menu sits near the notch.

**Gotcha:** `super.hitTest(point)` is called first so SwiftUI subviews inside the hosting controller (buttons, sliders) still receive clicks — the `view !== self` guard returns those subviews unchanged. Only points that resolve to the bare `PassThroughView` background are conditionally suppressed.

### 5.4 — Per-screen `NSHostingController` + frame offset (multi-screen)

**Slot construction** — `NemoNotch/Notch/NotchCoordinator.swift:127-155  makeSlot(for:)`

```swift
private func makeSlot(for screen: NSScreen) -> NotchWindowSlot {
    let wf = Self.windowFrame(for: screen)
    let window = NotchWindow(rect: wf)
    let passThrough = PassThroughView(frame: NSRect(x: 0, y: 0, width: wf.width, height: wf.height))
    passThrough.wantsLayer = true
    passThrough.layer?.backgroundColor = .clear

    let hosting = NSHostingController(rootView: contentBuilder(self, screen))
    let sf = screen.frame
    hosting.view.frame = NSRect(
        x: sf.minX - wf.minX,
        y: sf.minY - wf.minY,
        width: sf.width,
        height: sf.height
    )
    // …
    passThrough.addSubview(hosting.view)
    window.contentView = passThrough
    window.orderFrontRegardless()
    // …
}
```

One `NotchWindow` per screen, keyed by `CGDirectDisplayID` in the `slots` dictionary (`NotchCoordinator.swift:29`). The window itself is sized to a fixed 800×340 rect centered above the notch (`windowFrame(for:)` at `NotchCoordinator.swift:157-165`); the hosting view inside is sized to the **full screen frame** and offset by `screen.frame.origin - window.frame.origin`.

**Gotcha:** The hosting view's frame is computed in **window-local coordinates** by subtracting the window origin from the screen origin. Skip this offset (or use `sf.minX` directly) and the SwiftUI content renders on the wrong physical display when an external monitor is attached — SwiftUI sees screen-global coordinates but the view system is window-local.

**Gotcha:** `orderFrontRegardless()` is used instead of `makeKeyAndOrderFront` during slot creation. Newly created slots stay visible (to render badges) but **do not steal focus** — only the active slot calls `makeKeyAndOrderFront` from `notchOpen` at `NotchCoordinator.swift:192`.

See `docs/plans/2026-05-07-multi-screen-design.md` for the full multi-screen design rationale.

### 5.5 — `NSScreen` notch geometry

**Notch detection** — `NemoNotch/Helpers/ScreenExtensions.swift:9-48  hasNotch / notchSize / displayID / isBuiltInDisplay`

```swift
var hasNotch: Bool {
    safeAreaInsets.top > 0
        && (auxiliaryTopLeftArea?.width ?? 0) > 0
        && (auxiliaryTopRightArea?.width ?? 0) > 0
}

var notchSize: NSSize {
    guard hasNotch else { return .zero }
    let notchHeight = safeAreaInsets.top
    let notchWidth = frame.width
        - (auxiliaryTopLeftArea?.width ?? 0)
        - (auxiliaryTopRightArea?.width ?? 0)
    return .init(width: notchWidth, height: notchHeight)
}

var displayID: UInt32 {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    guard let screenNumber = deviceDescription[key] as? NSNumber else { return 0 }
    return screenNumber.uint32Value
}
```

`safeAreaInsets.top` is non-zero on notched MacBooks; `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` give the visible menubar segments flanking the notch. The notch's physical width is the screen width minus those two flanks; its height equals the top safe-area inset.

**Gotcha:** Non-notch Macs (Mac mini, Mac Pro, M1 iMac) and external displays return `safeAreaInsets.top == 0`. `notchSize` returns `.zero`, which would collapse the closed window to nothing. The fallback lives in `NotchCoordinator.resolveUnifiedNotchSize()` (`NotchCoordinator.swift:98-103`) which substitutes `NotchConstants.defaultNotchWidth = 200` × `defaultNotchHeight = 32` (`NemoNotch/Helpers/Constants.swift:5-6`).

**Gotcha:** `displayID` comes from `deviceDescription[NSScreenNumber]` cast to `NSNumber.uint32Value` — that key returns `Optional<Any>`, and a missing/wrong-type value falls back to `0`. Two screens with `displayID == 0` would collide in the `slots` dictionary; in practice this only happens during display teardown and is handled by `rebuildSlots()` removing stale entries.

**Gotcha:** `CGDisplayIsBuiltin(displayID) == 1` filters built-in vs external — used in `isBuiltInDisplay` (lines 41-48) to decide where the HUD overlay renders. The HUD only paints on the built-in display to avoid flicker on external monitors that have their own brightness/volume OSD. Cross-link to [§16].

### 5.6 — `didChangeScreenParametersNotification` rebuild

**Display reconfiguration observer** — `NemoNotch/Notch/NotchCoordinator.swift:81-93  init()` and `NotchCoordinator.swift:244-252  screenParametersChanged()`

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(screenParametersChanged),
    name: NSApplication.didChangeScreenParametersNotification,
    object: nil
)
// …
@objc private func screenParametersChanged() {
    notchSize = Self.resolveUnifiedNotchSize()
    rebuildSlots()
    // If the active screen disappeared mid-session, gracefully collapse.
    if let active = activeScreen, slots[active.displayID] == nil {
        activeScreen = nil
        status = .closed
    }
}
```

`rebuildSlots()` (`NotchCoordinator.swift:107-125`) diffs `Set(NSScreen.screens.map(\.displayID))` against existing slot keys: missing displays get `slot.close()` + removal, new displays get a fresh `makeSlot`, surviving displays just have their frame updated.

**Gotcha:** This notification fires on plug/unplug, resolution change, scale-factor change, and several sleep/wake transitions. The handler must be **idempotent and cheap** — it can fire many times in rapid succession during clamshell-mode docking.

**Gotcha:** If the previously-active screen disappears (laptop lid closes with external attached), failing to null out `activeScreen` and force `status = .closed` leaves a dangling reference to a removed `NSScreen`. Subsequent calls to `isActiveScreen(_:)` would never match any current screen and the user appears stuck in a half-open state. The explicit collapse on lines 248-251 is the recovery.

### 5.7 — Activation policy + previous-app restoration

What/why: NemoNotch normally runs as `.accessory` (no Dock icon, absent from ⌘+Tab). The settings window needs **standard** AppKit activation behavior, and closing the notch should return focus to whatever app was foreground before the user invoked the notch.

**Launch + settings-window policy toggle** — `NemoNotch/NemoNotchApp.swift:97 + 182-194  handleSettingsAppear/Disappear()`

```swift
// applicationDidFinishLaunching:
NSApp.setActivationPolicy(.accessory)

@MainActor func handleSettingsAppear() {
    suppressRestoreUntil = Date().addingTimeInterval(1.2)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
}

@MainActor func handleSettingsDisappear() {
    suppressRestoreUntil = .distantPast
    NSApp.setActivationPolicy(.accessory)
}
```

**Frontmost-app capture/restore around notch open/close** — `NemoNotch/Notch/NotchCoordinator.swift:29 + 220-239  captureFrontmostApp/restorePreviousApp()`

```swift
private var previousApp: NSRunningApplication?

private func captureFrontmostApp() {
    let frontmost = NSWorkspace.shared.frontmostApplication
    if frontmost?.bundleIdentifier != Self.ourBundleIdentifier {
        previousApp = frontmost
    }
}

private func restorePreviousApp() {
    if restoreSuppressionCheck?() == true { previousApp = nil; return }
    guard let app = previousApp else { return }
    previousApp = nil
    let currentFront = NSWorkspace.shared.frontmostApplication
    if currentFront == nil || currentFront?.bundleIdentifier == Self.ourBundleIdentifier {
        app.activate()
    }
}
```

**Gotcha:** `.accessory` apps can't host a normal-feeling window — text fields lose key-event routing, ⌘+Q targets the wrong app, the window decoration looks off. The transient `.regular` switch is what makes the settings window behave like a real window. Forgetting to flip back to `.accessory` on dismiss leaves a phantom Dock icon and inserts NemoNotch into ⌘+Tab permanently.

**Gotcha:** Without `previousApp` capture/restore, opening the notch over (e.g.) Xcode and closing it again leaves the user stuck in NemoNotch — they then ⌘+Tab to get back to their work, which is the bad UX we paid for. The `frontmost?.bundleIdentifier != Self.ourBundleIdentifier` guard prevents capturing ourselves when the user toggles the notch via global hotkey while NemoNotch is already foreground.

**Gotcha:** `suppressRestoreUntil` (1.2s window) is set on **settings appear** so the notch-close path skips the restore. Without it, if the user opens settings (which auto-closes the notch), restore would yank focus back to Xcode and instantly dismiss the settings window the user just opened. The coordinator consults this via the injected `restoreSuppressionCheck` closure rather than holding an `AppDelegate.shared` reference — see [§17.2].

### 5.8 — Reference projects

- *NotchDrop* — original NSPanel subclass + `.statusBar` level discovery and global mouse-monitor patterns.
- *Peninsula* — tri-state machine (closed / popping / opened), Carbon-based global hotkey approach, `NotchBackgroundView` for rounded notch corners.
- *DynamicNotchKit* — spring animation parameter choices (`.bouncy(duration: 0.4)`) and `NSScreen` extensions (`hasNotch` / `notchSize` / `notchFrame`).

### 5.9 — Centered draggable `NSPanel` for hotkey-summoned quick-utility windows

A borderless, click-outside-dismissable, all-Spaces `NSPanel` that lives at the screen center (used by the Pomodoro QuickStart window). Pattern:

- `NSPanel` subclass with `styleMask: [.borderless, .nonactivatingPanel]`
- `isFloatingPanel = true`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .transient]`
- `isMovableByWindowBackground = true` — entire window is the drag handle (no titlebar needed)
- `override var canBecomeKey: Bool { true }` — required so embedded `TextField` receives keyboard input
- Click-outside dismiss via `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)`; uninstall on dismiss
- Restore previous-frontmost app via `previousApp?.activate()` so the user returns to their flow

Example: `NemoNotch/Notch/QuickStartWindow.swift`, controller at `QuickStartWindowController.swift`.

---

## 6. Event capture & hotkeys

NemoNotch listens for mouse approach/leave via paired global+local `NSEvent` monitors, registers global keyboard shortcuts via the `KeyboardShortcuts` library, shows a right-click context menu via `NSMenu.popUp`, and triggers haptic feedback on open.

### 6.1 — Paired global + local `NSEvent` monitors

**`start()` — `NemoNotch/Notch/EventMonitor.swift:17-52  start()`**

```swift
private func start() {
    let globalMove = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
        MainActor.assumeIsolated {
            self?.onMouseMove?(NSEvent.mouseLocation)
        }
    }
    // … globalDown / globalRightDown installed identically for .leftMouseDown / .rightMouseDown
    let localMove = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
        MainActor.assumeIsolated {
            self?.onMouseMove?(NSEvent.mouseLocation)
        }
        return event
    }
    // … localDown / localRightDown mirror localMove, each returning `event`
    monitors = [globalMove as Any, globalDown as Any, globalRightDown as Any, localMove as Any, localDown as Any, localRightDown as Any]
}
```

**Gotcha:** **Both** monitors are needed. Global fires when your app isn't focused (the normal case for a notch utility — the user's focused app is something else); local fires when NemoNotch itself is key. The local handler **must return the event** (or `nil` to swallow it) or downstream views never receive input.

**Gotcha:** `addGlobalMonitorForEvents` returns an opaque object; **retain it** (the monitor is removed when the returned object is released). Store in a property (`monitors: [Any]` here), not a local — otherwise the monitor is torn down as soon as `start()` returns.

**Gotcha:** Handler closures cross from arbitrary AppKit dispatch into `@MainActor` state. `MainActor.assumeIsolated { … }` is the Swift 6 escape hatch — only correct because `NSEvent` monitors are documented to invoke on the main thread.

### 6.2 — `NSEvent.mouseLocation` for screen-coordinate hit testing

Used inline at `EventMonitor.swift:20, 30, 35, 47` and `NotchCoordinator.swift:295`:

```swift
self?.onMouseMove?(NSEvent.mouseLocation)
```

**Gotcha:** Returns screen coordinates with the **primary screen's bottom-left as origin**. When comparing against `NSScreen.frame` (also bottom-left-origin), `NSMouseInRect` works directly. When converting to view-local coords, do `screen.frame` math first — don't assume Y grows downward.

### 6.3 — Hitbox math with hysteresis

**`handleMouseMove(_:)` — `NemoNotch/Notch/NotchCoordinator.swift:275-291  handleMouseMove(_:)`** and **`handleMouseDown()` — `NotchCoordinator.swift:293-311  handleMouseDown()`**

```swift
private func handleMouseMove(_ location: NSPoint) {
    guard !isContextMenuVisible else { return }
    switch status {
    case .closed:
        guard let screen = screen(at: location) else { return }
        if NSMouseInRect(location, hitboxRect(for: screen), false) {
            notchOpen(on: screen)
        }
    case .opened:
        guard let active = activeScreen else { return }
        let contentHit = contentRect(for: active, hitInset: NotchConstants.closeHitboxInset)
        if !NSMouseInRect(location, contentHit, false) {
            notchClose()
        }
    }
}
```

`hitboxRect` (`NotchCoordinator.swift:48-50`) is the device notch rect inflated by `NotchConstants.hitboxPadding = 10`. `contentRect(for:hitInset:)` (`NotchCoordinator.swift:63-71`) is the opened content rect inflated by either `closeHitboxInset = 20` (hover) or `clickHitboxInset = 10` (click).

**Gotcha:** Open-hitbox uses notch frame + **10pt** padding — must be tight or you re-open while the cursor is moving away. Close-hitbox uses opened content frame + **20pt inset for hover** vs **10pt for click** — different insets prevent accidental dismissal during interaction (e.g. a user scrolling a list near the edge shouldn't trigger close, but a deliberate click outside the tighter click-inset rect should). See `Helpers/Constants.swift:10-12` for the canonical values. Cross-link: the panel itself uses [§5.3 PassThroughView] for click-through behavior, so the hitbox math is the **only** thing keeping the notch open.

**Gotcha:** `isContextMenuVisible` short-circuits at the top — without this, moving the cursor into a popped-up `NSMenu` (which sits outside `contentRect`) would immediately fire `notchClose()`. See §6.6.

### 6.4 — User-customizable global hotkeys via `KeyboardShortcuts`

**Hotkey name registry — `NemoNotch/Services/Hotkeys.swift`**

```swift
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleNotch = Self("toggleNotch")  // no default — user-configured
    static let openOverview = Self("openOverview", default: .init(.one, modifiers: [.option, .command]))
    static let openAI       = Self("openAI",       default: .init(.two, modifiers: [.option, .command]))
    // … one Name per Tab, with default Cmd+Opt+<digit>
}

extension Tab {
    var hotkeyName: KeyboardShortcuts.Name {
        switch self {
        case .overview: return .openOverview
        case .claude:   return .openAI
        // …
        }
    }
}
```

**Gotcha:** The string passed to `Self("…")` is the UserDefaults key under which `KeyboardShortcuts` persists the binding. Treat it as a stable API surface — renaming `"openAI"` resets every user's saved binding for that action. Add new names, don't rename old ones.

**Gotcha:** `import AppKit` is **required** even though it looks unused. `[.option, .command]` resolves to `NSEvent.ModifierFlags` (defined in AppKit). With Swift 6's `MemberImportVisibility` upcoming feature, transitive imports from `KeyboardShortcuts` don't expose these symbols, so the omission produces `error: static property 'option' is not available due to missing import of defining module 'AppKit'`.

**Gotcha:** `KeyboardShortcuts.Recorder` is a SwiftUI control — not a global event monitor. The library handles registration and unregistration internally; callers only register `onKeyDown` callbacks. Compare to Carbon's `RegisterEventHotKey` (replaced in this redesign), which required manually unbalanced `Unmanaged.passUnretained(self).toOpaque()` userdata threading through C callbacks — about 80 lines of bridging the library renders unnecessary.

### 6.5 — Hotkey registration in `applicationDidFinishLaunching`

**`setupHotkeys(...)` — `NemoNotch/NemoNotchApp.swift  setupHotkeys(coordinator:)`**

```swift
private func setupHotkeys(coordinator: NotchCoordinator) {
    KeyboardShortcuts.onKeyDown(for: .toggleNotch) { [weak coordinator] in
        guard let c = coordinator else { return }
        switch c.status {
        case .closed: c.notchOpen()
        case .opened: c.notchClose()
        }
    }

    for tab in Tab.allCases {
        KeyboardShortcuts.onKeyDown(for: tab.hotkeyName) { [weak coordinator] in
            guard let c = coordinator else { return }
            c.notchOpen(tab: tab)
        }
    }
}
```

**Gotcha:** `[weak coordinator]` captures are defensive — `AppDelegate.coordinator` is set once in `applicationDidFinishLaunching` and never cleared. The library retains its callbacks for the app lifetime, so strong captures would be acceptable too; `weak` keeps the dependency direction one-way.

**Gotcha:** User-customizable defaults flow through `KeyboardShortcuts.Name(_:default:)`. Where the previous Carbon path hardcoded each binding inline, this redesign moves all defaults into `Hotkeys.swift` so the Settings → Hotkeys recorder can display and override them.

**Gotcha:** Settings exposes each `Name` via `KeyboardShortcuts.Recorder("…", name: .openOverview)` — see `NemoNotch/Settings/HotkeysSettingsView.swift`. The recorder displays the current binding, lets the user re-record, and persists to UserDefaults. No extra code paths.

**Gotcha:** Tabs use a fixed per-case `KeyboardShortcuts.Name` (via `Tab.hotkeyName`). The previous Carbon code assigned hotkeys by index over `Tab.sorted(settings.enabledTabs)`, so disabling a tab shifted others' shortcuts. The fixed mapping makes per-tab bindings stable; a disabled tab's binding sits idle until re-enabled.

### 6.6 — Right-click context menu via `NSMenu.popUp`

**`handleRightMouseDown(_:)` — `NemoNotch/Notch/NotchCoordinator.swift:313-351  handleRightMouseDown(_:)`** and **`ContextMenuDelegate` — `NotchCoordinator.swift:400-421`**

```swift
isContextMenuVisible = true
let menu = NSMenu()
let delegate = ContextMenuDelegate(
    onClose: { [weak self] in self?.isContextMenuVisible = false },
    onSettings: { @MainActor [weak self] in self?.onShowSettings?() },
    onQuit: { NSApp.terminate(nil) }
)
contextMenuDelegate = delegate
menu.delegate = delegate
let settingsItem = NSMenuItem(
    title: String(localized: "notch.context.settings"),
    action: #selector(ContextMenuDelegate.openSettings),
    keyEquivalent: ","
)
settingsItem.target = delegate
menu.addItem(settingsItem)
// … separator + quitItem appended the same way
menu.popUp(positioning: nil, at: point, in: nil)
```

```swift
private final class ContextMenuDelegate: NSObject, NSMenuDelegate {
    // … stored closures: onClose / onSettings / onQuit
    func menuDidClose(_ menu: NSMenu) {
        onClose()
    }
    @objc func openSettings() { onSettings() }
    @objc func quitApp() { onQuit() }
}
```

**Gotcha:** Without `NSMenuDelegate.menuDidClose` clearing `isContextMenuVisible`, the §6.3 hover logic fires while the menu is up and immediately closes the notch (the cursor is over the menu, **not** over `contentRect`). The flag short-circuits both `handleMouseMove` and `handleMouseDown` — see [§6.3].

**Gotcha:** `menu.popUp(positioning:at:in:)` is **synchronous** — it spins a nested run loop until the user dismisses the menu. Any Swift state changes that should race with menu lifecycle (e.g. resetting `isContextMenuVisible`) must go through the delegate callback, not through code after the `popUp` call (which only resumes once the menu is already gone).

**Gotcha:** The delegate must outlive `popUp`. Storing it in `contextMenuDelegate` (a strong property) is required — a local would be deallocated mid-nested-runloop and the `@objc` targets would dangle.

### 6.7 — `NSHapticFeedbackManager.levelChange` on open

**`notchOpen(...)` — `NemoNotch/Notch/NotchCoordinator.swift:186  notchOpen(tab:on:)`**

```swift
NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
```

**Gotcha:** Only fires on hardware with a Force Touch trackpad. Silent on Magic Mouse, external keyboards, and pre-2015 MacBooks — that's fine. Don't gate UX behind it (use it strictly as a polish layer alongside the animation in [§5]).

### 6.8 — Reference projects

- *NotchDrop* — original global `NSEvent` monitor pattern for detecting cursor approach to the notch.
- *sindresorhus/KeyboardShortcuts* — User-customizable global hotkeys with a SwiftUI `Recorder` control and built-in UserDefaults persistence. Replaces the previous in-tree Carbon `RegisterEventHotKey` wrapper.
- *Peninsula* — Carbon `RegisterEventHotKey` packaged as a reusable service (historical reference; superseded by KeyboardShortcuts in this codebase).

---

## 7. Media subsystem

The deepest subsystem. Three layered information sources (NowPlayingCLI daemon, MediaRemote private framework, ScriptingBridge to Music/Spotify) are reconciled by an optimistic-UI + guard pattern so play/pause taps feel instant while playback metadata stays accurate.

### 7.1 — NowPlayingCLI daemon

A bundled perl helper (`mediaremote-mini.pl`) drives the MediaRemote private API on our behalf via a gzipped dylib resource. We talk to it over stdin/stdout with line-delimited JSON. Used in preference to direct dlopen because the same perl script handles every macOS version's MediaRemote quirks for us.

- **Bundled perl script + extracted dylib** — `NemoNotch/Services/NowPlayingCLI.swift:38-54  init()` and `309-387  extractDylib(gzPath:)`. On first run we look up `mediaremote-mini.pl` and `MediaRemoteMini.bin.gz` from the app bundle, gunzip the dylib into `~/Library/Application Support/NemoNotch/MediaRemoteMini.dylib`, then keep that path cached for every later launch.

  ```swift
  if let script = Bundle.main.path(forResource: "mediaremote-mini", ofType: "pl"),
     let gzPath = Bundle.main.path(forResource: "MediaRemoteMini", ofType: "bin.gz"),
     let dylib = Self.extractDylib(gzPath: gzPath) {
      helpers.append(.bundled(script: script, dylib: dylib))
  }
  // …
  private static func extractDylib(gzPath: String) -> String? {
      let dest = (supportDir as NSString).appendingPathComponent("MediaRemoteMini.dylib")
      if FileManager.default.fileExists(atPath: dest) { return dest }
      // … run /usr/bin/gunzip -c gzPath > tempDest, then move tempDest → dest
  }
  ```

  **Gotcha:** The bundle resource ships **gzipped** because the dylib is non-trivially large and only useful when written somewhere `dlopen` can read it. The app bundle is read-only at runtime under all hardening modes, so the dylib **must** be extracted to a writable Application Support directory. `FileManager.default.fileExists(atPath:)` short-circuits on every launch after the first.

  **Gotcha:** Extraction writes to `dest + ".tmp"` first and then `moveItem` — atomic replacement avoids a half-written dylib if the app is killed mid-`gunzip`. The temp file gets deleted on every failure path.

- **`Process` + `Pipe` daemon spawn** — `NemoNotch/Services/NowPlayingCLI.swift:80-118  startDaemon()`. The daemon is `/usr/bin/perl` running our script with the dylib path as an argument; we wire all three stdio pipes so we own the read/write side of the protocol.

  ```swift
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
  process.arguments = [script, dylib, "adapter_get_env", "--daemon"]

  let stdinPipe = Pipe()
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardInput = stdinPipe
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  try process.run()
  daemonProcess = process
  daemonStdin = stdinPipe.fileHandleForWriting
  daemonStdout = stdoutPipe.fileHandleForReading
  daemonStdout?.readabilityHandler = { [weak self] handle in /* … */ }
  ```

  **Gotcha:** Retain the `Process` instance (we store it as `daemonProcess`). Losing the reference lets ARC release it, which reaps the daemon — the next request hangs waiting on a dead pipe.

  **Gotcha:** `signal(SIGPIPE, SIG_IGN)` is installed at app startup (`NemoNotch/NemoNotchApp.swift:26`). Without it, a daemon-side pipe close (e.g. perl process exits during a write) delivers `SIGPIPE` and **kills the parent app** with no traceable crash log. Single-line app-wide fix; trivial to forget; catastrophic when missing.

- **Line-delimited JSON protocol** — `NemoNotch/Services/NowPlayingCLI.swift:141-189  fetchViaDaemon(completion:)` and `handleDaemonData(_:)`. Each request is a single newline byte written to stdin; the daemon responds with one JSON object followed by `\n`. The `readabilityHandler` accumulates bytes into `responseBuffer` and dispatches whenever it sees `0x0A`.

  ```swift
  pendingCompletion = completion
  responseBuffer = Data()
  guard let data = "\n".data(using: .utf8) else { finishPending(nil); return }
  guard let stdin = daemonStdin, let p = daemonProcess, p.isRunning else {
      finishPending(nil); return
  }
  stdin.write(data)

  let item = DispatchWorkItem { [weak self] in
      self?.queue.async { self?.handleDaemonTimeout() }
  }
  timeoutItem = item
  queue.asyncAfter(deadline: .now() + processTimeoutSeconds, execute: item)
  ```

  **Gotcha:** A single `pendingCompletion` slot is tracked per daemon. Concurrent requests are rejected (`guard pendingCompletion == nil else { … completion(nil) }`) — every caller must serialize through `queue` or accept a `nil` callback. The daemon's stdin/stdout is strict request/response, not multiplexed; do not try to interleave.

  **Gotcha:** `responseBuffer.range(of: Data([0x0A]))` is the *only* delimiter. If perl ever produces a JSON value containing an embedded newline (e.g. via base64 line-wrapping at 76 chars), it will be mis-framed. The script avoids this; do **not** swap the protocol for pretty-printed JSON.

- **One-shot fallback with semaphore** — `NemoNotch/Services/NowPlayingCLI.swift:207-251  fetchUsingFallbacks(from:completion:)` and `253-298  runProcess(executable:arguments:sourceTag:)`. If the daemon refuses to start (no bundled dylib + no Homebrew install) we fall through to per-request `Process` invocations with a 4-second `DispatchSemaphore` timeout.

  ```swift
  let semaphore = DispatchSemaphore(value: 0)
  try process.run()
  DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      semaphore.signal()
  }

  let timeout = processTimeoutSeconds
  let waitResult = semaphore.wait(timeout: .now() + timeout)
  if waitResult == .timedOut {
      LogService.error("\(sourceTag) timed out after \(timeout)s", category: "NowPlayingCLI")
      process.terminate()
      _ = semaphore.wait(timeout: .now() + 1)
      return nil
  }
  ```

  **Gotcha:** After `process.terminate()` we `semaphore.wait(timeout: .now() + 1)` so the `waitUntilExit` callback unblocks the global queue thread before we return — leak-free even on the timeout path.

  **Gotcha:** When the *daemon* itself times out (`handleDaemonTimeout`, line 191-196), we call `restartDaemon()`: there is **no recover-without-restart** path because we don't know whether the daemon is mid-write or stalled. The protocol's lack of message framing means partial responses can't be discarded safely.

### 7.2 — MediaRemote private framework (usage)

Loading the function pointers (`MRMediaRemoteSendCommand`, `MRMediaRemoteSetElapsedTime`, `MRMediaRemoteRegisterForNowPlayingNotifications`) is covered in [§4 Pattern B]. The 15.4+ `MRNowPlayingController` fallback is [§4 Pattern C]. This sub-section is only about how those pointers are *invoked*.

- **`sendCommand` and `skip(interval:)`** — `NemoNotch/Services/MediaRemote.swift:141-165`. `sendCommand` is a thin cast over the function pointer; `skip(interval:)` packages a numeric `kMRMediaRemoteOptionSkipInterval` into the options dict and prefers the generic skip command over the fixed-15s commands.

  ```swift
  @discardableResult
  func sendCommand(_ command: Command, options: [AnyHashable: Any]? = nil) -> Bool {
      guard let fn = sendCommandFn else { return false }
      return fn(command.rawValue, options)
  }

  @discardableResult
  func skip(interval: Double) -> Bool {
      guard interval != 0 else { return false }
      let forward = interval > 0
      let magnitude = abs(interval)
      let options: [AnyHashable: Any] = [
          "kMRMediaRemoteOptionSkipInterval": NSNumber(value: magnitude),
      ]
      if sendCommand(forward ? .skipForward : .skipBackward, options: options) { return true }
      return sendCommand(forward ? .skipForward15 : .skipBackward15)
  }
  ```

  **Gotcha (the big one): DON'T call `sendCommand(.skipForward)` or `.skipBackward` on Spotify or Music.** The system returns "never supported" via `MPRemoteCommandCenter`, with no error and no recovery — the command is silently dropped. Music sometimes accepts it; Spotify never does. Always route those two players through `MediaBridge.setPlayerPosition` (AppleScript). See [§7.3] and [§9].

- **`setElapsedTime` for seek** — `NemoNotch/Services/MediaRemote.swift:169-174`. Absolute-position seek via the `MRMediaRemoteSetElapsedTime` symbol.

  ```swift
  @discardableResult
  func setElapsedTime(_ seconds: Double) -> Bool {
      guard let fn = setElapsedTimeFn else { return false }
      fn(seconds)
      return true
  }
  ```

  **Gotcha:** The boolean return value only indicates whether **the symbol was loaded**, not whether the call did anything. For Music/Spotify it silently no-ops; for Podcasts, Safari, and Chrome it works. Always pair with a MediaBridge fallback when the bundleID is a `KnownPlayer`. See [§7.5 decision tree].

- **15.4+ `MRNowPlayingController` fallback** — covered in [§4 Pattern C] (`getNowPlayingInfoSwift15_4Plus()`). Cross-link only — no duplication here.

### 7.3 — MediaBridge (ScriptingBridge)

The authoritative source for Music/Spotify play state and the only path that can reliably seek Spotify. Wraps generated `MusicApplication`/`SpotifyApplication` protocols behind a type-erased `PlayerHandle`.

- **`SBApplication(bundleIdentifier:)` resolution** — `NemoNotch/Services/MediaBridge.swift:52-63  PlayerHandle.resolve(_:)`. Returns a typed handle if the app is reachable, sets the shared delegate so async errors are captured.

  ```swift
  static func resolve(_ player: KnownPlayer) -> PlayerHandle? {
      switch player {
      case .spotify:
          guard let app: SpotifyApplication = SBApplication(bundleIdentifier: player.rawValue) else { return nil }
          (app as? SBApplication)?.delegate = PlayerEventDelegate.shared
          return .spotify(app)
      case .music:
          guard let app: MusicApplication = SBApplication(bundleIdentifier: player.rawValue) else { return nil }
          (app as? SBApplication)?.delegate = PlayerEventDelegate.shared
          return .music(app)
      }
  }
  ```

  **Gotcha:** Calling `SBApplication(bundleIdentifier:)` *launches the app* if it's not already running. **Always** guard with `NSRunningApplication.runningApplications(withBundleIdentifier:)` first — see `MediaBridge.isRunning(bundleID:)` at line 134-137. Without the guard, a routine `isPlaying` poll launches Music in the dock just because we wanted to read its state.

- **`SBApplicationDelegate` for async error capture** — `NemoNotch/Services/MediaBridge.swift:24-44  PlayerEventDelegate`. The only mechanism for detecting that an AppleEvent was blocked by automation permissions.

  ```swift
  private final class PlayerEventDelegate: NSObject, SBApplicationDelegate, @unchecked Sendable {
      static let shared = PlayerEventDelegate()
      private override init() {}

      private(set) var lastErrorCode: Int = 0
      func resetLastError() { lastErrorCode = 0 }

      func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
          let code = (error as NSError).code
          lastErrorCode = code
          LogService.warn("MediaBridge: AppleEvent failed code=\(code) error=\(error.localizedDescription)", category: "media")
          if code == -1743 { MediaBridge.notifyPermissionDenied() }
          return nil
      }
  }
  ```

  **Gotcha:** This delegate is the **only** way to detect automation failures asynchronously. Without it, `SBApplication` methods **silently no-op** — your toggle/seek calls return `Void` whether they succeeded or were blocked by `errAEEventNotPermitted = -1743`. There is no synchronous return-code path.

  **Gotcha:** `SBApplication.delegate` is declared `unowned` (legacy ObjC API contract). The delegate **must** be retained elsewhere — we use a `static let shared` singleton so it lives forever. A local-scoped delegate would be deallocated by the next runloop tick and `eventDidFail` would never fire.

- **`isPlaying` via `playerState` enum** — `NemoNotch/Services/MediaBridge.swift:73-80  PlayerHandle.isPlaying` and per-app enums in `NemoNotch/Services/ScriptingBridge/MusicApplication.swift:25-31` and `NemoNotch/Services/ScriptingBridge/SpotifyApplication.swift:28-32`.

  ```swift
  var isPlaying: Bool? {
      switch self {
      case .spotify(let a): return a.playerState == .playing
      case .music(let a):
          let s = a.playerState
          return s == .playing || s == .fastForwarding || s == .rewinding
      }
  }
  ```

  **Gotcha:** Music has **5** states (`kPSS` stopped, `kPSP` playing, `kPSp` paused, `kPSF` fastForwarding, `kPSR` rewinding); Spotify has **3** (`kPSS`/`kPSP`/`kPSp`, no FF/REW). When you write generic state code, treat any **non-stopped, non-paused** state as "playing" — otherwise fast-forwarding Music tracks show up as paused for 200ms each scrub.

- **`setPlayerPosition` for seek** — `NemoNotch/Services/MediaBridge.swift:103-108  PlayerHandle.setPosition(_:)` and `191-195  MediaBridge.setPlayerPosition(bundleID:position:)`.

  ```swift
  func setPosition(_ value: Double) {
      switch self {
      case .spotify(let a): a.setPlayerPosition?(value)
      case .music(let a): a.setPlayerPosition?(value)
      }
  }
  ```

  **Gotcha:** The generated SB protocols mark `setPlayerPosition` `@objc optional` — you **must** call it with `?` and accept that nothing happens on an old/stripped Music binary. AppleScript `set player position` is the **only** way to seek Spotify reliably (MediaRemote silently drops the request, see [§7.2]). Music accepts both but AppleScript is the consistent path. See [§9] for the broader AppleScript story.

- **`hasAutomationAccess` and `requestPermissionIfNeeded`** — `NemoNotch/Services/MediaBridge.swift:142-163`. A synchronous probe and a once-per-bundleID permission prompt.

  ```swift
  static func hasAutomationAccess(bundleID: String?) -> Bool {
      guard let bundleID, let player = KnownPlayer(bundleID: bundleID) else { return false }
      guard isRunning(bundleID: bundleID) else { return false }
      PlayerEventDelegate.shared.resetLastError()
      _ = PlayerHandle.resolve(player)?.position
      return PlayerEventDelegate.shared.lastErrorCode != -1743
  }
  ```

  **Gotcha:** There is no API to *ask* macOS whether automation permission is granted. The probe pattern is: reset the delegate's error code, issue a **benign read** (`playerPosition`), then check whether the delegate captured `-1743`. The dialog itself is triggered by the same benign call — `requestPermissionIfNeeded` just records that we've fired the prompt once via `UserDefaults` so we don't re-prompt every launch.

### 7.4 — Reconcile pattern (optimistic UI + authoritative SB)

User taps play/pause → UI flips **instantly** to the new state (`isPlaying = !current`) and records a guard (`reconcileExpectedIsPlaying = newValue`). 0.5s later, `reconcilePlayState()` queries `MediaBridge.isPlaying(bundleID:)` (synchronous ScriptingBridge call — that's truth). Meanwhile, every `applyInfo()` from CLI polling checks the guard against `cliInfo.isPlaying`: if they disagree, **keep the expected value** (CLI is stale); when they agree, **clear the guard** (CLI caught up, safe to trust again).

- **Properties** — `NemoNotch/Services/MediaService.swift:26-31  reconcileExpectedIsPlaying`.

  ```swift
  // After an optimistic toggle we set `reconcileExpectedIsPlaying` to
  // the value we expect.  `applyInfo` must preserve it until
  // `reconcilePlayState` clears the flag and queries the authoritative
  // source (ScriptingBridge for known players, CLI otherwise).
  private var reconcileExpectedIsPlaying: Bool?
  ```

- **`togglePlayPause()` sets optimistic + guard, schedules reconcile** — `NemoNotch/Services/MediaService.swift:56-69  togglePlayPause()`.

  ```swift
  func togglePlayPause() {
      let bundleID = playbackState.appBundleIdentifier
      let target = !playbackState.isPlaying
      playbackState.isPlaying = target              // optimistic flip
      reconcileExpectedIsPlaying = target           // arm the guard
      updateProgressTimer(isPlaying: target)
      if MediaBridge.supportsSeeking(bundleID: bundleID) {
          MediaBridge.togglePlayPause(bundleID: bundleID)
      } else {
          remote.sendCommand(.togglePlayPause)
      }
      scheduleReconcile(after: 0.5)
  }
  ```

- **`reconcilePlayState()` queries the authoritative source** — `NemoNotch/Services/MediaService.swift:113-132  reconcilePlayState()`.

  ```swift
  private func reconcilePlayState() {
      let bundleID = playbackState.appBundleIdentifier
      if let playing = MediaBridge.isPlaying(bundleID: bundleID) {
          playbackState.isPlaying = playing
          updateProgressTimer(isPlaying: playing)
          // Keep guard set to SB value — applyInfo will auto-clear it
          // once CLI returns a matching value.
          reconcileExpectedIsPlaying = playing
      } else {
          reconcileExpectedIsPlaying = nil
          updateNowPlaying()
      }
  }
  ```

- **`applyInfo()` respects the guard until CLI catches up** — `NemoNotch/Services/MediaService.swift:287-306  applyInfo(_:)` (isPlaying resolution block).

  ```swift
  let cliPlaying = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0 > 0
  let resolvedIsPlaying: Bool
  if let expected = reconcileExpectedIsPlaying {
      if cliPlaying == expected {
          reconcileExpectedIsPlaying = nil          // CLI caught up — drop guard
          resolvedIsPlaying = cliPlaying
      } else {
          resolvedIsPlaying = expected              // guarded — ignore stale CLI
      }
  } else {
      resolvedIsPlaying = cliPlaying                // no guard active — trust CLI
  }
  ```

  **Gotcha:** If `reconcilePlayState` is removed or skipped, the guard never clears whenever CLI happens to never match the optimistic value (e.g. the player was actually never reachable) → UI gets stuck in optimistic state forever. The 0.5s delay in `scheduleReconcile(after: 0.5)` is **empirical**: shorter and the CLI hasn't caught up yet so `reconcilePlayState` re-arms the guard with the still-stale value; longer and the user notices visible stutter on rapid double-taps.

  **Gotcha:** The guard is `Bool?`, not `Bool`. `nil` means "no pending optimistic update; trust CLI". `applyInfo` must treat `nil` as "no guard active" and accept whatever CLI returns — otherwise the very first poll after a fresh launch would be filtered out and the UI would never paint.

  **Gotcha:** `MediaBridge.isPlaying(bundleID:)` returns **`nil`** for unknown bundleIDs and offline apps — that's why `reconcilePlayState` has a fallback branch that nils the guard and re-fires `updateNowPlaying()`. Don't conflate "false" with "nil" here: false means "the app reports paused", nil means "I cannot ask the app".

### 7.5 — Media seek decision tree

| Player | MediaRemote `skip` | `setElapsedTime` | AppleScript `set player position` | Use |
|---|---|---|---|---|
| Music | accepts | accepts | accepts | AppleScript (most reliable) |
| Spotify | rejects | silent fail | accepts | **AppleScript only** |
| Podcasts | accepts | accepts | no AS verb | MediaRemote |
| Safari/Chrome video | accepts | partial | no AS verb | MediaRemote |
| Unknown | try MR first | — | — | MediaRemote with fallback log |

The dispatch lives in `NemoNotch/Services/MediaService.swift:160-173  seek(toAbsolute:fallbackInterval:)`: known players (`KnownPlayer.init(bundleID:)` matches) go to `MediaBridge.setPlayerPosition` (AppleScript path); otherwise `remote.setElapsedTime`; if both fail, `remote.skip(interval:)` as the relative fallback.

**Reference projects:**
- *nowplaying-cli* — origin of the dylib-extraction + perl-daemon pattern (`NowPlayingCLI` is a direct adaptation).
- *PlayStatus* — MediaRemote private API loading (covered in [§4 Pattern B]) and the media-key interception story.
- *Tuneful* — ScriptingBridge approach for Music/Spotify control, including the `SBApplicationDelegate` error-capture pattern.

---

## 8. System sensing

Seven small subsystems for reading machine state. Each uses a different framework with different cleanup/polling rules; mixing them carelessly is how you leak kernel buffers or drain battery. Each subsystem below: anchor + minimal verbatim skeleton + the one gotcha that hurts most.

### 8.1 CPU — Mach `host_processor_info`

**Per-core ticks** — `NemoNotch/Services/SystemService.swift:80-118  updateCPU()`

```swift
var numCPU: natural_t = 0
var cpuInfo: processor_info_array_t?
var numCPUInfo: mach_msg_type_number_t = 0

let result = withUnsafeMutablePointer(to: &numCPU) { numCPUPtr in
    host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, numCPUPtr, &cpuInfo, &numCPUInfo)
}
guard result == KERN_SUCCESS, let cpuInfo else { return }

for i in 0 ..< Int(numCPU) {
    let idx = Int32(i) * Int32(CPU_STATE_MAX)
    let user = Double(cpuInfo[Int(idx + Int32(CPU_STATE_USER))])
    // … system / nice / idle, accumulate total + idle
}

let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
```

**Gotcha:** Forgetting `vm_deallocate` leaks kernel buffers every tick. The leak is **invisible to Instruments' default views** — you only notice when `vm_stat` shows wired memory creeping up over hours. CPU% is a delta against the previous sample (`prevTotal` / `prevIdle`); the first sample is meaningless.

### 8.2 Memory — Mach `host_statistics64`

**VM stats** — `NemoNotch/Services/SystemService.swift:120-136  updateMemory()`

```swift
var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
let statsPtr = UnsafeMutablePointer<vm_statistics64>.allocate(capacity: 1)
defer { statsPtr.deallocate() }
let result = host_statistics64(
    mach_host_self(),
    HOST_VM_INFO64,
    UnsafeMutableRawPointer(statsPtr).bindMemory(to: integer_t.self, capacity: Int(count)),
    &count
)
guard result == KERN_SUCCESS else { return }
let pageSize = UInt64(vm_kernel_page_size)
memoryUsed = (UInt64(statsPtr.pointee.active_count) + UInt64(statsPtr.pointee.wire_count)) * pageSize
```

**Gotcha:** The `count` parameter is the number of `integer_t` slots, not bytes. Compute it as `MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size` and pass the buffer rebound to `integer_t` — pass the wrong unit and the call returns `KERN_INVALID_ARGUMENT` silently. Also: "memory used" = `active + wire`; including `inactive` overcounts because macOS keeps freed pages around speculatively.

### 8.3 Process enumeration — `libproc`

**Two-call buffer + per-PID task info** — `NemoNotch/Services/SystemService.swift:219-270  updateProcesses()`

```swift
// 1) Probe required buffer size
let bufferCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
guard bufferCount > 0 else { return }
let pidCount = Int(bufferCount) / MemoryLayout<Int32>.size
var pids = [Int32](repeating: 0, count: pidCount)

// 2) Fill it
let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(bufferCount))
guard actualSize > 0 else { return }

for i in 0 ..< Int(actualSize) / MemoryLayout<Int32>.size {
    let pid = pids[i]; guard pid > 0 else { continue }
    var taskInfo = proc_taskinfo()
    let infoSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
    guard infoSize > 0 else { continue }
    let totalTicks = UInt64(taskInfo.pti_total_user) + UInt64(taskInfo.pti_total_system)
    let memoryBytes = UInt64(taskInfo.pti_resident_size)
    // … delta vs prevProcessTicks[pid], convert to CPU% over elapsed
}
```

**Gotcha:** `proc_pidinfo` returns `0` (not the requested struct size) on permission-denied PIDs — kernel processes you don't own. Treat zero/negative as "skip"; never assume the struct was filled. Also: `pti_total_user` / `pti_total_system` are in **nanoseconds**, not jiffies — divide by elapsed × `processorCount` × 1e9 for percent.

### 8.4 Battery polling — IOPS snapshot

**One-shot capacity / charging** — `NemoNotch/Services/SystemService.swift:138-155  updateBattery()`

```swift
guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

for source in sources {
    guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
    else { continue }
    if let capacity = info[kIOPSCurrentCapacityKey] as? Int { batteryLevel = capacity }
    if let charging = info[kIOPSIsChargingKey] as? Bool { isCharging = charging }
    if let time = info[kIOPSTimeToEmptyKey] as? Int { timeRemaining = time }
}
```

**Gotcha:** `IOPSCopyPowerSourcesInfo` is `Copy` (Create Rule) — `takeRetainedValue()`. `IOPSGetPowerSourceDescription` is `Get` — `takeUnretainedValue()`. Mixing them either leaks or crashes. On Macs without a battery (mini, Studio) `sources` is empty — the loop body never runs, so guard your UI against the "never updated" state rather than the "value is zero" state.

### 8.5 Battery notification — IOPS runloop source

**Push-based variant** — `NemoNotch/Services/HUDService.swift:220-236  setupBatteryMonitoring()`

```swift
let context = Unmanaged.passUnretained(self).toOpaque()
guard let unmanagedSource = IOPSNotificationCreateRunLoopSource(
    { context in
        guard let context else { return }
        let service = Unmanaged<HUDService>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { service.readBattery() }
    },
    context
) else { return }
let source = unmanagedSource.takeRetainedValue() as CFRunLoopSource
batteryRunLoopSource = source
CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
```

**Gotcha:** The callback runs on whichever runloop you added the source to — and it's a C function pointer, so **no `@MainActor` inference**. If your service is `@MainActor`-isolated (this one is), you must hop with `DispatchQueue.main.async` before touching state. Skip the hop and Swift 6 will catch it as a data-race; pre-Swift-6 it will silently corrupt. Recover the receiver via `Unmanaged.fromOpaque(...).takeUnretainedValue()` to match the `passUnretained` you handed in.

### 8.6 Brightness — DisplayServices, adaptive polling

DisplayServices loading (`dlopen` + `dlsym`) is covered in [§4.1]; here is the **usage + polling cadence**.

**Adaptive polling loop** — `NemoNotch/Services/HUDService.swift:186-216  readBrightness()`

```swift
private func readBrightness() {
    guard let brightness = getBrightness() else { return }

    if lastBrightness >= 0, abs(brightness - lastBrightness) > 0.01 {
        showHUD(.brightness, value: brightness)
        brightnessTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.readBrightness() }
        }
        brightnessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    } else if lastBrightness >= 0,
              let timer = brightnessTimer, timer.timeInterval < 1.0 {
        timer.invalidate()
        // … reschedule at 1.0s
    }
    lastBrightness = brightness
}
```

**Gotcha:** **No interrupt mechanism exists.** DisplayServices does not post a notification when brightness changes — we *must* poll. Idle cadence is 1.0s; after detecting a change we drop to 0.1s for responsiveness, then climb back to 1.0s after a tick of stability. Constant 0.1s polling drains battery noticeably on idle MacBooks (the `dlsym`'d call is cheap but the timer-induced wakeups are not).

### 8.7 Volume — Core Audio listener with device rebind

**System-wide listener + default-device watcher** — `NemoNotch/Services/HUDService.swift:72-123  setupVolumeListener()`

```swift
// Prefer VirtualMainVolume (system-wide), fall back to per-device VolumeScalar
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
)
if !AudioObjectHasProperty(deviceID, &address) {
    address.mSelector = kAudioDevicePropertyVolumeScalar
}
volumeListener = { [weak self] _, _ in
    DispatchQueue.main.async { self?.readVolume() }
}
AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, volumeListener!)

// Also rebind when the default output device changes (AirPods connect, etc.)
var devChangeAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devChangeAddr, DispatchQueue.main) { [weak self] _, _ in
    DispatchQueue.main.async { self?.rebindVolumeListener() }
}
```

**Gotcha:** When the default output device changes (AirPods connect, monitor unplugs) the listener attached to the **old** device keeps existing but **stops firing** — its device is no longer routed. You must observe `kAudioHardwarePropertyDefaultOutputDevice`, then `AudioObjectRemovePropertyListenerBlock` on the old device and re-add on the new one. Forget this and "the volume HUD just stopped working" after switching audio sinks. Bonus: `VirtualMainVolume` doesn't exist on every device — probe with `AudioObjectHasProperty` first, fall back to `VolumeScalar`.

### 8.8 Network counters — BSD `getifaddrs`

**Per-interface byte totals + delta** — `NemoNotch/Services/SystemService.swift:169-215  updateNetwork()`

```swift
var ifaddr: UnsafeMutablePointer<ifaddrs>?
guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
defer { freeifaddrs(ifaddr) }

var totalIBytes: UInt64 = 0
var totalOBytes: UInt64 = 0
var ptr = firstAddr
while true {
    let addr = ptr.pointee
    let name = String(cString: addr.ifa_name)
    if name != "lo0", addr.ifa_addr.pointee.sa_family == AF_LINK,
       let data = addr.ifa_data {
        let nd = data.assumingMemoryBound(to: if_data.self)
        totalIBytes += UInt64(nd.pointee.ifi_ibytes)
        totalOBytes += UInt64(nd.pointee.ifi_obytes)
    }
    guard let next = addr.ifa_next else { break }
    ptr = next
}
// Compute deltas against last sample; downloadSpeed = (totalIBytes - lastTotalIBytes) / elapsed
```

**Gotcha:** Counters are **cumulative since boot**, not per-interval — compute deltas yourself (store `lastTotalIBytes` / `lastTotalOBytes` + sample time, subtract per tick). Skip the very first sample (no baseline) or you'll report a gigabyte-per-second spike. On rare 32-bit counter wraparound the delta goes negative; clamp to zero rather than trusting the math. And **always** `freeifaddrs` (the `defer` above) — the linked list is heap-allocated and the leak grows with every call.

### 8.9 Disk capacity — `URLResourceValues`

**Volume total + "important usage" free space** — `NemoNotch/Services/SystemService.swift:157-165  updateDisk()`

```swift
private func updateDisk() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let values = try? home.resourceValues(forKeys: [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
    ])
    diskTotal = UInt64(values?.volumeTotalCapacity ?? 0)
    diskFree = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
}
```

**Gotcha:** Use `.volumeAvailableCapacityForImportantUsageKey`, **not** `.volumeAvailableCapacityKey`. The former is what "About This Mac → Storage" shows: it excludes purgeable caches the OS will reclaim under pressure. The latter is the raw filesystem free count and is always smaller — sometimes by tens of GB — which alarms users into thinking the disk is full when it isn't.

**Gotcha:** Pass a URL on the **data volume** (home directory works). On Apple Silicon, passing `/` queries the signed system volume (SSV), which is read-only and reports near-zero free space — a confusing zero rather than a sensible number.

### 8.10 Reference projects

- *eul* — reference for `host_processor_info` / `host_statistics64` and the system-monitor menubar UI style; their per-core CPU sampling is the direct ancestor of [§8.1].
- *MonitorControl* — original discovery of `DisplayServicesGetBrightness()` private API + the `dlopen` recipe used in [§4.1] and [§8.6].

---

## 9. ScriptingBridge & AppleScript

NemoNotch uses **ScriptingBridge with generated Swift protocols** instead of `osascript` strings. This section covers how those protocol files were produced, the AE keyword codes embedded in them, and the decision rule for when AppleScript wins over MediaRemote. SBApplication wiring and AE-error detection are in [§7.3] — not repeated here.

### 9.1 How the generated headers were produced

`MusicApplication.swift` and `SpotifyApplication.swift` are Swift ports of headers originally generated by `sdef Music.app | sdp -fh --basename MusicApplication` (which emits **Objective-C**), then hand-translated to Swift `@objc` protocols. Both files cite their upstream gists in their header comments — Music from `gist.github.com/jkelol111/5754a3d3f1d05df3434447b2714f38da`, Spotify from `gist.github.com/gf3/d622d927496d50c6108fd6ea36619bdf`. The same pipeline works for any scriptable app: `sdef /Applications/Foo.app | sdp -fh --basename FooApplication` → port to Swift.

- **Gotcha:** Apple ships no pre-generated Swift output for `sdef` — `sdp` only emits Objective-C, so the Swift port is hand-done. Budget ~1 hour to add a new bridged app (e.g. VLC) and verify every verb compiles + dispatches.
- **Gotcha:** Generated headers lag the target app. If Spotify or Music adds a new AppleScript verb in an OS update, this file won't have it until you regenerate — silent feature gap, no compiler warning.

### 9.2 Protocol structure & AE keyword codes

Anchor: `NemoNotch/Services/ScriptingBridge/MusicApplication.swift:L24-L31, L131-L195  protocol MusicApplication + MusicEPlS enum`.

```swift
// MARK: MusicEPlS — the AE keyword enum for player state
@objc public enum MusicEPlS : AEKeyword {
    case stopped         = 0x6b505353 /* b'kPSS' */
    case playing         = 0x6b505350 /* b'kPSP' */
    case paused          = 0x6b505370 /* b'kPSp' */
    case fastForwarding  = 0x6b505346 /* b'kPSF' */
    case rewinding       = 0x6b505352 /* b'kPSR' */
}

// MARK: MusicApplication — only the verbs NemoNotch actually calls
@objc public protocol MusicApplication: SBApplicationProtocol {
    @objc optional var playerState: MusicEPlS { get }
    @objc optional var playerPosition: Double { get }
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func previousTrack()
    @objc optional func setPlayerPosition(_ playerPosition: Double)
}
extension SBApplication: MusicApplication {}
```

- **Gotcha:** AE keyword codes are **4-byte big-endian ASCII**. `'kPSP'` packs as `0x6b 50 53 50` = `0x6b505350` ("playing" in Music). To look up an unknown code, dump the relevant sdef: `xxd /System/Applications/Music.app/Contents/Resources/Music.sdef | grep kPSP`. Don't try to decode them in your head — reverse-byte-order mistakes are easy and silent.
- **Gotcha:** Every verb is `@objc optional`, so the call site must use `?` and tolerate `nil`. Some bridged apps (e.g. Podcasts) don't implement `setPlayerPosition` at all — see [§7.5] for the seek fallback table.

### 9.3 SBApplication wiring + AE error detection

See [§7.3] for `SBApplication(bundleIdentifier:)` resolution, the `SBApplicationDelegate.eventDidFail` async error capture, and the `-1743` (`errAEEventNotPermitted`) recovery flow. Repeating only the load-bearing fact: `errAEEventNotPermitted = -1743` is the code macOS returns when the user has not granted Automation permission in System Settings — see also [§11.2] for the TCC prompt UX.

### 9.4 Why ScriptingBridge beats `osascript`

A `grep -r osascript NemoNotch/` returns **nothing** — this codebase exclusively uses ScriptingBridge. The reasons:

- **SB pros:** generated `@objc` protocol gives compile-time type checking on verb names and argument types; calls dispatch in-process via the Objective-C runtime (no fork/exec per command); microseconds per call vs. tens of milliseconds for `osascript`. Critical for the play-state reconcile loop in [§7.3] which polls every 0.5s.
- **`osascript` pros:** opaque string at runtime — fine for one-off shell glue or scripts that have to call verbs missing from your generated protocol. Never put it on a hot path.

- **Gotcha:** A small set of `.sdef` verbs are reachable only from compiled AppleScript, not from SB protocols (compound terminology references, `tell ... to ...` blocks with non-trivial coercions). If a method "just doesn't exist" in your generated Swift, fall back to `NSAppleScript` — still in-process, no fork/exec — but you trade type safety for a runtime-evaluated string.

### 9.5 Decision rule: AppleScript vs MediaRemote

**The rule:** *If the app implements an AppleScript verb (its `.sdef` lists it), use AppleScript via SB. Only fall back to MediaRemote if the verb is missing or known-broken for that app.*

Concrete cases (cross-link [§7.5]):

- Spotify `set player position` → **SB only**. MediaRemote's `SkipBackward`/`SkipForward` are silently rejected by Spotify with "never supported".
- Music `set player position` → **SB preferred** over MediaRemote `setElapsedTime` (more reliable, no race against the system info center).
- Podcasts seek → **MediaRemote only** — no AppleScript seek verb in its sdef.

---

## 10. Accessibility & Dock badges

NemoNotch reads notification badge text from Dock tiles (e.g. "3" on Messages, "12" on Mail) via the Accessibility API. The walk is recursive, the badge attribute is undocumented, and the text may contain invisible Unicode marks that break naive string equality.

### 10.1 `AXIsProcessTrusted` gate

**Trust check** — `NemoNotch/Services/NotificationService.swift:14,84  init / pollDock()`

```swift
// Read-only probe — never prompts
var isAXTrusted: Bool = AXIsProcessTrusted()

// Inside pollDock(), re-read each tick so UI reflects flips
isAXTrusted = AXIsProcessTrusted()

// One-shot prompt (call once at first launch; not used in current code)
// let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
// _ = AXIsProcessTrustedWithOptions(opts)
```

- **Gotcha:** The prompt **only appears once per app version (bundle signature)**. If the user denies, subsequent `AXIsProcessTrustedWithOptions` calls silently return false — you must direct them to *System Settings → Privacy & Security → Accessibility* manually. NemoNotch surfaces this via `openAccessibilitySettings()` which opens the panel deeplink. Cross-link [§11.3].
- **Gotcha:** Granting accessibility while the app is running does **not** always pick up immediately. Either poll `AXIsProcessTrusted()` on a timer (NemoNotch re-reads it every 2s inside `pollDock()`) or prompt the user to relaunch.

### 10.2 `AXUIElementCreateApplication(dockPID)`

**Dock handle** — `NemoNotch/Services/NotificationService.swift:93-100  pollDock()`

```swift
guard let dockPID = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.dock"
).last?.processIdentifier else {
    LogService.warn("NotificationService: Dock not found", category: "Notification")
    return
}
let dockApp = AXUIElementCreateApplication(dockPID)
```

- **Gotcha:** The Dock may briefly have **no PID during respawns** (kill+restart cycles, OS updates, `killall Dock`). Always handle nil and retry on the next poll tick — never crash.
- **Gotcha:** Use `.last` not `.first` — during a Dock relaunch transition you can transiently see two PIDs; the newer one is the live process.

### 10.3 Recursive `AXChildren` walk

**Tree traversal** — `NemoNotch/Services/NotificationService.swift:187-205  getSubElements(root:)`

```swift
private func getSubElements(root: AXUIElement) -> [AXUIElement] {
    var count: CFIndex = 0
    let err = AXUIElementGetAttributeValueCount(root, "AXChildren" as CFString, &count)
    guard err == .success, count > 0 else { return [] }

    var children: CFArray?
    let copyErr = AXUIElementCopyAttributeValues(
        root, "AXChildren" as CFString, 0, count, &children)
    guard copyErr == .success, let elements = children as? [AXUIElement] else {
        return []
    }

    var result: [AXUIElement] = []
    result.append(contentsOf: elements)
    for element in elements {
        result.append(contentsOf: getSubElements(root: element))
    }
    return result
}
```

- **Gotcha:** `AXUIElementCopyAttributeValues` returns `kAXErrorNoValue` (or count == 0) on leaf nodes; bail early via the `count > 0` guard rather than treating it as a hard error. It's a normal "leaf" signal.
- **Gotcha:** Dock tiles nest several AX children (icon, label, badge container). Don't assume a fixed depth — recurse until you exhaust the subtree, then filter by attribute at the call site.

### 10.4 `kAXTitleAttribute` and `"AXStatusLabel"` for badge text

**Badge extraction** — `NemoNotch/Services/NotificationService.swift:129-146  pollDock() match loop`

```swift
for element in allElements {
    var title: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    guard err == .success, let titleStr = title as? String else { continue }
    let normalized = normalizeName(titleStr)
    guard let bundleID = nameToBundleID[normalized] else { continue }

    var statusLabel: AnyObject?
    AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &statusLabel)
    let label = statusLabel as? String ?? ""
    // parseBadgeCount(label) -> Int? ("3" -> 3, "•" -> 0, "" -> nil)
}
```

- **Gotcha:** `"AXStatusLabel"` is **not in the public `kAX*` enum** — pass it as a CFString literal. Returns nil for tiles without badges. The attribute is undocumented and could change between macOS versions; log the raw value so you notice regressions.
- **Gotcha:** Some apps publish **duplicate Dock tiles** with the same normalized title (WhatsApp at times). Iterate all matches and prefer the one whose `AXStatusLabel` is non-empty.

### 10.5 Unicode LRM / RLM normalization

**Invisible mark stripper** — `NemoNotch/Services/NotificationService.swift:65-70  normalizeName(_:)`

```swift
private func normalizeName(_ name: String) -> String {
    name.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0)
            && !($0.properties.generalCategory == .format)
    }.map(String.init).joined()
}
// Equivalent targeted form for known marks:
// name.replacingOccurrences(of: "\u{200E}", with: "")  // LRM
//     .replacingOccurrences(of: "\u{200F}", with: "")  // RLM
//     .replacingOccurrences(of: "\u{FEFF}", with: "")  // ZWNBSP
```

- **Gotcha:** **WhatsApp's Dock tile title contains a hidden `U+200E` LEFT-TO-RIGHT MARK.** Naive `titleStr == "WhatsApp"` (or dictionary lookup keyed on the plain name) fails silently — the badge appears in the Dock but never reaches your observer. Some CJK-locale builds also embed `U+FEFF` (ZWNBSP). Normalize *both* sides (the AX title **and** `NSRunningApplication.localizedName`) before any comparison.
- **Gotcha:** Don't reach for `precomposedStringWithCompatibilityMapping` — it mangles emoji and ligatures in app names. Filtering by Unicode general category `Cf` (Format) + control characters is targeted and safe.

### 10.6 Reference projects

- **DockDoor** — related Dock-interaction patterns: SCWindow for window thumbnails, AXUIElement for window control. Useful when extending beyond badge reading into per-tile window manipulation.

---

## 11. Permissions playbook

macOS permission flows are silent-failure-prone: missing Info.plist keys disable dialogs without errors, denials can't always be detected synchronously, and granting at runtime often requires app relaunch. This section is the per-permission recipe: **what to request, how to detect denial, how to recover**.

### 11.1 Calendar (EventKit)

Required Info.plist key: `INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription` (declared in `project.pbxproj`; see [§3] for why source `Info.plist` is ignored under `GENERATE_INFOPLIST_FILE = YES`).

`NemoNotch/Services/CalendarService.swift:33-67  init / requestAccess / openSystemSettings`:

```swift
init() {
    authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    requestAccessIfNeeded()
    NotificationCenter.default.addObserver(
        self, selector: #selector(eventsChanged),
        name: .EKEventStoreChanged, object: nil
    )
}

func requestAccess() {
    Task { @MainActor in
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            authorizationStatus = granted ? .fullAccess : .denied
            if granted { fetchEvents() }
        } catch {
            authorizationStatus = .denied
        }
    }
}

func openSystemSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
        NSWorkspace.shared.open(url)
    }
}
```

- **Gotcha:** macOS 14+ uses `.fullAccess` / `.writeOnly` / `.denied` enum cases; older code using `.authorized` is **deprecated** and produces a runtime warning. Use the newer API and gate with `if #available(macOS 14, *)` if you must support older OS.
- **Gotcha:** `EKEventStoreChanged` fires on **any change anywhere** — including iCloud-pushed edits while the user is in Calendar.app. Debounce before re-querying, otherwise you'll hammer EventKit during sync storms.

### 11.2 Apple Events / Automation

Required Info.plist key: `INFOPLIST_KEY_NSAppleEventsUsageDescription` (must be declared in `project.pbxproj` — see [§3]).

- **Gotcha (the big one):** Without `NSAppleEventsUsageDescription`, macOS **silently refuses** to show the automation prompt. System Settings → Privacy & Security → Automation **won't even list your app**. The first time we hit this, it took a full day of debugging because the failure mode is **invisible**. Verify the built `.app` actually has the key: `/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" build/Release/NemoNotch.app/Contents/Info.plist`.

Detect denial via the SBApplication delegate's async error callback. `NemoNotch/Services/MediaBridge.swift:35-43  PlayerEventDelegate.eventDidFail` (see also [§7.3]):

```swift
func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
    let code = (error as NSError).code
    lastErrorCode = code
    if code == -1743 {           // errAEEventNotPermitted
        MediaBridge.notifyPermissionDenied()
    }
    return nil
}
```

Recovery — `MediaBridge.swift:207-210  openAutomationSettings()`:

```swift
static func openAutomationSettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    NSWorkspace.shared.open(url)
}
```

- **Gotcha:** Detecting denial **post-call** via AE error `-1743` is the only async-safe signal. There is no synchronous "do I have permission?" API — `MediaBridge.hasAutomationAccess` works only by performing a benign read and inspecting the delegate's `lastErrorCode` afterward. The recovery flow must trigger a benign AS call, watch the delegate, and notify the user if it fails.

### 11.3 Accessibility

No Info.plist key required.

See [§10.1] for the canonical `AXIsProcessTrusted()` + `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` pattern — don't duplicate.

Recovery URL is cited verbatim in `NemoNotch/Services/NotificationService.swift:50-53`:

```swift
func openAccessibilitySettings() {
    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    NSWorkspace.shared.open(url)
}
```

- **Gotcha:** Granting Accessibility while the app is **already running** does **not** automatically pick up. The user must either relaunch or you must poll `AXIsProcessTrusted()` and trigger a soft-relaunch flow. There is no NotificationCenter event for "accessibility was granted".

### 11.4 Notifications

**Not currently used by NemoNotch.** No `UNUserNotificationCenter` references exist in the source. Standard pattern:

```swift
UNUserNotificationCenter.current()
    .requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        // granted == false on user denial; error is non-nil only on system failures
    }
// Query existing state without re-prompting:
UNUserNotificationCenter.current().getNotificationSettings { settings in
    // settings.authorizationStatus: .notDetermined / .denied / .authorized / .provisional
}
```

- **Gotcha:** All options (`.alert`, `.sound`, `.badge`, `.provisional`) must be requested **up-front**. Adding `.sound` later requires a **fresh authorization request** and **re-prompts** the user. Plan your option set carefully.

### 11.5 Cross-cutting summary

| Permission | Info.plist key | Async request API | Detect denial | Recovery |
|---|---|---|---|---|
| Calendar | `NSCalendarsFullAccessUsageDescription` | `EKEventStore.requestFullAccessToEvents` | check return / `authorizationStatus == .denied` | `Privacy_Calendars` URL |
| Automation | `NSAppleEventsUsageDescription` | first SB call triggers system dialog | AE error `-1743` in `SBApplicationDelegate.eventDidFail` | `Privacy_Automation` URL |
| Accessibility | (none) | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` | `AXIsProcessTrusted()` poll | `Privacy_Accessibility` URL |
| Notifications | (none) | `UNUserNotificationCenter.requestAuthorization` | `getNotificationSettings` callback | `Privacy_Notifications` URL |

**Universal gotcha:** for any permission, the prompt only fires on the **first call after first launch**. Subsequent denials are silent. Always have a recovery UI path that opens the relevant Settings pane via `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:...")!)` or surfaces manual instructions.

### 11.6 Reactive permission state (immediate UI update)

§11.1–§11.3 each describe a different *detection* mechanism. The "UI refreshes the moment the user toggles permission in System Settings" effect comes from a separate layer: `@Observable` + SwiftUI. macOS has no unified "permission granted" notification — bridging detection to the UI is on you, and the bridge differs per permission.

The pattern is the same shape every time:

1. The Service is `@Observable` with the permission state as a **stored property** (`authorizationStatus`, `isAXTrusted`, …).
2. The detection mechanism writes to that property (NotificationCenter handler, Timer tick, or async delegate callback).
3. Views inject the Service via `@Environment` — SwiftUI's dependency tracking re-renders them when the property changes.

Per-permission bridges:

| Permission | What writes the `@Observable` property | Latency | Anchor |
|---|---|---|---|
| Calendar | `.EKEventStoreChanged` NotificationCenter handler → `authorizationStatus` | ~immediate | `CalendarService.swift:9, 37-42` |
| Accessibility | 2 s Timer re-reads `AXIsProcessTrusted()` → `isAXTrusted` | ≤ 2 s | `NotificationService.swift:14, 84` |
| Automation | `SBApplicationDelegate.eventDidFail` (`-1743`) → `MediaBridge.notifyPermissionDenied()` | on next AS call | `MediaBridge.swift:35-43` |

```swift
// Calendar — system pushes a notification, handler writes the @Observable property
@Observable final class CalendarService {
    var authorizationStatus: EKAuthorizationStatus = .notDetermined
    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(eventsChanged),
            name: .EKEventStoreChanged, object: nil)
    }
}

// Accessibility — no notification exists; poll into the @Observable property
@Observable final class NotificationService {
    var isAXTrusted: Bool = AXIsProcessTrusted()
    private func pollDock() {
        isAXTrusted = AXIsProcessTrusted()   // re-read each 2 s tick
        // …
    }
}
```

- **Gotcha:** Accessibility has *no* NotificationCenter event for "granted" (called out in §11.3) — polling is the only way to surface a grant without relaunch. Pick a cadence the user perceives as immediate (≤ 2 s) but doesn't burn cycles.
- **Gotcha:** Don't keep permission state outside the `@Observable` class (e.g. as a `static let` cache or a global enum). SwiftUI's tracking only sees stored properties on the observed instance — writes elsewhere don't trigger re-render and the UI stays stale.
- **Why this matters:** Without the `@Observable` bridge, every dependent View has to poll on its own or listen to a custom notification. Funnelling all permission state through Service properties keeps detection logic in one place and lets the UI stay declarative.

---

## 12. IPC & subprocess

NemoNotch acts as an IPC hub for AI CLIs: it runs a Unix-socket server that receives hook events, spawns helper subprocesses (covered in [§7.1]), and watches conversation files for incremental updates. Three patterns: socket server, file watcher, and JSONL parser.

### 12.1 Unix-socket server

#### Socket setup
Anchor `NemoNotch/Services/HookServer.swift:23-69  doStart()`.

```swift
nonisolated private func doStart(socketPath: String) {
    unlink(socketPath)
    socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFd >= 0 else { /* … */ return }

    var optval: Int32 = 1
    setsockopt(socketFd, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout.size(ofValue: optval)))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = socketPath.withCString { ptr in strncpy(&addr.sun_path.0, ptr, 103) }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
    }
    guard bind(socketFd, bindResult, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 else { /* … */ return }
    guard listen(socketFd, 10) == 0 else { /* … */ return }
    // … set up acceptSource
}
```

**Gotcha:** `sockaddr_un.sun_path` is a **fixed-size 104-byte buffer** on Darwin (note the `strncpy(..., 103)` to leave room for the NUL terminator). Long paths under `~/Library/Application Support/...` won't fit — use a short path like `/tmp/com.nemonotch.hook`.

**Gotcha:** `unlink` on the stale socket path before `bind` is mandatory — a previous crash leaves a stale socket file on disk and `bind` returns `EADDRINUSE` until you remove it. See critical pitfall in [§2].

#### `DispatchSourceRead` accept loop
Anchor `HookServer.swift:63-82  acceptSource setup + acceptConnection()`.

```swift
acceptSource = DispatchSource.makeReadSource(fileDescriptor: socketFd, queue: socketQueue)
acceptSource?.setEventHandler { [weak self] in self?.acceptConnection() }
acceptSource?.resume()

nonisolated private func acceptConnection() {
    var addr = sockaddr_un()
    var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let clientFd = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebased in
            accept(socketFd, rebased, &addrLen)
        }
    }
    guard clientFd >= 0 else { return }
    readRequest(fd: clientFd)
}
```

**Gotcha:** `socketFd` and `acceptSource` are declared `@ObservationIgnored nonisolated(unsafe)` because they're touched from `socketQueue`, not the MainActor. Re-dispatch back via `DispatchQueue.main.async { ... }` (or `Task { @MainActor in ... }`) before mutating any `@Observable` state. See [§15] for the actor-isolation rules.

#### Line-delimited JSON read
Anchor `HookServer.swift:84-115  readRequest()`.

```swift
nonisolated private func readRequest(fd: Int32) {
    var buffer = Data()
    var tempBuf = [UInt8](repeating: 0, count: 4096)
    while true {
        let bytesRead = read(fd, &tempBuf, tempBuf.count)
        if bytesRead > 0 {
            buffer.append(tempBuf, count: bytesRead)
            if let str = String(data: buffer, encoding: .utf8), str.hasSuffix("\n") { break }
        } else { break }
    }
    guard let message = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !message.isEmpty else { close(fd); return }
    // … JSON-decode HookEvent and dispatch
}
```

**Gotcha:** Partial messages can straddle buffer boundaries. The loop accumulates into `buffer` until it sees a trailing newline or EOF — don't assume a single `read()` returns a complete message. Also log payload **size only**, never content, since hook bodies contain conversation text and file paths.

#### Permission-request waiter pattern
Anchor `HookServer.swift:139-155  handlePermissionRequest()`.

```swift
nonisolated private func handlePermissionRequest(_ event: HookEvent, fd: Int32) {
    guard let sessionId = event.sessionId else {
        sendResponse(fd: fd, response: #"{"decision":"deny","reason":"no session id"}"#)
        return
    }
    let waitKey = sessionId + ":" + (event.toolUseId ?? UUID().uuidString)
    responseWaiters[waitKey] = { [weak self] response in
        self?.sendResponse(fd: fd, response: response)
    }
    socketQueue.asyncAfter(deadline: .now() + 120) { [weak self] in
        if let waiter = self?.responseWaiters.removeValue(forKey: waitKey) {
            waiter(#"{"decision":"deny","reason":"timeout"}"#)
        }
    }
}
```

**Gotcha:** Each waiter must fire **exactly once**. The pattern relies on `removeValue(forKey:)` being atomic on the dictionary — whichever path (real response, 120s timeout, or session cancel) wins the removal owns the response. All three writers run on the same `socketQueue`, which serializes the race; if you ever move them off, switch to a `Set<String>` of completed IDs or an explicit lock.

### 12.2 Subprocess (`Process` + `Pipe`)

See [§7.1 NowPlayingCLI] for the canonical `Process` + `Pipe` daemon pattern — long-lived perl spawn, stdin/stdout line-delimited JSON protocol, daemon retention, and semaphore-based timeout/fallback. Two additional gotchas relevant beyond §7.1:

**Gotcha:** Spawned daemons inherit the parent's signal mask. If you `signal(SIGPIPE, SIG_IGN)` in the parent (NemoNotch does — see [§7.1]) the child inherits it too, unless the child explicitly resets via `signal(SIGPIPE, SIG_DFL)`. Symptom: child happily writes to a closed pipe and wedges instead of dying.

**Gotcha:** `Process.environment` defaults to **`nil`**, which inherits the parent environment — but the moment you set `currentDirectoryURL` and start passing your own `environment` dict, you must explicitly merge in `ProcessInfo.processInfo.environment` or the child loses `PATH`, `HOME`, `LANG`, etc. and helper binaries fail to resolve.

### 12.3 File watching with `DispatchSourceFileSystemObject`

Anchor `NemoNotch/Services/AgentFileWatcher.swift:55-72  beginWatching()`.

```swift
private func beginWatching() {
    guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return }
    self.fileHandle = handle
    let fd = handle.fileDescriptor
    source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .extend],
        queue: queue
    )
    source?.setEventHandler { [weak self] in self?.parseFile() }
    parseFile()
    source?.resume()
}
```

**Gotcha:** `FileHandle(forReadingFrom:)` opens with normal read semantics, which keeps the descriptor valid against `unlink`. But if you use `O_EVTONLY` directly and the file is **replaced** (log rotation, atomic rename via `mv`), the source stops firing because the watched inode is gone. Subscribe to `.delete` / `.rename` in the `eventMask` and re-open on those events.

### 12.4 Incremental offset + `pendingTail`

Anchor `AgentFileWatcher.swift:74-114  parseFile()`.

```swift
private func parseFile() {
    guard let handle = fileHandle else { return }
    do { try handle.seek(toOffset: readOffset) } catch { return }
    guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }
    readOffset += UInt64(chunk.count)

    var buffer = pendingTail
    buffer.append(chunk)
    pendingTail.removeAll(keepingCapacity: true)

    let newline = UInt8(ascii: "\n")
    var lineStart = buffer.startIndex
    for i in buffer.indices {
        if buffer[i] == newline {
            // … processLine(buffer.subdata(in: lineStart..<i))
            lineStart = buffer.index(after: i)
        }
    }
    if lineStart < buffer.endIndex {
        pendingTail = buffer.subdata(in: lineStart..<buffer.endIndex)
    }
}
```

**Gotcha:** If the file is **truncated or replaced** (`> file`, log rotation), `readOffset` is now past EOF and `seek` either fails silently or `readToEnd` returns empty forever. Before seeking, stat the file: if `fileSize < readOffset`, reset `readOffset = 0` and clear `pendingTail` — otherwise the watcher goes deaf for the lifetime of the process.

### 12.5 JSONL incremental parsing (Claude)

Anchor `NemoNotch/Services/ConversationParser.swift:46-104  parseIncremental()`.

```swift
static func parseIncremental(filePath: String, fromOffset: UInt64) -> ParseResult {
    var result = ParseResult(/* … */ newOffset: fromOffset, interrupted: false, cleared: false)
    guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return result }
    defer { try? fileHandle.close() }
    if fromOffset > 0 { try? fileHandle.seek(toOffset: fromOffset) }
    guard let data = try? fileHandle.readToEnd() else { return result }
    guard let text = String(data: data, encoding: .utf8) else { return result }
    result.newOffset = fromOffset + UInt64(data.count)

    for line in text.components(separatedBy: "\n") {
        guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
        if json["type"] as? String == "assistant",
           let message = json["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            result.lastContextTokens = input + cacheRead + cacheCreation
            // … accumulate output_tokens, model name, message body
        }
    }
    return result
}
```

**Gotcha:** Claude JSONL distinguishes `assistant` from `user` events; **only `assistant` events carry a `usage` block** with token counts. `cache_read_input_tokens` and `cache_creation_input_tokens` are **optional** — default to 0 when absent, otherwise the optional cast crashes the running total on older sessions or non-cached calls.

### 12.6 Reference projects (inline pointer)

- *masko-code* — origin of the Unix Socket event delivery + `HookInstaller` writing to `~/.claude/settings.json` pattern; see [§13] for the installer side.

---

## 13. Hook installers

NemoNotch installs shell-based hook entries into AI CLI config files so the CLIs forward tool events to NemoNotch's Unix socket (see [§12.1]). Three targets, two formats (JSON for Claude/Gemini, YAML for Hermes). The shared invariant is **idempotent install**: re-running install must never produce duplicate entries.

### 13.1 The idempotent install pattern (the load-bearing idea)

```
read existing JSON/YAML config
for each event-array in the config:
    REMOVE all entries whose command path is under ~/.nemonotch/hooks/
for each currently-enabled event in our settings:
    APPEND a fresh entry
write back
```

`HookInstaller.install` first walks every existing event bucket and strips entries pointing at our script, then re-adds the current event set. `HermesHookInstaller` does the same with line-based YAML mutation. Without the remove-pass, each install duplicates entries.

**Gotcha:** The "remove all `nemonotch` entries first" step is what makes re-install safe across versions. If you only *append*, every install duplicates. This is the most common bug pattern in hook installers across the ecosystem.

### 13.2 Claude target

Anchor `NemoNotch/Services/HookInstaller.swift:54-94  install()`; path constant at `NemoNotch/Services/HookInstaller.swift:7-12` resolves to `~/.claude/settings.json`.

```swift
static func install(_ target: HookTarget) throws {
    try ensureScriptExists()
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        settings = json
    }
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    // … strip every event-entry whose command matches hookCommand
    // … then append a fresh entry for each event in target.hookEvents
    settings["hooks"] = hooks
    let data = try JSONSerialization.data(
        withJSONObject: settings,
        options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: target.settingsPath))
}
```

**Gotcha:** Use `[.prettyPrinted, .sortedKeys]` on write — `.sortedKeys` keeps key order stable so users editing `settings.json` by hand don't see churn in `git diff` after each install.

**Gotcha:** `JSONSerialization.jsonObject(with: data)` returns an immutable `NSDictionary` cast to `[String: Any]`. The cast-to-mutable-Swift-dictionary copies — fine here — but if you pass `options: [.mutableContainers]` expecting in-place mutation, you still need a `var` rebinding. The code uses copy-and-reassign, not mutable containers.

### 13.3 Gemini target

Same `install(_:)` function with `target = .gemini`; path `~/.gemini/settings.json`. Event names differ — Claude uses `PreToolUse / PostToolUse / Stop / SessionStart / SessionEnd / Notification / UserPromptSubmit / PermissionRequest`, Gemini uses `SessionStart / SessionEnd / Notification / BeforeAgent / AfterAgent / BeforeTool / AfterTool` (`HookTarget.hookEvents`, `HookInstaller.swift:14-25`). JSON read/write skeleton is identical — see [§13.2].

**Gotcha:** Gemini's event names differ from Claude's. The mapping lives in `HookTarget.hookEvents`; don't hardcode either set at the call site or you'll forget to update one when the upstream CLI adds an event.

### 13.4 Hermes target (YAML + named profiles)

Anchor `NemoNotch/Services/HermesHookInstaller.swift:33-47  install() / uninstall()` and `:52-67  allConfigPaths()`.

```swift
private static func allConfigPaths() -> [String] {
    var paths = [hermesDir + "/config.yaml"]
    let profilesDir = hermesDir + "/profiles"
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
        for name in contents {
            let configPath = profilesDir + "/" + name + "/config.yaml"
            if FileManager.default.fileExists(atPath: configPath) {
                paths.append(configPath)
            }
        }
    }
    return paths
}
```

**Gotcha:** YAML format means **string-based mutation**, not structured. The `isInstalled` check uses `content.contains("nemonotch/hooks/hermes-hook-sender.sh")` — **fragile** if the script is renamed or its path changes. Pin the substring to a single named constant (`scriptCommand`) and grep for it from both install and uninstall.

**Gotcha:** Profiles can be added by the user **after** NemoNotch has been installed once. The installer must re-scan `~/.hermes/profiles/*/config.yaml` on every install, not cache the list — `allConfigPaths()` is called fresh from both `install()` and `uninstall()`.

### 13.5 Sender script generation

Anchor `NemoNotch/Services/HookInstaller.swift:125-198  ensureScriptExists()`. Writes `~/.nemonotch/hooks/hook-sender.sh`, marked with a version string so older versions get rewritten on next launch.

```swift
let script = """
#!/bin/bash
\(scriptVersion)
SOCKET="\(socketPath)"
[ -S "$SOCKET" ] || exit 0
// … detect CLI_SOURCE from $GEMINI_SESSION_ID / $CLAUDE_SESSION_ID / parent ps
// … read stdin, inject "cli_source" via python3, pipe to nc -U
"""
try script.write(to: scriptURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: hookScriptPath)
```

**Gotcha:** The script picks `CLI_SOURCE` from `$GEMINI_SESSION_ID` / `$CLAUDE_SESSION_ID` first, then falls back to parsing the parent process command line. Needed because Claude Code and Gemini set different env vars; the parent-`ps` fallback covers older CLI versions that set neither. Test both invocation paths if you modify the script.

**Gotcha:** `setAttributes([.posixPermissions: 0o755], ...)` is mandatory — `String.write(to:atomically:encoding:)` produces a 0644 file, which the CLI host then **silently refuses to execute**. The failure mode is "hooks just don't fire" with no error message — easy to misdiagnose as a socket bug.

### 13.6 Reference projects (inline pointer)

- *masko-code* — origin of the `HookInstaller` writing-to-`~/.claude/settings.json` pattern and `hook-sender.sh` process-tree detection idea.

---

## 14. Keychain

NemoNotch persists a long-lived device-identity key (Curve25519 signing key) in the system Keychain for the OpenClaw integration. Pattern: load via `SecItemCopyMatching`; on `errSecItemNotFound`, generate fresh and save via `SecItemAdd`. The same pattern works for any long-lived secret.

### 14.1 `SecItemCopyMatching` load

`NemoNotch/Services/OpenClawService.swift:73-90  loadOrCreateDeviceIdentity()`:

```swift
let keychainKey = "ai.openclaw.nemonotch.device-key"

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: keychainKey,
    kSecReturnData as String: true,
]
var result: AnyObject?
if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
   let keyData = result as? Data,
   let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
    // … derive deviceId from publicKey SHA256 fingerprint
    return (key, deviceId)
}
```

**Gotcha:** `SecItemCopyMatching` returns `errSecItemNotFound` (`-25300`) when the key doesn't exist — **that's the "generate new" signal, not a real error**. Don't log it as a failure; the load-or-generate pattern depends on this status code being routine.

**Gotcha:** `kSecReturnData: true` returns raw bytes only. If you also want metadata (account, service, accessGroup), make a second query with `kSecReturnAttributes: true` — you can't get both data and attributes from a single call without `kSecReturnRef` indirection.

**Gotcha:** No `kSecAttrService` is set here, so the item is keyed on `kSecAttrAccount` alone within the default service namespace. For multi-secret services, always pair `kSecAttrService` (your bundle id or feature name) with `kSecAttrAccount` (the specific key) to avoid collisions.

### 14.2 `SecItemAdd` save

`OpenClawService.swift:99-104`:

```swift
let addQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrAccount as String: keychainKey,
    kSecValueData as String: key.rawRepresentation,
]
SecItemAdd(addQuery as CFDictionary, nil)
```

**Gotcha:** Production code should always include `kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked` (or stricter, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). The default access class is more permissive than appropriate for a long-lived identity key, and without `*ThisDeviceOnly` the item can sync via iCloud Keychain unintentionally.

**Gotcha:** `SecItemAdd` returns `errSecDuplicateItem` (`-25299`) if the key already exists. The current code ignores the return value because the preceding load guarantees absence — but if you split load/save across functions, switch to `SecItemUpdate` on duplicate, or call `SecItemDelete` first.

---

## 15. Swift 6 concurrency conventions

How NemoNotch satisfies Swift 6's strict-concurrency checker without sacrificing performance. Five patterns recur: `@MainActor @Observable` services, `@unchecked Sendable` bridge structs for crossing isolation, `nonisolated(unsafe)` for queue-owned mutable state, `Task { @MainActor }` re-dispatch from background callbacks, and `nonisolated(unsafe) static let shared` for thread-safe singletons.

### 15.1 Default service shape: `@MainActor @Observable final class`

Fifteen services follow this shape: `AICLIMonitorService`, `AISessionStore`, `CalendarService`, `ClaudeCodeService`, `GeminiProvider`, `HermesService`, `HookServer`, `HUDService`, `LauncherService`, `MediaService`, `NotificationService`, `OpenClawService`, `SystemService`, `WeatherService`, `AgentMonitorRegistry`.

```swift
@MainActor
@Observable
final class MediaService {
    var playbackState = PlaybackState()
    // … all mutable state lives on MainActor; SwiftUI observes via @Observable.
}
```

**Gotcha:** `@Observable` **requires `final`** — without it the macro emits a compile error from inside its own expansion, not on your class declaration, so the surfaced diagnostic is misleading. Always declare `final` from day one.

**Gotcha:** `@MainActor` on the class is what makes the whole service "free" to mutate from SwiftUI views. Drop it and every UI-side property assignment becomes an actor-hop, ballooning latency on cold UI paths.

### 15.2 `@unchecked Sendable` bridge structs

Used to carry non-`Sendable` payloads (typically `[String: Any]?` from C APIs) across isolation boundaries. Two production examples:

`NemoNotch/Services/NowPlayingCLI.swift:438-440  InfoBox`

```swift
private struct InfoBox: @unchecked Sendable {
    let info: [String: Any]?
}
// Invariant: written once on `queue`, read once on MainActor; never aliased.
```

`NemoNotch/Services/MediaService.swift:4-7  NowPlayingInfoBox`

```swift
private struct NowPlayingInfoBox: @unchecked Sendable {
    let info: [String: Any]?
    init(info: [String: Any]?) { self.info = info }
}
```

**Gotcha:** The wrapped type is `[String: Any]?`, which is **NOT** `Sendable`. We mark the wrapper `@unchecked Sendable` because we *only* read it after the queue transition, never share mutation. Misuse silently leaks data races. **Always document the invariant in a one-line comment on the wrapper** so the next reader understands why the bypass is safe.

**Gotcha:** `@unchecked` is not a license to share — it's a license to *transfer*. If two threads can hold the same wrapper instance and mutate the wrapped dictionary, you have UB and the type checker won't catch it.

### 15.3 `nonisolated(unsafe)` for queue-owned state

`NemoNotch/Services/HookServer.swift:7-11`

```swift
@ObservationIgnored nonisolated(unsafe) private var socketFd: Int32 = -1
@ObservationIgnored nonisolated(unsafe) private var acceptSource: DispatchSourceRead?
private let socketQueue = DispatchQueue(label: "com.nemonotch.hookserver", qos: .userInitiated)
@ObservationIgnored nonisolated(unsafe) private var responseWaiters: [String: (String) -> Void] = [:]
```

**Gotcha:** Safe **only** if the state is exclusively accessed on a specific queue (here, `socketQueue`). Mix in a stray `self.socketFd = …` from `@MainActor` code and you have a silent race the compiler will not flag. Pair every `nonisolated(unsafe)` field with a comment naming the owning queue.

**Gotcha:** `deinit` of a `@MainActor` class is `nonisolated` — to safely tear down queue-owned state, hop back with `socketQueue.sync { … }` before releasing. Skipping this can leave file descriptors leaked into restart cycles.

### 15.4 `Task { @MainActor [weak self] in }` re-dispatch

When a `NotificationCenter` block, `DispatchSource` event handler, or `URLSession` completion fires off-actor, re-enter MainActor before touching service state. `NemoNotch/Services/MediaService.swift:200-204`:

```swift
nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
    Task { @MainActor [weak self] in
        LogService.debug("[Media] notification: \(name.rawValue)", category: "media")
        self?.updateNowPlaying()
    }
}
```

**Gotcha:** Required when the observer block is `nonisolated`. You cannot just call `self.foo = bar` — the compiler will refuse. `[weak self]` on **both** the outer block and the inner `Task` prevents retain cycles on long-lived sources (timers, sockets, websockets).

**Gotcha:** Don't conflate "queue: .main" with "MainActor" — they're different isolation domains in Swift 6. The `Task { @MainActor in }` hop is still required even when `OperationQueue.main` is specified.

### 15.5 `nonisolated(unsafe) static let shared`

`NemoNotch/Services/LogService.swift:4`

```swift
nonisolated(unsafe) static let shared = LogService()
```

**Gotcha:** Appropriate **only** when the singleton is internally thread-safe (DDLog is — see [§18]). For services that mutate state, prefer `@MainActor` initialization in `AppDelegate` instead of a global singleton (see [§17]).

---

## 16. SwiftUI patterns in this codebase

How NemoNotch wires `@Observable` services into views, kills per-screen animation flash on multi-display setups, picks its spring-animation pair, and uses shared view modifiers as the design system.

### 16.1 `@Environment` + `@Observable` service injection

`NemoNotch/Notch/NotchView.swift:3-15`

```swift
struct NotchView: View {
    let screen: NSScreen

    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings
    @Environment(MediaService.self) var mediaService
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(NotificationService.self) var notificationService
    @Environment(AgentMonitorRegistry.self) var agentRegistry
    @Environment(CalendarService.self) var calendarService
    @Environment(HUDService.self) var hudService
    // …
}
```

Services are seeded via `.environment(serviceInstance)` on a parent — typically the `NotchCoordinator` content builder in `AppDelegate.applicationDidFinishLaunching` (see [§17]).

**Gotcha:** If a service is missing at runtime, SwiftUI **crashes** at first access, not gracefully degrades. There is no `@Environment(MediaService.self)?` optional form. Ensure every `@Environment` in a view tree has been seeded by an ancestor; for transient or feature-flagged services, gate the consumer view at the parent so it never gets to render without dependencies.

**Gotcha:** New `@Observable` Environment injection (Swift 5.9+) is **not** interchangeable with the older `@EnvironmentObject` API. Don't mix the two in the same view tree — values flow only along the matching channel.

### 16.2 `effectiveStatus` per-screen flicker suppression

`NemoNotch/Notch/NotchView.swift:36-38`

```swift
private var effectiveStatus: NotchCoordinator.Status {
    coordinator.isActiveScreen(screen) ? coordinator.status : .closed
}
```

Every `notchSize`, `cornerRadius`, and `.animation(…, value: effectiveStatus)` read this computed property instead of `coordinator.status` directly.

**Gotcha:** Without this indirection, **secondary displays animate-expand in sync with the primary** — a visible flash on plug/unplug, and a permanent open-state on the wrong screen if the mouse is hovering the primary's notch. This is critical pitfall #8; see [§2] for the full pitfall index.

**Gotcha:** The `.animation(_:value:)` modifier observes `effectiveStatus`, not the global `coordinator.status`. If you ever introduce a new animated property, drive it from `effectiveStatus` too, or you'll regress the fix.

### 16.3 Animation pair: interactive open, regular close

`NemoNotch/Notch/NotchCoordinator.swift:187 + 198`

```swift
// Open
withAnimation(.interactiveSpring(duration: NotchConstants.openSpringDuration)) { … }   // 0.314s

// Close
withAnimation(.spring(duration: NotchConstants.closeSpringDuration)) { … }              // 0.24s
```

**Gotcha:** Open uses **interactive** spring so animations don't stack when the user re-hovers mid-animation — interactiveSpring blends with in-flight motion. Close uses regular spring because we want it to finish even if the user moves the mouse back briefly. **Don't swap them** — interactive-close gives jittery, never-fully-closed notches; regular-open gives stacked motion artifacts on rapid hover.

**Gotcha:** Both durations live in `NotchConstants` (`openSpringDuration = 0.314`, `closeSpringDuration = 0.24`). Changing the literals in callsites instead of the constants will desync the multiple `.animation(…)` modifiers in `NotchView` that share these values.

### 16.4 Shared decorators as the design system

`NemoNotch/Helpers/ViewModifiers.swift` defines `NotchTheme` (color tokens), `NotchCardModifier` / `.notchCard()`, `NotchPillButtonStyle`, `PulseModifier`, `GlowPulseModifier`, `ScrollEdgeShadowMaskModifier` / `.notchScrollEdgeShadow()`.

`NemoNotch/Helpers/ToolStyles.swift` defines `ToolStyle.icon(_:)` and `ToolStyle.color(_:)` mapping AI tool names (`Read`, `Bash`, `Edit`, `Web*`, `Agent`) to SF Symbols and tint colors.

**Gotcha:** These encode the design system. **Adding new ad-hoc `.background(Color…)` or `.font(.system(size: …))` inline in a tab view is a code smell** — extend the shared modifier or token instead. Reviewers should reject inline styling that duplicates an existing modifier.

### 16.5 Cancellable auto-dismiss via `Task` (HUD pattern)

**Restartable dismiss timer** — `NemoNotch/Services/HUDService.swift:20 + 283-292  restartDismissTimer()`

```swift
private var dismissTask: Task<Void, Never>?

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
```

`restartDismissTimer()` is called on every volume/brightness/battery change. Tapping the volume key rapidly cancels the previous in-flight `Task` and starts a fresh one — the HUD only fades after the user actually stops nudging.

**Gotcha:** Two layers of cancel protection are both required. `dismissTask?.cancel()` before reassigning kills the in-flight task; the `guard !Task.isCancelled` after the sleep catches the rare race where cancellation lands between `Task.sleep` returning and the `withAnimation` block. Without the post-sleep guard, a rapid sequence of changes occasionally flickers the HUD to nil mid-animation.

**Gotcha:** The `Task { @MainActor in }` annotation is non-optional — without it the `withAnimation` block runs off the main actor and the animation silently does nothing (the UI snaps instead of fading). Prefer this idiom over `DispatchQueue.main.asyncAfter(deadline:)`, which is **not cancelable** and forces an awkward boolean-flag dance instead.

### 16.6 Pie chart with SwiftUI `Path.addArc`

`NemoNotch/Notch/Badge/PomodoroPieView.swift`

```swift
GeometryReader { geo in
    let radius = min(geo.size.width, geo.size.height) / 2
    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
    Path { p in
        p.move(to: center)
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),                       // 12 o'clock start
            endAngle: .degrees(-90 + 360 * remainingFraction),
            clockwise: false
        )
        p.closeSubpath()
    }
    .fill(color)
}
```

Wrap with a background `Circle().stroke(color.opacity(0.25))` for the empty wedge. Used by both the 14pt notch badge and the 88pt active-block face — same component, different size presets.

**Gotcha:** Don't drive the fraction through the `BadgeItem` `Equatable` case — each-second change would re-trigger the badge spring animation in `BadgeViewModel.updateDisplayedBadges`. Pass identity (e.g. `.pomodoro(phase:)`) through the case; read the live `remainingFraction` inside the view via `@Environment(PomodoroTimerService.self)`.

---

## 17. Architecture patterns

How services are owned, wired, and exposed to the notch coordinator. The two load-bearing decisions: `AppDelegate` owns and instantiates all services in `applicationDidFinishLaunching`, and consumers receive dependencies via closures and initializer args — **not** via an `AppDelegate.shared` global.

### 17.1 Service ownership in `AppDelegate`

`NemoNotch/NemoNotchApp.swift:105-188  applicationDidFinishLaunching(_:)`

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    _ = LogService.shared

    let settings = AppSettings()
    let media = MediaService()
    let calendar = CalendarService()
    let aiMonitor = AICLIMonitorService()
    // … all sibling services instantiated in declaration order

    let notchCoordinator = NotchCoordinator { coordinator, screen in
        AnyView(
            NotchView(screen: screen)
                .environment(coordinator)
                .environment(settings)
                .environment(media)
                .environment(aiMonitor)
                // … one .environment(_) per injected service
        )
    }
    notchCoordinator.autoSelectTab = { [weak self] in /* read services */ }
    coordinator = notchCoordinator
    setupHotkeys(coordinator: notchCoordinator, settings: settings)
}
```

**Gotcha:** Order matters. `setupHotkeys(coordinator:)` registers `KeyboardShortcuts.onKeyDown` callbacks that capture `coordinator` weakly — wire the coordinator *first*, then attach hotkeys. Reversing the order means the captured `weak coordinator` is `nil` when the user presses the hotkey, and the action silently no-ops. No compile-time signal.

**Gotcha:** Each closure passed to `NotchCoordinator` (the content builder, `autoSelectTab`, `restoreSuppressionCheck`, `onShowSettings`) captures `self` or the local services. Use `[weak self]` on the AppDelegate-facing ones to avoid a cycle through `coordinator → closure → self → coordinator`.

### 17.2 Closure injection over `AppDelegate.shared`

The refactor sequence `91dc446 → 44d3587 → aff5663` (Nov 2024) removed `AppDelegate.shared` entirely. Before/after:

```swift
// BEFORE — global singleton read at point of use
func notchOpen() {
    AppDelegate.shared.mediaService?.togglePlayPause()
}

// AFTER — closure injected at coordinator construction
let coordinator = NotchCoordinator(
    onToggleMedia: { [weak media] in media?.togglePlayPause() }
)
```

**Gotcha:** The refactor took several commits because every consumer had to be reworked. **New code should follow this pattern, not regress to a global.** Resist the urge to add back `AppDelegate.shared` "just for one quick thing" — the cost of regrowing the global is the cost of removing it again later, multiplied by every new caller you bring along.

**Gotcha:** Closures captured at AppDelegate scope hold strong references to services. Use `[weak service]` (or `[weak self]` on AppDelegate-bound closures) for any closure that outlives the call stack, e.g. coordinator callbacks, timer handlers, NotificationCenter blocks.

### 17.3 Protocol-first multi-provider design

`NemoNotch/Models/AIProvider.swift:8-16`

```swift
@MainActor
protocol AIProvider: AnyObject, Observable {
    var source: AISource { get }
    var isHookInstalled: Bool { get set }
    func handleEvent(_ event: HookEvent)
    func installHooks()
    func uninstallHooks()
    func respondToPermission(sessionId: String, approved: Bool)
}
```

`ClaudeCodeService` and `GeminiProvider` each implement this; provider-specific fields (Claude's `cacheReadTokens`, Gemini's thought tokens) live on the concrete types. Same pattern for `ConversationParserProtocol` (Claude/Gemini/Hermes parsers, file at `NemoNotch/Models/ConversationParserProtocol.swift`) and `MultiAgentMonitor` (OpenClaw + Hermes monitors at `NemoNotch/Models/MultiAgentMonitor.swift:79-92`).

**Gotcha:** **Don't** force provider-specific fields (e.g. Claude's `cache_read_input_tokens`, Gemini's `thoughts_tokens`) into the shared protocol. Keep them on the concrete type; access via downcast in code that needs them. Forcing parity will balloon the protocol and break the "add a new provider in one file" property.

**Gotcha:** `Observable` (capital-O, the runtime conformance from `@Observable`) appears in the protocol composition so SwiftUI can observe any conforming type. Don't drop it — views that hold `any AIProvider` will silently stop reacting to changes.

### 17.4 `LifecycleAware` for activate-on-appear services

`NemoNotch/Helpers/LifecycleAware.swift:6-20`

```swift
@MainActor
protocol LifecycleAware: AnyObject {
    func setActive(_ active: Bool)
}

extension View {
    func activates(_ service: any LifecycleAware) -> some View {
        self.onAppear { service.setActive(true) }
            .onDisappear { service.setActive(false) }
    }
}
```

**Gotcha:** Apply `.activates(service)` on the **leaf consumer view**, not a container. Containers stay mounted even when their content is offscreen — putting the modifier there means the service runs whenever the notch is open, defeating the purpose. The contract is also idempotent: redundant `setActive(true)` calls must be no-ops in the implementation.

### 17.5 Settings persistence: `@Observable` + `didSet` → `UserDefaults`

What/why: `AppSettings` is a `@MainActor @Observable` value injected as an `@Environment`. Each user-facing property carries its own `didSet` that writes the new value straight to `UserDefaults`. No separate persistence layer, no Combine pipeline, no Codable ceremony beyond what `JSONEncoder` requires for the `[AppItem]` launcher list.

**Pattern** — `NemoNotch/Models/AppSettings.swift:19-52`

```swift
@MainActor @Observable
final class AppSettings {
    var defaultTab: Tab {
        didSet { UserDefaults.standard.set(defaultTab.rawValue, forKey: "defaultTab") }
    }
    var enabledTabs: Set<Tab> {
        didSet {
            let raw = enabledTabs.map(\.rawValue)
            UserDefaults.standard.set(raw, forKey: "enabledTabs")
        }
    }
    var launcherApps: [AppItem] {
        didSet {
            if let data = try? JSONEncoder().encode(launcherApps) {
                UserDefaults.standard.set(data, forKey: "launcherApps")
            }
        }
    }
    var weatherCity: String {
        didSet { UserDefaults.standard.set(weatherCity, forKey: "weatherCity") }
    }
    // … init() reads each key from UserDefaults and assigns the stored value.
}
```

**Gotcha:** Swift skips `didSet` during `init`, so the constructor's reads-from-`UserDefaults` assignments don't trigger write-backs — no infinite loop. If you ever refactor to assign through a property setter from `init` (e.g. via a helper method), the loop comes back; keep init body simple and direct.

**Gotcha:** `didSet` fires on **every** write, including reassigning the same value. SwiftUI bindings during a drag-reorder produce a stream of writes per second. `UserDefaults` is in-memory with lazy disk flush so it's cheap; **never** put network calls or expensive serialization in `didSet` — they will fire dozens of times per second. The `JSONEncoder().encode(launcherApps)` path above is borderline acceptable because the list is small; if it grew to hundreds of items, debounce before persisting.

**Gotcha:** Don't mix this pattern with `@Published` (Combine-era). The new `@Observable` macro synthesizes change tracking on bare stored properties; wrapping them in `@Published` confuses the synthesis and silently breaks the `@Environment` injection in [§16.1].

---

## 18. Logging conventions

NemoNotch uses CocoaLumberjack via a thin `LogService` wrapper. Logs go to both console (DEBUG only) and a daily-rolling file under `~/.NemoNotch/logs/`. Static `nonisolated` API so any thread/actor can log without ceremony. Category strings = module names for filterable `tail` / `grep`.

### 18.1 `DDFileLogger` setup

`NemoNotch/Services/LogService.swift:7-28  init()`:

```swift
let logDir = NSHomeDirectory() + "/.NemoNotch/logs"
// … create directory if missing

DDLog.add(DDOSLogger.sharedInstance)

let logFileManager = DDLogFileManagerDefault(logsDirectory: logDir)
logFileManager.maximumNumberOfLogFiles = 7
fileLogger = DDFileLogger(logFileManager: logFileManager)
fileLogger.rollingFrequency = 60 * 60 * 24    // daily roll
DDLog.add(fileLogger)
```

**Gotcha:** Logs live in `~/.NemoNotch/logs/`, **not** `~/Library/Logs/` (which would be the macOS convention). Intentional — easier to `tail` and ship in bug reports. If you sandbox the app later, this path won't be writable; you'd have to migrate to `~/Library/Containers/<bundle-id>/Data/Library/Logs/`.

**Gotcha:** `rollingFrequency` is in **seconds**, not days. `60 * 60 * 24` is daily; setting `1` rolls every log call (don't). Combined with `maximumNumberOfLogFiles = 7` this gives roughly a one-week retention window.

### 18.2 Static API + categories

`LogService.swift:36-50`:

```swift
nonisolated static func debug(_ message: String, category: String = "App") {
    DDLogDebug("[\(category)] \(message)")
}
nonisolated static func info(_ message: String, category: String = "App") {
    DDLogInfo("[\(category)] \(message)")
}
// … warn, error follow the same shape
```

**Gotcha:** Uses `nonisolated(unsafe) static let shared = LogService()` for the singleton (cross-link [§15] Swift concurrency). Safe because `DDLog` is thread-safe internally and `shared` is initialized once on first access. **Don't** copy this pattern to `@Observable` services — they have actor-bound state and the compiler's race detection exists for a reason.

**Gotcha:** Default `category: "App"` is a footgun — easy to forget the explicit category at a call site, which then makes log filtering useless. Code review for `category:` on every new `LogService.*` call.

### 18.3 Log levels (DEBUG vs Release)

`LogService.swift:23-27`:

```swift
#if DEBUG
dynamicLogLevel = .all
#else
dynamicLogLevel = .info
#endif
```

**Gotcha:** `.debug` and `.verbose` calls are **stripped at the log macro** in release. Don't put load-bearing logic inside a `LogService.debug(...)` argument expression — the expression argument **still evaluates** even when the log line is dropped (Swift evaluates function arguments eagerly). Hide expensive computations behind `if dynamicLogLevel.rawValue >= DDLogLevel.debug.rawValue { … }` or autoclosure-wrap them.

### 18.4 Category naming convention

Use the module/service name as the category — e.g. `"MediaService"`, `"HookServer"`, `"NotchCoordinator"`, `"NowPlayingCLI"`, `"OpenClaw"`. This makes `grep` / `tail -F | grep '\[HookServer\]'` trivial.

```swift
LogService.info("daemon spawned pid=\(pid)", category: "NowPlayingCLI")
```

---

## 19. Reference-projects index

Mirror of CLAUDE.md's "Reference Projects" table — kept here so the cookbook is greppable without opening CLAUDE.md. **If you update one, update the other in the same commit.** All projects live under `/Users/gaozimeng/Learn/macOS/`.

| Need | Reference Project | What to Reference |
|------|------------------|-------------------|
| Notch window positioning, multi-screen | **NotchDrop** | NSPanel subclass, screen.notchSize detection, per-screen WindowController |
| Notch window management, tri-state machine | **Peninsula** | NSPanel subclass, notch positioning, closed/popping/opened state machine, NotchBackgroundView notch shape rendering |
| Notch animation, auto-collapse | **DynamicNotchKit** | Spring animation .bouncy(duration: 0.4), Timer auto-dismiss, NSScreen extensions (hasNotch/notchSize/notchFrame) |
| Mouse event monitoring | **NotchDrop** | Global NSEvent monitor for mouse approach/leave detection |
| Global hotkeys | **KeyboardShortcuts** | User-customizable bindings via `KeyboardShortcuts.Name` registry in `Hotkeys.swift`; SwiftUI `Recorder` for rebinding |
| Now Playing info retrieval | **PlayStatus** / **Tuneful** | MediaPlayer framework, MPNowPlayingInfoCenter polling |
| Media key interception | **PlayStatus** | sendEvent override intercepting NX_KEYTYPE_PLAY etc. |
| CLI now playing info | **nowplaying-cli** | daemon connection → legacy callback → MRNowPlayingController three-tier fallback, dylib path search |
| MediaRemote bridging | **PlayStatus** | dlopen/dlsym dynamic loading of MediaRemote.framework private API |
| Window management | **Loop** | WindowEngine architecture, radial menu, keyboard event handling |
| Spotlight-style search | **DSFQuickActionBar** | NSPanel floating window, async search, keyboard navigation |
| Dock hover preview | **DockDoor** | SCWindow screenshots, window thumbnail cache, AXUIElement window control |
| Menu bar architecture | **eul** | StatusBarManager, Combine reactive, dark/light mode adaptation, host_processor_info CPU sampling, host_statistics64 memory reading |
| Brightness monitoring | **MonitorControl** | DisplayServicesGetBrightness() private API, dlopen dynamic loading |
| AI Hook architecture | **masko-code** | Unix Socket event delivery, HookInstaller writing to ~/.claude/settings.json, hook-sender.sh process tree detection |
| Conversation parsing | **vibe-notch** | Incremental JSONL parsing, ChatMessage structured parsing, PermissionRequest approval flow |
| Status icons | **NotchNook** | Notch-side icon layout style |

---

## 20. UI-test screenshot harness (`--uitest`)

Because the notch panel is a hover/hotkey-summoned borderless `NSPanel` whose content depends on live external state (calendar, media, AI sessions, agents), there is no clean way to script "open tab X with good-looking data and screenshot it." The `--uitest` mode makes the app **self-driving and deterministic** so a shell script can capture every tab. Pattern (no XCUITest target, no `project.pbxproj` edits):

- **Arg gate** — `UITestMode` (`NemoNotch/Helpers/UITestMode.swift`) reads `ProcessInfo.processInfo.arguments` for `--uitest` and `--tab=<rawValue>`. Pure `isActive(in:)`/`tab(in:)` are unit-tested; runtime `isActive`/`tab` read the real process args.
- **Side-effect suppression** — `applicationDidFinishLaunching` gates every live subsystem behind `if !UITestMode.isActive`: `MediaService(disableLiveUpdates:)` skips the perl NowPlaying daemon + polling, and `HookServer.start()` / OpenClaw+Hermes `connect()` / `MediaAutomationPermissionMonitor.startProbing()` / weather network are not called. Critical: this avoids the second instance fighting the installed app for the HookServer TCP port. `SystemService.update()` early-returns under uitest so its 2 s sampler can't overwrite seeded process rows.
- **Seeding** — `UITestSeeder` (`NemoNotch/Helpers/UITestSeeder.swift`) writes marketing-quality state directly into each `@Observable` service. `var` state is set directly; `private(set)` state gets a tiny `seedForUITest(...)` entry (e.g. `CalendarService`). `TaskStore(fileURL:)` is pointed at a temp file so seeding never touches `~/.NemoNotch/tasks.json`. The Agents tab is seeded by registering a mock `MultiAgentMonitor` (`UITestMockAgentMonitor`, `isInstalled`/`isOnline` = true) rather than faking OpenClaw/Hermes internals. Album art is drawn programmatically (`NSGradient` + glyph → PNG) to avoid bundling copyrighted assets.
- **Stay-open** — `NotchCoordinator.init` skips `setupEventMonitoring()` when `UITestMode.isActive`, so the programmatically-opened panel does not auto-close on mouse-outside. The app opens via `notchOpen(tab:on:)` forced onto the built-in notch screen (`NSScreen.first { $0.isBuiltInDisplay && $0.hasNotch }`), independent of cursor position.
- **Now-playing vs permission card gotcha** — seeding `playbackState.appBundleIdentifier` to a `KnownPlayer` (Music/Spotify) makes Overview render the Automation-permission card instead of the track. Leave the bundle id `nil` to force the MediaRemote/now-playing path.
- **Capture geometry** — on open, `UITestSeeder.writeCaptureRect(for:on:)` writes the panel's `screencapture`-style rect (origin = main-display top-left, y down) to `/tmp/nemonotch-uitest.rect`: `x = screen.frame.midX - width/2`, `y = 0`, `width = overviewOpenedWidth(700)|openedWidth(560)`, `height = openedHeight(328)`. The script reads this file per tab (width differs by tab) and runs `screencapture -x -R<x,y,w,h>`.
- **Orchestration** — `scripts/uitest-screenshots.sh` quits the running install (so two notch overlays don't ghost), `xcodebuild`-builds Debug, then per tab: launch `NemoNotch.app --uitest --tab=<tab>`, `osascript -e 'delay …'` (not shell `sleep`), read the rect file, `screencapture`, kill the instance — then reopens the user's install. Output → `docs/images/tab-*.png`.
