---
summary: 'Review checklist for keeping NemoNotch UI consistent with the Warm Noir Utility style.'
read_when:
  - 'reviewing a UI pull request'
  - 'checking an AI-generated UI change'
  - 'deciding whether a new component matches NemoNotch style'
---

# UI Review Checklist

Use this checklist after any NemoNotch UI change.

## Style Fit

- The UI feels like a macOS Notch HUD, not a web page or product landing page.
- The main surface is black or near-black.
- Orange is used only for state, progress, attention, or primary action.
- Non-orange colors are limited to external identity or system semantics.
- The design avoids decorative gradients, glass cards, orbs, bokeh, and oversized hero typography.

## Layout

- The component fits the relevant Notch size, especially the default opened panel around `560x328`.
- Edges align with nearby rows, headers, and tab content.
- Dynamic values have stable slots and do not shift layout.
- Long text uses `lineLimit`, truncation, or `minimumScaleFactor` where appropriate.
- Dense information remains scannable.

## Components

- Headers follow the source tile + title/summary + trailing metrics/action pattern.
- Rows follow the source mark + title/badges + spacer + time/value pattern.
- Badges are compact capsules with small rounded typography.
- Progress bars use dark rails and warm/source-colored capsule fills.
- Primary actions use `NotchPillButtonStyle(prominent: true)` or restrained orange text.
- Empty states are short, centered, and operational.

## Implementation

- Uses `NotchTheme` instead of ad hoc colors.
- Uses `NotchConstants` for existing geometry, animation, HUD, and Notch dimensions.
- Reuses `notchCard`, `NotchPillButtonStyle`, pulse/glow modifiers, and scroll edge shadows when applicable.
- New visual helpers are promoted only when a pattern repeats.
- User-facing strings are localized.
- Icon-only controls have accessible labels where needed.

## Motion

- Open/close/tab transitions use existing spring timing.
- Hover and pressed states do not change layout.
- Continuous animation is limited to active state indicators.
- New motion respects reduced-motion expectations.

## Reject Or Revise

Revise the UI if it includes:

- Purple-blue AI gradient as the main visual identity.
- A marketing hero or explanatory product card inside the app surface.
- Multiple unrelated accent colors competing for attention.
- Nested cards that make the Notch shell stop feeling like the main object.
- Large orange backgrounds.
- Emoji as core navigation or action icons.
- Text that overlaps, clips unexpectedly, or pushes controls out of place.

