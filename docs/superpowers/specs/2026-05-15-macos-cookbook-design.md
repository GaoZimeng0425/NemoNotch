# macOS Cookbook — Design Spec

**Date:** 2026-05-15
**Owner:** GaoZimeng
**Status:** Draft — awaiting user review before implementation

## 1. Problem

NemoNotch has accumulated dense macOS-specific knowledge across ~30 Swift files: private framework loading (`MediaRemote`, `DisplayServices`), Mach/libproc system sensing, Carbon hotkeys, Unix-socket IPC, AppleScript fallbacks, multi-screen notch handling, and a custom `@Observable` + closure-injection architecture. None of this is consolidated. CLAUDE.md captures a handful of pitfalls but is intentionally short and not a reference; design docs in `docs/plans/` are per-feature snapshots, not transferable patterns.

The cost of this is concrete: an AI collaborator (or a returning human) re-derives the same techniques on every task — re-discovers the `INFOPLIST_KEY_*` pitfall, re-reads `MediaService` to remember the reconcile guard, re-greps for how brightness polling adapts. The fix is a single, structured, English reference that points at real code via `file:line` anchors so the AI can grep one heading, jump to evidence, and act.

## 2. Goal

Produce a single durable reference doc — `docs/macos-cookbook.md` — that maps every macOS-specific technique used in this codebase to its location, gotcha, and minimal code skeleton. Optimize for **AI lookup**, not human narrative: skimmable headings, short bullets, `file:line` everywhere, no long prose.

A successful cookbook lets a Claude Code session that has never seen this repo answer a question like *"how do I add a new global hotkey?"* by grepping the cookbook, reading 30 lines, and producing correct code on the first try.

## 3. Non-goals

- Not a tutorial on macOS development for newcomers.
- Not a Swift language reference.
- Not a narrative blog post or public-facing writeup.
- Not a complete API documentation for every framework used.
- Not an architectural decision log (those live in `docs/plans/`).
- Not duplicating CLAUDE.md — the cookbook is referenced *from* CLAUDE.md but lives separately.

## 4. Scope

Per user confirmation, all four scope buckets are in:

1. **macOS-specific pitfalls & private API tricks** (the load-bearing core)
2. **This codebase's architecture patterns** (`@Observable` service ownership, AIProvider protocol-first, closure injection)
3. **macOS system-sensing & permissions recipes** (brightness, volume, CPU/mem, calendar, automation, accessibility)
4. **Generic Swift 6 / SwiftUI / AppKit conventions** *as they manifest in this project* — included when there's a project-specific twist (e.g. `@unchecked Sendable` bridge structs for crossing isolation), excluded when it's textbook Swift.

## 5. Organization

Subsystem-organized over recipe-organized or layered. An AI given a task usually knows the subsystem (`MediaRemote`, `notch window`, `hooks`) faster than it knows the recipe name; subsystem headings map directly to grep queries. The "Critical pitfalls" section is hoisted to position 2 to surface silent-failure traps before deep content.

### Section list (19 sections)

1. **How to use this doc** — Citation conventions (file:line everywhere, real code not paraphrased, **Gotcha** callouts), when to update (when adding a new private API / subsystem / pattern), how AI should search it (grep section headings first, then `file:line` anchors).
2. **Critical pitfalls (read first)** — Top ~8 silent failures: Info.plist + `GENERATE_INFOPLIST_FILE = YES` → must use `INFOPLIST_KEY_*`; missing `NSAppleEventsUsageDescription` → silent automation denial with no dialog; Spotify ignores `MRMediaRemoteSendCommand` skip → must use AppleScript `set player position`; stale Unix socket at `/tmp/com.nemonotch.hook` → must `unlink` at startup; AE error `-1743` = automation permission denied; Dock badge text contains hidden LRM Unicode marks → must normalize before comparison; multi-screen hosting controller needs frame-offset math; per-screen `effectiveStatus` required to suppress secondary-screen expansion flash. **Each pitfall is a short summary + a pointer to its deep section** — the duplication is intentional: §2 is a fast-scan surface, the deep sections are where the full context lives.
3. **Build & release configuration** — `INFOPLIST_KEY_*` pattern in `project.pbxproj`, `LSUIElement=YES` for menubar app, entitlements (sandbox **disabled** — `com.apple.security.app-sandbox = false`), `build.sh` ad-hoc signing (`CODE_SIGN_IDENTITY="-"`), `.github/workflows/release.yml` on `macos-15` + Xcode 26.3, `MACOSX_DEPLOYMENT_TARGET=26.2`, `softprops/action-gh-release@v2` for DMG upload.
4. **Private API loading** — Three patterns documented side-by-side:
   - **dlopen + dlsym** (single symbol): used for `DisplayServicesGetBrightness` in `HUDService`.
   - **dlopen + CFBundle + GetFunctionPointerForName** (multiple symbols with `@convention(c)` typedefs): used for 6 `MRMediaRemote*` symbols in `MediaRemote.swift`.
   - **Reflective fallback** via `NSClassFromString("MRNowPlayingController") + class_createInstance + KVC + poll loop`: used as 15.4+ fallback when legacy callback API returns empty.
   Plus: dylib path search precedence (bundled → system → external), `dlerror()` capture, `CFBundleCreate(URL)` for framework-bundled symbols vs `dlsym(RTLD_DEFAULT, ...)` for direct.
5. **Notch & window management** — `NSPanel` subclass at level `.statusBar + 8`, required style/transparency flags (`borderless`, `isOpaque=false`, `backgroundColor=.clear`, `hasShadow=false`, `titleVisibility=.hidden`, `titlebarAppearsTransparent=true`), `collectionBehavior` flag set (`.fullScreenAuxiliary | .stationary | .canJoinAllSpaces | .ignoresCycle`), `PassThroughView` `hitTest` toggle for click-through control, per-screen `NSHostingController` slot + frame-offset math for multi-screen, `NSScreen` notch geometry helpers (`auxiliaryTopLeftArea`, `safeAreaInsets.top`, `CGDisplayIsBuiltin`, `displayID` via `NSDeviceDescriptionKey("NSScreenNumber")`), `didChangeScreenParametersNotification` rebuild trigger.
6. **Event capture & hotkeys** — `NSEvent.addGlobalMonitorForEvents` + paired `addLocalMonitorForEvents` (both needed: global fires in background, local intercepts UI), `NSMouseInRect` hitbox math (open hysteresis: closeHitboxInset=20 hover vs clickHitboxInset=10 click), Carbon `RegisterEventHotKey` + `InstallEventHandler(GetApplicationEventTarget())` with shared `FourCharCode` signature + `Unmanaged` userdata for callback dispatch, `NSMenu.popUp` for right-click context + `NSMenuDelegate` to suppress mouse logic while menu is visible, `NSHapticFeedbackManager.levelChange` on open.
7. **Media subsystem** — Layered architecture:
   - **NowPlayingCLI**: bundled `mediaremote-mini.pl` + gunzip-extracted `MediaRemoteMini.dylib` to `~/Library/Application Support/NemoNotch/`, perl daemon spawned via `Process` + `Pipe`, newline-delimited JSON request/response on stdin/stdout, 3.5s timeout + daemon restart, semaphore-based one-shot fallback.
   - **MediaRemote**: dlopen-loaded private framework for sending commands (play/pause/next/prev/skip), registering for system notifications, 15.4+ `MRNowPlayingController` poll-based fallback.
   - **MediaBridge**: `SBApplication(bundleIdentifier:)` for Music/Spotify, `SBApplicationDelegate` to capture AE errors, `playerState` enums (kPSS/kPSP/kPSp/kPSF/kPSR), `setPlayerPosition?` for seek.
   - **Reconcile pattern**: optimistic UI on tap → `reconcileExpectedIsPlaying` guard preserves authoritative SB value during CLI sync window → `applyInfo` respects guard until CLI catches up → guard self-clears.
   - **DON'T**: don't try `MRMediaRemoteSendCommand(.skipForward)` on Spotify — system returns "never supported"; must use AppleScript path.
8. **System sensing** — Each subsystem one subsection with skeleton + gotcha:
   - **Mach CPU**: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` + `vm_deallocate` cleanup.
   - **Mach memory**: `host_statistics64(HOST_VM_INFO64)` + `vm_statistics64` struct.
   - **libproc**: `proc_listpids(PROC_ALL_PIDS, ...)`, `proc_pidinfo(pid, PROC_PIDTASKINFO, ...)`, `proc_pidpath(pid, ...)`.
   - **Battery**: `IOPSNotificationCreateRunLoopSource` + callback (uses `Unmanaged.passUnretained(self)` for context, manual `DispatchQueue.main` dispatch), `IOPSCopyPowerSourcesInfo`/`List`/`Description` polling.
   - **Brightness**: `DisplayServicesGetBrightness` via `dlsym`, adaptive polling (1.0s default, 0.1s on change, reset when stable — no interrupt mechanism exists).
   - **Volume**: `AudioObjectAddPropertyListenerBlock` on `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` or per-device fallback, device-change rebinding.
   - **Network**: `getifaddrs(3)` + `if_data` struct walk for `ifi_ibytes`/`ifi_obytes`.
9. **ScriptingBridge & AppleScript** — Generated header structure (`MusicApplication.swift`, `SpotifyApplication.swift` as protocol files in `ScriptingBridge/`), `SBApplication(bundleIdentifier:)` resolution, optional-method invocation (`a.setPlayerPosition?(_:)`), `SBApplicationDelegate` for async error capture (the only way to detect AE failures cleanly), AE keyword codes (`kPSP = 0x6b505350`), decision rule: prefer AppleScript over MediaRemote when the target app implements an AS verb (Spotify seek) but rejects the MediaRemote equivalent.
10. **Accessibility & Dock badges** — `AXIsProcessTrusted` gate (throws prompt when first called from un-granted app), `AXUIElementCreateApplication(dockPID)` to get Dock handle, recursive `AXUIElementGetAttributeValueCount` + `AXUIElementCopyAttributeValues(kAXChildrenAttribute)` walk, `kAXTitleAttribute` for app name + `"AXStatusLabel"` attribute for badge text, Unicode normalization for hidden L2R/R2L marks (WhatsApp ships LRM in its name and badge).
11. **Permissions playbook** — Per-permission recipe with: how to request, how to detect denial, how to recover:
    - **Calendar**: `EKEventStore.authorizationStatus(for: .event)` + `requestFullAccessToEvents()` async; observe `EKEventStoreChanged` for re-sync.
    - **Apple Events / Automation**: `NSAppleEventsUsageDescription` required in Info.plist (silent failure without it — System Settings won't even list the app); detect denial post-call via AE error `-1743` in `SBApplicationDelegate`; recovery is to direct the user to *System Settings → Privacy & Security → Automation* (the exact URL scheme used by this codebase, if any, will be cited from the source file rather than guessed here).
    - **Accessibility**: `AXIsProcessTrusted` returns false until granted; cannot prompt directly — must direct user to Settings.
    - **Notifications**: `UNUserNotificationCenter.current().requestAuthorization`.
12. **IPC & subprocess** — Unix socket server pattern: `socket(AF_UNIX, SOCK_STREAM)` → `sockaddr_un.sun_path` → `unlink(stalePath)` → `bind` → `listen` → `DispatchSourceRead` on accept fd → line-delimited JSON parse → `DispatchQueue.main.async` re-dispatch to MainActor; `Process` + `Pipe` daemon spawn (perl + dylib args); `DispatchSourceFileSystemObject` for file watching (`eventMask: [.write, .extend]`) + offset tracking + `pendingTail` for partial-line buffering during incremental JSONL parse.
13. **Hook installers** — Idempotent install pattern: read existing JSON/YAML config → **clean all `nemonotch` entries from all relevant event arrays** (so re-install doesn't duplicate) → re-register only currently-enabled events → write back. Targets covered: `~/.claude/settings.json` (JSON), `~/.gemini/settings.json` (JSON), `~/.hermes/config.yaml` + `~/.hermes/profiles/*/config.yaml` (YAML, string-match `isInstalled` check). Sender script generation: writes shell script to `~/.nemonotch/hooks/*-sender.sh`, sets 0o755 via `setAttributes`, detects `CLI_SOURCE` from env/argv.
14. **Keychain** — `SecItemCopyMatching(kSecClassGenericPassword query)` to load, `SecItemAdd` to persist on miss, fallback-generate pattern used in `OpenClawService` for Ed25519 device identity.
15. **Swift 6 concurrency conventions** — How this codebase satisfies the strict-concurrency checker:
    - `@MainActor @Observable final class` is the default service shape (16 instances).
    - `@unchecked Sendable` bridge wrapper structs (`InfoBox`, `NowPlayingInfoBox`, `PlayerEventDelegate`) for marshalling `[String: Any]?` across isolation boundaries.
    - `nonisolated(unsafe)` for queue-owned mutable state (`HookServer.socketFd`, `acceptSource`).
    - `Task { @MainActor [weak self] in ... }` re-dispatch from background DispatchSources back to MainActor.
    - `nonisolated(unsafe) static let shared` for `LogService` (intentionally global, thread-safe internally via DDLog).
16. **SwiftUI patterns in this codebase** — `@Environment(\.serviceName)` + `@Observable` wiring in `NotchView` (8 services injected), `effectiveStatus = isActiveScreen ? coordinator.status : .closed` per-screen computed property (kills expansion flash on secondary displays), animation pair (`interactiveSpring(duration: 0.314)` open + `spring(duration: 0.24)` close), shared decorators in `ViewModifiers.swift` and `ToolStyles.swift`, `MarkdownRenderer.swift` for AI message rendering.
17. **Architecture patterns** — `AppDelegate.applicationDidFinishLaunching` instantiates all services and wires the `NotchCoordinator` via `contentBuilder` closure. **Closure injection over singletons** (refactor `91dc446 → aff5663`): `AppDelegate.shared` was removed; consumers now receive their dependencies via initializer args / closures, not via a global. Protocol-first multi-provider design: `AIProvider`, `ConversationParser`, `MultiAgentMonitor` define only common interfaces; each implementation keeps its own Result type. `LifecycleAware` helper for tab views.
18. **Logging conventions** — `CocoaLumberjackSwift` via `LogService`, `DDFileLogger` with `rollingFrequency = 86400` and 7-day retention at `~/.NemoNotch/logs/`, DEBUG builds use `.all`, Release uses `.info`, static `nonisolated` API (`LogService.debug/info/warn/error`), category naming = module name (`"MediaService"`, `"HookServer"`, `"NotchCoordinator"`).
19. **Reference-projects index** — Mapping pulled from CLAUDE.md, kept here as a single grep target so AI doesn't need to re-derive from CLAUDE.md prose. One row per (capability → reference project → what to look at).

## 6. Writing conventions

Per technique:
- 1-sentence "what / why" (no fluff).
- `file_path:line_range` anchor (e.g. `NemoNotch/Services/MediaRemote.swift:39-61`). When the technique is a function, include the function name in the anchor line so the reader can re-locate it after line numbers drift (e.g. `MediaRemote.swift:39-61  initialize()`).
- 5–15 line code skeleton — real code copied from the file, not paraphrased. Trim with `// …` ellipsis lines for unrelated branches; never silently delete code, the reader must be able to tell what was elided.
- Explicit `**Gotcha:**` line if one exists. One gotcha = one line. If multiple, multiple lines.
- Cross-link with `[§N Section]` markers where another section is relevant.
- Inline reference-project pointer where one applies (e.g. *see NotchDrop NSPanel subclass*).

Doc-wide conventions:
- No prose paragraph longer than 3 lines.
- Bullets and code dominate.
- Use **DON'T** call-outs for encoded anti-patterns (e.g. don't `MRSkipForward` on Spotify).
- Headings use `##` for sections, `###` for techniques.
- Code blocks use the `swift` language tag for Swift, `objc` for `@convention(c)` bits when clearer, `bash` for shell, `json` for config.

## 7. Acceptance criteria

The cookbook is "done" when:

1. All 19 sections exist with content (no `TBD` placeholders).
2. Every technique mentioned in this spec has a `file:line` anchor and a code skeleton.
3. Every **Gotcha** identified in the scout-agent reports (≥15 documented) appears as a `**Gotcha:**` line somewhere.
4. CLAUDE.md has a 4-line addition pointing to the cookbook + a flat list of section titles for grep.
5. The cookbook plus the CLAUDE.md addition are committed in a single commit on `develop` (per repo workflow — small docs change, no feature branch needed per `[[feedback_git-workflow]]`).
6. Final size: 1500–2200 lines. If >2500, Section 8 (System sensing) gets split into its own file and the cookbook references it.

## 8. Out of scope for this spec

- Decision on splitting Section 8 happens *during* writing, not now.
- Translating to Chinese (`README_CN.md` style) — not requested.
- A second-pass review by the user for accuracy will happen after the cookbook is written, not as part of this spec gate.

## 9. Risks

- **Drift:** Cookbook references `file:line` ranges that will rot as the codebase changes. Mitigation: cite **function names alongside line numbers** so a moved function is still findable; add a doc maintenance note in Section 1 that says "if you change a function the cookbook references, update the cookbook in the same commit."
- **Size:** Risk of overrunning 2200 lines. Mitigation: budget per section (avg 80–120 lines), aggressive trimming during writing, willingness to split Section 8 if needed.
- **Inaccuracy in private API material:** Some private API behavior is OS-version-dependent (`MRNowPlayingController` is 15.4+, not earlier). Mitigation: state OS-version constraints inline for each private API.

## 10. Next step

Hand off to `superpowers:writing-plans` to produce the implementation plan that actually writes the cookbook content. The plan should include verification steps (e.g. open each cited file, confirm `file:line` is correct, confirm code skeleton compiles in isolation as a snippet — not a full compile check, just "the syntax is real Swift").
