# Unified Service Enablement (Tab-First) — Design

## Overview

Four integrations — Claude Code, Gemini CLI, Hermes Agent, OpenClaw — currently expose their enable/disable flows inconsistently:

| Service | In-tab enable | Settings enable | Settings uninstall |
|---|---|---|---|
| Claude Code | ✅ `AIChatTab.installPrompt` | ✅ | ✅ |
| Gemini CLI | ✅ same prompt | ✅ | ✅ |
| Hermes Agent | ❌ | ✅ | ✅ |
| OpenClaw | ❌ (only an `npm install` hint) | ❌ | ❌ |

From the user's perspective every enablement is "click once and it shows up", but the surfaces don't match that mental model. This spec aligns the four around two principles:

1. **Tab = discovery + first action.** Wherever the user first finds emptiness, they can resolve it with one click.
2. **Settings = management.** Re-install, uninstall, disable — all symmetrical across four services.

## Problem

- `AgentMonitorTab.notInstalled` (`NemoNotch/Tabs/AgentMonitorTab.swift:33-46`) shows only `npm install -g openclaw@latest` as text — no actionable button, and Hermes is invisible.
- `Settings → AI CLI` (`NemoNotch/Settings/SettingsView.swift:249-296`) has Claude / Gemini / Hermes hook cards but **no entry for OpenClaw** — the user can't disconnect or revoke a paired device from inside the app.
- The Settings tab is labeled "AI CLI" while it already contains Hermes (non-CLI agent) — the name no longer matches contents.

## Goals

- All four services have an actionable "enable" path in the tab where their absence is visible.
- All four services have a symmetrical management surface in Settings (status + enable/disable + remove).
- No nagging: when **any** agent monitor is online, the AgentMonitorTab does not push setup CTAs for other monitors.

## Non-Goals

- Auto-detect whether `hermes` / `openclaw` binaries exist on `$PATH`.
- Auto-start agent processes.
- Remove the existing `AIChatTab.installPrompt` (already conforms to the new model).
- Change `MultiAgentMonitor` protocol surface.
- Replace `AppDelegate`-driven service ownership.

## Design

### Change 1 — AgentMonitorTab empty state

Replace the current `notInstalled` branch in `NemoNotch/Tabs/AgentMonitorTab.swift:33-46`:

```swift
// Current
private var notInstalled: some View {
    VStack(spacing: 10) {
        Image(systemName: "ladybug.fill")
        Text("agents.not_installed")
        Text("npm install -g openclaw@latest")
    }
}
```

New `setupState` view: two parallel cards stacked vertically.

```
┌─ Hermes Agent ──────────────────────────────┐
│  🐦 (icon)                                  │
│  status: "Hook 未安装" | "已安装，未运行"   │
│  [ 安装 Hook ]   (primary, calls            │
│                   hermesService.installHooks)│
└─────────────────────────────────────────────┘
┌─ OpenClaw ──────────────────────────────────┐
│  Two variants chosen by service state:      │
│                                             │
│  (a) pendingApproval != nil →               │
│      existing OpenClawApprovalCard          │
│      (icon + approve command + run/copy)    │
│                                             │
│  (b) pendingApproval == nil AND             │
│      isInstalled == false →                 │
│      simple "未安装" card:                  │
│        🦞 icon                              │
│        "OpenClaw 未安装"                    │
│        `npm install -g openclaw@latest`     │
│      (no buttons — install is out-of-band)  │
└─────────────────────────────────────────────┘
```

The variant-(b) card is a new private view `OpenClawInstallHintCard` in `AgentMonitorTab.swift`, separate from `OpenClawApprovalCard` to keep each card's responsibility single. Both use the same visual rhythm as the new Hermes card.

#### Visibility rules

| Condition | Render |
|---|---|
| Any monitor `isOnline` | `agentSections` (existing path). No setup cards. |
| All offline AND OpenClaw `pendingApproval != nil` AND Hermes installed | Existing `OpenClawApprovalCard` only (Hermes will show in `agentSections` once online — current behavior preserved). |
| All offline AND nothing installed | New `setupState` with both cards. |
| All offline AND only Hermes installed | Hermes appears in `offlineState` (current path); no OpenClaw card. |
| User disabled OpenClaw via Settings (`openClawEnabled = false`) | OpenClaw card hidden from `setupState`. |

Key invariant: **if any monitor has agents flowing, the user is never prompted to set up another monitor.** This is the "有一个就不提醒" rule.

### Change 2 — Settings tab rename + OpenClaw section

`NemoNotch/Settings/SettingsView.swift`:

- Tab label `"AI CLI"` → `"AI / Agents"` (line 27).
- After the existing Hermes `hookSection` (line 274-280), add a new OpenClaw section that mirrors the visual rhythm but uses different verbs ("连接" / "断开" / "移除设备", not "安装" / "卸载") to be honest about what's happening.

```swift
// New OpenClaw section in claudeView
Divider()

openClawSection(
    status: openClaw.gatewayOnline ? .connected(deviceIdShort: openClaw.deviceIdShort)
                                   : .disconnected,
    isUserEnabled: appSettings.openClawEnabled,
    onConnect:   { appSettings.openClawEnabled = true; openClaw.connect() },
    onDisconnect:{ appSettings.openClawEnabled = false; openClaw.disconnect() },
    onRemoveDevice: { openClaw.removeDeviceSelf() }
)
```

`openClawSection` view layout:

```
┌──────────────────────────────────────────────┐
│  🦞  OpenClaw                                │
│  ●  已连接 · device a1b2c3d4…                │  ← or  "○ 已断开"
│  [ 断开 ]            [ 移除设备 ]            │  ← or  "[ 连接 ]" only
└──────────────────────────────────────────────┘
```

Only the deviceId short (first 8 chars) is displayed — no gateway URL, no token, no port.

`[ 移除设备 ]` button is destructive role; only visible when `gatewayOnline == true` (we need a paired identity to revoke).

### Change 3 — OpenClawService API additions

`NemoNotch/Services/OpenClawService.swift`:

1. **Expose deviceId short form** (read-only) for Settings display:

   ```swift
   var deviceIdShort: String { String(deviceId.prefix(8)) }
   ```

2. **`removeDeviceSelf()`** — mirror of `approveSelf()` at lines 635-643. Runs `openclaw devices remove <deviceId>` via the existing `runInUserShell` helper (lines 668-712), then on success calls `disconnect()`.

   ```swift
   func removeDeviceSelf() {
       guard !deviceId.isEmpty else { return }
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
           LogService.info("Device removed, disconnecting", category: "OpenClaw")
           disconnect()
       } else {
           LogService.error(
               "Remove device failed (exit=\(result.exitCode)): \(result.stderr)",
               category: "OpenClaw"
           )
       }
   }
   ```

   New state flag: `var isRemovingDevice = false` alongside `isApproving`.

3. **Respect user-disable in `connect()`** — `AppSettings` is constructed once in `NemoNotchApp.swift:109` and injected via `@Environment`; services don't have access. To avoid coupling `OpenClawService` to `AppSettings`, the guard reads `UserDefaults` directly using the same key + default as the `AppSettings` accessor:

   ```swift
   func connect() {
       let enabled = (UserDefaults.standard.object(forKey: "openClawEnabled") as? Bool) ?? true
       guard enabled else {
           LogService.info("User-disabled, skipping connect", category: "OpenClaw")
           return
       }
       guard isInstalled else { … }
       …
   }
   ```

   The key string `"openClawEnabled"` is shared with `AppSettings`; to prevent drift, extract it to a static constant `AppSettings.openClawEnabledKey` and reference from both call sites.

`disconnect()` itself needs no change — it's already idempotent and clears reconnectTimer.

### Change 4 — AppSettings flag

`NemoNotch/Models/AppSettings.swift`:

```swift
static let openClawEnabledKey = "openClawEnabled"

var openClawEnabled: Bool {
    get { (UserDefaults.standard.object(forKey: Self.openClawEnabledKey) as? Bool) ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Self.openClawEnabledKey) }
}
```

Default `true` preserves current behavior for existing users — OpenClaw connects on launch unless the user explicitly turns it off. The static key constant is also read by `OpenClawService.connect()` so both sides agree on the UserDefaults key.

### Change 5 — i18n strings

New Localizable keys (Chinese + English):

| Key | en | zh |
|---|---|---|
| `agents.hermes.install_hook` | "Install Hook" | "安装 Hook" |
| `agents.hermes.status.uninstalled` | "Hook not installed" | "Hook 未安装" |
| `agents.hermes.status.offline` | "Installed, not running" | "已安装，未运行" |
| `settings.openclaw.title` | "OpenClaw" | "OpenClaw" |
| `settings.openclaw.connected` | "Connected · device %@" | "已连接 · device %@" |
| `settings.openclaw.disconnected` | "Disconnected" | "已断开" |
| `settings.openclaw.connect` | "Connect" | "连接" |
| `settings.openclaw.disconnect` | "Disconnect" | "断开" |
| `settings.openclaw.remove_device` | "Remove device" | "移除设备" |
| `settings.tab.ai_agents` | "AI / Agents" | "AI / Agents" |

## Component Changes

| File | Change |
|---|---|
| `NemoNotch/Tabs/AgentMonitorTab.swift` | Replace `notInstalled` with `setupState`; add visibility predicate for "any monitor online" rule; add private views `HermesSetupCard` and `OpenClawInstallHintCard`; reuse existing `OpenClawApprovalCard` for the pending-approval variant. |
| `NemoNotch/Settings/SettingsView.swift` | Rename tab label; add `openClawSection` view + supporting status enum; inject `@Environment(OpenClawService.self)` + `@Environment(AppSettings.self)`. |
| `NemoNotch/Services/OpenClawService.swift` | Expose `deviceIdShort`; add `removeDeviceSelf()` + `finishRemoveDevice(result:)` + `isRemovingDevice` flag; add `openClawEnabled` guard at top of `connect()`. |
| `NemoNotch/Models/AppSettings.swift` | Add `openClawEnabled: Bool` (default `true`). |
| Localizable strings | Add 10 new keys (table above) to both `zh-Hans` and `en` strings catalogs. |

Net code estimate: roughly **+150 / −15 LOC**.

## Data Flow

### Enable Hermes from AgentMonitorTab

```
User clicks "安装 Hook" in setupState
  → hermesService.installHooks()
  → HermesHookInstaller.install() patches ~/.hermes/config.yaml
  → hermesService.isHookInstalled becomes true
  → AgentMonitorRegistry.installedMonitors picks up Hermes
  → AgentMonitorTab re-renders: setupState replaced by offlineState
    (still no agents yet — user needs to start Hermes process)
```

### Disconnect OpenClaw from Settings

```
User clicks "断开" in OpenClaw settings card
  → appSettings.openClawEnabled = false   (persisted)
  → openClawService.disconnect()
  → gatewayOnline = false, reconnectTimer invalidated
  → AgentMonitorTab: OpenClaw card hidden from setupState
  → On next app launch, openClawService.connect() bails on the new guard
```

### Remove device from Settings

```
User clicks "移除设备" in OpenClaw settings card
  → openClawService.removeDeviceSelf()
  → runInUserShell("openclaw devices remove <deviceId>")
  → on success: disconnect()  (does NOT set openClawEnabled=false —
    leaving the toggle as a separate concern. User who wants to
    re-pair from scratch flips toggle off, removes device, flips on.)
```

Note: device removal does **not** delete the local Ed25519 keypair at `~/Library/Application Support/NemoNotch/openclaw-device.key`. The same deviceId persists locally; the user re-pairs by running `openclaw approve <deviceId>` again. This is intentional — losing the local key would force a fresh pairing flow without any benefit.

## Error Handling

| Path | Failure | Behavior |
|---|---|---|
| `hermesService.installHooks()` | Write to `~/.hermes/config.yaml` fails | Existing `LogService.error`; UI button re-enables; no toast (current behavior preserved). |
| `removeDeviceSelf` | Shell exit non-zero | `LogService.error` with shell + exit + stderr (mirrors `finishApproval`); UI re-enables button; OpenClaw stays connected. |
| `removeDeviceSelf` | `openclaw` not on `$PATH` | Captured by shell stderr; logged. No UI prompt. |
| User disables OpenClaw mid-session | `disconnect()` is idempotent | WS closes cleanly via `cancel(with: .goingAway)`. |

No new failure modes vs. today.

## Verification

The project has unit tests only for pure logic (per `CLAUDE.md`). This change is UI + IPC, so verification is end-to-end smoke testing:

1. **Empty state, fresh install (no `~/.hermes/config.yaml`, no `~/.openclaw/openclaw.json`)**: AgentMonitorTab shows both setup cards stacked.
2. **Hermes hook installed via tab button**: Card swaps to `offlineState` for Hermes; OpenClaw card remains.
3. **OpenClaw paired (gateway running, deviceId approved)**: When agents are active, both setup cards hidden, `agentSections` renders.
4. **OpenClaw pendingApproval mid-session**: `OpenClawApprovalCard` / `Banner` still appears per existing logic.
5. **Settings → AI / Agents** tab: 4 sections visible, OpenClaw section shows `已断开` initially (until first connect).
6. **Settings "断开" toggle**: WS closes; `gatewayOnline = false`; re-launching app does not auto-connect.
7. **Settings "连接" toggle**: WS reopens; if not yet approved, `pendingApproval` appears in tab.
8. **Settings "移除设备"**: Shell command runs, log shows exit 0; service disconnects but `openClawEnabled` remains `true`.

## Completion Criteria

- All 8 smoke checks pass.
- `grep -rn "agents.not_installed" NemoNotch/` returns zero hits (key replaced).
- Re-running fresh-launch from clean state (`rm ~/Library/Preferences/com.gao.NemoNotch.plist`) lands on both setup cards visible by default.
- Settings shows 4 service sections regardless of installation state.
