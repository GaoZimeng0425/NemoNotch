# Logo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5-state SF Symbol menubar icon with a fixed pixel-art notch shape, and populate `AppIcon.appiconset/` with a coherent PNG icon at all 10 macOS AppIcon sizes.

**Architecture:** A single canonical 12 × 12 pixel-grid geometry feeds two surfaces. A stand-alone Swift script (`scripts/generate-app-icon.swift`) renders the gradient + shape to PNGs via SwiftUI `ImageRenderer` for the AppIcon. A SwiftUI `Canvas` inside `MenuBarLabel` draws the same 3 rectangles live for the menubar, with `.foregroundStyle(.primary)` so the system tints it per appearance.

**Tech Stack:** Swift 6, SwiftUI (Canvas, ImageRenderer, LinearGradient), AppKit (NSBitmapImageRep for PNG encoding), Xcode `.xcassets`.

**Spec:** [`docs/plans/2026-05-16-logo-design.md`](./2026-05-16-logo-design.md) (approved 2026-05-16).

---

## Task 1: Update `AppIcon.appiconset/Contents.json` with `filename` fields

Xcode binds AppIcon PNGs to slots by the `filename` key in each `images` entry. The current file lists all 10 size/scale combos but with no filenames, so the generated PNGs would be ignored.

**Files:**
- Modify: `NemoNotch/Assets.xcassets/AppIcon.appiconset/Contents.json`

- [ ] **Step 1: Rewrite Contents.json**

Replace the entire file with:

```json
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 2: Verify JSON syntax**

Run: `python3 -m json.tool < NemoNotch/Assets.xcassets/AppIcon.appiconset/Contents.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Assets.xcassets/AppIcon.appiconset/Contents.json
git commit -m "build(icon): wire AppIcon Contents.json to filenames"
```

---

## Task 2: Write `scripts/generate-app-icon.swift`

A standalone Swift script that defines the canonical 12 × 12 geometry + colors, then uses SwiftUI `ImageRenderer` to write the AppIcon PNGs.

**Files:**
- Create: `scripts/generate-app-icon.swift`

- [ ] **Step 1: Confirm scripts/ directory exists**

Run: `ls -ld scripts 2>/dev/null || mkdir scripts`
Expected: either lists the dir or creates it silently.

- [ ] **Step 2: Write the script**

Create `scripts/generate-app-icon.swift` with this content:

```swift
#!/usr/bin/env swift

import SwiftUI
import AppKit

// MARK: - Canonical geometry

/// 12 × 12 pixel grid. Mirrored in NemoNotch/Notch/MenuBar/MenuBarLabel.swift
/// (the menubar surface) — keep them in sync if either changes.
private let gridSize: CGFloat = 12

private struct GridBar {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
}

private let bars: [GridBar] = [
    GridBar(x: 0, y: 4, width: 12),  // display top edge
    GridBar(x: 2, y: 5, width: 8),   // notch body
    GridBar(x: 3, y: 6, width: 6),   // chamfer
]

// MARK: - Colors

private let backgroundTop    = Color(red: 245.0 / 255, green: 242.0 / 255, blue: 236.0 / 255)
private let backgroundBottom = Color(red: 232.0 / 255, green: 227.0 / 255, blue: 216.0 / 255)
private let foreground       = Color(red:  26.0 / 255, green:  26.0 / 255, blue:  26.0 / 255)

// MARK: - View

private struct AppIconView: View {
    let side: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [backgroundTop, backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Canvas { context, canvasSize in
                let cell = canvasSize.width / gridSize
                for bar in bars {
                    let rect = CGRect(
                        x: bar.x * cell,
                        y: bar.y * cell,
                        width: bar.width * cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(foreground))
                }
            }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Render targets

private let targets: [(filename: String, pixels: CGFloat)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - Output path

// #filePath resolves to this script's source file at compile time, even when
// invoked via shebang from anywhere.
let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputDir = repoRoot
    .appendingPathComponent("NemoNotch")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: outputDir.path) else {
    FileHandle.standardError.write(
        Data("error: output dir not found: \(outputDir.path)\n".utf8)
    )
    exit(1)
}

// MARK: - Render & write

for (filename, pixels) in targets {
    let renderer = ImageRenderer(content: AppIconView(side: pixels))
    renderer.scale = 1   // view side already equals output pixel count

    guard
        let nsImage = renderer.nsImage,
        let tiff = nsImage.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(
            Data("error: render failed for \(filename)\n".utf8)
        )
        exit(1)
    }

    let outURL = outputDir.appendingPathComponent(filename)
    do {
        try png.write(to: outURL)
    } catch {
        FileHandle.standardError.write(
            Data("error: write failed for \(filename): \(error)\n".utf8)
        )
        exit(1)
    }
}

print("Wrote \(targets.count) PNGs to NemoNotch/Assets.xcassets/AppIcon.appiconset/")
```

- [ ] **Step 3: Make script executable**

Run: `chmod +x scripts/generate-app-icon.swift`
Expected: no output (success).

- [ ] **Step 4: Commit the script (no PNGs yet)**

```bash
git add scripts/generate-app-icon.swift
git commit -m "build(icon): add AppIcon generator script"
```

---

## Task 3: Run the script, smoke-verify outputs, commit PNGs

**Files:**
- Create (script-generated): `NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_*.png` (10 files)

- [ ] **Step 1: Run the generator**

Run: `scripts/generate-app-icon.swift`
Expected stdout: `Wrote 10 PNGs to NemoNotch/Assets.xcassets/AppIcon.appiconset/`
Expected exit code: 0

If the script fails with a Swift compile error, fix the script and re-run before continuing. Common issue: macOS version too old for `ImageRenderer` (requires macOS 13+) — verify with `sw_vers`.

- [ ] **Step 2: Verify all 10 PNGs exist**

Run:
```bash
ls NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_*.png | wc -l
```
Expected: `10`

- [ ] **Step 3: Verify each PNG has the correct pixel dimensions**

Run:
```bash
for entry in \
  "icon_16x16.png:16" "icon_16x16@2x.png:32" \
  "icon_32x32.png:32" "icon_32x32@2x.png:64" \
  "icon_128x128.png:128" "icon_128x128@2x.png:256" \
  "icon_256x256.png:256" "icon_256x256@2x.png:512" \
  "icon_512x512.png:512" "icon_512x512@2x.png:1024"; do
  name="${entry%%:*}"; expected="${entry##*:}"
  actual=$(sips -g pixelWidth -g pixelHeight \
    "NemoNotch/Assets.xcassets/AppIcon.appiconset/$name" \
    | awk '/pixelWidth|pixelHeight/{print $2}' | sort -u)
  if [ "$actual" = "$expected" ]; then
    echo "OK  $name  ${expected}x${expected}"
  else
    echo "FAIL $name expected ${expected}x${expected}, got $actual"; exit 1
  fi
done
```
Expected: 10 lines starting with `OK`.

- [ ] **Step 4: Visually preview one icon**

Run: `open NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_512x512.png`
Expected: Preview opens the icon. Visual check — cream gradient background with three black horizontal bars (top one full-width, then 8-wide, then 6-wide, stepping inward). No camera dot.

- [ ] **Step 5: Commit the PNGs**

```bash
git add NemoNotch/Assets.xcassets/AppIcon.appiconset/icon_*.png
git commit -m "feat(icon): generate AppIcon PNG set"
```

---

## Task 4: Rewrite `MenuBarLabel.swift` to draw the fixed shape

Drop the 5-state SF Symbol switch and the three environment dependencies. Draw the same 12-grid notch shape with a SwiftUI `Canvas`, using `.foregroundStyle(.primary)` so the system handles light/dark mode tinting.

**Files:**
- Modify (full rewrite): `NemoNotch/Notch/MenuBar/MenuBarLabel.swift`

- [ ] **Step 1: Replace the file's contents**

Overwrite `NemoNotch/Notch/MenuBar/MenuBarLabel.swift` with:

```swift
import SwiftUI

/// Fixed pixel-art notch shape rendered live for the menubar. Geometry mirrors
/// scripts/generate-app-icon.swift — same 12 × 12 grid, three horizontal bars.
/// State information lives on the notch panel above the menubar, not here.
struct MenuBarLabel: View {
    var body: some View {
        NotchPixelShape()
            .fill(.primary)
            .frame(width: 18, height: 18)
    }
}

/// Three horizontal bars on a 12 × 12 grid. Rendered as a Shape (not a
/// Canvas) so the fill style participates in `.foregroundStyle` /
/// `.fill(.primary)` and adapts to the menubar's effective appearance.
private struct NotchPixelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cell = rect.width / 12
        var path = Path()
        // display top edge (cols 0–11)
        path.addRect(CGRect(x: 0,        y: 4 * cell, width: 12 * cell, height: cell))
        // notch body (cols 2–9)
        path.addRect(CGRect(x: 2 * cell, y: 5 * cell, width:  8 * cell, height: cell))
        // chamfer (cols 3–8)
        path.addRect(CGRect(x: 3 * cell, y: 6 * cell, width:  6 * cell, height: cell))
        return path
    }
}
```

Notes for the engineer:
- The previous file imported nothing besides SwiftUI and had three `@Environment` lines for `AICLIMonitorService`, `AgentMonitorRegistry`, `MediaService`. All three are removed.
- The only caller is `NemoNotchApp.swift:18` which writes `MenuBarLabel()` — no parameters changed, so that call site is untouched.
- `.fill(.primary)` on a `Shape` resolves through SwiftUI's color hierarchy,
  so the icon tints correctly across light/dark menubar appearances.
  Don't switch back to a `Canvas` with `.color(.primary)` — Canvas drawing
  uses a snapshot of the color and won't re-render on appearance change.

- [ ] **Step 2: Confirm no stale references remain**

Run: `grep -n "symbol\|@Environment" NemoNotch/Notch/MenuBar/MenuBarLabel.swift`
Expected: no output.

- [ ] **Step 3: Confirm caller still compiles cleanly (lexical check)**

Run: `grep -n "MenuBarLabel" NemoNotch/NemoNotchApp.swift`
Expected: one match — `MenuBarLabel()`.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/MenuBar/MenuBarLabel.swift
git commit -m "feat(menubar): replace state-driven icon with fixed notch shape"
```

---

## Task 5: Build, launch, visually verify both surfaces

This is the verification step. There is no automated visual test for menubar icons or AppIcon — we build the app, launch it, and look.

**Files:** none.

- [ ] **Step 1: Build the app**

Run in repo root:
```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug build 2>&1 | tail -20
```
Expected last line: `** BUILD SUCCEEDED **`. If it fails, read the diagnostic above the failure and fix.

- [ ] **Step 2: Launch the built app**

Find the build product:
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "NemoNotch.app" -path "*Debug*" 2>/dev/null | head -1)
echo "$APP"
```

Quit any existing NemoNotch instance, then launch:
```bash
pkill -x NemoNotch 2>/dev/null; sleep 1
open "$APP"
```
Expected: NemoNotch starts; a menubar icon appears in the top-right area.

- [ ] **Step 3: Visually verify menubar icon**

Look at the menubar. Expected:
- One static three-bar pixel notch shape (top bar full-width, middle 8-wide, bottom 6-wide).
- Color matches other menubar text (white on dark menubar / black on light).
- Shape stays the same when AI sessions start, media plays, etc. (no state-driven switching).

If the icon is invisible, blurry beyond recognition, or visibly clipped — note the symptom in the commit message body of Task 7 and consider revisiting the 18 pt frame size in MenuBarLabel.

- [ ] **Step 4: Visually verify Dock icon**

Right-click the app in the Dock or check the About window (`NemoNotch` menu → About). Expected:
- Cream gradient background.
- Three black horizontal bars on the upper half (display edge / body / chamfer).
- No image-missing placeholder.

- [ ] **Step 5: Quit the app**

```bash
pkill -x NemoNotch 2>/dev/null
```

No commit in this task — verification only.

---

## Task 6: Update docs

Three doc files mention the old state-driven menubar icon. Update them to describe the new fixed shape.

**Files:**
- Modify: `README.md`
- Modify: `README_CN.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `README.md`**

Find the line in README.md (under "Highlights"):

```
- **Menu Bar Entry** — State-driven icon (AI approval / agent active / AI working / media playing / idle); menu shows Now Playing controls (previous / play-pause / next) when media is active, plus an Open Notch submenu listing each enabled tab with its current hotkey hint
```

Replace with:

```
- **Menu Bar Entry** — Fixed pixel-art notch icon (state is visible on the notch panel above the menubar); menu shows Now Playing controls (previous / play-pause / next) when media is active, plus an Open Notch submenu listing each enabled tab with its current hotkey hint
```

- [ ] **Step 2: Update `README_CN.md`**

Find the matching bullet under "亮点" (or equivalent section). Replace any "状态驱动图标 / state-driven icon" wording with "固定刘海图标（状态从刘海面板查看）".

If the exact line is not present, search:
```bash
grep -n "State-driven\|状态驱动\|state-driven" README_CN.md
```
And revise the surrounding bullet to mirror the English change above.

- [ ] **Step 3: Update `CLAUDE.md`**

Find any mention of the menubar icon. Likely in the architecture overview or feature list. Search:
```bash
grep -n "menubar\|state-driven\|MenuBarLabel" CLAUDE.md
```

Where the doc says the menubar icon is state-driven, change it to say the menubar shows a fixed notch shape and that state is reflected on the notch panel itself. Keep the unrelated parts of the surrounding sentence (menu items, hotkeys, etc.) intact.

- [ ] **Step 4: Verify no stale "state-driven icon" references remain**

Run: `grep -rn "state-driven\|State-driven" README.md README_CN.md CLAUDE.md`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add README.md README_CN.md CLAUDE.md
git commit -m "docs: reflect fixed menubar icon and new AppIcon"
```

---

## Task 7: Wrap-up sanity check

**Files:** none.

- [ ] **Step 1: Confirm a clean working tree**

Run: `git status`
Expected: `nothing to commit, working tree clean`.

- [ ] **Step 2: Confirm the new commits are in place**

Run: `git log --oneline -8`
Expected to see (newest first), in some order:
- `docs: reflect fixed menubar icon and new AppIcon`
- `feat(menubar): replace state-driven icon with fixed notch shape`
- `feat(icon): generate AppIcon PNG set`
- `build(icon): add AppIcon generator script`
- `build(icon): wire AppIcon Contents.json to filenames`

- [ ] **Step 3: Final smoke build**

Run:
```bash
xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug build 2>&1 | tail -5
```
Expected last line: `** BUILD SUCCEEDED **`.

Implementation done. Spec at `docs/plans/2026-05-16-logo-design.md` is now fulfilled and can be archived per project convention.
