# NemoNotch — Logo & Menubar Icon Redesign

**Date**: 2026-05-16
**Status**: Approved — ready for implementation
**Scope**: app icon (Dock / Finder / About) + menubar icon
**Replaces**: state-driven 5-symbol menubar icon + empty `AppIcon.appiconset`

## Motivation

The menubar icon currently cycles through 5 SF Symbols based on app state
(waiting approval / agent active / AI working / media playing / idle). With
the notch panel surfacing the same information directly above the menubar,
the menubar variation is redundant — it adds visual noise without adding
information.

`Assets.xcassets/AppIcon.appiconset/` lists 10 image slots but ships no
actual PNGs, so the app has no real Dock / Finder icon.

This work delivers one coherent identity for both surfaces.

## Visual Concept

**Pixel-art notch geometric abstract.** A pixel-quantized rendering of a
MacBook notch hanging from a screen's top edge. Inherits the pixel-art
vocabulary already used by `Helpers/ClaudeCrabIcon.swift` (Canvas + coarse
grid), plus the self-referential meaning of drawing the notch the app
inhabits.

## Geometry

12 × 12 viewBox. Three solid horizontal bars:

| Row | Content | Cols (inclusive) | Width |
|---|---|---|---|
| 4 | Display top edge | 0–11 | 12 |
| 5 | Notch body | 2–9 | 8 |
| 6 | Chamfer | 3–8 | 6 |

Rows 0–3 and 7–11 are empty padding. The visual weight sits in the upper
half so the notch reads as hanging from the top of the screen, matching
where a real MacBook notch lives.

No camera dot. Pure stepped geometry.

```
. . . . . . . . . . . .   row 0–3 padding
■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■ ■   row 4   display top edge
. . ■ ■ ■ ■ ■ ■ ■ ■ . .   row 5   notch body (8 wide)
. . . ■ ■ ■ ■ ■ ■ . . .   row 6   chamfer (6 wide)
. . . . . . . . . . . .   row 7–11 padding
```

## Color

| Element | Value |
|---|---|
| App icon background — top stop | `#F5F2EC` |
| App icon background — bottom stop | `#E8E3D8` |
| App icon background gradient direction | 135° (top-left → bottom-right) |
| Foreground shape | `#1A1A1A` (softer than pure black at small sizes) |
| Menubar template | alpha-only mask; system tints automatically per appearance |

## Production approach

A single canonical SwiftUI view definition (12 × 12 grid + colors) is
referenced by two render paths:

- **App icon** — pre-rendered to 10 PNG files at AppIcon sizes via a
  stand-alone Swift script using `ImageRenderer`. Committed under
  `Assets.xcassets/AppIcon.appiconset/`.
- **Menubar** — rendered live by SwiftUI inside `MenuBarLabel`. Not a PNG
  asset. `.foregroundStyle(.primary)` lets the system handle dark/light
  tinting. The frame is fixed to ~16 pt to match the menubar slot height.

Single source of truth: both paths draw the same 3 rectangles on the same
12 × 12 grid. Only the colors differ.

## File outputs

### Created

```
scripts/generate-app-icon.swift                                  # CLI tool
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_16x16.png      # 16×16
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png   # 32×32
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_32x32.png      # 32×32
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png   # 64×64
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_128x128.png    # 128×128
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png # 256×256
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_256x256.png    # 256×256
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png # 512×512
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_512x512.png    # 512×512
NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png # 1024×1024
```

### Modified

```
NemoNotch/Notch/MenuBar/MenuBarLabel.swift                  # drop state logic, draw shape
NemoNotch/Assets.xcassets/AppIcon.appiconset/Contents.json  # add "filename" per entry
README.md                                                    # update Menu Bar Entry description
README_CN.md                                                 # ditto
CLAUDE.md                                                    # update Architecture / menubar notes
```

## `MenuBarLabel` rewrite

**Before** (`MenuBarLabel.swift`):

- Depends on `AICLIMonitorService`, `AgentMonitorRegistry`, `MediaService`
  via `@Environment`.
- `private var symbol: String` returns one of 5 SF Symbol names by priority:
  `exclamationmark.bubble.fill` → `ant.fill` → `sparkle` → `play.circle.fill`
  → `menubar.rectangle`.
- Body: `Image(systemName: symbol)`.

**After**:

- No `@Environment` declarations.
- Body draws three `Rectangle`s on a 12-unit grid using a `Canvas` (or three
  positioned `Rectangle`s in a `ZStack`).
- `.foregroundStyle(.primary)` so the system tints it per appearance.
- Frame chosen so each 12-grid cell lands on whole points (avoids
  subpixel blur). Implementation plan decides the exact value within the
  menubar slot height.

The five service dependencies disappear from this file. The services
themselves are untouched.

## Script: `scripts/generate-app-icon.swift`

A stand-alone Swift script. Shebang `#!/usr/bin/env swift`. No
`Package.swift`, no Xcode target.

Behavior:

- Defines the grid (rows + col ranges) and the colors as constants — the
  same definition that `MenuBarLabel` will use, copy-pasted (both files are
  ~10 lines of constants; abstracting through a shared module would buy
  nothing and complicate the script).
- Iterates over the 10 target sizes.
- For each: builds a SwiftUI view (gradient background + three rectangles
  on the 12-unit grid) and renders to PNG via `ImageRenderer`.
- Writes each PNG to `<repo>/NemoNotch/Assets.xcassets/AppIcon.appiconset/`
  with the appropriate filename.
- Resolves the output directory relative to the script's own file path so
  it works from any cwd.
- No CLI flags. Re-run when the shape or colors change.

Expected output:

```
$ scripts/generate-app-icon.swift
Wrote 10 PNGs to NemoNotch/Assets.xcassets/AppIcon.appiconset/
```

## `AppIcon.appiconset/Contents.json`

The current file lists 10 image entries by size+scale only, without a
`filename` key. Xcode will not bind the rendered PNGs unless each entry
has a matching `filename`. The script writes filenames matching the
convention above (`icon_<W>x<H>@<S>x.png`).

## Doc updates

`README.md` — current text:

> Menu Bar Entry — State-driven icon (AI approval / agent active / AI
> working / media playing / idle); ...

Updated text:

> Menu Bar Entry — Fixed notch-shape icon. State is visible directly on the
> notch panel above the menubar; the menu shows Now Playing controls when
> media is active, plus an Open Notch submenu listing each enabled tab.

`README_CN.md` mirrors the change.

`CLAUDE.md` — under the menubar bullet in the Highlights or Architecture
description, drop the "state-driven icon" line, note the static shape, and
keep the "menu shows controls" part.

## Out of scope

- Dark-mode-specific AppIcon variant (macOS Sonoma+ tinted icons).
- Animated icon.
- Notification-badge overlays.
- DMG installer background art.

## Open questions

None — geometry, color, and production approach all confirmed during
brainstorming (see `.superpowers/brainstorm/.../content/*.html` for the
mockup history).
