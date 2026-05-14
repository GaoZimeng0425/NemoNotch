# AgentMonitorRegistry Design

## Overview

Introduce `AgentMonitorRegistry` — a small `@MainActor @Observable` service that aggregates all `MultiAgentMonitor` instances. Consumers (NotchView, AgentMonitorTab, NotchCoordinator, BadgeViewModel) depend only on the registry, not on concrete `OpenClawService` / `HermesService` types.

Adding a new agent monitor in the future should require touching exactly one file outside the new monitor itself: `NemoNotchApp.swift` (one `register(...)` call).

## Problem

`MultiAgentMonitor` protocol already exists in `Models/MultiAgentMonitor.swift`, and both `OpenClawService` and `HermesService` conform. But consumers still reference the concrete services directly. `grep -rn "OpenClawService\|HermesService"` outside the service files themselves returns **6 files**:

| File | Coupling |
|---|---|
| `NemoNotchApp.swift` | 2 `private var ...Service?` + 2 `.environment(...)` injections; `autoSelectTab` closure reads both `.activeAgent` |
| `Notch/NotchView.swift` | 2 `@Environment(...)` declarations |
| `Notch/Badge/BadgeViewModel.swift` | Constructor takes both services, iterates both `.agents.values` separately |
| `Tabs/AgentMonitorTab.swift` | 2 `@Environment(...)` + 2 conditional `isInstalled` appends |
| `Settings/SettingsView.swift` | Per-monitor settings sections (intentional, see Out of Scope) |
| `Services/AICLIMonitorService.swift` | `weak var hermesService: HermesService?` for hook event routing (intentional, see Out of Scope) |

Note: `NotchCoordinator.swift` itself does not reference the concrete services. The `autoSelectTab` logic that checks both is a closure assigned to the coordinator from `AppDelegate`, capturing AppDelegate's properties — so it is part of `NemoNotchApp.swift`.

Adding a third monitor today requires editing 4 of these files. After this refactor, only `NemoNotchApp.swift` plus the new monitor's own files.

## Out of Scope

The following coupling exists but is **not** addressed by this spec — each is a distinct concern best handled separately:

1. **`AICLIMonitorService.hermesService` weak ref** — used to route hook events received via the shared HookServer socket to Hermes. This is IPC/event-bus coupling, not UI aggregation. Belongs in a future "hook event routing" spec.
2. **Per-monitor settings sections** — OpenClaw and Hermes have substantially different install flows (Keychain device identity + WebSocket handshake vs. hook file installation). Forcing them through a generic settings API would create more coupling than it removes. Settings UI continues to type-switch.
3. **MultiAgentMonitor protocol surface** — the existing interface is sufficient for all derived properties Registry needs. No protocol changes.

## Architecture

### New Component

```
NemoNotch/Services/AgentMonitorRegistry.swift   (new, ~50 lines)
```

```swift
@MainActor
@Observable
final class AgentMonitorRegistry {
    private(set) var monitors: [any MultiAgentMonitor] = []

    func register(_ monitor: any MultiAgentMonitor) {
        monitors.append(monitor)
    }

    var installedMonitors: [any MultiAgentMonitor] {
        monitors.filter { $0.isInstalled }
    }

    var anyActiveAgent: MonitoredAgent? {
        installedMonitors.lazy.compactMap(\.activeAgent).first
    }

    var hasAnyActiveAgent: Bool { anyActiveAgent != nil }

    /// Non-idle agents across all installed monitors, sorted by lastEventTime desc.
    var activeAgents: [MonitoredAgent] {
        installedMonitors
            .flatMap(\.agents.values)
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
    }
}
```

### Dependency Direction

```
AppDelegate
  ├── creates OpenClawService, HermesService
  ├── creates AgentMonitorRegistry
  └── registers both monitors into the registry

  Consumers depend only on AgentMonitorRegistry:
    ├── NotchView
    ├── AgentMonitorTab
    ├── NotchCoordinator
    └── BadgeViewModel
```

## Data Flow

### Startup sequence

```
1. let openClaw = OpenClawService()
   let hermes   = HermesService()

2. let registry = AgentMonitorRegistry()
   registry.register(openClaw)
   registry.register(hermes)

3. openClaw.connect()
   hermes.connect()

4. NotchView gets .environment(registry) instead of two service environments.
   BadgeViewModel constructor takes registry.
   AppDelegate keeps a strong `agentRegistry` property; the autoSelectTab
   closure assigned to NotchCoordinator captures `self` (AppDelegate) and
   reads `self.agentRegistry?.hasAnyActiveAgent`.
```

Registration is synchronous and happens before any consumer is constructed. `connect()` is async I/O — Registry doesn't depend on connect order, since `isInstalled` / `isOnline` are read on-demand.

### Runtime observation

Registry itself is `@Observable` but its derived properties (`activeAgents`, `anyActiveAgent`, etc.) read through `any MultiAgentMonitor` references. Each concrete monitor is also `@Observable`. The Observation framework tracks reads globally during view body evaluation — when a SwiftUI View reads `registry.activeAgents`, the framework registers dependencies on both the Registry's `monitors` array and each accessed monitor's properties (`agents`, `activeAgent`, etc.).

Therefore Registry needs **no manual subscription, forwarding, or Combine pipelines**. State changes in any monitor propagate to all dependent views automatically.

### autoSelectTab semantics

The closure lives in `AppDelegate.applicationDidFinishLaunching` and is assigned to `NotchCoordinator.autoSelectTab`. It captures `[weak self]`.

Before:
```swift
if openClawService?.activeAgent != nil || hermesService?.activeAgent != nil { return .agents }
```

After:
```swift
if agentRegistry?.hasAnyActiveAgent == true { return .agents }
```

Semantically equivalent.

## Component Changes

Net change estimate: **+11 / −23 LOC** plus the new ~50 line Registry file.

| File | Change |
|---|---|
| `Services/AgentMonitorRegistry.swift` | New file |
| `NemoNotchApp.swift` | (a) Create registry, register both monitors; (b) inject `environment(registry)`; (c) remove `environment(openClaw)` and `environment(hermes)` once consumers are migrated; (d) update the `autoSelectTab` closure to use `agentRegistry?.hasAnyActiveAgent`; (e) replace the two `private var ...Service?` fields with a single `agentRegistry` property (leave individual service refs only if other code paths in AppDelegate still need them) |
| `Notch/NotchView.swift` | Replace `@Environment(OpenClawService.self)` + `@Environment(HermesService.self)` with `@Environment(AgentMonitorRegistry.self)` |
| `Notch/NotchCoordinator.swift` | **Not touched** — the class doesn't reference the concrete services; the `autoSelectTab` closure is owned by AppDelegate (see above) |
| `Notch/Badge/BadgeViewModel.swift` | Constructor params `(OpenClawService, HermesService)` → `(AgentMonitorRegistry)`; replace dual iteration with single `for agent in registry.activeAgents` |
| `Tabs/AgentMonitorTab.swift` | 2 `@Environment` → 1 Registry env; remove the `monitors` computed property, use `registry.installedMonitors` directly |
| `Settings/SettingsView.swift` | **Not touched** (out of scope) |
| `Services/AICLIMonitorService.swift` | **Not touched** (out of scope) |

### MultiAgentMonitor protocol

Not modified. Current surface (`agents`, `activeAgent`, `isOnline`, `isInstalled`, `displayName`, `iconEmoji`, `iconAssetName`, `sessionMessages`, `connect()`, `disconnect()`) is sufficient.

## Lifetime & Ownership

- Registry holds `strong` references to monitors (via `monitors` array). This is intentional — there's exactly one Registry, owned by AppDelegate; lifetime matches AppDelegate.
- AppDelegate continues to hold its own strong refs to each Service (transitional — cleaning that up belongs to a future "service container" spec).
- NotchCoordinator holds a `weak` ref to Registry, mirroring how it holds weak refs to other services it consults at decision time.

No retain cycles introduced.

## Error Handling

This refactor introduces **no new failure modes**:
- Registry performs no I/O, no networking, no file access.
- All derived properties are pure computations over the `monitors` array.
- `register(_:)` has no failure semantics.

Existing per-monitor failure handling (connection drops, parse errors, etc.) remains in the concrete services and is unaffected.

## Migration Order

Each step is a separately committable, separately verifiable change. Any step can be reverted independently without breaking earlier steps.

1. **Add `AgentMonitorRegistry.swift`** — pure addition, zero consumers, zero risk.
2. **AppDelegate**: instantiate registry, register both monitors, inject `environment(registry)`. **Keep** existing `environment(openClaw)` and `environment(hermes)` so old consumers still work — new and old coexist.
3. **AgentMonitorTab**: switch to registry. Smoke-test the tab.
4. **AppDelegate autoSelectTab closure**: switch to `agentRegistry?.hasAnyActiveAgent`. Smoke-test tab auto-selection.
5. **BadgeViewModel**: constructor takes registry. Smoke-test badge.
6. **NotchView**: drop the two concrete `@Environment` declarations (all consumers now use Registry).
7. **AppDelegate**: drop the now-unused `environment(openClaw)` and `environment(hermes)` injections.

## Verification

The project has no unit test infrastructure. Verification is end-to-end smoke testing — explicit, not papered over.

After each migration step:

1. App launches without crash; menu bar icon visible.
2. AgentMonitorTab: with at least one OpenClaw or Hermes agent active, the tab renders the agent's section correctly.
3. CompactBadge (notch collapsed state): when an agent is non-idle, the badge shows the active agent's icon at the right priority.
4. autoSelectTab: with no media playing and no AI session, opening the notch while an agent is active lands on `.agents` tab.
5. Settings: OpenClaw and Hermes settings sections remain visible and functional (they weren't touched).

## Completion Criteria

- All smoke checks pass.
- `grep -rn "OpenClawService\|HermesService" NemoNotch/ | grep -v "Service.swift\|NemoNotchApp.swift"` returns only `Settings/SettingsView.swift` and `Services/AICLIMonitorService.swift` (the two intentional out-of-scope sites). `NemoNotchApp.swift` is excluded because AppDelegate still owns and instantiates the concrete services — Registry doesn't replace ownership, only aggregates references.
- Adding a hypothetical third monitor would require changes only in: the new monitor's own files plus `NemoNotchApp.swift` (one `registry.register(...)` line).
