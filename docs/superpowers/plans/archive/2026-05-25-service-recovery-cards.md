# Service Recovery Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two empty-state dead-ends in `AIChatTab` and `AgentMonitorTab` by adding a passive "re-enable" card kind, and tighten the no-nag rule to use ready (enabled+installed) instead of installed-only.

**Architecture:** Extend `AgentMonitorRenderDecision` with a parallel `HermesCardKind` enum and a `.reenableCard` variant on `OpenClawCardKind`. Replace inline `needs*Install` flags in `AIChatTab` with a small `ProviderCardKind` enum + `hasAnyReadyProvider` predicate. Add `passive: Bool` styling to the existing card helpers + one new `OpenClawReenableCard` view.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, Swift Testing (`@Suite`, `@Test`, `#expect`). UserDefaults via existing `AppSettings` flags. CocoaLumberjack via `LogService`.

**Working branch:** `develop` (current). Per project policy (`feedback_git-workflow` memory), this UX fix is appropriate for direct commits to develop.

**Spec:** `docs/superpowers/specs/2026-05-25-service-recovery-cards-design.md`

---

## File Structure

| File | Role | Status |
|---|---|---|
| `NemoNotchTests/AgentMonitorRenderDecisionTests.swift` | Update 4 existing tests; add 2 new tests | Modify |
| `NemoNotch/Helpers/AgentMonitorRenderDecision.swift` | Add `HermesCardKind`; add `.reenableCard` + drop `.hidden` on `OpenClawCardKind`; rename `setupCards` payload; tighten no-nag rule to ready | Modify |
| `NemoNotch/Tabs/AgentMonitorTab.swift` | Update `setupState(...)` signature; add `passive: Bool` to `HermesSetupCard`; add new `OpenClawReenableCard` view | Modify |
| `NemoNotch/Tabs/AIChatTab.swift` | Add `ProviderCardKind` enum; replace `needs*Install` flags; rewrite body branch; rename `installPrompt` → `recoveryCards`; rename `providerInstallCard` → `providerCard` with `kind:` parameter | Modify |
| `NemoNotch/Resources/Localizable.xcstrings` | Add 4 new keys: `ai.currently_off`, `ai.enable`, `agents.currently_off`, `agents.enable` (en + zh-Hans) | Modify |

Order rationale: pure decision logic (with TDD) first, then UI views downstream so each task compiles against a stable type.

---

## Task 1: Decision tests — update payload + add ready-based no-nag tests (TDD red)

**Files:**
- Modify: `NemoNotchTests/AgentMonitorRenderDecisionTests.swift`

This task writes the new test expectations before the production code changes. After this task the file will not compile until Task 2 lands. That is intentional — it's the "red" half of red-green.

- [ ] **Step 1: Replace the entire test file with the new payload + new tests**

Open `NemoNotchTests/AgentMonitorRenderDecisionTests.swift` and replace its contents with:

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
        hermesInstalled: Bool = false,
        hermesEnabled: Bool = true
    ) -> AgentMonitorRenderDecision.Mode {
        AgentMonitorRenderDecision.decide(
            hasOnlineMonitor: hasOnlineMonitor,
            openClawPendingApproval: openClawPending,
            openClawIsInstalled: openClawInstalled,
            openClawUserEnabled: openClawEnabled,
            hermesIsInstalled: hermesInstalled,
            hermesUserEnabled: hermesEnabled
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

    @Test("Nothing online, nothing installed → setupCards with both install kinds")
    func freshInstallShowsBothCards() {
        let mode = decide()
        #expect(mode == .setupCards(hermes: .installCard, openClaw: .installHintCard))
    }

    @Test("Nothing online, Hermes installed AND enabled → offlineState (no-nag: hermes ready)")
    func hermesInstalledAndEnabledFallsToOffline() {
        #expect(decide(hermesInstalled: true) == .offlineState)
    }

    @Test("Nothing online, OpenClaw installed AND enabled (no pending) → offlineState")
    func openClawInstalledAndEnabledFallsToOffline() {
        #expect(decide(openClawInstalled: true) == .offlineState)
    }

    @Test("User disabled OpenClaw + nothing installed → setupCards with openClaw reenable")
    func userDisabledOpenClawShowsReenable() {
        let mode = decide(openClawEnabled: false)
        #expect(mode == .setupCards(hermes: .installCard, openClaw: .reenableCard))
    }

    @Test("User disabled OpenClaw + pending approval → still reenable (respects user choice)")
    func userDisabledOverridesPending() {
        // Edge case: user disabled OpenClaw while a stale pendingApproval lingers.
        // Honor the user's disable.
        let mode = decide(openClawPending: true, openClawEnabled: false)
        #expect(mode == .setupCards(hermes: .installCard, openClaw: .reenableCard))
    }

    @Test("User disabled Hermes + nothing installed → setupCards with hermes reenable")
    func userDisabledHermesShowsReenable() {
        let mode = decide(hermesEnabled: false)
        #expect(mode == .setupCards(hermes: .reenableCard, openClaw: .installHintCard))
    }

    @Test("User disabled both Hermes and OpenClaw → setupCards with both reenable")
    func userDisabledBothShowsReenable() {
        let mode = decide(openClawEnabled: false, hermesEnabled: false)
        #expect(mode == .setupCards(hermes: .reenableCard, openClaw: .reenableCard))
    }

    // ── NEW: ready-based no-nag rule (was installed-only) ──────────────────

    @Test("User disabled OpenClaw + OpenClaw still installed → reenable (not stuck offline)")
    func disabledOpenClawWithOrphanInstallShowsReenable() {
        // Was: openClawIsInstalled=true → offlineState (misleading: never reconnects)
        // Now: openClawUserEnabled=false means not ready, so falls to setupCards
        let mode = decide(openClawInstalled: true, openClawEnabled: false)
        #expect(mode == .setupCards(hermes: .installCard, openClaw: .reenableCard))
    }

    @Test("User disabled Hermes + Hermes still installed → reenable (not stuck offline)")
    func disabledHermesWithOrphanInstallShowsReenable() {
        let mode = decide(hermesInstalled: true, hermesEnabled: false)
        #expect(mode == .setupCards(hermes: .reenableCard, openClaw: .installHintCard))
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail to compile (expected red state)**

Run:
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/AgentMonitorRenderDecisionTests 2>&1 | tail -20
```

Expected: compile errors like `'setupCards(hermes:openClaw:)' does not exist` and `'reenableCard' is not a member of OpenClawCardKind`. This proves the tests reference the new payload before Task 2 implements it.

- [ ] **Step 3: Do not commit yet**

This file is in a non-building state; we'll commit it together with Task 2's matching production change as a single atomic switch.

---

## Task 2: AgentMonitorRenderDecision — new payload + ready-based no-nag (TDD green)

**Files:**
- Modify: `NemoNotch/Helpers/AgentMonitorRenderDecision.swift`

- [ ] **Step 1: Replace the file with the updated decision type**

Open `NemoNotch/Helpers/AgentMonitorRenderDecision.swift` and replace its contents with:

```swift
import Foundation

/// Pure decision logic for what AgentMonitorTab should render.
///
/// Extracted from AgentMonitorTab so the visibility rules in
/// `docs/superpowers/specs/2026-05-25-service-recovery-cards-design.md`
/// can be tested without mocking SwiftUI environments or MultiAgentMonitor
/// existentials.
enum AgentMonitorRenderDecision {
    enum Mode: Equatable {
        /// At least one monitor is online — show the existing agent rows.
        case agentSections
        /// Monitors ready (enabled+installed) but all offline — show offlineState.
        case offlineState
        /// OpenClaw has a pending approval; render only its approval card.
        case approvalCardOnly
        /// Nothing ready — show recovery cards (install or reenable per service).
        case setupCards(hermes: HermesCardKind, openClaw: OpenClawCardKind)
    }

    /// Card kind for the Hermes slot inside `setupCards`.
    enum HermesCardKind: Equatable {
        /// User enabled but hook not installed — active install CTA.
        case installCard
        /// User disabled — passive re-enable CTA.
        case reenableCard
    }

    /// Card kind for the OpenClaw slot inside `setupCards`.
    enum OpenClawCardKind: Equatable {
        /// Approval pending — render the existing OpenClawApprovalCard.
        case approvalCard
        /// User enabled, not installed (npm package missing) — install hint.
        case installHintCard
        /// User disabled — passive re-enable CTA.
        case reenableCard
    }

    static func decide(
        hasOnlineMonitor: Bool,
        openClawPendingApproval: Bool,
        openClawIsInstalled: Bool,
        openClawUserEnabled: Bool,
        hermesIsInstalled: Bool,
        hermesUserEnabled: Bool
    ) -> Mode {
        if hasOnlineMonitor {
            return .agentSections
        }

        // OpenClaw pending approval is high-priority — but only if the user
        // hasn't explicitly disabled OpenClaw.
        if openClawPendingApproval, openClawUserEnabled {
            return .approvalCardOnly
        }

        // "No nag" rule: only suppress recovery cards if a service is truly
        // ready (enabled AND installed). A disabled-but-installed service is
        // not "ready" because its connect/reconnect is blocked by the flag.
        let hermesReady = hermesUserEnabled && hermesIsInstalled
        let openClawReady = openClawUserEnabled && openClawIsInstalled
        if hermesReady || openClawReady {
            return .offlineState
        }

        let hermesKind: HermesCardKind = hermesUserEnabled ? .installCard : .reenableCard
        let openClawKind: OpenClawCardKind = if !openClawUserEnabled {
            .reenableCard
        } else if openClawPendingApproval {
            .approvalCard
        } else {
            .installHintCard
        }

        return .setupCards(hermes: hermesKind, openClaw: openClawKind)
    }
}
```

- [ ] **Step 2: Run tests to confirm they pass**

Run:
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/AgentMonitorRenderDecisionTests 2>&1 | tail -20
```

Expected: `Test Suite 'AgentMonitorRenderDecision' passed`, 11 tests pass.

- [ ] **Step 3: Build the full project to surface any callers that reference the old payload**

Run:
```
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' build 2>&1 | tail -30
```

Expected: compile errors in `NemoNotch/Tabs/AgentMonitorTab.swift` referring to `showHermesCard:`, `.hidden`, or the old `setupCards(showHermesCard:openClaw:)` payload. These will be fixed in Task 3. Do not proceed until you see this is the only remaining build failure.

- [ ] **Step 4: Do not commit yet**

The repo is in a transient broken state. Commit together with Task 3.

---

## Task 3: AgentMonitorTab — route new payload + add passive Hermes + OpenClawReenableCard

**Files:**
- Modify: `NemoNotch/Tabs/AgentMonitorTab.swift`

- [ ] **Step 1: Update the body switch to consume the new payload**

In `NemoNotch/Tabs/AgentMonitorTab.swift`, find the `body` switch (currently lines 14-25). Replace:

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
```

with:

```swift
var body: some View {
    switch renderMode {
    case .agentSections:
        agentSections
    case .offlineState:
        offlineState
    case .approvalCardOnly:
        OpenClawApprovalCard()
    case let .setupCards(hermes, openClaw):
        setupState(hermes: hermes, openClaw: openClaw)
    }
}
```

- [ ] **Step 2: Update the `setupState` helper signature + body**

Find `setupState(showHermesCard:openClawKind:)` (currently lines 38-57). Replace it with:

```swift
private func setupState(
    hermes: AgentMonitorRenderDecision.HermesCardKind,
    openClaw: AgentMonitorRenderDecision.OpenClawCardKind
) -> some View {
    VStack(spacing: 10) {
        HermesSetupCard(passive: hermes == .reenableCard)
        switch openClaw {
        case .approvalCard:
            OpenClawApprovalCard()
        case .installHintCard:
            OpenClawInstallHintCard()
        case .reenableCard:
            OpenClawReenableCard()
        }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
}
```

Note: `HermesSetupCard` is always rendered now (it has its own active/passive styling); only the OpenClaw slot uses a switch.

- [ ] **Step 3: Update `HermesSetupCard` with `passive: Bool` parameter**

Find `private struct HermesSetupCard: View` (search for `HermesSetupCard` near the end of the file). Replace its entire definition with:

```swift
// MARK: - Hermes Setup Card (active install or passive reenable)

private struct HermesSetupCard: View {
    @Environment(HermesService.self) var hermesService
    @Environment(AppSettings.self) var appSettings
    let passive: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text("🐦")
                .font(.system(size: passive ? 22 : 26))
                .opacity(passive ? 0.65 : 1.0)
            Text("Hermes Agent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(passive ? NotchTheme.textSecondary : NotchTheme.textPrimary)
            Text(passive ? "agents.currently_off" : statusText)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                if passive {
                    appSettings.hermesEnabled = true
                }
                if !hermesService.isHookInstalled {
                    hermesService.installHooks()
                }
            } label: {
                Text(passive ? "agents.enable" : "agents.hermes.install_hook")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(
                Group {
                    if passive {
                        Capsule().stroke(NotchTheme.accent.opacity(0.55), lineWidth: 1)
                    } else {
                        Capsule().fill(NotchTheme.accent.opacity(0.18))
                    }
                }
            )
            .clipShape(Capsule())
            .foregroundStyle(NotchTheme.accent)
            .disabled(!passive && hermesService.isHookInstalled)
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

- [ ] **Step 4: Add the new `OpenClawReenableCard` view**

Locate `OpenClawInstallHintCard` (search for `private struct OpenClawInstallHintCard`). Immediately after its closing brace, append:

```swift
// MARK: - OpenClaw Reenable Card (passive — user disabled, click to enable)

private struct OpenClawReenableCard: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(OpenClawService.self) var openClawService

    var body: some View {
        VStack(spacing: 8) {
            Text("🦞")
                .font(.system(size: 22))
                .opacity(0.65)
            Text("OpenClaw")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
            Text("agents.currently_off")
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                appSettings.openClawEnabled = true
                openClawService.connect()
            } label: {
                Text("agents.enable")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Capsule().stroke(NotchTheme.accent.opacity(0.55), lineWidth: 1))
            .clipShape(Capsule())
            .foregroundStyle(NotchTheme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .notchCard(radius: 10, fill: NotchTheme.surface)
    }
}
```

- [ ] **Step 5: Build to verify the project compiles**

Run:
```
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. Localizable keys `agents.currently_off` and `agents.enable` will render as literal keys at this stage — that's fixed in Task 6.

- [ ] **Step 6: Run the full test suite to confirm decision tests + everything else passes**

Run:
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: all suites pass, including the 11 `AgentMonitorRenderDecision` tests.

- [ ] **Step 7: Commit Tasks 1–3 together as one atomic change**

```bash
git add NemoNotchTests/AgentMonitorRenderDecisionTests.swift \
        NemoNotch/Helpers/AgentMonitorRenderDecision.swift \
        NemoNotch/Tabs/AgentMonitorTab.swift
git commit -m "feat(agents): passive reenable card + ready-based no-nag rule

Adds AgentMonitorRenderDecision.HermesCardKind and OpenClawCardKind.reenableCard
to fix the empty-state dead-end when user disables services in Settings.
Tightens no-nag rule from installed-only to ready (enabled+installed) so
orphan installs no longer get stuck in misleading offlineState."
```

---

## Task 4: AIChatTab — ProviderCardKind + recoveryCards branch + passive providerCard

**Files:**
- Modify: `NemoNotch/Tabs/AIChatTab.swift`

This is the largest file change. The refactor is mechanical: delete three flag properties, add three new properties + a static helper, rewrite the body branch, rename one view and one helper, and parametrize the helper with `kind:`.

- [ ] **Step 1: Add the `ProviderCardKind` enum at file scope**

Open `NemoNotch/Tabs/AIChatTab.swift`. At the top of the file, after `import SwiftUI` (line 1) and before `struct AIChatTab: View` (line 3), insert:

```swift
enum ProviderCardKind: Equatable {
    case ready    // enabled+installed — service contributes to sessions/idle
    case install  // enabled, not installed — active install CTA
    case reenable // disabled — passive re-enable CTA (handles orphan-installed case too)
}
```

- [ ] **Step 2: Replace the three `needs*Install` computed properties with the new state model**

In `AIChatTab`, find the block (currently lines 19-29):

```swift
private var needsClaudeInstall: Bool {
    appSettings.claudeEnabled && !aiService.claudeProvider.isHookInstalled
}

private var needsGeminiInstall: Bool {
    appSettings.geminiEnabled && !aiService.geminiProvider.isHookInstalled
}

private var needsAnyInstall: Bool {
    needsClaudeInstall || needsGeminiInstall
}
```

Replace with:

```swift
private var claudeKind: ProviderCardKind {
    Self.kind(
        enabled: appSettings.claudeEnabled,
        installed: aiService.claudeProvider.isHookInstalled
    )
}

private var geminiKind: ProviderCardKind {
    Self.kind(
        enabled: appSettings.geminiEnabled,
        installed: aiService.geminiProvider.isHookInstalled
    )
}

private var hasAnyReadyProvider: Bool {
    claudeKind == .ready || geminiKind == .ready
}

private var hasRecoveryCards: Bool {
    claudeKind != .ready || geminiKind != .ready
}

private static func kind(enabled: Bool, installed: Bool) -> ProviderCardKind {
    switch (enabled, installed) {
    case (true,  true):  .ready
    case (true,  false): .install
    case (false, _):     .reenable
    }
}
```

- [ ] **Step 3: Rewrite the `body` branch**

In `AIChatTab`, find `var body: some View` (currently lines 98-108):

```swift
var body: some View {
    if needsAnyInstall, allSessions.isEmpty {
        installPrompt
    } else if allSessions.isEmpty {
        idleState
    } else if let sessionId = selectedSessionId, let session = sessionById(sessionId) {
        chatDetail(session: session)
    } else {
        sessionList
    }
}
```

Replace with:

```swift
var body: some View {
    if !hasAnyReadyProvider, hasRecoveryCards, allSessions.isEmpty {
        recoveryCards
    } else if allSessions.isEmpty {
        idleState
    } else if let sessionId = selectedSessionId, let session = sessionById(sessionId) {
        chatDetail(session: session)
    } else {
        sessionList
    }
}
```

- [ ] **Step 4: Rename `installPrompt` → `recoveryCards` and rewire it**

In `AIChatTab`, find `private var installPrompt: some View` (currently lines 110-129). Replace the entire property with:

```swift
private var recoveryCards: some View {
    VStack(spacing: 10) {
        if claudeKind != .ready {
            providerCard(
                source: .claude,
                name: "Claude Code",
                kind: claudeKind
            ) {
                appSettings.claudeEnabled = true
                if !aiService.claudeProvider.isHookInstalled {
                    aiService.claudeProvider.installHooks()
                }
            }
        }
        if geminiKind != .ready {
            providerCard(
                source: .gemini,
                name: "Gemini CLI",
                kind: geminiKind
            ) {
                appSettings.geminiEnabled = true
                if !aiService.geminiProvider.isHookInstalled {
                    aiService.geminiProvider.installHooks()
                }
            }
        }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
}
```

- [ ] **Step 5: Replace `providerInstallCard(...)` with the parametrized `providerCard(...)`**

In `AIChatTab`, find `private func providerInstallCard(source:name:onInstall:)` (currently lines 131-159). Replace the entire function with:

```swift
private func providerCard(
    source: AISource,
    name: String,
    kind: ProviderCardKind,
    onAction: @escaping () -> Void
) -> some View {
    let isPassive = kind == .reenable
    return VStack(spacing: 8) {
        sourceIcon(source, size: isPassive ? 22 : 26)
            .opacity(isPassive ? 0.65 : 1.0)
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isPassive ? NotchTheme.textSecondary : NotchTheme.textPrimary)
        Text(isPassive ? "ai.currently_off" : "ai.hooks_not_installed")
            .font(.system(size: 10))
            .foregroundStyle(NotchTheme.textSecondary)
            .multilineTextAlignment(.center)
        Button(action: onAction) {
            Text(isPassive ? "ai.enable" : "ai.install_hooks")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            Group {
                if isPassive {
                    Capsule().stroke(NotchTheme.accent.opacity(0.55), lineWidth: 1)
                } else {
                    Capsule().fill(NotchTheme.accent.opacity(0.18))
                }
            }
        )
        .clipShape(Capsule())
        .foregroundStyle(NotchTheme.accent)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .notchCard(radius: 10, fill: NotchTheme.surface)
}
```

- [ ] **Step 6: Build to verify**

Run:
```
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. New string keys `ai.currently_off` and `ai.enable` will render literal until Task 6.

- [ ] **Step 7: Run the full test suite**

Run:
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: all suites pass. (AIChatTab has no unit tests per CLAUDE.md UI-test policy; this is just a regression check on the broader suite.)

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Tabs/AIChatTab.swift
git commit -m "feat(ai): passive reenable card + ProviderCardKind state model

Replaces needs*Install flags with a 4-valued ProviderCardKind so the AI
tab always offers a recovery path. When user disables both providers in
Settings, the tab now shows two passive reenable cards instead of the
dead-end idleState."
```

---

## Task 5: Verify stale identifiers are gone

**Files:** none modified — verification only.

This is a quick grep gate that catches stale references the compiler might not flag (e.g., comments, dead code branches, doc strings).

- [ ] **Step 1: Verify the old AIChatTab identifiers are gone from source**

Run:
```
grep -rn "needsClaudeInstall\|needsGeminiInstall\|needsAnyInstall\|installPrompt" NemoNotch/ --include="*.swift"
```

Expected: no hits. If any hit, fix it in this task (most likely a stale comment).

- [ ] **Step 2: Verify the old decision payload is gone from source**

Run:
```
grep -rn "showHermesCard" NemoNotch/ --include="*.swift"
```

Expected: no hits.

```
grep -rn "OpenClawCardKind\.hidden\|openClawKind:" NemoNotch/ --include="*.swift"
```

Expected: no hits in `NemoNotch/` source. (Tests can reference `.reenableCard` but `.hidden` is gone.)

- [ ] **Step 3: No commit needed if grep is clean**

If you made fix-up edits, commit them as `fix: drop stale references to old service-card identifiers`.

---

## Task 6: Localizable strings

**Files:**
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

`Localizable.xcstrings` is JSON. Add the four new keys following the existing pattern (a `"strings"` map keyed by the localizable key).

- [ ] **Step 1: Add the four keys**

Insert each block inside the top-level `"strings"` object. The Xcode string catalog tolerates any ordering — alphabetical placement near existing `ai.*` and `agents.*` entries is conventional:

```json
"ai.currently_off" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Currently off" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "已关闭" } }
  }
},
"ai.enable" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Enable" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "启用" } }
  }
},
"agents.currently_off" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Currently off" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "已关闭" } }
  }
},
"agents.enable" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Enable" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "启用" } }
  }
}
```

- [ ] **Step 2: Build to verify the catalog parses**

Run:
```
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`. A malformed `.xcstrings` will fail the build.

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Resources/Localizable.xcstrings
git commit -m "i18n: add recovery card strings (currently_off, enable)"
```

---

## Task 7: Full test + smoke verification

**Files:** none modified — verification only.

- [ ] **Step 1: Full test suite**

Run:
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: all suites pass, including the 11 `AgentMonitorRenderDecision` tests.

- [ ] **Step 2: Build and launch the app**

Run:
```
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch \
  -destination 'platform=macOS' -derivedDataPath build \
  -configuration Debug build 2>&1 | tail -5 && \
open build/Build/Products/Debug/NemoNotch.app
```

- [ ] **Step 3: Manual smoke — Bug 1 (AI tab dead-end fix)**

Preconditions: Claude + Gemini hooks installed, both flags `enabled=true`.

1. Open Settings → AI / Agents.
2. Click "Uninstall" on Claude Code section.
3. Click "Uninstall" on Gemini CLI section.
4. Switch to the AI tab in the notch.

Expected: two stacked passive cards — "Claude Code · Currently off · [Enable]" and "Gemini CLI · Currently off · [Enable]". Icons are dim (~0.65 opacity), Enable button is outlined (not filled).

Failure mode to watch for: `idleState` ("No active sessions" + server status dot) — that's the unfixed bug.

- [ ] **Step 4: Manual smoke — Bug 2 (Agent tab blank fix)**

Preconditions: Hermes hook installed, OpenClaw paired+connected.

1. Settings → AI / Agents → uninstall Hermes hook.
2. Settings → OpenClaw section → click "Disconnect" (sets `openClawEnabled=false`).
3. Switch to Agent tab.

Expected: two stacked passive cards — "🐦 Hermes Agent · Currently off · [Enable]" and "🦞 OpenClaw · Currently off · [Enable]".

Failure mode: completely blank tab (the old empty-VStack bug).

- [ ] **Step 5: Manual smoke — enable from passive card (AI)**

From Step 3 state, click "Enable" on the Claude passive card.

Expected: `claudeEnabled` flips to `true`, Claude hook installs, Claude card disappears from the recovery view. Gemini card stays as passive reenable. After Claude card disappears, if Gemini remains the only card, only it shows. If Gemini also flips to ready in a follow-up click, the tab moves to `idleState` (now correct — Claude is ready, waiting for sessions).

- [ ] **Step 6: Manual smoke — no-nag rule (AI tab)**

Preconditions: Claude `enabled=true, installed=true`; Gemini `enabled=false`.

Open the AI tab.

Expected: `idleState` (or `sessionList` if Claude has run a session). The Gemini passive card is NOT shown — because Claude is ready, recovery cards are suppressed.

- [ ] **Step 7: Manual smoke — no-nag rule (Agent tab)**

Preconditions: OpenClaw paired+connected (`openClawEnabled=true, isInstalled=true`); Hermes `hermesEnabled=false`.

Open the Agent tab.

Expected: agent rows visible. No Hermes passive card.

- [ ] **Step 8: Manual smoke — ready-based no-nag edge case (the new bug we also fixed)**

Preconditions: OpenClaw was previously paired (config exists on disk = `isInstalled=true`), but user toggled `openClawEnabled=false`. Hermes uninstalled.

Open the Agent tab.

Expected: passive OpenClaw reenable card (not `offlineState`). Before this fix, `openClawIsInstalled=true` would have routed to `offlineState` showing "waiting for connection" with no path to reconnect.

- [ ] **Step 9: Manual smoke — fresh user path is unchanged**

Preconditions: `defaults delete com.gao.NemoNotch.plist`, then relaunch.

Open AI tab and Agent tab.

Expected: active install cards on both tabs (full-opacity icon, filled accent button). This proves the active install flow is regression-free.

- [ ] **Step 10: If all 9 smoke steps pass, no commit needed; if any required code fixes, commit as fix-up**

If a fix was needed:
```bash
git add <files>
git commit -m "fix(<area>): <what was off in smoke step N>"
```

---

## Self-Review

**Spec coverage:**

- Spec §Design "State model" 4-state table → Task 4 (`ProviderCardKind`) + Task 2 (`HermesCardKind` + `OpenClawCardKind.reenableCard`).
- Spec §Design "No nag rule" → Task 2 (ready-based decide logic) + Task 4 (`hasAnyReadyProvider`).
- Spec §Design "AIChatTab changes" → Task 4 (all body / property / helper changes).
- Spec §Design "AgentMonitorTab changes" → Task 3 (signature update + passive Hermes + new OpenClawReenableCard).
- Spec §Design "Card visual rhythm" → Task 4 Step 5 (AIChatTab `providerCard`) + Task 3 Step 3 (`HermesSetupCard`) + Task 3 Step 4 (`OpenClawReenableCard`). All three apply the same active/passive treatment.
- Spec §Component Changes table — all rows have a corresponding task.
- Spec §Verification automated test table — Task 1 + Task 2 implement all 11 tests.
- Spec §Verification manual smoke (8 steps) → Task 7 Steps 3-9 (note: spec's 8 steps collapse into 9 smoke-test steps here because the "fresh user path" check landed as its own step; net coverage identical).
- Spec §Completion Criteria — Task 7 (test pass) + Task 5 (grep gate) + manual smoke.

All spec items have a task. No gaps.

**Placeholder scan:** No `TBD` / `TODO` / "implement appropriate" / "similar to Task N". Every step has either exact code, an exact command, or a precise grep pattern.

**Type consistency check:**

- `ProviderCardKind` defined Task 4 Step 1 — consumed Task 4 Steps 2-5.
- `AgentMonitorRenderDecision.HermesCardKind` defined Task 2 Step 1 — consumed Task 3 Step 2 (`HermesCardKind`) + Task 1's test assertions.
- `AgentMonitorRenderDecision.OpenClawCardKind.reenableCard` defined Task 2 Step 1 — consumed Task 3 Step 2 (switch case) + Task 1's test assertions.
- `AgentMonitorRenderDecision.Mode.setupCards(hermes:openClaw:)` defined Task 2 Step 1 — consumed Task 3 Steps 1-2 + Task 1's test assertions.
- `HermesSetupCard.init(passive: Bool)` defined Task 3 Step 3 — called from Task 3 Step 2.
- `OpenClawReenableCard` defined Task 3 Step 4 — instantiated in Task 3 Step 2.
- `AIChatTab.providerCard(source:name:kind:onAction:)` defined Task 4 Step 5 — called from Task 4 Step 4.
- `AppSettings.claudeEnabled`, `geminiEnabled`, `hermesEnabled`, `openClawEnabled` — pre-existing (defined in earlier unified-service-enablement work), referenced Tasks 3 + 4.
- `AICLIMonitorService.claudeProvider.isHookInstalled`, `geminiProvider.isHookInstalled` — pre-existing, referenced Task 4.
- `HermesService.isHookInstalled`, `installHooks()` — pre-existing, referenced Task 3.
- `OpenClawService.connect()` — pre-existing, referenced Task 3.
- Localizable keys `ai.currently_off`, `ai.enable`, `agents.currently_off`, `agents.enable` — defined Task 6, referenced in Tasks 3 + 4 views. Build verifies catalog parses; missing keys render literal at runtime but do not break the build.

All identifiers line up across tasks.
