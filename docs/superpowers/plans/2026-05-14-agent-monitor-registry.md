# AgentMonitorRegistry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `AgentMonitorRegistry` and migrate 4 consumer sites off concrete `OpenClawService` / `HermesService` types, so adding a new agent monitor only requires editing `NemoNotchApp.swift` + the new monitor's own files.

**Architecture:** A small `@MainActor @Observable` aggregator (`AgentMonitorRegistry`) holds `[any MultiAgentMonitor]` and exposes derived properties (`installedMonitors`, `anyActiveAgent`, `activeAgents`). SwiftUI Observation framework propagates monitor changes through Registry to consumers automatically — no Combine, no manual forwarding. Migration is incremental: old and new wiring coexist while each consumer is moved one at a time.

**Tech Stack:** Swift 6, SwiftUI, `@Observable` macro (Observation framework). Verification is `xcodebuild` + manual smoke testing (no unit test infrastructure exists).

**Spec:** `docs/superpowers/specs/2026-05-14-agent-monitor-registry-design.md`

---

## Verification Conventions

- **Build gate** (after every code change):
  ```
  xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
  ```
  Expected: `** BUILD SUCCEEDED **`

- **Smoke test gate** (where indicated): launch the app from Xcode or `open build/Debug/NemoNotch.app`, perform the listed manual check, then quit.

- **Commit hook**: pre-commit hook blocks direct commits on `main` and runs swiftformat. Both behaviors are expected.

---

## Task 0: Create Feature Branch

This refactor produces ~8 commits coordinated across 5 files. Per Git Flow it warrants a feature branch (small fixes can go directly on `develop`, but this is structural work touching public APIs of `BadgeViewModel`).

**Files:** none (branch operation only)

- [ ] **Step 1: Verify clean working tree on develop**

```bash
git status
```

Expected: `On branch develop` and `nothing to commit, working tree clean`. If not clean, stop and resolve before continuing.

- [ ] **Step 2: Create and switch to feature branch**

```bash
git checkout -b feature/agent-monitor-registry
```

Expected: `Switched to a new branch 'feature/agent-monitor-registry'`

---

## Task 1: Create AgentMonitorRegistry

Add the new aggregator file. Zero consumers yet, zero risk.

**Files:**
- Create: `NemoNotch/Services/AgentMonitorRegistry.swift`

- [ ] **Step 1: Create the file**

Write `NemoNotch/Services/AgentMonitorRegistry.swift` with this exact content:

```swift
import Foundation

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

    var onlineMonitors: [any MultiAgentMonitor] {
        monitors.filter { $0.isInstalled && $0.isOnline }
    }

    var anyActiveAgent: MonitoredAgent? {
        monitors.lazy.compactMap(\.activeAgent).first
    }

    var hasAnyActiveAgent: Bool { anyActiveAgent != nil }

    /// Non-idle agents across all installed monitors, sorted by lastEventTime descending.
    var activeAgents: [MonitoredAgent] {
        installedMonitors
            .flatMap(\.agents.values)
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
    }
}
```

- [ ] **Step 2: Build to verify the file compiles**

```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/AgentMonitorRegistry.swift
git commit -m "$(cat <<'EOF'
feat(agent-registry): add AgentMonitorRegistry aggregator

Pure addition — no consumers yet. Exposes installedMonitors,
onlineMonitors, anyActiveAgent, hasAnyActiveAgent, and activeAgents
derived from registered MultiAgentMonitor instances.
EOF
)"
```

---

## Task 2: Wire Registry into AppDelegate (Keep Old Wiring)

Instantiate the registry and inject it as an environment value, but **keep** the existing `.environment(openClaw)` / `.environment(hermes)` so consumers continue to compile. New and old wiring coexist until consumers migrate.

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: Add `agentRegistry` property to AppDelegate**

Find the block of optional service properties around `NemoNotch/NemoNotchApp.swift:86-98`:

```swift
private var hermesService: HermesService?
private var launcherService: LauncherService?
```

Insert a new property immediately after `hermesService`:

```swift
private var hermesService: HermesService?
private var agentRegistry: AgentMonitorRegistry?
private var launcherService: LauncherService?
```

- [ ] **Step 2: Instantiate and register both monitors**

Find `NemoNotch/NemoNotchApp.swift` lines around 122-125 (Hermes wiring block):

```swift
let hermes = HermesService()
hermes.connect()
aiMonitor.hermesService = hermes
hermesService = hermes
```

Immediately after these 4 lines, insert:

```swift
let registry = AgentMonitorRegistry()
registry.register(openClaw)
registry.register(hermes)
agentRegistry = registry
```

- [ ] **Step 3: Inject registry as a NotchView environment**

Find the `notchCoordinator` block at `NemoNotch/NemoNotchApp.swift:148-164`. The current `.environment(...)` chain on `NotchView` is:

```swift
NotchView(screen: screen)
    .environment(coordinator)
    .environment(settings)
    .environment(media)
    .environment(calendar)
    .environment(aiMonitor)
    .environment(openClaw)
    .environment(hermes)
    .environment(launcher)
    .environment(notification)
    .environment(weather)
    .environment(hud)
    .environment(system)
```

Add `.environment(registry)` immediately after `.environment(hermes)`:

```swift
    .environment(openClaw)
    .environment(hermes)
    .environment(registry)
    .environment(launcher)
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Smoke test — app launches**

Launch the app (from Xcode Run, or `open ~/Library/Developer/Xcode/DerivedData/NemoNotch-*/Build/Products/Debug/NemoNotch.app`). Verify:
- Menu bar icon appears
- No crash on launch

Quit the app.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "$(cat <<'EOF'
feat(agent-registry): instantiate and inject registry alongside concrete services

Old environment(openClaw) and environment(hermes) injections kept
intact — consumers will migrate one at a time in subsequent commits.
EOF
)"
```

---

## Task 3: Migrate AgentMonitorTab to Registry

Switch the Tab to read from Registry. Drop both concrete `@Environment` declarations and the local `monitors` computed property.

**Files:**
- Modify: `NemoNotch/Tabs/AgentMonitorTab.swift`

- [ ] **Step 1: Replace environment declarations and monitors property**

Find `NemoNotch/Tabs/AgentMonitorTab.swift:3-13`:

```swift
struct AgentMonitorTab: View {
    @Environment(OpenClawService.self) var openClawService
    @Environment(HermesService.self) var hermesService
    @State private var expandedAgentId: String?

    private var monitors: [any MultiAgentMonitor] {
        var list: [any MultiAgentMonitor] = []
        if openClawService.isInstalled { list.append(openClawService) }
        if hermesService.isInstalled { list.append(hermesService) }
        return list
    }
```

Replace with:

```swift
struct AgentMonitorTab: View {
    @Environment(AgentMonitorRegistry.self) var registry
    @State private var expandedAgentId: String?

    private var monitors: [any MultiAgentMonitor] {
        registry.installedMonitors
    }
```

(Keep `private var monitors` as a thin alias so the rest of the file — `body`, `agentSections`, etc. — continues to compile without further edits.)

- [ ] **Step 2: Build**

```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Smoke test — AgentMonitorTab renders**

Launch the app. With at least one of OpenClaw or Hermes installed (i.e., `isInstalled == true`):
1. Open the notch.
2. Switch to the `.agents` tab.
3. Confirm the tab shows the expected installed monitor section(s). If no agents are currently running, the empty section header should still appear.
4. If neither is installed: confirm the "not installed" placeholder view shows.

Quit.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Tabs/AgentMonitorTab.swift
git commit -m "$(cat <<'EOF'
refactor(agent-registry): migrate AgentMonitorTab to AgentMonitorRegistry

Drops direct @Environment dependencies on OpenClawService and
HermesService. The local `monitors` property is preserved as a thin
alias over registry.installedMonitors so the rest of the view body
stays unchanged.
EOF
)"
```

---

## Task 4: Migrate AppDelegate autoSelectTab Closure

Switch the closure-captured concrete-service reads to a single registry read.

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: Edit the autoSelectTab closure**

Find `NemoNotch/NemoNotchApp.swift:165-173`:

```swift
notchCoordinator.autoSelectTab = { [weak self] in
    guard let self else { return nil }
    if let session = aiMonitorService?.activeSession, session.status == .working {
        return .claude
    }
    if openClawService?.activeAgent != nil || hermesService?.activeAgent != nil { return .agents }
    if mediaService?.playbackState.isPlaying == true { return .overview }
    return nil
}
```

Change the agents check line to:

```swift
notchCoordinator.autoSelectTab = { [weak self] in
    guard let self else { return nil }
    if let session = aiMonitorService?.activeSession, session.status == .working {
        return .claude
    }
    if agentRegistry?.hasAnyActiveAgent == true { return .agents }
    if mediaService?.playbackState.isPlaying == true { return .overview }
    return nil
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Smoke test — autoSelectTab behavior**

Launch the app. With media not playing and no AI session active, trigger an agent to enter a non-idle state (e.g., start a Hermes session). Open the notch via menu bar "Open Notch". Confirm the notch lands on the `.agents` tab.

If you can't easily trigger an active agent, at minimum confirm: opening the notch with everything idle does **not** crash and does not unexpectedly land on `.agents`.

Quit.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "$(cat <<'EOF'
refactor(agent-registry): autoSelectTab reads from registry

Replaces (openClawService?.activeAgent != nil ||
hermesService?.activeAgent != nil) with
agentRegistry?.hasAnyActiveAgent == true. Semantically equivalent.
EOF
)"
```

---

## Task 5: Migrate BadgeViewModel to Registry

This is the largest single-file change in the plan. BadgeViewModel's constructor signature changes (public-ish API), and its `activeBadgeItems` agent-iteration block collapses from two loops into one.

**Files:**
- Modify: `NemoNotch/Notch/Badge/BadgeViewModel.swift`
- Modify: `NemoNotch/Notch/NotchView.swift` (the BadgeViewModel construction site)

- [ ] **Step 1: Update BadgeViewModel properties**

Find `NemoNotch/Notch/Badge/BadgeViewModel.swift:6-11`:

```swift
private let mediaService: MediaService
private let calendarService: CalendarService
private let aiService: AICLIMonitorService
private let notificationService: NotificationService
private let openClawService: OpenClawService
private let hermesService: HermesService
```

Replace with:

```swift
private let mediaService: MediaService
private let calendarService: CalendarService
private let aiService: AICLIMonitorService
private let notificationService: NotificationService
private let agentRegistry: AgentMonitorRegistry
```

- [ ] **Step 2: Update BadgeViewModel initializer**

Find `NemoNotch/Notch/Badge/BadgeViewModel.swift:18-32`:

```swift
init(
    mediaService: MediaService,
    calendarService: CalendarService,
    aiService: AICLIMonitorService,
    notificationService: NotificationService,
    openClawService: OpenClawService,
    hermesService: HermesService
) {
    self.mediaService = mediaService
    self.calendarService = calendarService
    self.aiService = aiService
    self.notificationService = notificationService
    self.openClawService = openClawService
    self.hermesService = hermesService
}
```

Replace with:

```swift
init(
    mediaService: MediaService,
    calendarService: CalendarService,
    aiService: AICLIMonitorService,
    notificationService: NotificationService,
    agentRegistry: AgentMonitorRegistry
) {
    self.mediaService = mediaService
    self.calendarService = calendarService
    self.aiService = aiService
    self.notificationService = notificationService
    self.agentRegistry = agentRegistry
}
```

- [ ] **Step 3: Collapse the two agent iteration blocks into one**

Find `NemoNotch/Notch/Badge/BadgeViewModel.swift:57-63`:

```swift
for agent in openClawService.agents.values.filter({ $0.state != .idle }) {
    items.append(.agents(state: agent.state, emoji: agent.emoji))
}

for agent in hermesService.agents.values.filter({ $0.state != .idle }) {
    items.append(.agents(state: agent.state, emoji: agent.emoji))
}
```

Replace with:

```swift
for agent in agentRegistry.activeAgents {
    items.append(.agents(state: agent.state, emoji: agent.emoji))
}
```

Note: `registry.activeAgents` is already sorted by `lastEventTime` descending. The previous code's ordering was insertion order (openClaw first, then hermes) — the new ordering may differ when both monitors have active agents simultaneously. This is acceptable because the outer sort at the end of `activeBadgeItems` re-sorts by `priority`, and `.agents` items share a single priority — within that priority the secondary sort is by `lhs.id < rhs.id`. Behavior is consistent.

- [ ] **Step 4: Update NotchView's BadgeViewModel construction site**

Find `NemoNotch/Notch/NotchView.swift:168-180`:

```swift
private func initializeBadgeViewModel() {
    guard badgeViewModel == nil else { return }
    let vm = BadgeViewModel(
        mediaService: mediaService,
        calendarService: calendarService,
        aiService: aiService,
        notificationService: notificationService,
        openClawService: openClawService,
        hermesService: hermesService
    )
    vm.initialize()
    badgeViewModel = vm
}
```

Replace with:

```swift
private func initializeBadgeViewModel() {
    guard badgeViewModel == nil else { return }
    let vm = BadgeViewModel(
        mediaService: mediaService,
        calendarService: calendarService,
        aiService: aiService,
        notificationService: notificationService,
        agentRegistry: agentRegistry
    )
    vm.initialize()
    badgeViewModel = vm
}
```

- [ ] **Step 5: Add the registry @Environment in NotchView**

Find `NemoNotch/Notch/NotchView.swift:13-14`:

```swift
@Environment(OpenClawService.self) var openClawService
@Environment(HermesService.self) var hermesService
```

Add a new line immediately after them (do **not** delete the existing two yet — that happens in Task 6):

```swift
@Environment(OpenClawService.self) var openClawService
@Environment(HermesService.self) var hermesService
@Environment(AgentMonitorRegistry.self) var agentRegistry
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Smoke test — badge updates when agents are active**

Launch the app. Trigger a non-idle agent (start a Claude/Gemini session that calls Hermes, or run an OpenClaw agent). With the notch collapsed:
- Confirm the compact badge appears
- Confirm the agent's emoji or icon is rendered in the badge
- If multiple agents are active, confirm the badge cycles or stacks correctly

If you can't trigger live agents, at minimum confirm: launching with no active agents leaves the notch collapsed with no badge crash.

Quit.

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Notch/Badge/BadgeViewModel.swift NemoNotch/Notch/NotchView.swift
git commit -m "$(cat <<'EOF'
refactor(agent-registry): BadgeViewModel depends on registry

Replaces dual OpenClawService + HermesService injection with a single
AgentMonitorRegistry. The two agents iteration loops collapse into
one read of registry.activeAgents (pre-sorted by lastEventTime).
Outer activeBadgeItems sort still groups by priority, so badge
ordering is preserved.

NotchView keeps its concrete OpenClaw/Hermes environments for now —
those are dropped in the next commit once nothing reads them.
EOF
)"
```

---

## Task 6: Drop Concrete Service Environments from NotchView

After Task 5, nothing in `NotchView` reads `openClawService` or `hermesService`. Remove the unused declarations.

**Files:**
- Modify: `NemoNotch/Notch/NotchView.swift`

- [ ] **Step 1: Verify the declarations are unused**

```bash
grep -n "openClawService\|hermesService" NemoNotch/Notch/NotchView.swift
```

Expected: only the two `@Environment(...)` declaration lines should match. If anything else matches, stop and audit before deleting — there's still a reader.

- [ ] **Step 2: Delete the two `@Environment` lines**

Find and delete these two lines at `NemoNotch/Notch/NotchView.swift:13-14`:

```swift
@Environment(OpenClawService.self) var openClawService
@Environment(HermesService.self) var hermesService
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/NotchView.swift
git commit -m "$(cat <<'EOF'
refactor(agent-registry): drop unused OpenClaw/Hermes envs from NotchView

All consumers within NotchView now read through AgentMonitorRegistry.
EOF
)"
```

---

## Task 7: Drop Now-Unused Environment Injections in AppDelegate

`NotchView` no longer reads `openClawService` or `hermesService` from its environment. The two `.environment(openClaw)` and `.environment(hermes)` injections in AppDelegate are dead.

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: Verify nothing outside AppDelegate/Settings/AICLIMonitorService still reads these envs**

```bash
grep -rn "@Environment(OpenClawService\|@Environment(HermesService" NemoNotch/
```

Expected: zero matches. If anything matches, stop — there's a leftover consumer.

- [ ] **Step 2: Remove the two `.environment(...)` lines**

Find `NemoNotch/NemoNotchApp.swift:148-164` (`notchCoordinator` block). The current chain includes:

```swift
.environment(openClaw)
.environment(hermes)
.environment(registry)
```

Delete the `.environment(openClaw)` and `.environment(hermes)` lines:

```swift
.environment(registry)
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Full smoke test — end-to-end**

Launch the app and run through the verification checklist from the spec:

1. App launches without crash; menu bar icon visible.
2. AgentMonitorTab renders correctly with at least one installed monitor.
3. CompactBadge shows the active agent icon when a non-idle agent exists.
4. autoSelectTab lands on `.agents` when an agent is active and nothing else takes priority.
5. Settings → OpenClaw and Hermes sections both visible and functional (these were intentionally not refactored).

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "$(cat <<'EOF'
refactor(agent-registry): remove dead OpenClaw/Hermes env injections

NotchView no longer reads these environments, so AppDelegate no
longer needs to inject them.
EOF
)"
```

---

## Task 8: Completion Audit

Verify the spec's completion criteria.

**Files:** none (verification only)

- [ ] **Step 1: Confirm only intended sites still reference concrete services**

```bash
grep -rn "OpenClawService\|HermesService" NemoNotch/ | grep -v "OpenClawService.swift\|HermesService.swift" | grep -v "AppDelegate" | grep -v "/.build/"
```

Expected: matches should appear only in:
- `NemoNotch/Settings/SettingsView.swift` (out of scope per spec)
- `NemoNotch/Services/AICLIMonitorService.swift` (out of scope per spec)
- `NemoNotch/NemoNotchApp.swift` (AppDelegate — instantiates the concrete services and registers them)

If any other file matches, audit it and either migrate it (extend this plan) or document why it's exempt.

- [ ] **Step 2: Mental check — adding a hypothetical third monitor**

Trace what files a "CursorAgentsService" implementing `MultiAgentMonitor` would touch:
- `NemoNotch/Services/CursorAgentsService.swift` (new monitor itself)
- `NemoNotch/NemoNotchApp.swift` (instantiate, `connect()`, `registry.register(cursor)`)

Settings UI changes too, but that's out of scope per the spec. Confirm no consumer file (`NotchView.swift`, `BadgeViewModel.swift`, `AgentMonitorTab.swift`) would need to change to make the new monitor show up correctly.

- [ ] **Step 3: Push branch and open PR (optional)**

```bash
git push -u origin feature/agent-monitor-registry
gh pr create --title "refactor: introduce AgentMonitorRegistry for agent-monitor aggregation" --body "$(cat <<'EOF'
## Summary

- Adds `AgentMonitorRegistry` — a small `@Observable` aggregator over `[any MultiAgentMonitor]`
- Migrates `NotchView`, `AgentMonitorTab`, `BadgeViewModel`, and AppDelegate's `autoSelectTab` to depend on the registry instead of concrete `OpenClawService` / `HermesService`
- Adding a new agent monitor now requires editing only `NemoNotchApp.swift` plus the monitor's own files

## Out of scope (documented in spec)

- `AICLIMonitorService.hermesService` weak ref (IPC concern)
- Per-monitor settings UI (intentional type-switching)
- `MultiAgentMonitor` protocol surface (already sufficient)

## Test plan

- [x] `xcodebuild` succeeds at every commit
- [x] App launches without crash
- [x] AgentMonitorTab renders correctly
- [x] CompactBadge shows active-agent icons
- [x] autoSelectTab behavior preserved
- [x] OpenClaw/Hermes Settings sections unchanged

Spec: docs/superpowers/specs/2026-05-14-agent-monitor-registry-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Skip this step and merge directly to develop if the user prefers no-PR flow for refactors.

---

## Rollback Notes

If a problem surfaces after merge, each task is a single isolated commit. Revert from the most recent backward:
- Task 7 revert → restores `.environment(openClaw/hermes)` injections
- Task 6 revert → restores `@Environment` declarations in `NotchView`
- Task 5 revert → restores `BadgeViewModel` old constructor + dual iteration
- etc.

Task 1 (the Registry file itself) can sit unused indefinitely — reverting it is only needed if the abstraction itself proves wrong.
