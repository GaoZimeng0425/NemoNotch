# Service Recovery Cards — Design

## Overview

Follow-up to `2026-05-25-unified-service-enablement-design.md`. The unified-enablement work landed a per-service `enabled` flag (`claudeEnabled`, `geminiEnabled`, `hermesEnabled`, `openClawEnabled`) plus install/uninstall buttons in Settings. After shipping, a UX gap surfaced: when the user uninstalls a service in Settings, the corresponding tab dead-ends instead of offering a recovery path.

This spec adds a fourth per-service state — **passive re-enable** — so the tab always shows a "click to mount" affordance whenever no service in that tab is ready. Tabs become the canonical mount surface; Settings stays as the management surface.

## Problem

Two reproducible bugs in the current `develop` build (post 8db745c):

**Bug 1 — AI tab dead-ends after uninstall.** User uninstalls Claude + Gemini in Settings. Both flags flip to `enabled=false`, both hooks removed. Result:

- `needsClaudeInstall = enabled && !installed` → `false`
- `needsGeminiInstall = enabled && !installed` → `false`
- `needsAnyInstall` → `false`, so `installPrompt` branch is skipped
- `allSessions` filters out both providers (enabled-gated), so `.isEmpty`
- `AIChatTab` falls to `idleState` — "No active sessions" + server status dot, **no path back to install**

The user must navigate to Settings → AI / Agents → "安装 Hook" to recover. The tab itself offers nothing.

**Bug 2 — Agent tab renders empty.** User toggles `openClawEnabled=false` and `hermesEnabled=false`. `AgentMonitorRenderDecision.decide(...)` returns `.setupCards(showHermesCard: false, openClaw: .hidden)`. The `setupState` view stacks two `EmptyView()`s — the tab is **literally blank**.

Both bugs trace to the same design pressure: `enabled=false` was originally meant as "user doesn't want to be nagged", and the implementation treats it as "hide all UI for this service". That choice hides the recovery path too.

## Goals

- Tab is always the canonical mount/enable surface — when no service in a tab is ready, the tab shows actionable per-service cards.
- Re-enable from tab is visually distinct from fresh-install (softer copy, dim styling) so the UX acknowledges the user's prior explicit-off choice.
- "No nag" rule is preserved: if any service is ready (enabled + installed), recovery cards are suppressed.
- Symmetrical between AI tab and Agent tab.

## Non-Goals

- Drop the `enabled` flag concept (we keep it — it's load-bearing for the install/uninstall semantics in Settings).
- Change Settings behavior — Settings keeps install/uninstall buttons unchanged.
- Auto-detect external installers (Hermes binary, `openclaw` npm package). Out of scope per `unified-service-enablement` non-goals.
- Unify AI tab and Agent tab under a shared decision type. The two tabs have genuinely different shapes (sessions vs agent rows); a shared decision engine adds indirection without clarity.

## Design

### State model

Each service S has two persisted booleans: `enabled[S]` (UserDefaults) and `installed[S]` (filesystem-derived). The pair drives a four-valued kind:

| `enabled` | `installed` | Kind | Tab treatment |
|---|---|---|---|
| true | true | `.ready` | service contributes to sessions / agent rows / idle / offline |
| true | false | `.install` | active CTA card |
| false | false | `.reenable` | passive CTA card |
| false | true | `.reenable` | rare; orphan install — treat as `.reenable` (Enable flips flag; hook already installed) |

### "No nag" rule

If any service in a tab is `.ready`, the tab does **not** render recovery cards — it renders its normal content (sessions list, agent sections, idle state, offline state, approval card). Recovery cards appear only when zero services in the tab are `.ready`.

This preserves the existing "one online → don't push setup" behavior for Agent tab and extends the same principle to AI tab.

### AIChatTab changes

`NemoNotch/Tabs/AIChatTab.swift`:

Add a file-scope enum:

```swift
enum ProviderCardKind: Equatable { case ready, install, reenable }
```

Replace the existing `needsClaudeInstall` / `needsGeminiInstall` / `needsAnyInstall` computed properties with:

```swift
private var claudeKind: ProviderCardKind {
    Self.kind(enabled: appSettings.claudeEnabled,
              installed: aiService.claudeProvider.isHookInstalled)
}

private var geminiKind: ProviderCardKind {
    Self.kind(enabled: appSettings.geminiEnabled,
              installed: aiService.geminiProvider.isHookInstalled)
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

Replace the body (currently lines 98–108):

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

Rename `installPrompt` → `recoveryCards`. Body becomes:

```swift
private var recoveryCards: some View {
    VStack(spacing: 10) {
        if claudeKind != .ready {
            providerCard(source: .claude, name: "Claude Code", kind: claudeKind) {
                appSettings.claudeEnabled = true
                if !aiService.claudeProvider.isHookInstalled {
                    aiService.claudeProvider.installHooks()
                }
            }
        }
        if geminiKind != .ready {
            providerCard(source: .gemini, name: "Gemini CLI", kind: geminiKind) {
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

The single onAction closure handles both kinds: passive `.reenable` flips the flag (and conditionally installs hooks if missing); active `.install` only installs hooks (flag is already true).

Rename `providerInstallCard` → `providerCard`, add a `kind: ProviderCardKind` parameter, and switch styling based on kind:

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

`allSessions` keeps its existing enabled-gated filter — when the user disables Claude, stale Claude sessions disappear from the list. That gate stays load-bearing.

### AgentMonitorTab changes

`NemoNotch/Helpers/AgentMonitorRenderDecision.swift`:

Extend the decision payload. Add a `HermesCardKind` parallel to `OpenClawCardKind`:

```swift
enum HermesCardKind: Equatable {
    case installCard      // enabled=true, !installed
    case reenableCard     // enabled=false
}

enum OpenClawCardKind: Equatable {
    case approvalCard
    case installHintCard
    case reenableCard     // NEW
    case hidden           // user disabled + no pending approval — still used? see below
}
```

Update `Mode.setupCards` payload:

```swift
case setupCards(hermes: HermesCardKind, openClaw: OpenClawCardKind)
```

Update `decide(...)`. The no-nag check uses **ready** (enabled+installed), not just installed — so a disabled-but-installed service falls to recovery cards rather than misleading `offlineState`:

```swift
static func decide(
    hasOnlineMonitor: Bool,
    openClawPendingApproval: Bool,
    openClawIsInstalled: Bool,
    openClawUserEnabled: Bool,
    hermesIsInstalled: Bool,
    hermesUserEnabled: Bool
) -> Mode {
    if hasOnlineMonitor { return .agentSections }

    if openClawPendingApproval, openClawUserEnabled {
        return .approvalCardOnly
    }

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
```

`OpenClawCardKind.hidden` is removed — every state in the disabled-flag matrix now maps to a concrete card. Callers that were branching on `.hidden` switch to handling `.reenableCard`.

`NemoNotch/Tabs/AgentMonitorTab.swift`:

Update `setupState(showHermesCard:openClawKind:)` signature to `setupState(hermes:openClaw:)`:

```swift
private func setupState(
    hermes: AgentMonitorRenderDecision.HermesCardKind,
    openClaw: AgentMonitorRenderDecision.OpenClawCardKind
) -> some View {
    VStack(spacing: 10) {
        HermesSetupCard(passive: hermes == .reenableCard)
        switch openClaw {
        case .approvalCard:     OpenClawApprovalCard()
        case .installHintCard:  OpenClawInstallHintCard()
        case .reenableCard:     OpenClawReenableCard()
        }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
}
```

Body switch becomes:
```swift
case let .setupCards(hermes, openClaw):
    setupState(hermes: hermes, openClaw: openClaw)
```

Modify `HermesSetupCard` to take a `passive: Bool` parameter that mirrors the AI tab's `providerCard` styling rules (dim icon, secondary title, outlined button). The active install action stays `hermesService.installHooks()`. The passive enable action flips `appSettings.hermesEnabled = true` and then calls `installHooks()` if not already installed.

Add a new private view `OpenClawReenableCard` near `OpenClawInstallHintCard`:

```swift
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

### Card visual rhythm

Both tabs share the same active/passive treatment so the user reads them identically:

- **Active install card**: filled accent button background (`accent.opacity(0.18)`), full-opacity icon (size 26), `textPrimary` title.
- **Passive re-enable card**: outlined accent button (1pt stroke, no fill), dim icon (size 22, opacity 0.65), `textSecondary` title, footer reads "currently_off".

Card outer shell (`notchCard(radius: 10, fill: NotchTheme.surface)`) is identical so the tab doesn't reflow when state changes mid-session.

## Component Changes

| File | Change |
|---|---|
| `NemoNotch/Tabs/AIChatTab.swift` | Replace `needs*Install` flags with `ProviderCardKind` + `hasAnyReadyProvider` + `hasRecoveryCards`; rewrite body decision; rename `installPrompt` → `recoveryCards`; rename `providerInstallCard` → `providerCard` and add `kind:` parameter for passive styling. |
| `NemoNotch/Helpers/AgentMonitorRenderDecision.swift` | Add `HermesCardKind` enum; add `.reenableCard` to `OpenClawCardKind` and remove `.hidden`; change `setupCards` payload signature; update `decide(...)` logic for both `enabled=false` cases. |
| `NemoNotch/Tabs/AgentMonitorTab.swift` | Update `setupState(...)` signature; modify `HermesSetupCard` with `passive: Bool` parameter; add `OpenClawReenableCard` private view. |
| `NemoNotch/Resources/Localizable.xcstrings` | Add 4 new keys: `ai.currently_off`, `ai.enable`, `agents.currently_off`, `agents.enable` (en + zh-Hans). |
| `NemoNotchTests/AgentMonitorRenderDecisionTests.swift` | Update existing 7 tests to new `setupCards` payload shape; add 4 new tests for the disabled-flag matrix. |

Net code estimate: roughly **+130 / −30 LOC**.

## Data Flow

### Re-enable Claude from tab after uninstall

```
User uninstalled Claude in Settings earlier:
  appSettings.claudeEnabled = false
  claudeProvider.uninstallHooks() → isHookInstalled = false

User opens AI tab:
  claudeKind = .reenable, geminiKind = .reenable (both flags off)
  hasAnyReadyProvider = false, hasRecoveryCards = true
  → recoveryCards renders 2 passive cards

User clicks "Enable" on Claude card:
  → appSettings.claudeEnabled = true
  → claudeProvider.installHooks() (because !isHookInstalled)
  → claudeKind becomes .ready
  → hasAnyReadyProvider = true
  → next render: idleState (claude ready, no sessions yet)
```

### Re-enable Hermes from tab

```
User toggled hermesEnabled=false earlier:
  hermesEnabled=false, isHookInstalled=false (or true if hook orphaned)

User opens Agent tab, no online monitor, no openclaw pending:
  decide(...) → setupCards(hermes: .reenableCard, openClaw: <state>)
  → setupState renders HermesSetupCard with passive=true

User clicks "Enable":
  → appSettings.hermesEnabled = true
  → hermesService.installHooks() if !isHookInstalled
  → next render: setupCards(hermes: .installCard, ...) if install pending,
    or offlineState if installed
```

### "No nag" path — partial-disable doesn't show recovery

```
appSettings.geminiEnabled = false (Gemini disabled)
appSettings.claudeEnabled = true, claudeProvider.isHookInstalled = true (Claude ready)

AI tab:
  claudeKind = .ready, geminiKind = .reenable
  hasAnyReadyProvider = true → recoveryCards branch skipped
  → idleState (or sessionList if active)
  → Gemini re-enable card not shown
```

## Error Handling

| Path | Failure | Behavior |
|---|---|---|
| `claudeProvider.installHooks()` from re-enable card | Settings.json write fails | Existing log via `LogService.error`; button re-clickable; `claudeEnabled` already flipped to `true` (idempotent) |
| `hermesService.installHooks()` from re-enable card | Config write fails | Existing log path; `hermesEnabled=true` persists; user can retry |
| `openClawService.connect()` from re-enable card | WS handshake fails | Existing reconnect logic kicks in; `openClawEnabled=true` persists |
| User rapidly toggles disable→enable | Race on flag write | UserDefaults `set(...)` is atomic; install/connect actions are idempotent |

No new failure modes vs. `unified-service-enablement`.

## Verification

Per `CLAUDE.md`, only the pure decision logic gets unit tests; UI is verified by manual smoke.

### Automated

Update `NemoNotchTests/AgentMonitorRenderDecisionTests.swift`. The file currently has 9 tests; 4 reference the old `setupCards(showHermesCard:openClaw:)` payload and the removed `.hidden` value.

**Rewrites** (existing test → new expected payload):

| Test | Old assertion | New assertion |
|---|---|---|
| `freshInstallShowsBothCards` | `setupCards(showHermesCard: true, openClaw: .installHintCard)` | `setupCards(hermes: .installCard, openClaw: .installHintCard)` |
| `userDisabledHidesOpenClawCard` (rename: `userDisabledOpenClawShowsReenable`) | `setupCards(showHermesCard: true, openClaw: .hidden)` | `setupCards(hermes: .installCard, openClaw: .reenableCard)` |
| `userDisabledOverridesPending` | `setupCards(showHermesCard: true, openClaw: .hidden)` | `setupCards(hermes: .installCard, openClaw: .reenableCard)` (disabled still overrides pending) |
| `userDisabledHidesHermesCard` (rename: `userDisabledHermesShowsReenable`) | `setupCards(showHermesCard: false, openClaw: .installHintCard)` | `setupCards(hermes: .reenableCard, openClaw: .installHintCard)` |
| `userDisabledBothHidesEverything` (rename: `userDisabledBothShowsReenable`) | `setupCards(showHermesCard: false, openClaw: .hidden)` | `setupCards(hermes: .reenableCard, openClaw: .reenableCard)` |

The other 4 existing tests (`anyMonitorOnline`, `openClawPendingTakesPriority`, `hermesInstalledFallsToOffline`, `openClawInstalledFallsToOffline`) don't reference the changed payload — they pass unchanged.

**New tests** for the no-nag-vs-disabled-installed edge case (these are the actual semantic change from the `installed`-based no-nag rule to the `ready`-based one):

- `User disabled OpenClaw + OpenClaw still installed → setupCards(hermes: .installCard, openClaw: .reenableCard)` — fixes "stuck in offlineState" edge case.
- `User disabled Hermes + Hermes still installed → setupCards(hermes: .reenableCard, openClaw: .installHintCard)` — symmetric Hermes edge case.

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/AgentMonitorRenderDecisionTests`

Expected: 11 tests pass (9 existing — 4 with rewritten assertions, 5 unchanged — plus 2 new).

### Manual smoke

1. **Bug 1 repro fixed.** With Claude+Gemini installed initially, go to Settings → AI / Agents → click "Uninstall" on both. Switch to AI tab. **Expected**: two stacked passive cards ("Claude Code · Currently off · [Enable]" + same for Gemini). **Regression check**: no `idleState` dead-end.
2. **Bug 2 repro fixed.** With Hermes hook installed and OpenClaw paired, go to Settings → uninstall Hermes hook, disconnect OpenClaw (`openClawEnabled=false`). Switch to Agent tab. **Expected**: two stacked passive cards.
3. **Enable from passive card — AI tab.** Click "Enable" on the Claude passive card. **Expected**: `claudeEnabled` flips true, hook installs, card disappears; if Gemini still passive, only Gemini card remains; if both flip ready, tab moves to `idleState`.
4. **Enable from passive card — Agent tab.** Click "Enable" on the OpenClaw passive card. **Expected**: `openClawEnabled` flips true, `connect()` runs; card swaps to `installHintCard` (if not paired) or `agentSections` (if already paired).
5. **No-nag rule — AI tab.** Disable Gemini in Settings, keep Claude installed+enabled, run a Claude Code session. Open AI tab. **Expected**: session list visible, no Gemini re-enable card anywhere.
6. **No-nag rule — Agent tab.** Disable Hermes (`hermesEnabled=false`), keep OpenClaw paired+online with an agent. Open Agent tab. **Expected**: agent rows visible, no Hermes re-enable card.
7. **Fresh user — install path unchanged.** `defaults delete com.gao.NemoNotch.plist`, relaunch. **Expected**: both tabs show active install cards (full-opacity icon, filled accent button), matching pre-fix behavior.
8. **Passive card visual differentiation.** Compare the active install card (Bug 1 step before uninstall, fresh state) side-by-side with the passive re-enable card (after uninstall). **Expected**: dim icon, outlined button, secondary title color clearly distinguish the two.

## Completion Criteria

- All 11 `AgentMonitorRenderDecision` unit tests pass.
- All 8 manual smoke steps pass.
- `grep -rn "needsClaudeInstall\\|needsGeminiInstall\\|needsAnyInstall" NemoNotch/` returns zero hits (renamed/removed).
- `grep -rn "showHermesCard" NemoNotch/` returns zero hits in source (payload renamed).
- After `defaults delete com.gao.NemoNotch.plist` + uninstall both providers in Settings, the AI tab visibly shows two passive cards with outlined "Enable" buttons — the exact state that was previously dead-ended.
