# opencode Notifications — Design

**Date:** 2026-06-26
**Status:** Approved (design)
**Topic:** Add opencode session notifications to NemoNotch, on par with the Claude Code experience.

## Goal

Surface opencode (the open-source AI coding CLI, https://opencode.ai) session activity in
NemoNotch exactly like Claude Code: collapsed-notch **badge**, **completion flash** + **toast**
when a session finishes, and a live **status card** in `AIChatTab`.

**Scope (explicitly chosen):**

- **In:** notifications + live status — phase (working / done / waiting / awaiting-approval),
  current tool, project folder, model. opencode sessions appear in `AIChatTab` as status cards
  and drive badges / completion flash / toast.
- **Out:** full conversation/message/token parsing (no `OpencodeConversationParser`); approve-from-notch
  (permission requests are **notify-only** — user approves in opencode's own TUI); opencode usage quota.

## Why a plugin (the chosen mechanism)

opencode does **not** use Claude/Gemini-style `settings.json` command hooks. It has a first-class
**plugin system**: `.ts`/`.js` files auto-loaded from `~/.config/opencode/plugin/` (global) and
`.opencode/plugins/` (project). opencode's own in-app tips literally recommend *"Use plugins to send
OS notifications when sessions complete."*

A plugin runs **in the opencode process** (TUI and `serve` modes both load the plugin host) and can
subscribe to lifecycle hooks. NemoNotch writes a small plugin that POSTs normalized `HookEvent`s to
NemoNotch's **existing** `HookServer` (`127.0.0.1:<port>`) with `cli_source: "opencode"`.

This reuses the entire existing pipeline with no new transport:

```
opencode process
  └─ nemonotch-notify.ts (plugin)  ──POST /hook (cli_source=opencode)──▶  HookServer
                                                                              │
                                              routeEvent("opencode") ────────┘
                                                       │
                                                OpencodeProvider.handleEvent
                                                       │ mutate
                                                       ▼
                                                 AISessionStore  ──▶ badges / CompletionFlashService / toast / AIChatTab
```

It is the exact mirror of `hook-sender.sh` + `HookInstaller` (Claude/Gemini) and
`hermes-hook-sender.sh` + `HermesHookInstaller` (Hermes). `OpencodePluginInstaller` is modeled on
`HermesHookInstaller` (own installer, own sender, registered via the existing
`MultiAgentMonitor`-style registration — here, an `AIProvider`).

### Alternatives considered (rejected)

- **File-watching `~/.local/share/opencode/storage/` (pull, like Gemini's parser).** More fragile
  (storage schema can change, polling latency), and cannot do real-time idle/permission signals as
  cleanly. The plugin push model is both simpler and higher-fidelity for notifications.
- **Connecting to `opencode serve`'s SSE event stream.** Requires opencode running in server mode on
  a known port; doesn't cover the common TUI usage. Rejected.

## Components

### New files

1. **`NemoNotch/Services/OpencodePluginInstaller.swift`**
   - Writes/removes the plugin file at `~/.config/opencode/plugin/nemonotch-notify.ts`.
   - `install()`, `uninstall()`, `refreshScript()`, `isInstalled` (file exists + contains our marker).
   - The plugin file **is** the registration — no `opencode.json` edit needed (auto-loaded from `plugin/`).
   - Embeds the current `NotchConstants.hookServerPort` at write time; `refreshScript()` rewrites it when
     the port changes (called from `HookServer.handleListenerState`, next to `HermesHookInstaller.refreshScript()`).
   - Mirrors `HermesHookInstaller`'s structure (marker constant, `scriptDir`/`scriptPath`, version line).

2. **The embedded TS plugin** (a Swift string literal inside `OpencodePluginInstaller`).
   - Default-exports a `Plugin` from `@opencode-ai/plugin` shape (a function returning `Hooks`).
   - Captures `cwd` from `PluginInput.directory` at construction.
   - Hooks → POST payloads (all fire-and-forget `fetch`, short timeout, swallow errors if NemoNotch is down):

     | opencode hook / event           | emitted `hook_event_name` | notes |
     |---------------------------------|---------------------------|-------|
     | `chat.message`                  | `UserPromptSubmit`        | also sends `model` = `providerID/modelID` |
     | `tool.execute.before`           | `PreToolUse`              | `tool_name`, `tool_use_id` = callID |
     | `tool.execute.after`            | `PostToolUse`             | `tool_name`, `tool_use_id` = callID |
     | `permission.ask`                | `Notification`            | **non-blocking**; returns immediately so opencode's TUI still owns the decision |
     | `event` → `session.idle`        | `Stop`                    | the "done" signal |
     | `event` → `session.error`       | `Stop`                    | treated as completion |
     | `event` → `session.compacted`   | `PreCompact`              | optional; sets compacting phase |

   - **Not** `PermissionRequest` for `permission.ask` — that name triggers `HookServer`'s blocking
     hold-the-connection path. We deliberately use `Notification` (immediate ack) for notify-only.

3. **`NemoNotch/Services/OpencodeProvider.swift`** — `AIProvider` conformer.
   - `source = .opencode`, `isHookInstalled` backed by `OpencodePluginInstaller.isInstalled`.
   - `installHooks()` / `uninstallHooks()` delegate to the installer.
   - `handleEvent(_:)` maps the pushed events to store mutations (`mutateOrCreate`):
     - `UserPromptSubmit` / `PreToolUse` / `PostToolUse` → `.processing` (set `currentTool` on
       Pre, clear on Post), set `cwd`, `model`, `lastEventTime`.
     - `Notification` → `.waitingForApproval`.
     - `Stop` → `.waitingForInput` (the active→idle edge `CompletionFlashService` keys on).
     - `PreCompact` → `.compacting`.
   - `respondToPermission(...)` is a **no-op** (notify-only; opencode owns the decision).
   - Reuses the same stale-session timeout cleanup as Claude/Gemini (demote `.waitingForInput`→`.idle`
     after 5 min, remove after 30 min) so an abandoned session doesn't pin the badge forever.
   - **No** conversation parser, **no** file watcher, **no** `scanExistingSessions` file scan
     (sessions appear when the plugin first fires; a v1 simplification).

### Edits (mostly compiler-forced exhaustive `AISource` switches)

- **`NemoNotch/Models/HookEvent.swift`** — add optional `model: String?` (`decodeIfPresent`,
  coding key `model`). Additive; all existing payloads still decode.
- **`NemoNotch/Models/AIProvider.swift`** — add `AISource.opencode`; add `.opencode` case to the
  `displayModel` switch with an opencode model formatter (strips `vendor/` prefix, title-cases).
- **`NemoNotch/Services/AICLIMonitorService.swift`** — construct + own `OpencodeProvider`; wire
  `setHookServer`; `routeEvent` `case "opencode"`; `respondToPermission` `.opencode` case; auto-install
  in `handleServerReady` and in `installHooks()`; include in `anyHookInstalled`.
- **`NemoNotch/Services/HookServer.swift`** — in `handleListenerState` (non-default-port branch) also
  call `try? OpencodePluginInstaller.refreshScript()`.
- **`NemoNotch/Models/AppSettings.swift`** — add `opencodeEnabled` (default `true`, UserDefaults-backed,
  mirroring `claudeEnabled`/`geminiEnabled`).
- **`NemoNotch/Tabs/AIChatTab.swift`** — add `.opencode` to the `allSessions` source filter (gated by
  `opencodeEnabled`); add `opencodeKind`, `opencodeCount`; extend `consoleTitle`/`consoleSummary`/
  mixed-source logic to include opencode.
- **`NemoNotch/Notch/Badge/BadgeViewModel.swift`** — add `.opencode` to the `activeSessions` filter
  (gated by `opencodeEnabled`).
- **`NemoNotch/Notch/Badge/BadgeIconView.swift`** — `aiSourceIcon` `.opencode` case (SF Symbol +
  accent); spinner/dot color branch.
- **`NemoNotch/Notch/MenuBar/HooksSection.swift`** — "Install opencode hooks" button when not installed.

### Automatic — no change needed

- **`CompletionFlashService`** observes `AISessionStore.sortedSessions` and treats
  `status == .working` → not-working as a completion edge. opencode sessions land in the store, so the
  flash + toast fire automatically once `Stop` moves the session out of `.processing`.
- **`AISessionStore`** priority comparator, `activeSession`, `sessions(for:)` are source-agnostic.

## Data flow / state mapping

`AISessionState.status` derivation (existing) gives:
- `.processing`/`.compacting` → `.working` (badge: working; activity glow)
- `.waitingForApproval` → `.waiting` (approval badge/glow)
- `.waitingForInput` → `.waiting`
- `.idle`/`.ended` → `.idle`

So the event mapping above produces: working badge during a turn → completion flash + toast on
`session.idle` → settles to waiting/idle; approval requests light the attention badge.

## Error handling

- Plugin `fetch` failures (NemoNotch not running) are swallowed in the plugin — opencode is never blocked.
- `HookServer` decode failures already `ack` and log; an unknown opencode payload degrades to a logged
  decode error, no crash.
- Abandoned `.processing` sessions (opencode killed mid-turn, no `session.idle`) are demoted/removed by
  the timeout cleanup, identical to Claude/Gemini.
- Port migration: `refreshScript()` rewrites the embedded port so a non-default `HookServer` port keeps working.

## Testing

- **Unit (Swift Testing, `NemoNotchTests/`):** `OpencodeProvider.handleEvent` phase transitions over a
  representative event sequence (`UserPromptSubmit` → `PreToolUse` → `PostToolUse` → `Stop` →
  `Notification`), asserting the resulting `phase`/`status`, `currentTool`, `cwd`, `model` in the store.
  Pure logic, no network/AppKit.
- **Manual:** install the plugin via Settings → run an opencode session → verify working badge, activity
  glow, completion flash + toast on idle, and the status card in `AIChatTab`; toggle `opencodeEnabled`.

## Documentation

Per project convention, update `README.md`, `README_CN.md`, and `CLAUDE.md` (AI Service Architecture
section + the providers list) to mention opencode as a third `AIProvider` and the plugin-based hook
mechanism. Add a macOS cookbook note only if a genuinely new technique is introduced (the plugin
installer reuses the established hook-sender pattern, so likely a one-line cross-reference).

## Out of scope / future

- Full conversation + token parsing (an `OpencodeConversationParser` over `storage/message` + `storage/part`).
- Approve/Deny from the notch (blocking `permission.ask` round-trip via the `/hook` hold-connection path).
- opencode usage quota.
- Resurrecting existing opencode sessions on launch via a storage scan.
