# AI Tab Empty-State Console — Design

**Date:** 2026-06-26
**Status:** Approved (design)
**Topic:** Redesign the AI tab's two empty presentations into one unified, more polished and more guiding "empty console".

## Goal

The AI tab (`AIChatTab`) currently has two separate, bare empty presentations:

- **`idleState`** — providers are set up but no session is running: a small `sparkles` icon, a single gray "No active sessions" line, and a tiny server-status dot. Feels empty and gives no guidance.
- **`recoveryCards`** — no provider enabled/installed: a vertical stack of per-provider install/enable cards (only the not-ready ones are shown).

Replace both with **one adaptive `emptyConsole`** that is more visually polished AND more guiding: it always shows the three monitored CLIs and their readiness, tells the user what to do, and stays visually consistent across the "waiting" and "needs setup" situations.

**Scope:** purely the empty-state UI of `AIChatTab`. No change to session list, chat detail, badges, providers, or the store.

## Current behavior (for reference)

`AIChatTab.body` (NemoNotch/Tabs/AIChatTab.swift:137):

```
if !hasAnyReadyProvider, hasRecoveryCards, allSessions.isEmpty { recoveryCards }
else if allSessions.isEmpty { idleState }
else if let sessionId = selectedSessionId, let session = sessionById(sessionId) { chatDetail(session:) }
else { sessionList }
```

Existing helpers used: `claudeKind` / `geminiKind` / `opencodeKind` (`ProviderCardKind` = `.ready | .install | .reenable`), `hasAnyReadyProvider`, `serverStatus`, `sourceIcon(_:size:)`, `sourceTint(_:)`, `consoleIcon`, `notchCard`. Theme: dark `panelBase`, warm-orange `accent`/`accentHot`/`accentText`, white-opacity text tiers (`textPrimary`/`textSecondary`/`textTertiary`), `surface`/`surfaceSubtle`.

## New design

### Body branch (simplified)

```
if allSessions.isEmpty { emptyConsole }
else if let sessionId = selectedSessionId, let session = sessionById(sessionId) { chatDetail(session:) }
else { sessionList }
```

`emptyConsole` adapts internally on `hasAnyReadyProvider`; the `recoveryCards` / `idleState` / `hasRecoveryCards` branch logic is removed.

### `emptyConsole` layout

Centered, inner content capped at `maxWidth: 360` so it doesn't stretch on a wide notch; `.frame(maxWidth: .infinity, maxHeight: .infinity)` outer, vertically centered. Vertical stack, ~16pt section spacing:

1. **Hero** (centered VStack, ~8pt spacing)
   - A **new** tile in `consoleIcon`'s visual style (do NOT call `consoleIcon` — it switches on `dominantSource` and renders a different fallback when nil): a `RoundedRectangle(cornerRadius: 12)` filled with `LinearGradient([NotchTheme.accent, NotchTheme.accentHot], topLeading→bottomTrailing)`, 48×48, overlaid with `Image(systemName: "sparkles")` in white.
   - **Breathe animation:** the hero glyph (the sparkles overlay) gently pulses opacity `1.0 ↔ ~0.55` on a slow ease-in-out autoreversing loop (~1.6s), conveying "waiting / alive". Driven by an `@State var breathe` toggled `.onAppear` with `.easeInOut(duration: 1.6).repeatForever(autoreverses: true)`. Calm, low-key.
   - **Title** (`.system(size: 16, weight: .bold)`, `textPrimary`):
     - `hasAnyReadyProvider` → `ai.empty.title_ready` ("AI Console")
     - else → `ai.empty.title_setup` ("Set up AI monitoring")
   - **Subtitle** (`.system(size: 12)`, `textSecondary`):
     - `hasAnyReadyProvider` → `ai.empty.subtitle_ready` ("Waiting for your next session")
     - else → `ai.empty.subtitle_setup` ("Enable a CLI to see live sessions")

2. **Provider list** — one grouped `notchCard(radius: 10, fill: NotchTheme.surface)` containing **all three** providers as rows (Claude Code, Gemini CLI, opencode), in that order, always shown. Rows separated by a hairline `Divider().overlay(NotchTheme.textTertiary.opacity(0.15))` (or simple spacing — implementer's call to match nearest existing grouped-row pattern). Each row via `providerStatusRow(source:name:kind:onAction:)`.

3. **Footer** (centered VStack, ~6pt spacing)
   - **Run hint** — shown only when `hasAnyReadyProvider`: `ai.empty.run_hint` ("Run claude, gemini, or opencode in a terminal — sessions appear here.") in `.system(size: 10)`, `textTertiary`, `.multilineTextAlignment(.center)`.
   - **Server status** — the existing `serverStatus` view (green dot + `ai.unix_socket_ready` / accent dot + `ai.hook_service_not_started`), always shown.

### `providerStatusRow(source:name:kind:onAction:)`

```
HStack: sourceIcon(source, size: 16) + Text(name, .system(size: 12, weight: .semibold))
        Spacer()
        trailing control (state-driven)
row vertical padding ~9, horizontal ~12.
```

Trailing control by `kind`:

- **`.ready`** — a calm status pill (NOT a button): a 6pt `Circle().fill(sourceTint(source))` + `Text("ai.ready")` ("Ready") in `.system(size: 10, weight: .medium)`, `textSecondary`. (No background, or a faint `surfaceSubtle` capsule — implementer matches the lightest existing pill style.)
- **`.install`** — accent-filled capsule button `Text("ai.install_hooks")` (`.system(size: 11, weight: .semibold)`, padding 14×6, `Capsule().fill(accent.opacity(0.18))`, foreground `accent`), `onAction`.
- **`.reenable`** — the whole row dims to opacity ~0.6 (name + icon), trailing accent-**outline** capsule button `Text("ai.enable")` (`Capsule().stroke(accent.opacity(0.55), lineWidth: 1)`, foreground `accent`), `onAction`.

Action closures (unchanged from today's `recoveryCards`):
- Claude: `appSettings.claudeEnabled = true; if !aiService.claudeProvider.isHookInstalled { aiService.claudeProvider.installHooks() }`
- Gemini: same with `geminiEnabled` / `geminiProvider`
- opencode: same with `opencodeEnabled` / `opencodeProvider`

### Removed

- `idleState`, `recoveryCards`, `providerCard` (only used by `recoveryCards`), and the `hasRecoveryCards` computed property if it becomes unused after the body simplification. (Verify `hasRecoveryCards` / `providerCard` have no other callers before deleting; remove imports/helpers that this change orphans.)

## Strings (new)

Add to the same localization catalog as the existing `ai.*` keys (en + zh-Hans, matching `ai.install_hooks`'s structure). Reuses existing `ai.install_hooks`, `ai.enable`, `ai.unix_socket_ready`, `ai.hook_service_not_started`.

| Key | English | 简体中文 |
|---|---|---|
| `ai.empty.title_ready` | AI Console | AI 控制台 |
| `ai.empty.title_setup` | Set up AI monitoring | 设置 AI 监控 |
| `ai.empty.subtitle_ready` | Waiting for your next session | 等待下一个会话 |
| `ai.empty.subtitle_setup` | Enable a CLI to see live sessions | 启用一个 CLI 以查看实时会话 |
| `ai.empty.run_hint` | Run claude, gemini, or opencode in a terminal — sessions appear here. | 在终端运行 claude、gemini 或 opencode — 会话会自动出现在这里。 |
| `ai.ready` | Ready | 就绪 |

## Error handling / edge cases

- **Mixed readiness** (some ready, some not): `hasAnyReadyProvider` is true → ready-copy title/subtitle + run hint shown; not-ready rows still show their Install/Enable buttons. Coherent ("run the ready ones, set up the others").
- **Server not running:** `serverStatus` already renders the accent "not started" state; unchanged.
- No new failure modes — this is presentation only.

## Testing

Pure SwiftUI view code with no extractable logic, so per the project convention (test pure logic only; skip view/NSWindow tests) there is **no unit test**. Verification:
- Clean build (`xcodebuild build … CODE_SIGN_IDENTITY="-"`).
- Manual / screenshot check of both situations: (a) all providers ready, no sessions → hero "AI Console" + three "Ready" rows + run hint; (b) at least one not ready → "Set up AI monitoring" + Install/Enable buttons on the not-ready rows.

## Documentation

Update `CLAUDE.md` only if it describes the AI tab empty states (it does not currently, so likely no change). `README.md` / `README_CN.md`: no change unless they screenshot/describe the empty state. Keep this surgical — docs updates only where the empty state is actually referenced.

## Out of scope

- Session list, chat detail, badges, providers, store.
- Onboarding flows beyond the inline Install/Enable actions already present.
- Any new animation beyond the single hero breathe.
