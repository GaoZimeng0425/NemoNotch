# Architecture Optimization Roadmap

Three follow-up proposals after the `AgentMonitorRegistry` refactor (merged 2026-05-14). Each is decision-grade — pick one to promote into a full design spec + plan.

All three are **independent** (no ordering constraint), but recommended sequence is **3 → 2 → 1** based on risk and churn.

---

## Proposal 1: ServiceContainer — consolidate AppDelegate / NotchView wiring

### Problem

After the AgentRegistry merge, `AppDelegate` still holds **10 optional service properties** (`mediaService: MediaService?`, `calendarService: CalendarService?`, ...) and `NotchView` still declares **9 `@Environment(...)` values** to receive them. Adding a service touches both files; every consumer that needs more than one service grows a long env-injection chain.

### Approach

Create `ServiceContainer` — a struct or `@Observable` class holding all services as **non-Optional `let`s**, constructed once at app launch.

```swift
@MainActor
@Observable
final class ServiceContainer {
    let settings: AppSettings
    let media: MediaService
    let calendar: CalendarService
    let aiMonitor: AICLIMonitorService
    let openClaw: OpenClawService
    let hermes: HermesService
    let agentRegistry: AgentMonitorRegistry
    let launcher: LauncherService
    let notification: NotificationService
    let weather: WeatherService
    let hud: HUDService
    let system: SystemService

    init() {
        // All services constructed here; no Optional lifetime games
    }
}
```

Inject **once** as `.environment(container)`. Consumers do `container.media.playbackState` instead of `@Environment(MediaService.self) var mediaService`.

### Alternative considered

**Domain-grouped containers** (`MediaContainer` holds media+calendar+weather; `AgentContainer` holds aiMonitor+openClaw+hermes+registry). More types, debatable cohesion benefit. Rejected as over-engineering — flat 12-property container is plenty readable.

### Scope boundaries

- **In:** runtime service container, `NotchView` env consolidation, `BadgeViewModel` constructor consolidation, `AgentMonitorTab` / other tab env consolidation
- **Out:** Settings UI (separate env chain there is fine — Settings touches a different subset), `AICLIMonitorService.hermesService` weak ref (still IPC concern), AppDelegate ownership semantics (container is owned by AppDelegate as a single `let`)

### Effort

**Medium.** ~10 files touched (AppDelegate, NotchView, every Tab, BadgeViewModel, Settings if we also consolidate it). Migration must be all-at-once unless we tolerate dual containers temporarily. No new behavior.

### Risk

**Low.** Pure structural; behavior unchanged. Risk concentrated in "forget one consumer during rename" — easily caught by build.

### Why it might NOT be worth doing

10 services in a flat `@Environment` list is unpleasant but functional. The AgentRegistry refactor already paid the "abstraction sale tax" once this week — stacking another structural refactor immediately may feel like change for its own sake. Reasonable to defer until adding service #13 or #14 actually hurts.

---

## Proposal 2: Decompose NotchCoordinator

### Problem

`NotchCoordinator` is 419 lines doing **six distinct things**:

1. Geometry calculations (`deviceNotchRect`, `hitboxRect`, `contentSize`, ~40 lines)
2. Multi-screen window slot lifecycle (`NotchWindowSlot`, slot dict management, screen-change handling, ~60 lines)
3. Open/close state machine + animation
4. Tab navigation (`selectNextTab` / `selectPreviousTab`)
5. Frontmost-app tracking (for restore-on-close)
6. Event routing (mouse hit testing, right-click context menu, ~100 lines)

Plus `NotchWindowSlot` (28-line inner type) at the bottom of the same file.

### Approach

Extract along responsibility lines:

```
NotchCoordinator.swift            — state machine + open/close + tab nav (≈150 lines)
NotchGeometry.swift               — pure functions: deviceNotchRect, hitboxRect,
                                    contentSize. No state. (≈50 lines)
NotchSlotManager.swift            — per-screen NotchWindowSlot dict, screen-
                                    parameter-change handling, slot lifecycle.
                                    Owned by NotchCoordinator as `private let`.
                                    (≈100 lines)
NotchEventRouting.swift           — mouse hit testing, context menu builder.
                                    Could be extension on Coordinator or a
                                    separate `NotchEventRouter` type. (≈100 lines)
NotchWindowSlot.swift             — moved out of NotchCoordinator.swift (≈30 lines)
```

`NotchCoordinator` stays the @Observable orchestrator; the extracted helpers are plain types it composes.

### Alternative considered

**Minimal split** — only extract `NotchWindowSlot` (one file). Skip the rest. Pro: minimal disruption. Con: `Coordinator` is still 390 lines doing five things. Doesn't fix the core problem.

### Scope boundaries

- **In:** decomposing NotchCoordinator's internals
- **Out:** changing what NotchCoordinator exposes to NotchView (`status`, `selectedTab`, `notchOpen()`, etc.) — public API stays identical; multi-screen rendering strategy (in-flight on `feature/ai-session-store` branch)

### Effort

**Medium.** New 3-4 files, careful refactor of one big file. Probably 1 focused session.

### Risk

**Medium.** Animation timing and state machine transitions are subtle; spring(0.236)/spring(0.314) durations and the open/close handoff are easy to break without noticing. Heavy smoke test required (open from menu bar, from hotkey, from mouse-approach, close from outside-click, close from drag).

### Why it might NOT be worth doing

419 lines is large but not catastrophic. If you're not actively reading/modifying NotchCoordinator regularly, the cost-of-status-quo is low. Worth doing **just before** any major feature work on the coordinator (e.g., when finishing the multi-screen branch), so the split pays off immediately.

---

## Proposal 3: Remove AppDelegate.shared

### Problem

```swift
nonisolated(unsafe) static var shared = AppDelegate()
```

Swift 6 strict concurrency considers this a smell. The `nonisolated(unsafe)` is required only because the static var is read off-main-thread in theory; in practice, all 5 callsites are on MainActor.

### Approach

Map all 5 callsites:

| Site | Current | Replacement |
|---|---|---|
| `NemoNotchApp.swift:27` (`init`) | `AppDelegate.shared = delegate` | Delete (the `@NSApplicationDelegateAdaptor` value is already the canonical instance) |
| `NemoNotchApp.swift:72` (`MenuContent`) | `AppDelegate.shared.appSettings?.currentLocale` | Pass locale via env or thread `appSettings` through MenuContent's args |
| `NemoNotchApp.swift:105` (`applicationDidFinishLaunching`) | `AppDelegate.shared = self` | Delete |
| `Notch/NotchCoordinator.swift:229` (`shouldSuppressPreviousAppRestore`) | `AppDelegate.shared.shouldSuppressPreviousAppRestore` | Inject closure `restoreSuppressionCheck: () -> Bool` into Coordinator at construction |
| `Notch/NotchCoordinator.swift:328` (`showSettings()`) | `AppDelegate.shared.showSettings()` | Inject closure `onShowSettings: () -> Void` into Coordinator (or pass via ContextMenuDelegate as it already is for other actions) |

Then delete the `static var shared` declaration entirely.

### Alternative considered

**Keep singleton but make it isolated** — `@MainActor static let shared`. Doesn't actually eliminate the antipattern, only papers over the compiler warning. Rejected.

### Scope boundaries

- **In:** 5 call sites + the static declaration + 2 new closure injection points on `NotchCoordinator`
- **Out:** the `AppDelegate` class itself, ownership semantics, NSApplicationDelegateAdaptor wiring

### Effort

**Small.** ~2 hours. Closure plumbing is mechanical.

### Risk

**Low.** Verifiable by `xcodebuild` (compile-time catches missed sites) plus smoke test (open Settings from notch right-click; close notch after focusing another app to test restore suppression).

### Why it might be worth doing first

- Smallest effort, highest "code smell removed" per line changed
- No structural cascade (doesn't touch services, doesn't touch UI)
- Closure injection pattern is already used elsewhere (Coordinator has `autoSelectTab: (() -> Tab?)?`) — consistent

---

## Recommended sequence

```
Proposal 3 (remove AppDelegate.shared)   ~2h  →  removes a Swift 6 smell, no cascade
Proposal 2 (split NotchCoordinator)      ~4h  →  internal to one file's universe
Proposal 1 (ServiceContainer)            ~6h  →  largest blast radius, do last
```

Rationale: do small/contained refactors first so the big structural one (P1) lands on a cleaner codebase. Also gives natural commit checkpoints in case any one introduces regressions.

If you only want to do **one**, my pick is **Proposal 3** — best ROI, lowest risk, and it sets up cleaner patterns for future closure-injection sites.

## Explicitly out of this roadmap

- **Multi-screen notch rendering strategy** — in-flight on `feature/ai-session-store` (`da17c1b feat: multi-screen notch`). Should land that branch first before any coordinator-touching refactor (Proposal 2).
- **AICLIMonitorService.hermesService weak ref** — separate concern (IPC bus, not service wiring or coordination). Deserves its own future spec when there's a 3rd hook-piggyback consumer.
- **`OpenClawService` / `OverviewTab` / `NowPlayingCLI` / `HermesService` file sizes** — same shape problem as Proposal 2, but each on a different file and with different risk profiles. Worth doing one at a time, when actively touching that file.
