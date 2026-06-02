# Notch AI/Agent Activity Glow — Design

**Date:** 2026-06-02
**Status:** Approved (proceeding to implementation)

## Goal

When the notch is **expanded** and there is AI/agent activity, render a soft
blurred glow along the panel's **lower inner edge** — brightest at the bottom,
covering the lower ~80% of the height and fading to nothing near the top,
leaving the center / content clean. Both
active states (running, approval) render in the app's theme accent (orange).
Purely visual; never affects layout or hit-testing.

## Behavior

Glow is visible **only when the notch is opened** (`status != .closed`) and the
active-badge set indicates activity:

| Condition (evaluated on `activeBadgeItems`)                          | Glow        |
|----------------------------------------------------------------------|-------------|
| Any AI session waiting for approval                                  | `.attention` |
| Else: any AI session `.working`, **or** any active agent             | `.running`   |
| Else (media-only / calendar-only / nothing)                          | `.none`     |

Approval wins over working when both are present. A lone approval still glows.
Both active states render in the same theme orange (`NotchTheme.accent`); the
enum split is retained for future re-differentiation. Media / calendar /
notification / pomodoro badges do **not** trigger the glow.

## Architecture

The expanded body is `NotchBackgroundView`, whose fill/highlight layers are
composited in a `ZStack { … }.mask(notchBackgroundMaskGroup)`. The glow is one
more layer **inside that masked ZStack**: stroke the notch's rounded shape,
blur the stroke, and let the existing `.mask` clip the *outward* half of the
blur — what remains is a soft glow hugging the inner edge only. No separate
mask to maintain.

```
UnevenRoundedRectangle(bottomLeadingRadius:, bottomTrailingRadius:)
    .stroke(color, lineWidth: glowRingWidth)
    .blur(radius: glowRingBlur)
    .mask(LinearGradient(.clear @ 1-glowRingCoverage → .black @ 1.0, top → bottom))  // lower ~80% only
    .blendMode(.screen)   // lightens over the near-black panel (same trick as the existing highlight layer)
```

It renders at `zIndex 0` (background), behind the tab content, so the glow sits
at the panel's lower inner border and never overlaps the centered content.

### Data flow

- `enum NotchGlow { case none, running, attention }`.
- `BadgeItem.glow(for items: [BadgeItem]) -> NotchGlow` — **pure** decision
  function (unit-testable, no services needed).
- `BadgeViewModel.glowState` = `BadgeItem.glow(for: activeBadgeItems)` — reuses
  the already provider-enabled-filtered `activeBadgeItems`; no duplicated logic.
- `NotchView.notchShape` passes `badgeViewModel?.glowState ?? .none` into
  `NotchBackgroundView`.
- `NotchBackgroundView` draws the glow only when `status != .closed`, resolving
  both `.running` and `.attention` to `NotchTheme.accent` (theme orange). On
  collapsed / non-active screens it draws nothing.

### Animation

Fade in/out transitions via `.animation(.easeInOut, value: glow)` alongside the
existing `value: effectiveStatus` animation in `NotchView`. No continuous
breathing pulse (matches the static mockup; can be added later).

## New tokens / constants

- (No new color token — uses the existing `NotchTheme.accent`.)
- `NotchConstants.glowRingOpacity` / `glowRingWidth` / `glowRingBlur` /
  `glowRingCoverage` — ring stroke opacity, stroke width, blur radius, and the
  fraction of the panel height (from the bottom) the glow covers, for tuning.

## Testing

Swift Testing file exercising `BadgeItem.glow(for:)`:
approval→`.attention`, working→`.running`, agents→`.running`,
working+approval→`.attention`, media-only→`.none`, empty→`.none`.

## Files touched

`NotchBackgroundView.swift`, `BadgeItem.swift`, `BadgeViewModel.swift`,
`NotchView.swift`, `ViewModifiers.swift` (theme token), `Constants.swift`,
new `NemoNotchTests/BadgeGlowTests.swift`, plus `README.md` / `README_CN.md` /
`CLAUDE.md` per project convention.
```
