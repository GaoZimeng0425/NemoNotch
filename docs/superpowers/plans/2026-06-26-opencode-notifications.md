# opencode Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface opencode CLI session activity in NemoNotch (badge, completion flash, toast, live status card in AIChatTab) on par with the Claude Code experience.

**Architecture:** A NemoNotch-written opencode plugin (`~/.config/opencode/plugin/nemonotch-notify.ts`) subscribes to opencode's lifecycle hooks and POSTs normalized `HookEvent`s to NemoNotch's existing `HookServer` with `cli_source: "opencode"`. A new `OpencodeProvider` (third `AIProvider`) maps those events into `AISessionStore`, so the existing badge / completion-flash / toast / AIChatTab pipeline lights up for free. Mirrors the Claude/Gemini hook architecture and the `HermesHookInstaller` installer pattern.

**Tech Stack:** Swift 6 + SwiftUI, `@Observable` services, `Network.framework` `HookServer` (existing), opencode `@opencode-ai/plugin` (TS), Swift Testing.

## Global Constraints

- Swift 6, macOS only; all services `@MainActor @Observable`.
- New AI providers implement `AIProvider` and write to `AISessionStore` only (UI never touches provider internals).
- Logging via `LogService.{info,debug,warn,error}(_, category:)` at lifecycle / external-IO / state-change / error points (see CLAUDE.md "Log coverage requirements").
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) in `NemoNotchTests/`. Test pure logic only — no FS/AX/NSWindow integration tests.
- Do NOT edit `project.pbxproj` to add source files (Xcode 16 auto-syncs root groups).
- Work on branch `feature/opencode-notifications` (already created from `develop`). Commit after every task.
- Scope: **notify + live status only.** No conversation/token parsing, no approve-from-notch, no opencode usage quota.

## File Structure

**Create:**
- `NemoNotch/Services/OpencodePluginInstaller.swift` — writes/removes the opencode plugin file; pure `pluginSource(port:)` generator.
- `NemoNotch/Services/OpencodeProvider.swift` — `AIProvider` conformer; maps pushed events → `AISessionStore` mutations.
- `NemoNotchTests/OpencodePluginInstallerTests.swift` — pure test of `pluginSource(port:)`.
- `NemoNotchTests/OpencodeProviderTests.swift` — phase-transition tests over decoded `HookEvent`s.

**Modify:**
- `NemoNotch/Models/HookEvent.swift` — add optional `model` field.
- `NemoNotch/Models/AIProvider.swift` — add `AISource.opencode`; `displayModel` case + formatter.
- `NemoNotch/Models/AppSettings.swift` — add `opencodeEnabled` flag.
- `NemoNotch/Services/AICLIMonitorService.swift` — construct/own/wire/route `OpencodeProvider`.
- `NemoNotch/Services/HookServer.swift` — refresh opencode plugin on port change.
- `NemoNotch/Tabs/AIChatTab.swift` — `.opencode` branches in source switches + recovery card.
- `NemoNotch/Notch/Badge/BadgeViewModel.swift` — `.opencode` in provider-enabled filter.
- `NemoNotch/Notch/Badge/BadgeIconView.swift` — `.opencode` source icon.
- `NemoNotch/Notch/MenuBar/HooksSection.swift` — "Install opencode hooks" button.
- `README.md`, `README_CN.md`, `CLAUDE.md` — feature/architecture docs.

---

## Task 1: Add `model` field to HookEvent

**Files:**
- Modify: `NemoNotch/Models/HookEvent.swift`
- Test: `NemoNotchTests/HookEventModelTests.swift` (create)

**Interfaces:**
- Produces: `HookEvent.model: String?` (coding key `"model"`), populated by the opencode plugin; consumed by `OpencodeProvider` (Task 4).

- [ ] **Step 1: Write the failing test**

Create `NemoNotchTests/HookEventModelTests.swift`:

```swift
import Testing
import Foundation
@testable import NemoNotch

struct HookEventModelTests {
    @Test func decodesModelField() throws {
        let json = #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","model":"anthropic/claude-sonnet-4-5","cli_source":"opencode"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.model == "anthropic/claude-sonnet-4-5")
    }

    @Test func modelIsNilWhenAbsent() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        #expect(event.model == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/HookEventModelTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'HookEvent' has no member 'model'` (compile error).

- [ ] **Step 3: Add the field**

In `NemoNotch/Models/HookEvent.swift`:
- Add the stored property after `let cliSource: String?` (line 11):
  ```swift
      let model: String?
  ```
- In `init(from decoder:)`, after the `cliSource = ...` line (line 22):
  ```swift
          model = try container.decodeIfPresent(String.self, forKey: .model)
  ```
- In `enum CodingKeys`, after `case cliSource = "cli_source"` (line 33):
  ```swift
          case model
  ```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/HookEventModelTests 2>&1 | tail -20`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Models/HookEvent.swift NemoNotchTests/HookEventModelTests.swift
git commit -m "feat(ai): add optional model field to HookEvent"
```

---

## Task 2: Add `opencodeEnabled` setting

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift`

**Interfaces:**
- Produces: `AppSettings.opencodeEnabled: Bool` (default `true`, UserDefaults-backed). Consumed by AIChatTab + BadgeViewModel (Task 4).

- [ ] **Step 1: Add the key + property**

In `NemoNotch/Models/AppSettings.swift`, after `static let hermesEnabledKey = "hermesEnabled"` (line 90):
```swift
    static let opencodeEnabledKey = "opencodeEnabled"
```
After the `geminiEnabled` computed property block (line 99), add:
```swift
    var opencodeEnabled: Bool {
        didSet { UserDefaults.standard.set(opencodeEnabled, forKey: Self.opencodeEnabledKey) }
    }
```

- [ ] **Step 2: Initialize it**

In `init()`, after the `geminiEnabled = ...` assignment (lines 167-168), add:
```swift
        opencodeEnabled = UserDefaults.standard
            .object(forKey: Self.opencodeEnabledKey) as? Bool ?? true
```

- [ ] **Step 3: Verify it builds**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Models/AppSettings.swift
git commit -m "feat(ai): add opencodeEnabled app setting"
```

---

## Task 3: OpencodePluginInstaller

**Files:**
- Create: `NemoNotch/Services/OpencodePluginInstaller.swift`
- Test: `NemoNotchTests/OpencodePluginInstallerTests.swift`

**Interfaces:**
- Produces:
  - `enum OpencodePluginInstaller` with `static var isInstalled: Bool`, `static func install() throws`, `static func uninstall() throws`, `static func refreshScript() throws`, and `static func pluginSource(port: UInt16) -> String`.
  - Plugin file path: `~/.config/opencode/plugin/nemonotch-notify.ts`; marker substring `nemonotch-opencode-plugin`.
- Consumes: `NotchConstants.hookServerPort` (existing), `LogService` (existing).

- [ ] **Step 1: Write the failing test**

Create `NemoNotchTests/OpencodePluginInstallerTests.swift`:

```swift
import Testing
@testable import NemoNotch

struct OpencodePluginInstallerTests {
    @Test func pluginSourceEmbedsPortAndMarker() {
        let src = OpencodePluginInstaller.pluginSource(port: 47321)
        #expect(src.contains("nemonotch-opencode-plugin"))
        #expect(src.contains("http://127.0.0.1:47321"))
        #expect(src.contains("\"cli_source\": \"opencode\"") || src.contains("cli_source: \"opencode\""))
    }

    @Test func pluginSourceWiresAllLifecycleHooks() {
        let src = OpencodePluginInstaller.pluginSource(port: 1)
        #expect(src.contains("UserPromptSubmit"))
        #expect(src.contains("PreToolUse"))
        #expect(src.contains("PostToolUse"))
        #expect(src.contains("Stop"))
        #expect(src.contains("permission.ask"))
        #expect(src.contains("session.idle"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/OpencodePluginInstallerTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'OpencodePluginInstaller' in scope`.

- [ ] **Step 3: Create the installer**

Create `NemoNotch/Services/OpencodePluginInstaller.swift`:

```swift
import Foundation

/// Installs/removes the opencode plugin that forwards session lifecycle events
/// to NemoNotch's HookServer. opencode auto-loads `*.ts` from its global
/// `~/.config/opencode/plugin/` directory, so dropping the file IS the
/// registration — no `opencode.json` edit needed. Mirrors HermesHookInstaller.
enum OpencodePluginInstaller {
    private static let pluginDir = NSHomeDirectory() + "/.config/opencode/plugin"
    private static let pluginPath = pluginDir + "/nemonotch-notify.ts"
    static let marker = "nemonotch-opencode-plugin"
    static let version = "v1"

    static var isInstalled: Bool {
        guard let content = try? String(contentsOfFile: pluginPath, encoding: .utf8) else { return false }
        return content.contains(marker)
    }

    static func install() throws {
        try writePlugin()
        LogService.info("opencode plugin installed at \(pluginPath)", category: "OpencodePluginInstaller")
    }

    static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: pluginPath) else { return }
        try FileManager.default.removeItem(atPath: pluginPath)
        LogService.info("opencode plugin uninstalled", category: "OpencodePluginInstaller")
    }

    /// Rewrite the plugin with the current hook-server port. Called on launch /
    /// port change (HookServer) when already installed. No-op otherwise.
    static func refreshScript() throws {
        guard isInstalled else { return }
        try writePlugin()
    }

    private static func writePlugin() throws {
        try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
        let port = NotchConstants.hookServerPort
        try pluginSource(port: port).write(toFile: pluginPath, atomically: true, encoding: .utf8)
        LogService.info("Wrote opencode plugin (port \(port))", category: "OpencodePluginInstaller")
    }

    /// Pure generator — the plugin's TS source for a given port. Kept internal
    /// (not private) so it can be unit-tested without touching the filesystem.
    static func pluginSource(port: UInt16) -> String {
        """
        // \(marker) \(version) — auto-generated by NemoNotch. Do not edit by hand.
        // Forwards opencode session lifecycle to NemoNotch for notch notifications.
        const URL_BASE = "http://127.0.0.1:\(port)"

        const post = (body) => {
          try {
            fetch(URL_BASE + "/hook", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(body),
              signal: AbortSignal.timeout(1500),
            }).catch(() => {})
          } catch (_) {}
        }

        export const NemoNotchNotify = async ({ directory }) => {
          const base = (extra) => ({ cwd: directory, cli_source: "opencode", ...extra })
          return {
            "chat.message": async (input) => {
              const model = input && input.model ? input.model.providerID + "/" + input.model.modelID : undefined
              post(base({ hook_event_name: "UserPromptSubmit", session_id: input.sessionID, model }))
            },
            "tool.execute.before": async (input) => {
              post(base({ hook_event_name: "PreToolUse", session_id: input.sessionID, tool_name: input.tool, tool_use_id: input.callID }))
            },
            "tool.execute.after": async (input) => {
              post(base({ hook_event_name: "PostToolUse", session_id: input.sessionID, tool_name: input.tool, tool_use_id: input.callID }))
            },
            "permission.ask": async (input) => {
              // Notify only — do NOT set output.status; opencode's TUI owns the decision.
              post(base({ hook_event_name: "Notification", session_id: input.sessionID, tool_name: input.type || input.title, tool_use_id: input.id, message: input.title || input.pattern }))
            },
            event: async ({ event }) => {
              const sid = event && event.properties ? event.properties.sessionID : undefined
              if (!sid) return
              if (event.type === "session.idle" || event.type === "session.error") {
                post(base({ hook_event_name: "Stop", session_id: sid }))
              } else if (event.type === "session.compacted") {
                post(base({ hook_event_name: "PreCompact", session_id: sid }))
              }
            },
          }
        }
        """
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/OpencodePluginInstallerTests 2>&1 | tail -20`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/OpencodePluginInstaller.swift NemoNotchTests/OpencodePluginInstallerTests.swift
git commit -m "feat(ai): add OpencodePluginInstaller + plugin source generator"
```

---

## Task 4: OpencodeProvider + AISource integration

This is the compile-atomic core: adding `AISource.opencode` forces every exhaustive `switch` over `AISource` to gain a `.opencode` branch in the same change, plus the new provider and its wiring.

**Files:**
- Create: `NemoNotch/Services/OpencodeProvider.swift`
- Test: `NemoNotchTests/OpencodeProviderTests.swift`
- Modify: `NemoNotch/Models/AIProvider.swift`, `NemoNotch/Services/AICLIMonitorService.swift`, `NemoNotch/Services/HookServer.swift`, `NemoNotch/Tabs/AIChatTab.swift`, `NemoNotch/Notch/Badge/BadgeViewModel.swift`, `NemoNotch/Notch/Badge/BadgeIconView.swift`

**Interfaces:**
- Consumes: `AISessionStore` (`mutateOrCreate`, `mutate`, `sessions(for:)`, `remove`), `HookEvent` (`hookEventName`, `sessionId`, `toolName`, `toolUseId`, `message`, `cwd`, `model`), `SessionPhase` (`transition(to:)`, `.processing/.waitingForInput/.waitingForApproval(PermissionContext)/.compacting`), `PermissionContext(toolUseId:toolName:toolInput:receivedAt:)`, `OpencodePluginInstaller`, `NotchConstants.hookServerPort`.
- Produces:
  - `final class OpencodeProvider: AIProvider` with `source: AISource = .opencode`, `var isHookInstalled`, `init(store:)`, `setHookServer(_:)`, `installHooks()`, `uninstallHooks()`, `respondToPermission(sessionId:approved:)` (no-op), `handleEvent(_:)`.
  - `AISource.opencode` case.
  - `AICLIMonitorService.opencodeProvider: OpencodeProvider` (stored, public).

- [ ] **Step 1: Write the failing provider test**

Create `NemoNotchTests/OpencodeProviderTests.swift`:

```swift
import Testing
import Foundation
@testable import NemoNotch

@MainActor
struct OpencodeProviderTests {
    private func event(_ json: String) -> HookEvent {
        try! JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    }

    @Test func lifecycleMovesThroughWorkingThenWaiting() {
        let store = AISessionStore()
        let provider = OpencodeProvider(store: store)
        let sid = "ses_a"

        provider.handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_a","cwd":"/tmp/proj","model":"anthropic/claude-sonnet-4-5","cli_source":"opencode"}"#))
        #expect(store.get(sid)?.source == .opencode)
        #expect(store.get(sid)?.status == .working)
        #expect(store.get(sid)?.cwd == "/tmp/proj")
        #expect(store.get(sid)?.model == "anthropic/claude-sonnet-4-5")

        provider.handleEvent(event(#"{"hook_event_name":"PreToolUse","session_id":"ses_a","tool_name":"bash","tool_use_id":"c1","cli_source":"opencode"}"#))
        #expect(store.get(sid)?.currentTool == "bash")
        #expect(store.get(sid)?.status == .working)

        provider.handleEvent(event(#"{"hook_event_name":"PostToolUse","session_id":"ses_a","tool_name":"bash","tool_use_id":"c1","cli_source":"opencode"}"#))
        #expect(store.get(sid)?.currentTool == nil)

        provider.handleEvent(event(#"{"hook_event_name":"Stop","session_id":"ses_a","cli_source":"opencode"}"#))
        #expect(store.get(sid)?.status == .waiting)
    }

    @Test func notificationMovesToWaitingForApproval() {
        let store = AISessionStore()
        let provider = OpencodeProvider(store: store)
        let sid = "ses_b"
        provider.handleEvent(event(#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_b","cli_source":"opencode"}"#))
        provider.handleEvent(event(#"{"hook_event_name":"Notification","session_id":"ses_b","tool_name":"bash","tool_use_id":"p1","message":"rm -rf x","cli_source":"opencode"}"#))
        #expect(store.get(sid)?.phase.isWaitingForApproval == true)
        #expect(store.get(sid)?.phase.approvalToolName == "bash")
    }

    @Test func ignoresEventsWithoutSessionId() {
        let store = AISessionStore()
        let provider = OpencodeProvider(store: store)
        provider.handleEvent(event(#"{"hook_event_name":"Stop","cli_source":"opencode"}"#))
        #expect(store.sortedSessions.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/OpencodeProviderTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'OpencodeProvider' in scope` and `type 'AISource' has no member 'opencode'`.

- [ ] **Step 3: Add the `AISource.opencode` case + model formatter**

In `NemoNotch/Models/AIProvider.swift`:
- Add to the enum (after `case gemini`, line 5):
  ```swift
      case opencode
  ```
- In `displayModel`'s `switch source` (lines 131-136), add:
  ```swift
          case .opencode:
              return formatOpencodeModel(model)
  ```
- Add this method next to `formatGeminiModel` (after line 166):
  ```swift
      private func formatOpencodeModel(_ model: String) -> String {
          // opencode model ids are "vendor/model" (e.g. "anthropic/claude-sonnet-4-5").
          let bare = model.split(separator: "/").last.map(String.init) ?? model
          return bare
              .split(separator: "-")
              .map { $0.prefix(1).uppercased() + $0.dropFirst() }
              .joined(separator: " ")
      }
  ```

- [ ] **Step 4: Create OpencodeProvider**

Create `NemoNotch/Services/OpencodeProvider.swift`:

```swift
import Foundation

/// Third AIProvider. Receives opencode lifecycle events (pushed by the
/// NemoNotch opencode plugin via HookServer) and maps them into AISessionStore.
/// Notify-only: no conversation/token parsing, no notch-side approval.
@MainActor
@Observable
final class OpencodeProvider: AIProvider {
    let source: AISource = .opencode
    var isHookInstalled = false

    private let store: AISessionStore
    private var timeoutTimer: Timer?
    private weak var hookServer: HookServer?

    init(store: AISessionStore) {
        self.store = store
        isHookInstalled = OpencodePluginInstaller.isInstalled
        LogService.info("OpencodeProvider init (hookInstalled=\(isHookInstalled))", category: "OpencodeProvider")
    }

    func setHookServer(_ server: HookServer) {
        hookServer = server
    }

    func installHooks() {
        do {
            try OpencodePluginInstaller.install()
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install opencode plugin: \(error)", category: "OpencodeProvider")
        }
    }

    func uninstallHooks() {
        do {
            try OpencodePluginInstaller.uninstall()
            isHookInstalled = false
        } catch {
            LogService.error("Failed to uninstall opencode plugin: \(error)", category: "OpencodeProvider")
        }
    }

    /// Notify-only — opencode's own TUI owns the approval decision.
    func respondToPermission(sessionId: String, approved: Bool) {}

    // MARK: - Event Handling

    func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()
        LogService.debug(
            "opencode event \(event.hookEventName) session \(sessionId.prefix(10))",
            category: "OpencodeProvider"
        )

        switch event.hookEventName {
        case "UserPromptSubmit":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .processing)
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PreToolUse":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = event.toolName
                s.isPreToolUse = true
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PostToolUse":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .processing)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "Notification":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                let ctx = PermissionContext(
                    toolUseId: event.toolUseId ?? UUID().uuidString,
                    toolName: event.toolName ?? "permission",
                    toolInput: event.message,
                    receivedAt: now
                )
                s.phase = s.phase.transition(to: .waitingForApproval(ctx))
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

        case "PreCompact":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .compacting)
                s.lastEventTime = now
            }

        case "Stop":
            store.mutateOrCreate(sessionId, source: .opencode) { s in
                s.phase = s.phase.transition(to: .waitingForInput)
                s.currentTool = nil
                s.isPreToolUse = false
                self.applyContext(to: &s, event: event)
                s.lastEventTime = now
            }

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

    // MARK: - Timeout (mirrors Claude/Gemini)

    private static let cleanupTickInterval: TimeInterval = 60
    private static let silentDemoteThreshold: TimeInterval = 300 // 5 min → clear badge
    private static let removeStaleThreshold: TimeInterval = 1800 // 30 min → drop session

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

        for session in store.sessions(for: .opencode) where session.lastEventTime < demoteCutoff {
            if case .waitingForInput = session.phase {
                store.mutate(session.id) { s in
                    s.phase = s.phase.transition(to: .idle)
                }
                LogService.info(
                    "Demoted silent opencode session \(session.id.prefix(8)) to idle",
                    category: "OpencodeProvider"
                )
            }
        }

        for session in store.sessions(for: .opencode) where session.lastEventTime < removeCutoff {
            store.remove(session.id)
            LogService.info("Removed stale opencode session \(session.id.prefix(8))", category: "OpencodeProvider")
        }

        if store.sessions(for: .opencode).isEmpty {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
    }
}
```

- [ ] **Step 5: Wire AICLIMonitorService**

In `NemoNotch/Services/AICLIMonitorService.swift`:
- Add stored property after `let geminiProvider: GeminiProvider` (line 8):
  ```swift
      let opencodeProvider: OpencodeProvider
  ```
- In `init()`, after `let gemini = GeminiProvider(store: store)` (line 17):
  ```swift
          let opencode = OpencodeProvider(store: store)
  ```
  After `geminiProvider = gemini` (line 20):
  ```swift
          opencodeProvider = opencode
  ```
  After `gemini.setHookServer(hookServer)` / `gemini.scanExistingSessions()` (lines 24-26):
  ```swift
          opencode.setHookServer(hookServer)
  ```
  Change the refresh guard (line 31) from:
  ```swift
          if claude.isHookInstalled || gemini.isHookInstalled {
  ```
  to:
  ```swift
          if claude.isHookInstalled || gemini.isHookInstalled || opencode.isHookInstalled {
  ```
- In `anyHookInstalled` (lines 55-57), change to:
  ```swift
      var anyHookInstalled: Bool {
          claudeProvider.isHookInstalled || geminiProvider.isHookInstalled || opencodeProvider.isHookInstalled
      }
  ```
- In `installHooks()` (lines 59-62), add:
  ```swift
          opencodeProvider.installHooks()
  ```
- In `respondToPermission` `switch session.source` (lines 66-69), add:
  ```swift
          case .opencode: opencodeProvider.respondToPermission(sessionId: sessionId, approved: approved)
  ```
- In `routeEvent`'s `switch source` (lines 90-107), add a case alongside `"gemini"`/`"claude"`:
  ```swift
          case "opencode":
              opencodeProvider.handleEvent(event)
  ```
  And in the `default:` fallback's inner `switch existing.source` (lines 100-103), add:
  ```swift
              case .opencode: opencodeProvider.handleEvent(event)
  ```
- In `handleServerReady()` (lines 110-116), after the gemini install lines, add:
  ```swift
          try? OpencodePluginInstaller.install()
          opencodeProvider.isHookInstalled = OpencodePluginInstaller.isInstalled
  ```

- [ ] **Step 6: Refresh plugin on port change (HookServer)**

In `NemoNotch/Services/HookServer.swift`, in `handleListenerState` `.ready` branch, inside the `if port != NotchConstants.hookServerDefaultPort {` block (after `try? HermesHookInstaller.refreshScript()`, line 86):
```swift
                try? OpencodePluginInstaller.refreshScript()
```

- [ ] **Step 7: Fix the remaining exhaustive AISource switches (UI)**

`NemoNotch/Notch/Badge/BadgeViewModel.swift` — in `activeBadgeItems`'s `switch session.source` (lines 43-46) add:
```swift
            case .opencode: appSettings.opencodeEnabled
```

`NemoNotch/Notch/Badge/BadgeIconView.swift` — in `aiSourceIcon`'s `switch source` (lines 126-133) add:
```swift
        case .opencode:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 0.55))
```

`NemoNotch/Tabs/AIChatTab.swift` — add `.opencode` to each `switch`:
- `allSessions` (lines 19-22):
  ```swift
            case .opencode: return appSettings.opencodeEnabled
  ```
- `consoleTitle`'s `switch dominantSource` (lines 89-93), before `case .none`:
  ```swift
          case .opencode: "opencode"
  ```
- `consoleIcon`'s `switch dominantSource` (lines 359-366):
  ```swift
                  case .opencode:
                      Image(systemName: "chevron.left.forwardslash.chevron.right")
                          .font(.system(size: 18, weight: .bold, design: .rounded))
                          .foregroundStyle(.white)
  ```
- `sourceIcon` (lines 642-649):
  ```swift
          case .opencode:
              Image(systemName: "chevron.left.forwardslash.chevron.right")
                  .font(.system(size: size * 0.8, weight: .semibold))
                  .foregroundStyle(sourceTint(source))
  ```
- `sourceLabel` (lines 703-706):
  ```swift
          case .opencode: "opencode"
  ```
- `sourceShortLabel` (lines 711-713):
  ```swift
          case .opencode: "O"
  ```
- `sourceTint` (lines 717-720):
  ```swift
          case .opencode: Color(red: 0.55, green: 0.78, blue: 0.55)
  ```

- [ ] **Step 8: Build, then run the provider tests**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **` (if the compiler flags another non-exhaustive `AISource` switch, add a `.opencode` branch following the nearest existing pattern, then rebuild).

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/OpencodeProviderTests 2>&1 | tail -20`
Expected: PASS (all three tests).

- [ ] **Step 9: Commit**

```bash
git add NemoNotch/Services/OpencodeProvider.swift NemoNotchTests/OpencodeProviderTests.swift \
        NemoNotch/Models/AIProvider.swift NemoNotch/Services/AICLIMonitorService.swift \
        NemoNotch/Services/HookServer.swift NemoNotch/Tabs/AIChatTab.swift \
        NemoNotch/Notch/Badge/BadgeViewModel.swift NemoNotch/Notch/Badge/BadgeIconView.swift
git commit -m "feat(ai): add OpencodeProvider and wire opencode into AISource pipeline"
```

---

## Task 5: Settings & recovery-card UI

Additive UI (no compiler-forced changes) — the "Install opencode hooks" menu button and the AIChatTab provider recovery/re-enable card, matching Claude/Gemini.

**Files:**
- Modify: `NemoNotch/Notch/MenuBar/HooksSection.swift`, `NemoNotch/Tabs/AIChatTab.swift`

**Interfaces:**
- Consumes: `aiService.opencodeProvider` (Task 4), `appSettings.opencodeEnabled` (Task 2), `AIChatTab.providerCard`, `ProviderCardKind`, `Self.kind(enabled:installed:)` (existing).

- [ ] **Step 1: HooksSection button**

In `NemoNotch/Notch/MenuBar/HooksSection.swift`, after the gemini button block (lines 12-16), add:
```swift
        if !aiService.opencodeProvider.isHookInstalled {
            Button("menu.install_opencode_hooks") {
                aiService.opencodeProvider.installHooks()
            }
        }
```
And update `showsAnyHook` (lines 22-24):
```swift
    private var showsAnyHook: Bool {
        !aiService.claudeProvider.isHookInstalled
            || !aiService.geminiProvider.isHookInstalled
            || !aiService.opencodeProvider.isHookInstalled
    }
```

- [ ] **Step 2: AIChatTab opencode kind + recovery card + counts**

In `NemoNotch/Tabs/AIChatTab.swift`:
- After `geminiKind` (lines 33-38), add:
  ```swift
      private var opencodeKind: ProviderCardKind {
          Self.kind(
              enabled: appSettings.opencodeEnabled,
              installed: aiService.opencodeProvider.isHookInstalled
          )
      }
  ```
- Update `hasAnyReadyProvider` (lines 40-42) and `hasRecoveryCards` (lines 44-46):
  ```swift
      private var hasAnyReadyProvider: Bool {
          claudeKind == .ready || geminiKind == .ready || opencodeKind == .ready
      }

      private var hasRecoveryCards: Bool {
          claudeKind != .ready || geminiKind != .ready || opencodeKind != .ready
      }
  ```
- After `geminiCount` (lines 72-74), add:
  ```swift
      private var opencodeCount: Int {
          allSessions.count(where: { $0.source == .opencode })
      }
  ```
- Replace `hasMixedSources` (lines 76-78):
  ```swift
      private var hasMixedSources: Bool {
          [claudeCount, geminiCount, opencodeCount].count(where: { $0 > 0 }) > 1
      }
  ```
- In `consoleSummary`'s `sourceParts` (lines 97-100), add the opencode entry:
  ```swift
          let sourceParts = hasMixedSources ? [
              claudeCount > 0 ? "Claude \(claudeCount)" : nil,
              geminiCount > 0 ? "Gemini \(geminiCount)" : nil,
              opencodeCount > 0 ? "opencode \(opencodeCount)" : nil,
          ].compactMap(\.self) : []
  ```
- In `recoveryCards` (after the gemini `if geminiKind != .ready { ... }` block, find its closing brace ~line 162), add:
  ```swift
              if opencodeKind != .ready {
                  providerCard(
                      source: .opencode,
                      name: "opencode",
                      kind: opencodeKind
                  ) {
                      appSettings.opencodeEnabled = true
                      if !aiService.opencodeProvider.isHookInstalled {
                          aiService.opencodeProvider.installHooks()
                      }
                  }
              }
  ```

- [ ] **Step 3: Add the localized menu string**

Find the file defining `menu.install_gemini_hooks` (run: `grep -rl "menu.install_gemini_hooks" NemoNotch/`). In each `*.strings`/`*.xcstrings` it appears in, add a sibling key `menu.install_opencode_hooks` = `"Install opencode hooks"` (English) / `"安装 opencode 钩子"` (zh-Hans), mirroring the gemini entry exactly.

- [ ] **Step 4: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -6`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual smoke test**

1. Run NemoNotch. Open the menu-bar menu → click "Install opencode hooks". Confirm `~/.config/opencode/plugin/nemonotch-notify.ts` exists (`ls ~/.config/opencode/plugin/`) and contains the current port (`grep 127.0.0.1 ~/.config/opencode/plugin/nemonotch-notify.ts`).
2. In a terminal, run `opencode` in any project and send a prompt that triggers a tool call.
3. Verify: collapsed-notch badge shows working state during the turn; on completion you get the completion flash + toast; opencode appears as a status card in the AI tab. Tail logs if needed: `tail -f ~/.NemoNotch/logs/*.log | grep -i opencode`.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Notch/MenuBar/HooksSection.swift NemoNotch/Tabs/AIChatTab.swift NemoNotch/**/*.strings NemoNotch/**/*.xcstrings
git commit -m "feat(ai): opencode settings menu + recovery card"
```

---

## Task 6: Documentation

**Files:**
- Modify: `README.md`, `README_CN.md`, `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md**

In the "AI Service Architecture" section, add opencode as a third `AIProvider`: note it integrates via a NemoNotch-written **opencode plugin** (`~/.config/opencode/plugin/nemonotch-notify.ts`, installed by `OpencodePluginInstaller`) that POSTs normalized `HookEvent`s (`cli_source: "opencode"`) to the existing `HookServer` — notify + live status only (no conversation/token parsing, no notch-side approval). Mention `OpencodeProvider` writes to `AISessionStore` like Claude/Gemini, and that `routeEvent` gained an `"opencode"` case.

- [ ] **Step 2: Update README.md and README_CN.md**

In the AI CLI monitoring feature description, add opencode alongside Claude Code / Gemini CLI as a supported, monitored CLI (badge / completion flash / toast / status card). Keep parity between the English and Chinese versions.

- [ ] **Step 3: Commit**

```bash
git add README.md README_CN.md CLAUDE.md
git commit -m "docs: document opencode notification integration"
```

---

## Self-Review

**Spec coverage:**
- Plugin → HookServer push mechanism → Task 3 (installer + plugin) + Task 4 (routing). ✓
- `OpencodeProvider` writing to `AISessionStore` → Task 4. ✓
- `model` field for model display → Task 1 + Task 4 (`applyContext`, `formatOpencodeModel`). ✓
- Event→phase mapping (UserPromptSubmit/PreToolUse/PostToolUse/Notification/Stop/PreCompact) → Task 4 `handleEvent` + Task 3 plugin. ✓
- Completion flash/toast automatic via `AISessionStore` → covered (no code change needed; verified in Task 5 manual test). ✓
- Notify-only permission (no blocking `PermissionRequest`) → plugin emits `Notification`; `respondToPermission` no-op. ✓
- Settings flag + install toggle + recovery card → Task 2 + Task 5. ✓
- Stale-session timeout cleanup → Task 4 provider. ✓
- Port-change refresh → Task 4 Step 6. ✓
- Docs → Task 6. ✓

**Placeholder scan:** No TBD/TODO; every code step shows exact code. ✓

**Type consistency:** `OpencodePluginInstaller.pluginSource(port:)`, `.isInstalled`, `.install()`, `.uninstall()`, `.refreshScript()` consistent across Tasks 3-5. `OpencodeProvider(store:)`, `setHookServer(_:)`, `handleEvent(_:)`, `installHooks()` consistent across Task 4-5. `AISource.opencode`, `appSettings.opencodeEnabled`, `aiService.opencodeProvider` consistent across Tasks 2, 4, 5. `HookEvent.model` consistent across Tasks 1, 4. ✓

**Known runtime uncertainty (verify in Task 5 manual test, not a plan gap):** the exact shape of opencode's `event` bus payload for `session.idle` (the `event.properties.sessionID` path) and `permission.ask` input fields (`type`/`title`/`id`/`pattern`). If a field name differs, adjust the plugin's extraction in `OpencodePluginInstaller.pluginSource` and reinstall. The Swift side is contract-tested independently of these names.
