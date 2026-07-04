# Single-Row Stacked Collapsed Badges — Design

**Date:** 2026-07-04
**Status:** Approved (pending spec review)
**Area:** Notch collapsed-state badge display

## Problem

When the notch is collapsed and multiple things are active, NemoNotch renders **two rows**:

1. The highest-priority badge splits across the physical notch — its logo on the left edge (`.compactLeft`), its status on the right edge (`.compactRight`) via `CompactBadgesView`.
2. **Every other** active badge renders as a horizontal `HStack` **below** the notch via `BadgeRowView`, which forces the collapsed notch to grow taller (`NotchView.notchSize` adds `badgeRowHeight` when `multiBadges && hasBadge`, `NotchView.swift:70`).

That second row obstructs the user's sight line and interaction. The goal is to collapse everything onto the single notch-flanking row.

## Goals

- Remove the second row (`BadgeRowView`) and the vertical growth it forces. Collapsed notch stays at hardware height.
- Represent multiple active items on the flanking row using **grouped, stacked logos** (left) + **corresponding statuses with count chips** (right).
- Preserve the single-item look exactly when only one thing is active.

## Non-Goals (YAGNI)

- No change to *what* becomes a badge — `BadgeViewModel.activeBadgeItems` logic is untouched.
- No changes to the expanded panel.
- No new user-facing settings toggle.

## Decisions (resolved during brainstorming)

1. **Grouping dimension:** by **icon identity**.
2. **Left↔right correspondence:** **mirror** — highest-priority group hugs the notch on both wings, fanning outward by descending priority.
3. **Overflow:** **cap N groups + "+K" chip**.
4. **Tap behavior:** open the highest-priority group's tab (unchanged from today's primary-item behavior).

## Design

### Data model — `BadgeGroup` (pure, testable)

New pure function transforms the already-priority-sorted `activeBadgeItems` into groups:

```
BadgeGrouping.group(_ items: [BadgeItem]) -> [BadgeGroup]

struct BadgeGroup: Identifiable, Equatable {
    let representative: BadgeItem   // the group's highest-priority member
    let count: Int                  // total members in the group
    // id derived from the group key; priority derived from representative
}
```

**Grouping key = icon identity:**

| Badge case | Group key |
|---|---|
| `.ai` | `source` (all Claude sessions → 1 group; `count` = number of sessions) |
| `.agents` | icon identity = `emoji` (empty emoji → shared Hermes icon → one group) |
| `.notification` | the case (in practice already a single item — top-count app) |
| `.media` | the case |
| `.pomodoro` | the case |
| `.calendar` | the case |

**Rules:**

- **Representative** = the group's highest-priority member (approval > working > idle, using the existing `BadgeItem.priority` comparator). Example: a Claude group with 1 waiting-approval + 2 working renders the ⚠️ approval status with `count = 3`.
- **Count aggregates the whole group** even when members have mixed states. The left logo says *which app*, the count says *how many*, the right status shows *the most urgent state*. (Alternative — count only same-status members — was considered and rejected as more complex for little gain.)
- Output groups remain ordered by priority (min priority of members = representative's priority).

This function is the home of the four user-described cases; each is a unit test.

### Layout (mirror)

```
   low -> high                          high -> low
[+K][L3 L2 L1] ==  physical notch  == [S1 S2 S3]
     (overlap)                          (HStack)
```

- **Left cluster** — one logo per group (each rendered via the group representative's existing `.compactLeft` style), overlapping/fanned, anchored at `notchLeftEdge`, extending leftward. Highest-priority group is **frontmost and closest to the notch** (rightmost of the left cluster).
- **Right cluster** — `HStack` of corresponding statuses (each via the representative's existing `.compactRight` style), anchored at `notchRightEdge`, extending rightward, highest-priority **closest to the notch** (leftmost of the right cluster). Thus `L1 <-> S1` both hug the notch.
- **Count chip** — when a group's `count > 1`, a small pill (styled like the existing notification count chip) overlays that group's **right-side status**.
- **One group, count 1** — pixel-identical to today's single-item look (one logo left, one status right).
- The existing `badgeSpread` open/close spread animation and the `badgeEmptyGrace` empty-collapse debounce are preserved.

### Overflow

Tunable `badgeGroupCap` (proposed **4**). If group count exceeds the cap: render the first `cap - 1` groups normally, plus a `+K` chip as the last (backmost, leftmost) slot of the **left** stack, where `K = (total groups) - (cap - 1)`. The right cluster shows only those first `cap - 1` statuses. This bounds the row width so it never obstructs the sight line.

### Interaction

Tapping anywhere in either cluster calls `handleBadgeTap(<highest-priority group representative>)` — identical to today: expands the notch and jumps to that representative's tab. A `.notification` representative still opens its app. No per-icon hit targets.

## Files touched

- **`NemoNotch/Notch/Badge/BadgeGrouping.swift`** (new) — pure `BadgeGrouping.group` + `BadgeGroup` type.
- **`NemoNotch/Notch/Badge/BadgeViewModel.swift`** — add `displayedGroups: [BadgeGroup]` computed from `displayedBadgeItems`; remove `hasMultipleBadges`.
- **`NemoNotch/Notch/Badge/BadgeIconView.swift`** — rewrite `CompactBadgesView` to render the two clusters from `displayedGroups`; **delete `BadgeRowView`** and the now-dead `.row` render style plus its per-badge branches.
- **`NemoNotch/Notch/NotchView.swift`** — remove the `BadgeRowView` block and the `extraHeight` / `multiBadges` vertical-growth branch in `notchSize` (collapsed height = hardware height).
- **`NemoNotch/Helpers/Constants.swift`** — add `badgeGroupCap`, `badgeStackOverlap`, `badgeStatusSpacing`; remove now-unused `badgeRowHeight`, `badgeRowSpacing`.
- **`NemoNotchTests/BadgeGroupingTests.swift`** (new) — Swift Testing coverage: single item; multiple same (count on right); multiple different (stacked logos + per-group statuses); mixed with duplicates; overflow cap + "+K"; priority ordering; representative selection.
- **Docs** — update `CLAUDE.md` (Badge Priority + Empty-collapse debounce sections), `README.md`, `README_CN.md` per project convention.

## Verification

- Unit tests for `BadgeGrouping.group` pass (the four cases + overflow + ordering).
- Manual: collapsed notch no longer grows a second row; single-item look unchanged; multiple same-app shows one logo + count; multiple different apps show stacked logos + mirrored statuses; overflow shows `+K`.
