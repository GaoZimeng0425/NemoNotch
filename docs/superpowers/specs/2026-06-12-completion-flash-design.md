# Completion Flash + Session Toast — Design

**Date:** 2026-06-12
**Status:** Approved, pending implementation

## Summary

When an AI session finishes a turn (**working → idle**) or an agent finishes
(**active → idle**), NemoNotch plays a one-shot visual notification:

1. **Full-screen edge glow** — a soft, blurred accent-orange glow hugs the
   screen edges, fading in then out once, on **all connected screens**.
2. **Session toast** — a HUD-style black capsule near the notch shows the
   finished session's **project name**, reusing the existing volume/brightness
   HUD presentation style.

Rapid completions are **throttled**: the first completion flashes and shows a
toast; any further completions arriving during the throttle window are **merged
into the same toast** (multiple project names, deduplicated) without replaying
the flash.

The whole feature is gated behind a Settings toggle, defaulting **on**.

## Motivation

Users running AI/agent work off-screen (notch collapsed, attention elsewhere)
have no ambient signal that a turn finished. The existing activity glow only
hugs the *expanded* notch's inner edge and only indicates *ongoing* activity —
there is no completion event. A brief full-screen flash plus a name toast gives
a glanceable "it's done, here's which project" signal without stealing focus.

## Triggers (confirmed)

- **AI session:** `SessionPhase` transition where the resulting
  `AISessionState.status` goes from `.working` to `.idle`
  (i.e. `processing`/`compacting` → `idle`/`ended`).
- **Agent:** an agent in `AgentMonitorRegistry` transitions from an active
  (`AgentMonitorState` non-idle) state to idle.

Both trigger the same flash + toast pipeline.

## Non-goals / suppression (confirmed)

- **No** suppression when the notch is open or when NemoNotch is frontmost — it
  always fires (subject to throttle).
- The only coalescing mechanism is the throttle/merge window.
- No per-outcome color (success/error) — unified accent orange.
- No sound.

## Architecture

### Chosen approach: decoupled observer service

A new `@MainActor @Observable CompletionFlashService` observes the existing
single-source-of-truth stores (`AISessionStore`, `AgentMonitorRegistry`) and
detects completion **edges** itself by diffing against a snapshot of the prior
phase/state per session/agent. This matches the codebase philosophy: stores are
passive truth sources; consumers read them. It adds **one new service file plus
small wiring**, with **no edits to any provider** (`ClaudeCodeService`,
`GeminiProvider`, `OpenClawService`, `HermesService`).

**Alternatives rejected:**

- *Push from providers* — each provider calls the service at its completion
  edge. More precise but scatters trigger logic across many files and increases
  coupling. Rejected as too invasive.
- *Extend `HUDService`* — fold completion in as a new `HUDType`. Rejected:
  `HUDService` is hardware-state (volume/brightness/battery); mixing session
  state in violates the service-separation principle.

### Components

1. **`CompletionFlashService`** — `NemoNotch/Services/`, new, `@MainActor`
   `@Observable`.
   - Observes `AISessionStore.sortedSessions` and the agent registry; keeps
     `[sessionID: priorStatus]` and `[agentID: priorState]` snapshots.
   - On each observed change, recomputes and finds entries whose prior state was
     active and whose new state is idle → these are completions.
   - **Published state for the UI:**
     - `flashActive: Bool` — set true to play one edge-glow cycle, reset after.
     - `toastNames: [String]` and `toastVisible: Bool` — drive the capsule.
   - **Throttle/merge logic:**
     - On a completion edge while **not** in cooldown: set `flashActive`, set
       `toastNames = [name]`, show toast, start a cooldown window
       (`completionFlashThrottle`).
     - On a completion edge **during** cooldown: append `name` to `toastNames`
       (dedup), restart the toast dismiss timer, **do not** replay the flash.
     - Cooldown end re-arms the flash for the next completion.
   - Toast auto-dismiss reuses the `Task`-based pattern from
     `HUDService.restartDismissTimer` (`hudDismissDelay`, fade out).
   - **Name resolution:** AI → `AISessionState.projectFolder ?? displayTitle`;
     agent → the monitor's display name/title.
   - **Gating:** reads `AppSettings.completionFlashEnabled`; when off, the
     service observes nothing / fires nothing.
   - **Logging:** init/deinit `.info`; each detected completion edge `.debug`
     with session id + old/new state; flash fire vs. merge `.debug`.

2. **`CompletionFlashWindow`** — `NemoNotch/Notch/`, new.
   - Borderless, transparent (`backgroundColor = .clear`, `isOpaque = false`),
     `ignoresMouseEvents = true`, non-activating `NSPanel` covering the full
     `screen.frame`.
   - Window level at/above the notch window (`.statusBar + 8` family) so the
     glow sits above app content; `collectionBehavior` includes
     `.canJoinAllSpaces` + `.fullScreenAuxiliary` + `.stationary`.
   - **One window per screen** — mirror the existing per-screen notch-window
     slot/rebuild logic (rebuild on screen-config change). Hosts
     `CompletionFlashView` bound to the shared service.

3. **`CompletionFlashView`** — `NemoNotch/Notch/`, new SwiftUI view.
   - Draws an all-edge inner glow/vignette in `NotchTheme.accent`, blurred,
     `.blendMode(.screen)`, `.allowsHitTesting(false)` — same visual family as
     `NotchGlowRing` but a full-screen rectangle's four edges instead of the
     notch's lower edge.
   - Opacity animates `0 → peak → 0` exactly once per trigger, driven by
     `service.flashActive` (fade-in → hold → fade-out durations from
     `NotchConstants`).

4. **`CompletionToastView`** — `NemoNotch/Notch/`, new SwiftUI view.
   - Black capsule matching `HUDOverlayView` (`background(.black)`,
     `Capsule()`, `NotchTheme.stroke` border, shadow). Content: a small SF
     Symbol (e.g. `checkmark.circle.fill`) in accent + the project name(s).
     Multiple names render as a compact joined/stacked list.
   - Mounted in `NotchView` adjacent to the existing HUD overlay, only on
     `isHUDScreen`, positioned the same way (near `notchCenterX`), driven by
     `CompletionFlashService`.

### Data flow

```
AISessionStore / AgentMonitorRegistry mutate (existing)
        │  (Observation)
        ▼
CompletionFlashService  ── detects idle edge, applies throttle/merge ──┐
        │                                                              │
        ├─ flashActive ──────────────► CompletionFlashView (per-screen window)
        └─ toastNames / toastVisible ─► CompletionToastView (NotchView, HUD screen)
```

### Wiring

- `AppDelegate.applicationDidFinishLaunching` (`NemoNotchApp.swift`): construct
  `CompletionFlashService(store:registry:settings:)`, retain it, and inject via
  `.environment` into `NotchView` (alongside `hud`, `registry`, etc.).
- Create/own the per-screen `CompletionFlashWindow`s alongside the notch window
  slots (same lifecycle and screen-change rebuild).
- `NotchView`: add the `CompletionToastView` overlay next to the HUD overlay.

## Tunables (`NotchConstants`)

| Constant | Purpose | Default |
|---|---|---|
| `completionFlashThrottle` | cooldown/merge window | ~2.0s |
| `completionFlashFadeIn` | glow fade-in | ~0.18s |
| `completionFlashHold` | glow hold at peak | ~0.12s |
| `completionFlashFadeOut` | glow fade-out | ~0.5s |
| `completionGlowWidth` | edge glow band width | tune live |
| `completionGlowBlur` | edge glow blur radius | tune live |
| `completionGlowOpacity` | edge glow peak opacity | tune live |

Toast lifetime reuses `hudDismissDelay` / `hudDismissDuration`.

## Settings

- New `AppSettings.completionFlashEnabled: Bool` (UserDefaults, default `true`).
- Surface a toggle in the existing Settings UI (general/notifications area).

## Testing

Swift Testing (`NemoNotchTests/`), pure logic only:

- **Edge detection:** feed sequences of phase snapshots → assert a completion is
  detected only on active→idle transitions (not idle→idle, not working→working,
  not idle→working).
- **Throttle/merge:** simulate N completions within the throttle window → assert
  the flash fires exactly once and `toastNames` accumulates all distinct names;
  a completion after the window re-arms the flash.

Window creation, animation, and rendering are not unit-tested (project
convention — they need real screens/AppKit).

## Documentation updates (same PR)

- `README.md` / `README_CN.md` — feature description.
- `CLAUDE.md` — architecture (new service + windows), and note the feature in
  the relevant sections.
- `docs/macos-cookbook.md` — new technique entry: full-screen transparent
  non-interactive overlay window (per-screen) for an ambient glow effect.
