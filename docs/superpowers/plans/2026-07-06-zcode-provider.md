# zcode AI Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add zcode (ZCode.app's GLM-based, Claude-Code-compatible agent CLI) as a fourth AI provider so its sessions drive NemoNotch's badge / activity-glow / completion-flash / AI-tab surfaces.

**Architecture:** zcode emits Claude-shaped hook payloads, so it reuses the existing `hook-sender.sh` → `HookServer` → provider pipeline (no plugin). A new `ZcodeProvider` (notify + live status only, mirroring `OpencodeProvider`) writes into the shared `AISessionStore`. A new `.zcode` `HookInstaller` target handles zcode's nested `hooks.events` config shape.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, Swift Testing.

## Global Constraints

- Swift Testing only for new tests (`import Testing`, `@Test`, `#expect`) — never XCTest.
- Never edit `project.pbxproj` to add files; the project auto-syncs root groups (new files under `NemoNotch/` are picked up automatically).
- Logging via `LogService.debug/info/warn/error(_, category:)`; category = module name (`"ZcodeProvider"`, `"HookInstaller"`).
- All services use `@Observable`; providers conform to `AIProvider` and mutate `AISessionStore`.
- zcode config path: `~/.zcode/cli/config.json`. Session id prefix: `sess_`. Hook env var: `ZCODE_SESSION_ID`. Config nests hooks under `hooks.events.<Event>` with a sibling `hooks.enabled = true`.
- `AppSettings.zcodeEnabled` default `true`.
- Build check command: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"`
- Test command: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "Test Suite|passed|failed|error:"`

---

### Task 1: `ZcodeLogoIcon` tintable vector

**Files:**
- Create: `NemoNotch/Helpers/ZcodeLogoIcon.swift`

**Interfaces:**
- Produces: `ZcodeLogoIcon(size: CGFloat = 14, color: Color = .white)` — a SwiftUI `View`, same API as `OpencodeLogoIcon`.

- [ ] **Step 1: Create the icon file**

The official `icon.svg` (viewBox 30×30) draws a white "Z" as three shapes on a rounded square. Port just the three white "Z" shapes as tintable filled paths (corner curves approximated as line segments — imperceptible at badge size).

```swift
import SwiftUI

/// zcode's brand "Z" mark, redrawn as a tintable vector (source: zcode.z.ai
/// icon.svg, viewBox 30×30 — the three white glyph shapes only, background
/// square dropped so it tints like a badge glyph). Mirrors `OpencodeLogoIcon`'s
/// `size`/`color` API so it drops into the same badge / source-icon slots.
struct ZcodeLogoIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { ctx, canvas in
            // Glyph bbox in the 30 viewBox: x 5.7…24.3, y 7.1…22.91.
            // Fit the full 30×30 viewBox into the frame (uniform scale).
            let scale = min(canvas.width, canvas.height) / 30.0
            let xInset = (canvas.width - 30 * scale) / 2
            let yInset = (canvas.height - 30 * scale) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale + xInset, y: y * scale + yInset)
            }
            func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                guard let first = pts.first else { return path }
                path.move(to: p(first.0, first.1))
                for pt in pts.dropFirst() { path.addLine(to: p(pt.0, pt.1)) }
                path.closeSubpath()
                return path
            }

            // Top bar
            ctx.fill(poly([(15.47, 7.1), (14.17, 8.95), (13.27, 9.42), (6.17, 9.42), (6.17, 7.1)]),
                     with: .color(color))
            // Diagonal
            ctx.fill(poly([(24.3, 7.1), (13.14, 22.91), (5.7, 22.91), (16.86, 7.1)]),
                     with: .color(color))
            // Bottom bar
            ctx.fill(poly([(14.53, 22.91), (15.84, 21.05), (16.74, 20.58), (23.83, 20.58), (23.83, 22.91)]),
                     with: .color(color))
        }
        .frame(width: size, height: size)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Helpers/ZcodeLogoIcon.swift
git commit -m "feat(zcode): add tintable ZcodeLogoIcon vector"
```

---

### Task 2: `AppSettings.zcodeEnabled`

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift`

**Interfaces:**
- Produces: `AppSettings.zcodeEnabled: Bool` (UserDefaults-backed, default `true`); `AppSettings.zcodeEnabledKey: String`.

- [ ] **Step 1: Add the key constant**

In the "Provider enable flags" block (next to `opencodeEnabledKey` at line ~91), add:

```swift
    static let zcodeEnabledKey = "zcodeEnabled"
```

- [ ] **Step 2: Add the stored property**

After the `opencodeEnabled` property (line ~104), add:

```swift
    var zcodeEnabled: Bool {
        didSet { UserDefaults.standard.set(zcodeEnabled, forKey: Self.zcodeEnabledKey) }
    }
```

- [ ] **Step 3: Initialize it in `init`**

After the `opencodeEnabled = ...` init line (line ~175), add:

```swift
        zcodeEnabled = UserDefaults.standard
            .object(forKey: Self.zcodeEnabledKey) as? Bool ?? true
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Models/AppSettings.swift
git commit -m "feat(zcode): add zcodeEnabled app setting"
```

---

### Task 3: `AISource.zcode` enum case + all exhaustive-switch arms

Adding the enum case breaks every exhaustive `switch AISource`. This task adds the case and fills every arm so the app compiles with zcode as a known source (still unwired to a provider — that's Task 5/6).

**Files:**
- Modify: `NemoNotch/Models/AIProvider.swift` (enum + `displayModel` + `formatZcodeModel`)
- Modify: `NemoNotch/Notch/Badge/BadgeViewModel.swift` (provider gate)
- Modify: `NemoNotch/Notch/Badge/BadgeIconView.swift` (`aiSourceIcon`)
- Modify: `NemoNotch/Notch/CompletionToastView.swift` (`sourceIcon`)
- Modify: `NemoNotch/Tabs/AIChatTab.swift` (`allSessions`, `consoleTitle`, `sourceIcon`, `sourceTint`)

**Interfaces:**
- Produces: `AISource.zcode`.
- Consumes: `ZcodeLogoIcon` (Task 1), `AppSettings.zcodeEnabled` (Task 2).

- [ ] **Step 1: Add the enum case**

`NemoNotch/Models/AIProvider.swift` line 3-7:

```swift
enum AISource: String, Codable, CaseIterable {
    case claude
    case gemini
    case opencode
    case zcode
}
```

- [ ] **Step 2: Add `displayModel` arm + `formatZcodeModel`**

In `AIProvider.swift`, in `displayModel` (line ~136) add the `.zcode` arm:

```swift
        case .opencode:
            return formatOpencodeModel(model)
        case .zcode:
            return formatZcodeModel(model)
        }
```

After `formatOpencodeModel` (line ~182), add:

```swift
    private func formatZcodeModel(_ model: String) -> String {
        // zcode runs GLM models, e.g. "glm-4.6" → "GLM 4.6".
        model
            .split(separator: "-")
            .map { $0.lowercased() == "glm" ? "GLM" : String($0) }
            .joined(separator: " ")
    }
```

- [ ] **Step 3: Add the `BadgeViewModel` provider-gate arm**

`NemoNotch/Notch/Badge/BadgeViewModel.swift` line ~46:

```swift
            case .opencode: appSettings.opencodeEnabled
            case .zcode: appSettings.zcodeEnabled
            }
```

- [ ] **Step 4: Add the badge source-icon arm**

`NemoNotch/Notch/Badge/BadgeIconView.swift` `aiSourceIcon` (line ~131):

```swift
        case .opencode:
            OpencodeLogoIcon(size: 13, color: Color(red: 0.55, green: 0.78, blue: 0.55))
        case .zcode:
            ZcodeLogoIcon(size: 13, color: Color(red: 0.11, green: 0.44, blue: 0.96))
        }
```

- [ ] **Step 5: Add the completion-toast source-icon arm**

`NemoNotch/Notch/CompletionToastView.swift` `sourceIcon` (line ~68):

```swift
        case .ai(.opencode):
            OpencodeLogoIcon(size: s, color: .white)
        case .ai(.zcode):
            ZcodeLogoIcon(size: s, color: Color(red: 0.11, green: 0.44, blue: 0.96))
```

- [ ] **Step 6: Add the AIChatTab arms**

`NemoNotch/Tabs/AIChatTab.swift`:

`allSessions` (line ~23):
```swift
            case .opencode: return appSettings.opencodeEnabled
            case .zcode: return appSettings.zcodeEnabled
            }
```

`consoleTitle` (line ~101):
```swift
        case .opencode: "opencode"
        case .zcode: "zcode"
        case .none: "AI Sessions"
        }
```

`sourceIcon(_:size:)` (line ~703):
```swift
        case .opencode:
            OpencodeLogoIcon(size: size, color: sourceTint(source))
        case .zcode:
            ZcodeLogoIcon(size: size, color: sourceTint(source))
        }
```

`sourceTint(_:)` (line ~782):
```swift
        case .opencode: Color(red: 0.55, green: 0.78, blue: 0.55)
        case .zcode: Color(red: 0.11, green: 0.44, blue: 0.96)
        }
```

- [ ] **Step 7: Build to verify all switches are exhaustive**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"`
Expected: `** BUILD SUCCEEDED **` (if any "switch must be exhaustive" error appears, add the missing `.zcode` arm at that file:line and rebuild)

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Models/AIProvider.swift NemoNotch/Notch/Badge/BadgeViewModel.swift NemoNotch/Notch/Badge/BadgeIconView.swift NemoNotch/Notch/CompletionToastView.swift NemoNotch/Tabs/AIChatTab.swift
git commit -m "feat(zcode): add AISource.zcode case and UI source arms"
```

---

### Task 4: `HookInstaller` `.zcode` target (nested config) + hook-sender detection

**Files:**
- Modify: `NemoNotch/Services/HookInstaller.swift`
- Test: `NemoNotchTests/ZcodeHookInstallerTests.swift`

**Interfaces:**
- Produces: `HookTarget.zcode`; `HookInstaller.install(.zcode)`, `.uninstall(.zcode)`, `.isInstalled(.zcode)` operating on the nested `hooks.events` container.

- [ ] **Step 1: Write the failing test**

Create `NemoNotchTests/ZcodeHookInstallerTests.swift`. The installer reads/writes real paths, so the test drives the pure container transform directly by pointing at a temp file via a helper. Since `HookInstaller` targets a fixed path, test the round-trip by writing a temp config, invoking the JSON transform through a small testable seam. Add this seam to `HookInstaller` in Step 3 (`applyInstall`/`applyUninstall`/`detectInstalled` as pure `[String:Any]` transforms); the test exercises those.

```swift
import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct ZcodeHookInstallerTests {
    private let cmdSuffix = "nemonotch/hooks/hook-sender.sh"

    @Test func installWrapsHooksInNestedEventsContainerWithEnabledFlag() {
        var settings: [String: Any] = ["mcp": ["servers": [:]], "plugins": ["x": true]]
        settings = HookInstaller.applyInstall(settings, target: .zcode, command: "~/\(cmdSuffix)")

        let hooks = settings["hooks"] as! [String: Any]
        #expect(hooks["enabled"] as? Bool == true)
        let events = hooks["events"] as! [String: Any]
        #expect(events["SessionStart"] != nil)
        #expect(events["Stop"] != nil)
        // Foreign top-level keys are preserved.
        #expect(settings["mcp"] != nil)
        #expect(settings["plugins"] != nil)
    }

    @Test func isInstalledDetectsNestedEntries() {
        var settings: [String: Any] = [:]
        settings = HookInstaller.applyInstall(settings, target: .zcode, command: "~/\(cmdSuffix)")
        #expect(HookInstaller.detectInstalled(settings, target: .zcode) == true)
    }

    @Test func uninstallRemovesOnlyOurEntriesAndKeepsForeign() {
        // Pre-existing foreign hook the user added.
        let foreign: [String: Any] = ["hooks": [["type": "command", "command": "bash /me/foo.sh"]]]
        var settings: [String: Any] = [
            "hooks": ["enabled": true, "events": ["Stop": [foreign]]],
            "mcp": ["servers": [:]],
        ]
        settings = HookInstaller.applyInstall(settings, target: .zcode, command: "~/\(cmdSuffix)")
        settings = HookInstaller.applyUninstall(settings, target: .zcode)

        #expect(HookInstaller.detectInstalled(settings, target: .zcode) == false)
        // Foreign Stop hook survives.
        let events = (settings["hooks"] as? [String: Any])?["events"] as? [String: Any]
        let stop = events?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
        #expect(settings["mcp"] != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "applyInstall|error:|BUILD FAILED"`
Expected: FAIL — `applyInstall`/`applyUninstall`/`detectInstalled` don't exist yet (compile error).

- [ ] **Step 3: Add the `.zcode` target and refactor to pure transforms**

In `NemoNotch/Services/HookInstaller.swift`, extend `HookTarget`:

```swift
enum HookTarget {
    case claude
    case gemini
    case zcode

    var settingsPath: String {
        switch self {
        case .claude: return NSHomeDirectory() + "/.claude/settings.json"
        case .gemini: return NSHomeDirectory() + "/.gemini/settings.json"
        case .zcode: return NSHomeDirectory() + "/.zcode/cli/config.json"
        }
    }

    var hookEvents: [String] {
        switch self {
        case .claude: return [
                "PreToolUse", "PostToolUse", "Stop", "SessionStart",
                "SessionEnd", "Notification", "UserPromptSubmit", "PermissionRequest",
            ]
        case .gemini: return [
                "SessionStart", "SessionEnd", "Notification",
                "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool",
            ]
        case .zcode: return [
                "SessionStart", "SessionEnd", "UserPromptSubmit",
                "PreToolUse", "PostToolUse", "Stop", "Notification",
            ]
        }
    }

    /// zcode nests hooks under `hooks.events.<Event>` with a sibling
    /// `hooks.enabled = true` flag, unlike Claude/Gemini's flat `hooks.<Event>`.
    var usesNestedEventsContainer: Bool {
        switch self {
        case .zcode: return true
        case .claude, .gemini: return false
        }
    }
}
```

Add these pure `[String: Any]` transforms (they carry all the mutation logic; the disk-facing `install`/`uninstall`/`isInstalled` call them). Place inside `enum HookInstaller`:

```swift
    /// Reads the event→entries map for `target`, unwrapping zcode's nested
    /// `hooks.events` container.
    static func readEvents(_ settings: [String: Any], target: HookTarget) -> [String: Any] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        if target.usesNestedEventsContainer {
            return hooks["events"] as? [String: Any] ?? [:]
        }
        return hooks
    }

    /// Writes the event→entries map back, re-wrapping zcode's nested container
    /// (and setting `enabled = true`). Drops the `hooks` key when empty.
    static func writeEvents(_ events: [String: Any], into settings: inout [String: Any], target: HookTarget) {
        if target.usesNestedEventsContainer {
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            if events.isEmpty {
                hooks.removeValue(forKey: "events")
                hooks.removeValue(forKey: "enabled")
            } else {
                hooks["events"] = events
                hooks["enabled"] = true
            }
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
        } else {
            if events.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = events
            }
        }
    }

    /// Pure install transform: strips all our old entries from every event, then
    /// registers `target.hookEvents` pointing at `command`.
    static func applyInstall(_ settings: [String: Any], target: HookTarget, command: String) -> [String: Any] {
        var out = settings
        var events = readEvents(out, target: target)

        for (event, entries) in events {
            if var eventEntries = entries as? [[String: Any]] {
                eventEntries.removeAll { entry in
                    guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                    return inner.contains { isOurHookCommand($0["command"] as? String) }
                }
                if eventEntries.isEmpty { events.removeValue(forKey: event) }
                else { events[event] = eventEntries }
            }
        }

        let hookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": command]],
        ]
        for event in target.hookEvents {
            var entries = events[event] as? [[String: Any]] ?? []
            entries.append(hookEntry)
            events[event] = entries
        }

        writeEvents(events, into: &out, target: target)
        return out
    }

    /// Pure uninstall transform: removes only our entries from `target.hookEvents`.
    static func applyUninstall(_ settings: [String: Any], target: HookTarget) -> [String: Any] {
        var out = settings
        var events = readEvents(out, target: target)
        for event in target.hookEvents {
            guard var entries = events[event] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { isOurHookCommand($0["command"] as? String) }
            }
            if entries.isEmpty { events.removeValue(forKey: event) }
            else { events[event] = entries }
        }
        writeEvents(events, into: &out, target: target)
        return out
    }

    /// Pure detection: any of `target.hookEvents` holds one of our entries.
    static func detectInstalled(_ settings: [String: Any], target: HookTarget) -> Bool {
        let events = readEvents(settings, target: target)
        for event in target.hookEvents {
            if let entries = events[event] as? [[String: Any]],
               entries.contains(where: { entry in
                   guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                   return inner.contains { isOurHookCommand($0["command"] as? String) }
               }) {
                return true
            }
        }
        return false
    }
```

Now rewrite the three disk-facing methods to delegate:

```swift
    static func isInstalled(_ target: HookTarget) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return detectInstalled(json, target: target)
    }

    static func install(_ target: HookTarget) throws {
        try ensureScriptExists()
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }
        settings = applyInstall(settings, target: target, command: hookCommand)
        try writeSettings(settings, to: target)
    }

    static func uninstall(_ target: HookTarget) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let settings = applyUninstall(json, target: target)
        try writeSettings(settings, to: target)
    }
```

Note: `isOurHookCommand`, `hookCommand`, `ensureScriptExists`, `writeSettings` already exist and are unchanged in signature. (`isOurHookCommand` is currently `private`; leave it — the pure transforms are in the same `enum HookInstaller` so they can call it. `applyInstall`/`applyUninstall`/`detectInstalled`/`readEvents`/`writeEvents` are `static` non-private so the test can reach them.)

- [ ] **Step 4: Add zcode detection to `hook-sender.sh` and bump the version**

In `ensureScriptExists`, bump the version marker (line ~35):

```swift
    private static let scriptVersion = "# version: 14"
```

In the script body, in the CLI-source detection block, add a zcode branch **before** the Claude branch (zcode is Claude-compatible, so must win):

```bash
        if [ -n "$GEMINI_SESSION_ID" ]; then
            CLI_SOURCE="gemini"
        elif [ -n "$ZCODE_SESSION_ID" ]; then
            CLI_SOURCE="zcode"
        elif [ -n "$CLAUDE_SESSION_ID" ]; then
            CLI_SOURCE="claude"
        else
            PARENT_PID=$PPID
            COMMAND_LINE=$(ps -o args= -p "$PARENT_PID" 2>/dev/null || echo "")
            if echo "$COMMAND_LINE" | grep -q "gemini"; then
                CLI_SOURCE="gemini"
            elif echo "$COMMAND_LINE" | grep -qi "zcode"; then
                CLI_SOURCE="zcode"
            elif echo "$COMMAND_LINE" | grep -q "claude"; then
                CLI_SOURCE="claude"
            else
                PARENT=$(ps -o comm= -p "$PARENT_PID" 2>/dev/null || echo "")
                case "$PARENT" in
                    *gemini*)  CLI_SOURCE="gemini" ;;
                    *[zZ]code*) CLI_SOURCE="zcode" ;;
                    *claude*)  CLI_SOURCE="claude" ;;
                    *)         CLI_SOURCE="unknown" ;;
                esac
            fi
        fi
```

Also update the script's header comment line to mention zcode:
```swift
        # hook-sender.sh — forwards Claude Code / Gemini CLI / zcode hook events to NemoNotch over TCP loopback.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "ZcodeHookInstaller|passed|failed|error:"`
Expected: the three `ZcodeHookInstallerTests` pass; no other tests break.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Services/HookInstaller.swift NemoNotchTests/ZcodeHookInstallerTests.swift
git commit -m "feat(zcode): HookInstaller .zcode target with nested events config"
```

---

### Task 5: `ZcodeProvider`

**Files:**
- Create: `NemoNotch/Services/ZcodeProvider.swift`
- Test: `NemoNotchTests/ZcodeProviderTests.swift`

**Interfaces:**
- Produces: `ZcodeProvider(store: AISessionStore)` conforming to `AIProvider`; `source == .zcode`; `handleEvent(_:)`, `installHooks()`, `uninstallHooks()`, `respondToPermission(sessionId:approved:)` (no-op), `setHookServer(_:)`.

- [ ] **Step 1: Write the failing test**

Create `NemoNotchTests/ZcodeProviderTests.swift`:

```swift
import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct ZcodeProviderTests {
    private func event(_ json: String) -> HookEvent {
        try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    @Test func sessionStartThenPromptThenStopTransitions() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_abc123"

        provider.handleEvent(event(#"{"hook_event_name":"SessionStart","session_id":"\#(sid)","cwd":"/tmp/proj"}"#))
        #expect(store.get(sid)?.source == .zcode)
        #expect(store.get(sid)?.phase == .idle)

        provider.handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        #expect(store.get(sid)?.status == .working)

        provider.handleEvent(event(#"{"hook_event_name":"Stop","session_id":"\#(sid)"}"#))
        #expect(store.get(sid)?.status == .waiting)
    }

    @Test func preToolUseRecordsTool() {
        let store = AISessionStore()
        let provider = ZcodeProvider(store: store)
        let sid = "sess_tool"
        provider.handleEvent(event(#"{"hook_event_name":"PreToolUse","session_id":"\#(sid)","tool_name":"Bash"}"#))
        #expect(store.get(sid)?.currentTool == "Bash")
        #expect(store.get(sid)?.status == .working)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "ZcodeProvider|error:|BUILD FAILED"`
Expected: FAIL — `ZcodeProvider` doesn't exist (compile error).

- [ ] **Step 3: Create `ZcodeProvider`**

Mirror `OpencodeProvider` (notify + status, no parsing, no approval). Uses `HookInstaller.install(.zcode)` since zcode uses the shared hook mechanism.

```swift
import Foundation

/// Fourth AIProvider. zcode (ZCode.app's GLM agent CLI) emits Claude-shaped
/// hook events through the shared hook-sender.sh → HookServer pipeline. This
/// provider maps them into AISessionStore. Notify + live status only: no
/// conversation/token parsing, no notch-side approval (zcode's TUI owns it).
@MainActor
@Observable
final class ZcodeProvider: AIProvider {
    let source: AISource = .zcode
    var isHookInstalled = false

    private let store: AISessionStore
    private var timeoutTimer: Timer?
    private weak var hookServer: HookServer?

    init(store: AISessionStore) {
        self.store = store
        isHookInstalled = HookInstaller.isInstalled(.zcode)
        LogService.info("ZcodeProvider init (hookInstalled=\(isHookInstalled))", category: "ZcodeProvider")
    }

    func setHookServer(_ server: HookServer) {
        hookServer = server
    }

    func installHooks() {
        do {
            try HookInstaller.install(.zcode)
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install zcode hooks: \(error)", category: "ZcodeProvider")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall(.zcode)
            isHookInstalled = false
            store.removeAll(source: .zcode)
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        } catch {
            LogService.error("Failed to uninstall zcode hooks: \(error)", category: "ZcodeProvider")
        }
    }

    /// Notify-only — zcode's own TUI owns the approval decision.
    func respondToPermission(sessionId: String, approved: Bool) {}

    // MARK: - Event Handling

    func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()
        LogService.debug(
            "zcode event \(event.hookEventName) session \(sessionId.prefix(10))",
            category: "ZcodeProvider"
        )

        switch event.hookEventName {
        case "SessionStart":
            var session = AISessionState(sessionId: sessionId, source: .zcode)
            session.phase = .idle
            applyContext(to: &session, event: event)
            store.upsert(session)

        case "UserPromptSubmit":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .processing)
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PreToolUse":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = event.toolName
                s.isPreToolUse = true
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PostToolUse":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "Notification":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .waitingForInput)
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "Stop":
            store.mutateOrCreate(sessionId, source: .zcode) { s in
                s.phase = s.phase.transition(to: .waitingForInput)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "SessionEnd":
            store.remove(sessionId)

        default:
            break
        }

        scheduleTimeoutCleanup()
    }

    private func applyContext(to session: inout AISessionState, event: HookEvent) {
        if let cwd = event.cwd { session.cwd = cwd }
        if let model = event.model, !model.isEmpty { session.model = model }
        if let msg = event.message, !msg.isEmpty { session.lastMessage = msg }
        session.lastEventName = event.hookEventName
    }

    // MARK: - Timeout (mirrors opencode)

    private static let cleanupTickInterval: TimeInterval = 60
    private static let silentDemoteThreshold: TimeInterval = 300
    private static let removeStaleThreshold: TimeInterval = 1800

    private func scheduleTimeoutCleanup() {
        guard timeoutTimer == nil else { return }
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: Self.cleanupTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupStaleSessions()
            }
        }
    }

    private func cleanupStaleSessions() {
        let now = Date()
        let demoteCutoff = now.addingTimeInterval(-Self.silentDemoteThreshold)
        let removeCutoff = now.addingTimeInterval(-Self.removeStaleThreshold)

        for session in store.sessions(for: .zcode) where session.lastEventTime < demoteCutoff {
            if case .waitingForInput = session.phase {
                store.mutate(session.id) { s in
                    s.phase = s.phase.transition(to: .idle)
                }
                LogService.info("Demoted silent zcode session \(session.id.prefix(8)) to idle", category: "ZcodeProvider")
            }
        }

        for session in store.sessions(for: .zcode) where session.lastEventTime < removeCutoff {
            store.remove(session.id)
            LogService.info("Removed stale zcode session \(session.id.prefix(8))", category: "ZcodeProvider")
        }

        if store.sessions(for: .zcode).isEmpty {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "ZcodeProvider|passed|failed|error:"`
Expected: both `ZcodeProviderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/ZcodeProvider.swift NemoNotchTests/ZcodeProviderTests.swift
git commit -m "feat(zcode): add ZcodeProvider (notify + live status)"
```

---

### Task 6: Wire `ZcodeProvider` into `AICLIMonitorService` + routing

**Files:**
- Modify: `NemoNotch/Services/AICLIMonitorService.swift`
- Test: `NemoNotchTests/AISourceRoutingTests.swift`

**Interfaces:**
- Consumes: `ZcodeProvider` (Task 5), `HookInstaller.install(.zcode)`/`isInstalled(.zcode)` (Task 4).
- Produces: `AICLIMonitorService.zcodeProvider`; routing of `cli_source: "zcode"` and `sess_`-prefixed sessions to zcode.

- [ ] **Step 1: Write the failing test**

Append to `NemoNotchTests/AISourceRoutingTests.swift` (inside the struct):

```swift
    /// zcode: an explicit cli_source routes to zcode.
    @Test func taggedZcodeEventRoutesToZcode() {
        let service = AICLIMonitorService()
        let sid = "sess_zc_tagged"
        service.hookServer.onEventReceived?(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)","cli_source":"zcode"}"#))
        #expect(service.store.get(sid)?.source == .zcode)
    }

    /// zcode: an untagged event for a `sess_`-prefixed session routes to zcode,
    /// not Claude. (`sess_` is distinct from opencode's `ses_`.)
    @Test func untaggedZcodeSessionRoutesToZcode() {
        let service = AICLIMonitorService()
        let sid = "sess_zc_untagged"
        service.hookServer.onEventReceived?(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"\#(sid)"}"#))
        #expect(service.store.get(sid)?.source == .zcode)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "ZcodeSession|RoutesToZcode|passed|failed|error:"`
Expected: FAIL — untagged `sess_` currently falls through to Claude (source is `.claude`, not `.zcode`); tagged case fails because there's no `zcodeProvider`.

- [ ] **Step 3: Add the provider to the service**

`NemoNotch/Services/AICLIMonitorService.swift`:

Stored property (after `opencodeProvider`, line ~9):
```swift
    let opencodeProvider: OpencodeProvider
    let zcodeProvider: ZcodeProvider
```

In `init` (after the opencode lines ~19, ~23, ~28):
```swift
        let opencode = OpencodeProvider(store: store)
        let zcode = ZcodeProvider(store: store)
        ...
        opencodeProvider = opencode
        zcodeProvider = zcode
        ...
        opencode.setHookServer(hookServer)
        zcode.setHookServer(hookServer)
```

Update the launch refresh guard (line ~35):
```swift
        if claude.isHookInstalled || gemini.isHookInstalled || opencode.isHookInstalled || zcode.isHookInstalled {
```

- [ ] **Step 4: Add zcode to the service's aggregate methods**

`anyHookInstalled` (line ~60):
```swift
    var anyHookInstalled: Bool {
        claudeProvider.isHookInstalled || geminiProvider.isHookInstalled
            || opencodeProvider.isHookInstalled || zcodeProvider.isHookInstalled
    }
```

`installHooks()` (line ~63):
```swift
    func installHooks() {
        claudeProvider.installHooks()
        geminiProvider.installHooks()
        opencodeProvider.installHooks()
        zcodeProvider.installHooks()
    }
```

`respondToPermission` switch (line ~74):
```swift
        case .opencode: opencodeProvider.respondToPermission(sessionId: sessionId, approved: approved)
        case .zcode: zcodeProvider.respondToPermission(sessionId: sessionId, approved: approved)
        }
```

- [ ] **Step 5: Add routing**

In `routeEvent`, extend the unknown-source block (line ~87). zcode's `sess_` is checked alongside opencode's `ses_` (distinct prefixes):
```swift
        if source == "unknown" {
            if event.sessionId?.hasPrefix("sess_") == true {
                source = "zcode"
            } else if event.sessionId?.hasPrefix("ses_") == true {
                source = "opencode"
            } else {
                let combined = "\(event.message ?? "") \(event.toolName ?? "") \(event.cwd ?? "")".lowercased()
                if combined.contains("gemini") || combined.contains("glm") {
                    source = "gemini"
                }
            }
        }
```

Add the `case "zcode"` arm (line ~111):
```swift
        case "opencode":
            opencodeProvider.handleEvent(event)
        case "zcode":
            zcodeProvider.handleEvent(event)
```

Add the owner-based fallback arm (line ~119):
```swift
                case .opencode: opencodeProvider.handleEvent(event)
                case .zcode: zcodeProvider.handleEvent(event)
                }
```

- [ ] **Step 6: Add auto-install on server ready**

In `handleServerReady` (line ~127), after the opencode install lines, add — gated on zcode being present so we never create a config on machines without zcode:
```swift
        try? OpencodePluginInstaller.install()
        opencodeProvider.isHookInstalled = OpencodePluginInstaller.isInstalled
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.zcode/cli/config.json") {
            try? HookInstaller.install(.zcode)
        }
        zcodeProvider.isHookInstalled = HookInstaller.isInstalled(.zcode)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "RoutesToZcode|RoutesToOpencode|passed|failed|error:"`
Expected: new zcode routing tests pass; `untaggedOpencodeSessionRoutesToOpencode` still passes (no regression).

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Services/AICLIMonitorService.swift NemoNotchTests/AISourceRoutingTests.swift
git commit -m "feat(zcode): wire ZcodeProvider into AICLIMonitorService + routing"
```

---

### Task 7: Install UI surfaces (AI tab card, Settings card, menu button)

**Files:**
- Modify: `NemoNotch/Tabs/AIChatTab.swift`
- Modify: `NemoNotch/Settings/SettingsView.swift`
- Modify: `NemoNotch/Notch/MenuBar/HooksSection.swift`
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `aiService.zcodeProvider` (Task 6), `appSettings.zcodeEnabled` (Task 2), `ZcodeLogoIcon` (Task 1).

- [ ] **Step 1: Add the AI-tab provider row + kind + counts**

`NemoNotch/Tabs/AIChatTab.swift`:

After `opencodeKind` (line ~47):
```swift
    private var zcodeKind: ProviderCardKind {
        Self.kind(
            enabled: appSettings.zcodeEnabled,
            installed: aiService.zcodeProvider.isHookInstalled
        )
    }
```

`hasAnyReadyProvider` (line ~50):
```swift
    private var hasAnyReadyProvider: Bool {
        claudeKind == .ready || geminiKind == .ready || opencodeKind == .ready || zcodeKind == .ready
    }
```

After `opencodeCount` (line ~83):
```swift
    private var zcodeCount: Int {
        allSessions.count(where: { $0.source == .zcode })
    }
```

`hasMixedSources` (line ~86):
```swift
    private var hasMixedSources: Bool {
        [claudeCount, geminiCount, opencodeCount, zcodeCount].count(where: { $0 > 0 }) > 1
    }
```

`consoleSummary` sourceParts (line ~110):
```swift
            opencodeCount > 0 ? "opencode \(opencodeCount)" : nil,
            zcodeCount > 0 ? "zcode \(zcodeCount)" : nil,
        ].compactMap(\.self) : []
```

In `providerStatusList` after the opencode row (line ~210):
```swift
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .zcode, name: "zcode", kind: zcodeKind) {
                appSettings.zcodeEnabled = true
                if !aiService.zcodeProvider.isHookInstalled {
                    aiService.zcodeProvider.installHooks()
                }
            }
```

- [ ] **Step 2: Add the Settings provider card**

`NemoNotch/Settings/SettingsView.swift`, after the opencode `hookCard` block (line ~310):
```swift
                // zcode
                hookCard(
                    name: "zcode",
                    tint: Self.zcodeTint,
                    isInstalled: aiService.zcodeProvider.isHookInstalled,
                    logo: { ZcodeLogoIcon(size: 19, color: Self.zcodeTint) },
                    onInstall: {
                        appSettings.zcodeEnabled = true
                        aiService.zcodeProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.zcodeEnabled = false
                        aiService.zcodeProvider.uninstallHooks()
                    }
                )
```

Add the tint constant after `opencodeTint` (line ~399):
```swift
    private static let zcodeTint = Color(red: 0.11, green: 0.44, blue: 0.96)
```

- [ ] **Step 3: Add the menu-bar install button**

`NemoNotch/Notch/MenuBar/HooksSection.swift`, after the opencode button (line ~21):
```swift
        if !aiService.opencodeProvider.isHookInstalled {
            Button("menu.install_opencode_hooks") {
                aiService.opencodeProvider.installHooks()
            }
        }
        if !aiService.zcodeProvider.isHookInstalled {
            Button("menu.install_zcode_hooks") {
                aiService.zcodeProvider.installHooks()
            }
        }
```

`showsAnyHook` (line ~27):
```swift
    private var showsAnyHook: Bool {
        !aiService.claudeProvider.isHookInstalled
            || !aiService.geminiProvider.isHookInstalled
            || !aiService.opencodeProvider.isHookInstalled
            || !aiService.zcodeProvider.isHookInstalled
    }
```

- [ ] **Step 4: Add the localization string**

In `NemoNotch/Resources/Localizable.xcstrings`, add a `menu.install_zcode_hooks` key mirroring `menu.install_opencode_hooks` (English + Chinese). Edit the JSON so the new key sits alphabetically near the other `menu.install_*` keys:

```json
    "menu.install_zcode_hooks" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Install zcode hooks" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "安装 zcode 钩子" } }
      }
    },
```

(Match the exact structure of the existing `menu.install_opencode_hooks` entry — copy its shape including whether it has a `comment`/`extractionState` field, and keep the file valid JSON.)

- [ ] **Step 5: Build to verify**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Tabs/AIChatTab.swift NemoNotch/Settings/SettingsView.swift NemoNotch/Notch/MenuBar/HooksSection.swift NemoNotch/Resources/Localizable.xcstrings
git commit -m "feat(zcode): install surfaces in AI tab, Settings, and menu bar"
```

---

### Task 8: Documentation

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `README_CN.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `CLAUDE.md`**

Add a paragraph to the AI Service Architecture section describing zcode as the fourth `AIProvider`: Claude-shaped hooks reused through `hook-sender.sh`/`HookServer` (no plugin), config at `~/.zcode/cli/config.json` with the nested `hooks.events` + `enabled` shape handled by a `.zcode` `HookTarget`, `sess_`-prefixed session routing (distinct from opencode's `ses_`), `ZCODE_SESSION_ID` source detection, notify + live status scope (no token/message parsing, no notch approval), gated by `AppSettings.zcodeEnabled`, with the `ZcodeLogoIcon` brand mark. Update the opencode-provider Mermaid/prose list to mention zcode where the other three providers are listed.

- [ ] **Step 2: Update `README.md` and `README_CN.md`**

In the AI CLI monitoring feature descriptions, add zcode (GLM) alongside Claude Code / Gemini CLI / opencode.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md README_CN.md
git commit -m "docs(zcode): document zcode provider integration"
```

---

## Self-Review Notes

- **Spec coverage:** AISource+displayModel (T3), ZcodeProvider notify/status (T5), HookInstaller nested target (T4), hook-sender detection + version bump (T4), routeEvent zcode + `sess_` (T6), assembly + auto-install-on-present (T6), ZcodeLogoIcon (T1), badge/toast/AItab/settings/menu surfaces (T3/T7), zcodeEnabled gating (T2/T3/T7), tests (T4/T5/T6), docs (T8). All spec sections mapped.
- **Type consistency:** `applyInstall`/`applyUninstall`/`detectInstalled`/`readEvents`/`writeEvents` signatures identical across T4 definition and its test; `zcodeProvider` name consistent across T6/T7; `ZcodeLogoIcon(size:color:)` consistent across T1/T3/T7; `zcodeKind`/`zcodeCount` consistent within T7.
- **No placeholders:** every code step shows full code; localization step points to copying the exact existing entry shape.
