# zcode AI Provider — Design

**Date:** 2026-07-06
**Status:** Approved (pending spec review)
**Area:** AI CLI monitoring — new provider

## Problem

NemoNotch monitors Claude Code, Gemini CLI, and opencode. Users also run **zcode**
(ZCode.app's GLM-based agent CLI). NemoNotch should surface zcode sessions in the
same badge / activity-glow / completion-flash / AI-tab surfaces as the other
providers.

## Background — what zcode is (verified against a local install)

- ZCode.app ships a Claude-Code-compatible agent CLI (`/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs`) using **GLM models** (GLM-5.2 / GLM-5-turbo etc.).
- **Hooks are Claude-Code-shaped.** Config lives at `~/.zcode/cli/config.json`. The hook payload is snake_case Claude format — `hook_event_name`, `session_id`, `tool_name`, `cwd`, `transcript_path` — so the existing `HookEvent` model decodes it unchanged.
- Session ids are prefixed **`sess_`** (distinct from opencode's `ses_`).
- During hook execution zcode sets env vars **`ZCODE_SESSION_ID`** and **`ZCODE_PROJECT_DIR`** (confirmed by `strings` on the binary), used for source detection.
- Config structure differs from Claude's: hooks nest under `hooks.events.<Event>` with a sibling **`hooks.enabled = true`** flag, vs Claude's flat `hooks.<Event>`.
- Conversation history (`~/.zcode/cli/rollout/model-io-sess_*.jsonl`) is raw, undocumented model-I/O (errors, request/response envelopes; files up to tens of MB) — **not a clean transcript**. Parsing it for tokens/messages would be fragile, so it is out of scope.

## Goals

- zcode sessions drive the collapsed badge, expanded activity glow, completion flash + toast, and the AI-tab status card — parity with **opencode's scope**.
- Reuse the existing `hook-sender.sh` → `HookServer` → provider pipeline (no plugin needed, unlike opencode).
- Adding zcode follows the established protocol-first provider pattern; no changes to how other providers behave.

## Non-Goals (YAGNI)

- No conversation transcript parsing → no message history, **no token / context-window meters**.
- No usage quota.
- No notch-side permission approval — zcode's own TUI owns approvals (like opencode). `respondToPermission` is a no-op.

## Decisions (resolved during brainstorming)

1. **Integration depth:** live status + notify only (no parsing, no approval).
2. **Auto-install:** write hooks into `~/.zcode/cli/config.json` on launch when zcode is detected (config file exists) **and** `zcodeEnabled`, matching Claude/Gemini/opencode auto-install.
3. **Install surfaces:** full opencode parity — a provider **card** in Settings → AI Agents (install / reinstall / uninstall) **and** an "Install zcode hooks" menu-bar button.
4. **Logo:** the official `icon.svg` "Z" glyph, ported to a tintable `Canvas` vector.

## Design

### Data model

- **`AISource.zcode`** — new enum case. Because `AISource` is used in exhaustive `switch`es, the compiler flags every UI touch point.
- **`AISessionState.displayModel`** — add a `.zcode` arm with `formatZcodeModel` (e.g. `glm-4.6` → `GLM 4.6`). Model may be absent from zcode's payload; degrade gracefully to `nil`.

### `ZcodeProvider` (new — `NemoNotch/Services/ZcodeProvider.swift`)

Mirrors `OpencodeProvider` (notify + status, no parsing, no approval). `source = .zcode`.
Event → phase mapping (via `store.mutateOrCreate(sessionId, source: .zcode)`):

| Hook event | Effect |
|---|---|
| `SessionStart` | create session, `phase = .idle`, record `cwd` |
| `UserPromptSubmit` | `→ .processing` |
| `PreToolUse` | `→ .processing`, `currentTool = tool_name`, `isPreToolUse = true` |
| `PostToolUse` | `→ .processing`, clear `currentTool` / `isPreToolUse` |
| `Notification` | `→ .waitingForInput` |
| `Stop` | `→ .waitingForInput`, clear tool |
| `SessionEnd` | `store.remove` |

Reuses the same 60s cleanup timer / silent-demote (5 min) / stale-remove (30 min) pattern as opencode, scoped to `store.sessions(for: .zcode)`. `applyContext` sets `cwd`, `model` (if present), `lastMessage`, `lastEventName`.

### `HookInstaller` — new `.zcode` target

Add `.zcode` to `HookTarget`:
- `settingsPath` = `~/.zcode/cli/config.json`
- `hookEvents` = `[SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, Stop, Notification]`
- a target trait `usesNestedEventsContainer` (true only for zcode).

`install` / `uninstall` / `isInstalled` gain a small branch: for a nested target they read/write the events map at `hooks["events"]` and set `hooks["enabled"] = true`; flat targets keep operating on `hooks` directly. The existing "clean up all our old entries first, then register current events" logic is preserved, applied to whichever container the target uses. The hook entry command is the same `~/.NemoNotch/hooks/hook-sender.sh`; matcher `""` (match all tools) for good status coverage.

### `hook-sender.sh`

Add zcode source detection **before** the Claude branch (zcode is Claude-compatible so must be disambiguated first):

```
elif [ -n "$ZCODE_SESSION_ID" ]; then CLI_SOURCE="zcode"
```

plus a parent-process fallback (`*zcode*` / `*ZCode*`). Inject `cli_source=zcode`. Bump `scriptVersion` (13 → 14) so the script auto-refreshes on launch.

### `AICLIMonitorService.routeEvent`

- New `case "zcode": zcodeProvider.handleEvent(event)`.
- Unknown-source fallback: `sessionId` starting `sess_` → `zcode` (added alongside the existing opencode `ses_` check; the two prefixes are distinct — `"sess_".hasPrefix("ses_")` is false).
- Owner-based final fallback switch gains a `.zcode` arm.

### Assembly (`AICLIMonitorService`)

Create and own `zcodeProvider`; include it in `anyHookInstalled`, `installHooks`, `respondToPermission` (no-op arm), and `handleServerReady`. In `handleServerReady`, install zcode hooks only when `zcodeEnabled` **and** `~/.zcode/cli/config.json` exists; refresh the shared hook script when any provider (incl. zcode) is installed.

### UI

- **`ZcodeLogoIcon`** (`NemoNotch/Helpers/ZcodeLogoIcon.swift`) — the three white "Z" shapes from `icon.svg` (viewBox 30×30) as tintable filled paths in a `Canvas`; same `init(size:color:)` API as `OpencodeLogoIcon`.
- **`BadgeIconView.aiSourceIcon`** — `.zcode` → `ZcodeLogoIcon`.
- **`AIChatTab`** — `.zcode` source-icon slot + `enabled: appSettings.zcodeEnabled`; recovery-card "enable zcode" path mirrors opencode.
- **`CompletionToastView`** — `.zcode` → `ZcodeLogoIcon`.
- **`SettingsView.claudeView`** — a zcode `providerCard` (install / reinstall / uninstall) with the zcode logo chip; window-appearance-adaptive tint like the others.
- **Menu bar** — an "Install zcode hooks" button mirroring opencode's.

### Settings / gating

- **`AppSettings.zcodeEnabled`** (default `true`), UserDefaults-backed, mirroring `opencodeEnabled`.
- `BadgeViewModel` provider gate gains `case .zcode: appSettings.zcodeEnabled`.

## Files touched

- **New:** `NemoNotch/Services/ZcodeProvider.swift`, `NemoNotch/Helpers/ZcodeLogoIcon.swift`, `NemoNotchTests/ZcodeRoutingTests.swift` (or extend `AISourceRoutingTests`), `NemoNotchTests/ZcodeHookInstallerTests.swift`.
- **Edited:** `Models/AIProvider.swift` (AISource + displayModel), `Services/HookInstaller.swift` (nested target + `hook-sender.sh` string + version bump), `Services/AICLIMonitorService.swift` (assembly + routing), `Models/AppSettings.swift` (zcodeEnabled), `Notch/Badge/BadgeIconView.swift`, `Notch/Badge/BadgeViewModel.swift`, `Tabs/AIChatTab.swift`, `Notch/CompletionToastView.swift`, `Settings/SettingsView.swift`, menu-bar assembly in `NemoNotchApp.swift`.
- **Docs:** `CLAUDE.md`, `README.md`, `README_CN.md`.

## Testing

- **Routing:** an unknown-source event with `session_id` `sess_abc` routes to zcode; a `cli_source: "zcode"` event routes to zcode; opencode `ses_` still routes to opencode (no regression).
- **HookInstaller (nested):** installing `.zcode` into an empty / pre-populated `config.json` produces `hooks.enabled = true` and `hooks.events.<Event>` entries pointing at our script; `isInstalled` detects them; `uninstall` removes only our entries and leaves foreign hooks + sibling `mcp`/`plugins` keys intact.
- **Provider status:** `SessionStart`→idle, `UserPromptSubmit`→working, `Stop`→waiting transitions on the store (Swift Testing, no network/FS beyond a temp config for the installer test).
- Manual: run zcode, confirm badge/glow/flash/toast/status-card light up with the Z logo; Settings card install/uninstall round-trips `config.json`.

## Verification

- Unit tests pass.
- `xcodebuild build` succeeds; exhaustive-switch compiler errors all resolved.
- Manual smoke test against the real zcode CLI.
