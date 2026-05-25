# Unified Service Enablement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align Claude / Gemini / Hermes / OpenClaw enablement around two surfaces — tab = first-click discovery, settings = symmetrical management — by adding OpenClaw to Settings and rewriting AgentMonitorTab's empty state with parallel setup cards.

**Architecture:** Add an `openClawEnabled` flag to `AppSettings` (UserDefaults-backed). Extend `OpenClawService` with `deviceIdShort`, `removeDeviceSelf()`, and a guard in `connect()` that respects the flag. Extract the "which cards to render" decision in `AgentMonitorTab` into a pure `AgentMonitorRenderDecision` type with tests. Build two new private cards (`HermesSetupCard`, `OpenClawInstallHintCard`). Add an OpenClaw section to `SettingsView` and rename the tab. Add Localizable strings.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, Swift Testing (`@Suite`, `@Test`, `#expect`). UserDefaults for persistence. CocoaLumberjack via `LogService` for logs.

**Working branch:** `develop` (current). Per project policy (`feedback_git-workflow` memory), small fixes commit directly on develop — this whole feature is appropriate for develop without a feature branch.

---

## File Structure

| File | Role | Status |
|---|---|---|
| `NemoNotch/Models/AppSettings.swift` | Adds `openClawEnabled` + `openClawEnabledKey` constant | Modify |
| `NemoNotch/Services/OpenClawService.swift` | Adds `deviceIdShort`, `isRemovingDevice`, `removeDeviceSelf`, guard in `connect()` | Modify |
| `NemoNotch/Helpers/AgentMonitorRenderDecision.swift` | Pure decision type for AgentMonitorTab render mode | **Create** |
| `NemoNotch/Tabs/AgentMonitorTab.swift` | Replace `notInstalled` with `setupState`; add `HermesSetupCard`, `OpenClawInstallHintCard`; route via decision | Modify |
| `NemoNotch/Settings/SettingsView.swift` | Rename tab; add `openClawSection` | Modify |
| `NemoNotch/Resources/Localizable.xcstrings` | +10 new keys (zh-Hans + en) | Modify |
| `NemoNotchTests/AgentMonitorRenderDecisionTests.swift` | Unit tests for decision matrix | **Create** |

Trivial property changes (UserDefaults-backed flag, computed property, subprocess wrapper) follow the project's existing test policy from `CLAUDE.md`: test pure logic, skip UI / IPC. Only the decision logic gets unit tests; the rest is verified by build + manual smoke per the spec's Verification section.

---

## Task 1: AppSettings — openClawEnabled flag

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift`

- [ ] **Step 1: Add the static key constant and stored property declaration**

Add a `static let openClawEnabledKey` constant inside the class, plus the new `openClawEnabled` stored property near the other `Bool` flags. Match the existing `didSet { UserDefaults... }` pattern used by `pomodoroSoundEnabled` (line 70-72).

Edit `NemoNotch/Models/AppSettings.swift`. Add the constant just above the `init()` (after the last `var` declaration, before `private func updateAppleLanguages()`):

```swift
    // MARK: - OpenClaw

    static let openClawEnabledKey = "openClawEnabled"

    var openClawEnabled: Bool {
        didSet { UserDefaults.standard.set(openClawEnabled, forKey: Self.openClawEnabledKey) }
    }
```

- [ ] **Step 2: Initialize in `init()`**

In `init()` (NemoNotch/Models/AppSettings.swift:91), after `pomodoroNotificationEnabled` initialization (line 128-129), add:

```swift
        openClawEnabled = UserDefaults.standard
            .object(forKey: Self.openClawEnabledKey) as? Bool ?? true
```

Default `true` preserves current behavior for existing users.

- [ ] **Step 3: Build verifies compilation**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Models/AppSettings.swift
git commit -m "feat(settings): add openClawEnabled UserDefaults flag"
```

---

## Task 2: OpenClawService — expose deviceIdShort

**Files:**
- Modify: `NemoNotch/Services/OpenClawService.swift`

- [ ] **Step 1: Add `deviceIdShort` computed property**

Open `NemoNotch/Services/OpenClawService.swift`. Just after the `deviceId` private let declaration (line 30), add a public computed property. Since `deviceId` is `private let`, the computed property must live in the same file (it does).

Add inside the class body, near the other public observable properties (after line 17 `var isApproving = false`):

```swift
    /// First 8 hex chars of the local device id, for Settings display.
    /// Returns empty string when the service is not installed (no config file).
    var deviceIdShort: String { String(deviceId.prefix(8)) }
```

- [ ] **Step 2: Build verifies compilation**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/OpenClawService.swift
git commit -m "feat(openclaw): expose deviceIdShort for Settings display"
```

---

## Task 3: OpenClawService — connect() respects openClawEnabled flag

**Files:**
- Modify: `NemoNotch/Services/OpenClawService.swift`

- [ ] **Step 1: Add user-disabled guard at top of `connect()`**

The existing `connect()` is at `NemoNotch/Services/OpenClawService.swift:171`. Replace its first lines:

Current:
```swift
    func connect() {
        guard isInstalled else {
            LogService.warn("Not installed, skipping connect", category: "OpenClaw")
            return
        }
        disconnect()
```

New:
```swift
    func connect() {
        let enabled = (UserDefaults.standard
            .object(forKey: AppSettings.openClawEnabledKey) as? Bool) ?? true
        guard enabled else {
            LogService.info("User-disabled, skipping connect", category: "OpenClaw")
            return
        }
        guard isInstalled else {
            LogService.warn("Not installed, skipping connect", category: "OpenClaw")
            return
        }
        disconnect()
```

The guard reads UserDefaults directly using the shared key constant from `AppSettings` — this avoids coupling the service to the `@Observable` `AppSettings` instance (services aren't SwiftUI views and don't get `@Environment` injection).

- [ ] **Step 2: Build verifies compilation**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/OpenClawService.swift
git commit -m "feat(openclaw): connect() respects openClawEnabled flag"
```

---

## Task 4: OpenClawService — removeDeviceSelf shell command

**Files:**
- Modify: `NemoNotch/Services/OpenClawService.swift`

- [ ] **Step 1: Add `isRemovingDevice` state flag**

In `NemoNotch/Services/OpenClawService.swift`, alongside `var isApproving = false` (line 17), add:

```swift
    /// True while the user-shell `openclaw devices remove` subprocess is running.
    var isRemovingDevice = false
```

- [ ] **Step 2: Add `removeDeviceSelf()` and `finishRemoveDevice()` methods**

Insert immediately after `finishApproval(result:)` (closes around line 659, before the `private struct ApprovalResult` declaration at line 661):

```swift
    /// Mirrors `approveSelf()` but runs `openclaw devices remove <deviceId>` to
    /// revoke this device's trust on the gateway. Called from Settings.
    func removeDeviceSelf() {
        guard !deviceId.isEmpty else {
            LogService.warn("No deviceId, skipping remove", category: "OpenClaw")
            return
        }
        guard !isRemovingDevice else { return }
        isRemovingDevice = true
        let cmd = "openclaw devices remove \(deviceId)"
        Task.detached { [weak self] in
            let result = Self.runInUserShell(cmd: cmd)
            await self?.finishRemoveDevice(result: result)
        }
    }

    @MainActor
    private func finishRemoveDevice(result: ApprovalResult) {
        isRemovingDevice = false
        if result.ok {
            LogService.info("Device removed via shell, disconnecting", category: "OpenClaw")
            disconnect()
        } else {
            let stderrTrimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderrTrimmed.isEmpty ? "(no stderr)" : stderrTrimmed
            LogService.error(
                "Remove device failed (shell=\(result.shell), exit=\(result.exitCode)): \(detail)",
                category: "OpenClaw"
            )
        }
    }
```

This mirrors `approveSelf()` / `finishApproval()` exactly so behavior, logging, and shell-invocation semantics are identical.

- [ ] **Step 3: Build verifies compilation**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Services/OpenClawService.swift
git commit -m "feat(openclaw): add removeDeviceSelf shell command"
```

---

## Task 5: AgentMonitorRenderDecision — pure decision type (TDD)

**Files:**
- Create: `NemoNotch/Helpers/AgentMonitorRenderDecision.swift`
- Create: `NemoNotchTests/AgentMonitorRenderDecisionTests.swift`

This is the heart of the rule table in the spec. By extracting it as a pure type with bool/optional inputs, we test the decision matrix without mocking `MultiAgentMonitor` protocol existentials.

- [ ] **Step 1: Write the failing test file**

Create `NemoNotchTests/AgentMonitorRenderDecisionTests.swift`:

```swift
@testable import NemoNotch
import Testing

@Suite("AgentMonitorRenderDecision")
struct AgentMonitorRenderDecisionTests {
    private func decide(
        hasOnlineMonitor: Bool = false,
        openClawPending: Bool = false,
        openClawInstalled: Bool = false,
        openClawEnabled: Bool = true,
        hermesInstalled: Bool = false
    ) -> AgentMonitorRenderDecision.Mode {
        AgentMonitorRenderDecision.decide(
            hasOnlineMonitor: hasOnlineMonitor,
            openClawPendingApproval: openClawPending,
            openClawIsInstalled: openClawInstalled,
            openClawUserEnabled: openClawEnabled,
            hermesIsInstalled: hermesInstalled
        )
    }

    @Test("Any monitor online → agentSections (no setup nag)")
    func anyMonitorOnline() {
        #expect(decide(hasOnlineMonitor: true) == .agentSections)
        #expect(decide(hasOnlineMonitor: true, openClawPending: true) == .agentSections)
        #expect(decide(hasOnlineMonitor: true, hermesInstalled: false) == .agentSections)
    }

    @Test("Nothing online, OpenClaw pending → approvalCardOnly")
    func openClawPendingTakesPriority() {
        #expect(decide(openClawPending: true, openClawInstalled: true) == .approvalCardOnly)
    }

    @Test("Nothing online, nothing installed → setupCards with both")
    func freshInstallShowsBothCards() {
        let mode = decide()
        #expect(mode == .setupCards(showHermesCard: true, openClaw: .installHintCard))
    }

    @Test("Nothing online, Hermes installed → offlineState (existing path)")
    func hermesInstalledFallsToOffline() {
        #expect(decide(hermesInstalled: true) == .offlineState)
    }

    @Test("Nothing online, OpenClaw installed (no pending) → offlineState")
    func openClawInstalledFallsToOffline() {
        #expect(decide(openClawInstalled: true) == .offlineState)
    }

    @Test("User disabled OpenClaw + nothing installed → setupCards without OpenClaw")
    func userDisabledHidesOpenClawCard() {
        let mode = decide(openClawEnabled: false)
        #expect(mode == .setupCards(showHermesCard: true, openClaw: .hidden))
    }

    @Test("User disabled OpenClaw + pending approval → still hidden (respects user choice)")
    func userDisabledOverridesPending() {
        // Edge case: user disabled OpenClaw while a stale pendingApproval lingers.
        // Honor the user's disable.
        let mode = decide(openClawPending: true, openClawEnabled: false)
        #expect(mode == .setupCards(showHermesCard: true, openClaw: .hidden))
    }
}
```

- [ ] **Step 2: Run the test — confirm it fails because the type doesn't exist**

Run:
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/AgentMonitorRenderDecisionTests 2>&1 | tail -30
```

Expected: Compile error — `cannot find 'AgentMonitorRenderDecision' in scope`.

- [ ] **Step 3: Create the implementation file**

Create `NemoNotch/Helpers/AgentMonitorRenderDecision.swift`:

```swift
import Foundation

/// Pure decision logic for what AgentMonitorTab should render.
///
/// Extracted from AgentMonitorTab so the visibility rules in
/// `docs/superpowers/specs/2026-05-25-unified-service-enablement-design.md`
/// can be tested without mocking SwiftUI environments or MultiAgentMonitor
/// existentials.
enum AgentMonitorRenderDecision {
    enum Mode: Equatable {
        /// At least one monitor is online — show the existing agent rows.
        case agentSections
        /// Monitors installed but all offline — show the existing offlineState.
        case offlineState
        /// OpenClaw has a pending approval; render only its approval card.
        case approvalCardOnly
        /// Nothing installed — show the new setup cards.
        case setupCards(showHermesCard: Bool, openClaw: OpenClawCardKind)
    }

    enum OpenClawCardKind: Equatable {
        case approvalCard
        case installHintCard
        /// User explicitly disabled OpenClaw via Settings — don't nag.
        case hidden
    }

    static func decide(
        hasOnlineMonitor: Bool,
        openClawPendingApproval: Bool,
        openClawIsInstalled: Bool,
        openClawUserEnabled: Bool,
        hermesIsInstalled: Bool
    ) -> Mode {
        if hasOnlineMonitor {
            return .agentSections
        }

        // OpenClaw pending approval is high-priority — but only if the user
        // hasn't explicitly disabled OpenClaw.
        if openClawPendingApproval, openClawUserEnabled {
            return .approvalCardOnly
        }

        if hermesIsInstalled || openClawIsInstalled {
            return .offlineState
        }

        // Fresh state: show setup cards.
        let openClawKind: OpenClawCardKind
        if !openClawUserEnabled {
            openClawKind = .hidden
        } else if openClawPendingApproval {
            openClawKind = .approvalCard
        } else {
            openClawKind = .installHintCard
        }

        return .setupCards(showHermesCard: true, openClaw: openClawKind)
    }
}
```

- [ ] **Step 4: Re-run tests — they should pass**

Run:
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/AgentMonitorRenderDecisionTests 2>&1 | tail -15
```

Expected: `Test Suite 'AgentMonitorRenderDecision' passed` with 7 tests.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Helpers/AgentMonitorRenderDecision.swift \
        NemoNotchTests/AgentMonitorRenderDecisionTests.swift
git commit -m "feat(agents): extract AgentMonitorRenderDecision with TDD"
```

---

## Task 6: AgentMonitorTab — HermesSetupCard private view

**Files:**
- Modify: `NemoNotch/Tabs/AgentMonitorTab.swift`

- [ ] **Step 1: Add the private view at the bottom of the file**

Open `NemoNotch/Tabs/AgentMonitorTab.swift`. Find the closing brace of the file (after `OpenClawApprovalCard` ends around line 682). Append before the final closing brace if there is wrapping content, or after the last private struct if all structs are top-level (this file uses top-level `private struct`s — append at end of file).

```swift
// MARK: - Hermes Setup Card (shown in setupState when Hermes hook not installed)

private struct HermesSetupCard: View {
    @Environment(HermesService.self) var hermesService

    var body: some View {
        VStack(spacing: 8) {
            Text("🐦")
                .font(.system(size: 26))
            Text("Hermes Agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                hermesService.installHooks()
            } label: {
                Text("agents.hermes.install_hook")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(NotchTheme.accent.opacity(0.18))
            .clipShape(Capsule())
            .foregroundStyle(NotchTheme.accent)
            .disabled(hermesService.isHookInstalled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .notchCard(radius: 10, fill: NotchTheme.surface)
    }

    private var statusText: LocalizedStringKey {
        if hermesService.isHookInstalled {
            return "agents.hermes.status.offline"
        } else {
            return "agents.hermes.status.uninstalled"
        }
    }
}
```

- [ ] **Step 2: Build verifies compilation**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED` (Localizable keys will resolve as missing but render literal — that's fixed in Task 11)

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Tabs/AgentMonitorTab.swift
git commit -m "feat(agents): add HermesSetupCard private view"
```

---

## Task 7: AgentMonitorTab — OpenClawInstallHintCard private view

**Files:**
- Modify: `NemoNotch/Tabs/AgentMonitorTab.swift`

- [ ] **Step 1: Add another private view at end of file**

Append after `HermesSetupCard`:

```swift
// MARK: - OpenClaw Install Hint Card (shown when OpenClaw is not installed and no pending approval)

private struct OpenClawInstallHintCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("🦞")
                .font(.system(size: 26))
            Text("OpenClaw")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text("agents.openclaw.not_installed")
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
            Text("npm install -g openclaw@latest")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(NotchTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(NotchTheme.surfaceSubtle))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .notchCard(radius: 10, fill: NotchTheme.surface)
    }
}
```

No buttons — installing the OpenClaw npm package is an out-of-band action by the user. Once they install it and run the gateway, `pendingApproval` will arrive and the card switches to the approval variant via the decision.

- [ ] **Step 2: Build verifies compilation**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Tabs/AgentMonitorTab.swift
git commit -m "feat(agents): add OpenClawInstallHintCard private view"
```

---

## Task 8: AgentMonitorTab — rewire body using decision

**Files:**
- Modify: `NemoNotch/Tabs/AgentMonitorTab.swift`

- [ ] **Step 1: Replace the body and remove the obsolete `notInstalled` view**

Locate the `var body: some View` of `AgentMonitorTab` (starts at line 12) and the `notInstalled` computed property (lines 33-46). Both will be replaced.

Current shape:
```swift
var body: some View {
    if monitors.isEmpty {
        notInstalled
    } else if monitors.allSatisfy({ !$0.isOnline }) {
        if openClaw.pendingApproval != nil {
            OpenClawApprovalCard()
        } else {
            offlineState
        }
    } else {
        agentSections
    }
}

private var notInstalled: some View {
    VStack(spacing: 10) { ... }
}
```

New shape — replace the entire `body` plus delete `notInstalled`:

```swift
var body: some View {
    switch renderMode {
    case .agentSections:
        agentSections
    case .offlineState:
        offlineState
    case .approvalCardOnly:
        OpenClawApprovalCard()
    case let .setupCards(showHermesCard, openClawKind):
        setupState(showHermesCard: showHermesCard, openClawKind: openClawKind)
    }
}

private var renderMode: AgentMonitorRenderDecision.Mode {
    AgentMonitorRenderDecision.decide(
        hasOnlineMonitor: monitors.contains(where: { $0.isOnline }),
        openClawPendingApproval: openClaw.pendingApproval != nil,
        openClawIsInstalled: openClaw.isInstalled,
        openClawUserEnabled: appSettings.openClawEnabled,
        hermesIsInstalled: hermesService.isHookInstalled
    )
}

@ViewBuilder
private func setupState(
    showHermesCard: Bool,
    openClawKind: AgentMonitorRenderDecision.OpenClawCardKind
) -> some View {
    VStack(spacing: 10) {
        if showHermesCard {
            HermesSetupCard()
        }
        switch openClawKind {
        case .approvalCard:
            OpenClawApprovalCard()
        case .installHintCard:
            OpenClawInstallHintCard()
        case .hidden:
            EmptyView()
        }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
}
```

- [ ] **Step 2: Add the new `@Environment` dependencies**

At the top of `AgentMonitorTab` struct (where `@Environment(AgentMonitorRegistry.self) var registry` and `@Environment(OpenClawService.self) var openClaw` already exist), add:

```swift
    @Environment(HermesService.self) var hermesService
    @Environment(AppSettings.self) var appSettings
```

Verify both are already injected at the call site — `NemoNotchApp.swift` already provides them via `.environment(...)` (per spec component changes table; both services are global env-injected).

- [ ] **Step 3: Build verifies compilation**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Smoke check — launch app**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -derivedDataPath build -configuration Debug build 2>&1 | tail -5 && open build/Build/Products/Debug/NemoNotch.app`

Manually verify (Spec Verification §1): with no `~/.hermes/config.yaml` and no `~/.openclaw/openclaw.json`, the Agents tab shows two stacked cards (Hermes + OpenClaw install hint). Strings will be literal keys until Task 11.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Tabs/AgentMonitorTab.swift
git commit -m "feat(agents): route AgentMonitorTab via decision + new setup cards"
```

---

## Task 9: SettingsView — rename tab + add OpenClaw section

**Files:**
- Modify: `NemoNotch/Settings/SettingsView.swift`

- [ ] **Step 1: Rename the tab label**

In `NemoNotch/Settings/SettingsView.swift:27`:

```swift
// Was:
claudeView
    .tabItem { Label("AI CLI", systemImage: "cpu") }
    .tag(2)

// Becomes:
claudeView
    .tabItem { Label("settings.tab.ai_agents", systemImage: "cpu") }
    .tag(2)
```

- [ ] **Step 2: Add the OpenClaw environment dependency**

At the top of `SettingsView` (after line 10 `@Environment(HermesService.self) var hermesService`), add:

```swift
    @Environment(OpenClawService.self) var openClawService
```

- [ ] **Step 3: Add the OpenClaw section into `claudeView`**

In `claudeView` (line 249), after the Hermes `hookSection` block (closes around line 280), before the `Text("settings.hooks_description")` footer, add:

```swift
            Divider()

            // OpenClaw — different semantics from hooks (connect/disconnect/revoke),
            // so it gets its own view shape instead of reusing hookSection.
            openClawSection
```

- [ ] **Step 4: Implement `openClawSection`**

After the existing `hookSection(name:icon:isInstalled:onInstall:onUninstall:)` method (closes around line 333), append:

```swift
    private var openClawSection: some View {
        VStack(spacing: 8) {
            if openClawService.gatewayOnline {
                Label(
                    "settings.openclaw.connected \(openClawService.deviceIdShort)",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.title3)
            } else {
                Label("settings.openclaw.disconnected", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            }

            HStack(spacing: 12) {
                if appSettings.openClawEnabled {
                    Button("settings.openclaw.disconnect") {
                        appSettings.openClawEnabled = false
                        openClawService.disconnect()
                    }
                    .controlSize(.large)
                } else {
                    Button("settings.openclaw.connect") {
                        appSettings.openClawEnabled = true
                        openClawService.connect()
                    }
                    .controlSize(.large)
                }

                if openClawService.gatewayOnline {
                    Button("settings.openclaw.remove_device", role: .destructive) {
                        openClawService.removeDeviceSelf()
                    }
                    .controlSize(.large)
                    .disabled(openClawService.isRemovingDevice)
                }
            }
        }
    }
```

- [ ] **Step 5: Verify `appSettings` is already in environment for this view**

`SettingsView` already declares `@Environment(AppSettings.self) var appSettings` at line 5 — no change needed.

- [ ] **Step 6: Build verifies compilation**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Settings/SettingsView.swift
git commit -m "feat(settings): add OpenClaw section + rename tab to AI / Agents"
```

---

## Task 10: Localizable strings

**Files:**
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add 10 new keys**

`Localizable.xcstrings` is JSON. Add each of the following key blocks to the top-level `"strings"` object (alphabetical position within the existing entries — the file is large; appending alphabetically near existing `agents.*` and `settings.*` entries works).

The structure for each key follows the existing pattern (see `settings.hooks_installed %@` for an `%@` example):

```json
"agents.hermes.install_hook" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Install Hook" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "安装 Hook" } }
  }
},
"agents.hermes.status.uninstalled" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Hook not installed" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "Hook 未安装" } }
  }
},
"agents.hermes.status.offline" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Installed, not running" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "已安装，未运行" } }
  }
},
"agents.openclaw.not_installed" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "OpenClaw not installed" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "OpenClaw 未安装" } }
  }
},
"settings.openclaw.connected %@" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Connected · device %@" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "已连接 · device %@" } }
  }
},
"settings.openclaw.disconnected" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Disconnected" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "已断开" } }
  }
},
"settings.openclaw.connect" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Connect" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "连接" } }
  }
},
"settings.openclaw.disconnect" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Disconnect" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "断开" } }
  }
},
"settings.openclaw.remove_device" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Remove device" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "移除设备" } }
  }
},
"settings.tab.ai_agents" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "AI / Agents" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "AI / Agents" } }
  }
}
```

Note the `%@` placeholder in `settings.openclaw.connected %@` matches the deviceIdShort substitution at the Settings call site.

- [ ] **Step 2: Build verifies the catalog parses**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED` (a malformed xcstrings will fail the build).

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Resources/Localizable.xcstrings
git commit -m "i18n: add strings for unified service enablement UI"
```

---

## Task 11: Build, run tests, smoke verify

**Files:** none modified — verification only.

- [ ] **Step 1: Full test suite**

Run:
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: all suites pass, including `AgentMonitorRenderDecision` (7 tests).

- [ ] **Step 2: Smoke verify — spec §Verification checks 1–8**

Per spec `docs/superpowers/specs/2026-05-25-unified-service-enablement-design.md` "Verification" section. Launch the built app and walk through:

1. **Empty state, fresh install** — Move `~/.hermes/config.yaml` and `~/.openclaw/openclaw.json` aside; relaunch; open AgentMonitorTab. Expected: two stacked setup cards.
2. **Install Hermes hook from tab button** — Click "安装 Hook" on the Hermes card. Expected: card swaps to `offlineState` for Hermes; OpenClaw card hidden (now in offlineState branch).
3. **OpenClaw paired and agents active** — Restore both files; run OpenClaw gateway with agents; reopen tab. Expected: `agentSections` renders, no setup cards.
4. **OpenClaw `pendingApproval` mid-session** — Trigger NOT_PAIRED handshake. Expected: existing `OpenClawApprovalCard` / `Banner` appears per existing logic (regression check).
5. **Settings → AI / Agents tab** — Open Settings. Expected: tab label reads "AI / Agents"; 4 sections visible (Claude / Gemini / Hermes / OpenClaw); OpenClaw initially shows "已断开" if not connected.
6. **Settings "断开" toggle** — Click disconnect. Expected: WS closes; log shows `User-disabled, skipping connect` on next manual connect attempt; relaunching app does not auto-connect.
7. **Settings "连接" toggle** — Click connect. Expected: WS reopens; if not paired yet, `pendingApproval` flows into the tab.
8. **Settings "移除设备"** — With OpenClaw online, click "移除设备". Expected: log shows shell exit 0; service disconnects; `openClawEnabled` remains `true` (verify in `defaults read com.gao.NemoNotch openClawEnabled` → returns 1 or no value).

- [ ] **Step 3: Confirm no stale string references**

Run: `grep -rn "agents.not_installed" NemoNotch/` (project's source only — not docs)
Expected: no hits in `.swift` files. The old `notInstalled` view + its string usage are gone.

- [ ] **Step 4: Final commit only if smoke fixes are needed**

If any smoke step required code fixes, commit them as fix-up commits with `fix(...)` prefix referencing the broken step. Otherwise, nothing to commit at this stage.

---

## Self-Review

**Spec coverage:**
- Change 1 (AgentMonitorTab empty state rewrite): Tasks 5–8.
- Change 2 (Settings 4-service uniform management + rename): Task 9.
- Change 3 (OpenClawService API additions: deviceIdShort, removeDeviceSelf, connect() guard): Tasks 2, 3, 4.
- Change 4 (AppSettings flag): Task 1.
- Change 5 (i18n strings): Task 10.
- Verification + Completion Criteria: Task 11.

All spec sections have a corresponding task.

**Placeholder scan:** No `TBD` / `TODO` / "implement appropriate" / "similar to Task N". Every step has either exact code or an exact verification command.

**Type consistency check:**
- `AppSettings.openClawEnabledKey` (defined Task 1) — read in Task 3 (`OpenClawService.connect()`).
- `AppSettings.openClawEnabled` (defined Task 1) — read in Tasks 8 (render decision) and 9 (Settings).
- `AgentMonitorRenderDecision.Mode` (defined Task 5) — consumed in Task 8.
- `AgentMonitorRenderDecision.OpenClawCardKind` (defined Task 5) — consumed in Task 8.
- `OpenClawService.deviceIdShort` (defined Task 2) — read in Task 9.
- `OpenClawService.removeDeviceSelf()` (defined Task 4) — called in Task 9.
- `OpenClawService.isRemovingDevice` (defined Task 4) — read in Task 9 button `.disabled(...)`.
- `HermesService.installHooks()` — pre-existing, called in Task 6.
- `HermesService.isHookInstalled` — pre-existing, read in Tasks 6 + 8.

All identifiers line up.
