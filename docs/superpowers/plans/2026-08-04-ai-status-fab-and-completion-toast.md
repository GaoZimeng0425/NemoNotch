# AI Status FAB + Completion Toast Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a draggable floating capsule that shows running AI sessions and expands into a list+detail panel; and enrich the completion toast to show the task title, last tool, source, model, and token/duration instead of just the project folder.

**Architecture:** Two independent features sharing one data source (`AISessionStore`). The FAB reuses the proven `NSPanel` floating-window pattern from `QuickStartWindow`. The completion-toast enhancement widens the value-type `CompletionItem`/`CompletionCandidate` models (pure, testable) so richer data flows through the existing flash pipeline with no new windows or mechanisms.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPanel`/`NSWindowController`), `@Observable` macro, swift-testing (`@Suite`/`@Test`/`#expect`), macOS 14+.

## Global Constraints

- New `.swift` files dropped into `NemoNotch/` are **auto-included** via `PBXFileSystemSynchronizedRootGroup` — never edit `project.pbxproj`.
- Tests use **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`) with `@testable import NemoNotch`. Value-type suites need no `@MainActor`; service suites annotate `@MainActor` on the suite.
- Localization is a single `NemoNotch/Resources/Localizable.xcstrings` (JSON). New keys ship both `en` and `zh-Hans`.
- Theme/visual constants live in `enum NotchConstants` (`Helpers/Constants.swift`) as `static let`; colors in `enum NotchTheme` (`Helpers/ViewModifiers.swift:3`).
- `AISessionState` (`Models/AIProvider.swift:20`) already exposes all derived fields used here: `displayTitle`, `currentTool`, `displayModel`, `tokenDisplay`, `contextPercent`, `contextTokenDisplay`, `contextLimitDisplay`, `projectFolder`, `status`, `sessionStart`, `lastEventTime`. **No new data collection.**
- The `MainThreadProbe.swift` work-in-progress on this branch is unrelated; do not touch it.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| **Modify** `Services/CompletionDetector.swift` | Widen `CompletionItem`/`CompletionCandidate` with optional rich fields; `step()`/`merge()` carry them through | 1 |
| **Modify** `NemoNotchTests/CompletionDetectorTests.swift` | Add tests for field pass-through & merge field-overwrite | 1 |
| **Modify** `Services/CompletionFlashService.swift` | `currentCandidates()` populates new fields from `AISessionState` | 2 |
| **Modify** `Notch/CompletionToastView.swift` | Single-item two-line layout; multi-item unchanged | 3 |
| **Modify** `Models/AppSettings.swift` | `aiStatusFabEnabled` + position key | 4 |
| **Modify** `Helpers/Constants.swift` | `// AI status FAB` section | 4 |
| **Modify** `Resources/Localizable.xcstrings` | `settings.ai_status_fab.*` keys | 4 |
| **Modify** `Settings/SettingsView.swift` | Toggle for the FAB | 4 |
| **Create** `Notch/AIStatusWindow.swift` | `NSPanel` subclass mirroring `QuickStartWindow` | 5 |
| **Modify** `Notch/QuickStartWindowController.swift` | Add `EnvironmentValues.aiStatusController` `@Entry` (lives here next to its sibling) | 5 |
| **Modify** `NemoNotchApp.swift` | Construct `AIStatusWindowController`, inject environment | 6 |
| **Create** `Notch/AIStatusWindowController.swift` | Lifecycle, 3-state machine, observe+show/hide, position persistence | 6 |
| **Create** `Notch/AIStatusFABView.swift` | SwiftUI capsule (collapsed) + list/detail panel (expanded) | 7 |

---

## Task 1: Widen the completion-detector value models (TDD)

Widening happens in the pure value layer first, with new fields defaulting to `nil` so existing tests and call sites stay source-compatible.

**Files:**
- Modify: `NemoNotch/Services/CompletionDetector.swift:5-49`
- Test: `NemoNotchTests/CompletionDetectorTests.swift`

**Interfaces:**
- Consumes: nothing new (pure value types).
- Produces: `CompletionItem` and `CompletionCandidate` now have `subtitle`, `tool`, `model`, `tokenDisplay`, `duration` (all optional, default `nil`). `step()` copies candidate fields into the completed item. `CompletionFlashNames.merge` overwrites same-name fields with the newer item's non-nil fields.

- [ ] **Step 1: Add the failing tests**

Append to `CompletionDetectorTests.swift` (inside the `struct`):

```swift
// MARK: - Rich-field pass-through

private func rich(
    _ key: String,
    _ name: String,
    _ active: Bool,
    subtitle: String? = nil,
    tool: String? = nil,
    model: String? = nil,
    tokenDisplay: String? = nil,
    duration: TimeInterval? = nil
) -> CompletionCandidate {
    CompletionCandidate(
        key: key, name: name, isActive: active, source: .ai(.claude),
        subtitle: subtitle, tool: tool, model: model,
        tokenDisplay: tokenDisplay, duration: duration
    )
}

@Test("completion item carries rich fields from the candidate")
func richFieldsCarriedThrough() {
    var d = CompletionDetector()
    _ = d.step([rich("ai:1", "NemoNotch", true,
                      subtitle: "fix auth bug", tool: "Edit",
                      model: "Sonnet 4.5", tokenDisplay: "12.4k", duration: 134)])
    let result = d.step([rich("ai:1", "NemoNotch", false,
                              subtitle: "fix auth bug", tool: "Edit",
                              model: "Sonnet 4.5", tokenDisplay: "12.4k", duration: 134)])
    #expect(result.count == 1)
    let item = result[0]
    #expect(item.subtitle == "fix auth bug")
    #expect(item.tool == "Edit")
    #expect(item.model == "Sonnet 4.5")
    #expect(item.tokenDisplay == "12.4k")
    #expect(item.duration == 134)
}

@Test("rich fields default to nil when not supplied")
func richFieldsDefaultNil() {
    var d = CompletionDetector()
    _ = d.step([c("ai:1", "Proj", true)])
    let result = d.step([c("ai:1", "Proj", false)])
    #expect(result.count == 1)
    #expect(result[0].subtitle == nil)
    #expect(result[0].tool == nil)
    #expect(result[0].model == nil)
    #expect(result[0].tokenDisplay == nil)
    #expect(result[0].duration == nil)
}

@Test("merge overwrites same-name item fields with newer non-nil values")
func mergeOverwritesFields() {
    var existing = item("A")
    existing.subtitle = "old subtitle"
    var incoming = item("A")
    incoming.subtitle = "new subtitle"
    incoming.tool = "Edit"
    let merged = CompletionFlashNames.merge(existing: [existing], new: [incoming])
    #expect(merged.count == 1)
    #expect(merged[0].subtitle == "new subtitle")
    #expect(merged[0].tool == "Edit")
}

@Test("merge keeps existing field when newer is nil")
func mergeKeepsExistingOnNil() {
    var existing = item("A")
    existing.subtitle = "kept"
    var incoming = item("A")  // subtitle nil
    incoming.tool = "Edit"
    let merged = CompletionFlashNames.merge(existing: [existing], new: [incoming])
    #expect(merged[0].subtitle == "kept")
    #expect(merged[0].tool == "Edit")
}
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild test -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/CompletionDetectorTests 2>&1 | tail -30`
Expected: COMPILE ERROR — `CompletionCandidate` has no `subtitle`/`tool`/... initializer args; `CompletionItem` has no such properties. (Confirms the test targets the new API.)

- [ ] **Step 3: Widen the models**

Edit `NemoNotch/Services/CompletionDetector.swift`. Replace the `CompletionItem` and `CompletionCandidate` structs (lines 11-27) with:

```swift
/// A finished unit of work: the name shown in the toast plus its source logo,
/// and optional rich detail (task title, last tool, model, tokens, duration)
/// carried through from the AI session that completed.
struct CompletionItem: Equatable {
    let name: String
    let source: CompletionSource
    var subtitle: String?
    var tool: String?
    var model: String?
    var tokenDisplay: String?
    var duration: TimeInterval?

    /// Convenience for callers that only have name + source (Pomodoro, multi-item merges).
    init(name: String, source: CompletionSource) {
        self.name = name
        self.source = source
        self.subtitle = nil
        self.tool = nil
        self.model = nil
        self.tokenDisplay = nil
        self.duration = nil
    }
}

/// One observed unit of work (an AI session or an agent) at a point in time.
struct CompletionCandidate: Equatable {
    /// Namespaced unique id, e.g. "ai:<sessionID>" or "agent:<agentID>".
    let key: String
    /// Human-facing name shown in the toast (project folder / agent name).
    let name: String
    /// True while the unit is doing work.
    let isActive: Bool
    /// Source application/subsystem — carried through to the toast logo.
    let source: CompletionSource
    /// Optional rich detail snapshot at the moment of completion.
    var subtitle: String?
    var tool: String?
    var model: String?
    var tokenDisplay: String?
    var duration: TimeInterval?

    /// Convenience for callers that only have the identity fields.
    init(key: String, name: String, isActive: Bool, source: CompletionSource) {
        self.key = key
        self.name = name
        self.isActive = isActive
        self.source = source
        self.subtitle = nil
        self.tool = nil
        self.model = nil
        self.tokenDisplay = nil
        self.duration = nil
    }
}
```

- [ ] **Step 4: Carry candidate fields into the completed item in `step()`**

In `CompletionDetector.step()` (the loop body), replace the `completed.append(...)` line:

```swift
if prior[candidate.key] == true, !candidate.isActive {
    completed.append(CompletionItem(
        name: candidate.name,
        source: candidate.source,
        subtitle: candidate.subtitle,
        tool: candidate.tool,
        model: candidate.model,
        tokenDisplay: candidate.tokenDisplay,
        duration: candidate.duration
    ))
}
```

Add the matching memberwise initializer for `CompletionItem` that accepts all fields (place it right after the convenience `init` above):

```swift
    init(name: String, source: CompletionSource,
         subtitle: String?, tool: String?, model: String?,
         tokenDisplay: String?, duration: TimeInterval?) {
        self.name = name
        self.source = source
        self.subtitle = subtitle
        self.tool = tool
        self.model = model
        self.tokenDisplay = tokenDisplay
        self.duration = duration
    }
```

- [ ] **Step 5: Update `merge` to overwrite fields**

Replace `CompletionFlashNames.merge(existing:new:)`:

```swift
/// Append `new` items to `existing`, skipping duplicate names, preserving order.
/// When a `new` item matches an existing name, its non-nil rich fields overwrite
/// the existing item's fields (newer data wins); nil fields leave existing values.
static func merge(existing: [CompletionItem], new: [CompletionItem]) -> [CompletionItem] {
    var result = existing
    for item in new {
        if let idx = result.firstIndex(where: { $0.name == item.name }) {
            // Field-level merge: newer non-nil values win.
            if let v = item.subtitle { result[idx].subtitle = v }
            if let v = item.tool { result[idx].tool = v }
            if let v = item.model { result[idx].model = v }
            if let v = item.tokenDisplay { result[idx].tokenDisplay = v }
            if let v = item.duration { result[idx].duration = v }
        } else {
            result.append(item)
        }
    }
    return result
}
```

- [ ] **Step 6: Run the full suite to verify pass + no regressions**

Run: `xcodebuild test -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/CompletionDetectorTests 2>&1 | tail -30`
Expected: PASS — all 13 tests (9 existing + 4 new). Existing tests still pass because the old single-arg `c()`/`item()` helpers compile via the convenience inits.

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Services/CompletionDetector.swift NemoNotchTests/CompletionDetectorTests.swift
git commit -m "feat(completion): widen CompletionItem/Candidate with rich optional fields

Carry subtitle (task title), tool, model, tokenDisplay and duration
through the detector's active→idle edge and the merge step, defaulting
to nil so Pomodoro/multi-item paths degrade unchanged."
```

---

## Task 2: Populate rich fields in CompletionFlashService

Feed `AISessionState` data into the widened candidate snapshot.

**Files:**
- Modify: `NemoNotch/Services/CompletionFlashService.swift:50-72`

**Interfaces:**
- Consumes: `AISessionState` derived fields (Task 1's widened `CompletionCandidate`).
- Produces: candidates that carry rich fields → flows into `toastItems` → read by the view (Task 3).

- [ ] **Step 1: Populate the AI branch of `currentCandidates()`**

In `CompletionFlashService.currentCandidates()`, replace the `for session in store.sortedSessions` loop body:

```swift
for session in store.sortedSessions {
    result.append(CompletionCandidate(
        key: "ai:\(session.id)",
        name: session.projectFolder ?? session.displayTitle,
        // Active == .working only; a session merely .waiting is not "working".
        isActive: session.status == .working,
        source: .ai(session.source),
        subtitle: session.displayTitle,
        tool: session.currentTool,
        model: session.displayModel,
        tokenDisplay: session.tokenDisplay,
        duration: Date().timeIntervalSince(session.sessionStart)
    ))
}
```

Leave the `agent:` branch unchanged (its fields stay nil via the convenience init → single-line degradation, as before).

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodebuild build -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -15`
Expected: BUILD SUCCEEDED. (No test here — `currentCandidates` is private; the data path is exercised by the manual completion test in Task 3 and the unit tests in Task 1 cover the model.)

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/CompletionFlashService.swift
git commit -m "feat(completion): populate rich fields from AISessionState in candidates"
```

---

## Task 3: Two-line completion toast for single items

Render the richer data without changing multi-item behavior or the flash animation.

**Files:**
- Modify: `NemoNotch/Notch/CompletionToastView.swift`

**Interfaces:**
- Consumes: `[CompletionItem]` with optional rich fields (Tasks 1–2).
- Produces: a single-item two-line layout (title + tool · model · tokens · duration); multi-item unchanged.

- [ ] **Step 1: Add a duration formatter helper**

At the top of `CompletionToastView.swift` (after `import SwiftUI`), add:

```swift
/// Formats a completion duration: <60s → "42s", <1h → "2m 14s", else "1h 5m".
private func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    let (m, rs) = (s / 60, s % 60)
    if m < 60 { return "\(m)m \(rs)s" }
    let (h, rm) = (m / 60, m % 60)
    return "\(h)h \(rm)m"
}
```

- [ ] **Step 2: Build the secondary-line string helper**

Add a computed property on the view (inside `struct CompletionToastView`):

```swift
/// "tool · model · tokens · duration" for the single-item detail line,
/// skipping nil fields. Returns nil when there is no detail at all.
private func detailLine(for item: CompletionItem) -> String? {
    var parts: [String] = []
    if let tool = item.tool, !tool.isEmpty { parts.append(tool) }
    if let model = item.model { parts.append(model) }
    if let tokens = item.tokenDisplay { parts.append(tokens) }
    if let duration = item.duration { parts.append(formatDuration(duration)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}
```

- [ ] **Step 3: Split the body into single vs multi-item layouts**

Replace the `var body: some View { ... }` (the `HStack` that builds `displayText`) with:

```swift
var body: some View {
    if items.count == 1, let item = items.first {
        singleItemBody(item)
    } else {
        multiItemBody
    }
}

/// Rich two-line layout: title + tool·model·tokens·duration.
@ViewBuilder
private func singleItemBody(_ item: CompletionItem) -> some View {
    HStack(spacing: 10) {
        sourceIcon(item.source)
            .frame(
                width: NotchConstants.completionToastIconSize + 4,
                height: NotchConstants.completionToastIconSize + 4
            )

        VStack(alignment: .leading, spacing: 2) {
            // Prefer the task title (firstUserMessage-derived); fall back to name.
            Text(item.subtitle ?? item.name)
                .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: NotchConstants.completionToastMaxWidth, alignment: .leading)

            if let detail = detailLine(for: item) {
                Text(detail)
                    .font(.system(size: NotchConstants.completionToastFontSize - 5, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: NotchConstants.completionToastMaxWidth, alignment: .leading)
            }
        }

        // The "name" (project folder) is dropped from the visible text when a
        // richer subtitle is present; otherwise it's the title line above.
    }
    .padding(.horizontal, NotchConstants.completionToastHPadding)
    .frame(minHeight: NotchConstants.completionToastHeight)
    .fixedSize(horizontal: true, vertical: false)
    .background(.black)
    .clipShape(Capsule())
    .overlay(Capsule().stroke(NotchTheme.stroke, lineWidth: 0.6))
    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
}

/// Multi-item layout: source logo + names joined by "·" + count chip (unchanged).
@ViewBuilder
private var multiItemBody: some View {
    HStack(spacing: 10) {
        if let source = items.first?.source {
            sourceIcon(source)
                .frame(
                    width: NotchConstants.completionToastIconSize + 4,
                    height: NotchConstants.completionToastIconSize + 4
                )
        }

        Text(items.map(\.name).joined(separator: " · "))
            .font(.system(size: NotchConstants.completionToastFontSize, weight: .semibold))
            .foregroundStyle(NotchTheme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: NotchConstants.completionToastMaxWidth)

        if items.count > 1 {
            Text("\(items.count)")
                .font(.system(size: NotchConstants.completionToastCountFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(NotchTheme.accent)
                .monospacedDigit()
        }
    }
    .padding(.horizontal, NotchConstants.completionToastHPadding)
    .frame(height: NotchConstants.completionToastHeight)
    .fixedSize(horizontal: true, vertical: false)
    .background(.black)
    .clipShape(Capsule())
    .overlay(Capsule().stroke(NotchTheme.stroke, lineWidth: 0.6))
    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
}
```

- [ ] **Step 4: Remove the now-unused `displayText` computed property**

Delete the old `private var displayText: String { items.map(\.name).joined(separator: " · ") }` (it's inlined into `multiItemBody` now).

- [ ] **Step 5: Build**

Run: `xcodebuild build -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -15`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Manual verification**

Run the app, start a Claude Code session that does some work then goes idle, and confirm the completion toast shows the task title as the primary line and `Edit · Sonnet 4.5 · 12.4k · 2m 14s`-style detail as the secondary line. Confirm a Pomodoro phase-end still shows the single-line toast (no detail line). Confirm two near-simultaneous completions still show the multi-item layout with the count chip.

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Notch/CompletionToastView.swift
git commit -m "feat(completion): two-line toast shows title, tool, model, tokens, duration"
```

---

## Task 4: Settings flag, constants, localization, settings toggle

Lay the configuration groundwork the FAB needs.

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift:93, 115-119, 185-186`
- Modify: `NemoNotch/Helpers/Constants.swift`
- Modify: `NemoNotch/Resources/Localizable.xcstrings`
- Modify: `NemoNotch/Settings/SettingsView.swift:113-118`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppSettings.aiStatusFabEnabled` (Bool, default true), `AppSettings.aiStatusFabPositionKey`, `NotchConstants` FAB constants, localized `settings.ai_status_fab.*` keys, a settings `Toggle`.

- [ ] **Step 1: Add the AppSettings flag + position key**

In `Models/AppSettings.swift`, beside `completionFlashEnabledKey` (≈ line 93):

```swift
static let aiStatusFabEnabledKey = "aiStatusFabEnabled"
static let aiStatusFabPositionKey = "aiStatusFabPosition"
```

Beside the `// MARK: - Completion flash` section (≈ line 115), add a new section:

```swift
// MARK: - AI status FAB

var aiStatusFabEnabled: Bool {
    didSet { UserDefaults.standard.set(aiStatusFabEnabled, forKey: Self.aiStatusFabEnabledKey) }
}
```

In `init()` (≈ line 185, next to the `completionFlashEnabled` load):

```swift
aiStatusFabEnabled = UserDefaults.standard
    .object(forKey: Self.aiStatusFabEnabledKey) as? Bool ?? true
```

- [ ] **Step 2: Add FAB constants**

In `Helpers/Constants.swift`, add a new section (e.g. after the completion-toast block):

```swift
// MARK: - AI status FAB

static let aiStatusFabPanelWidth: CGFloat = 420
static let aiStatusFabListColumnWidth: CGFloat = 168
static let aiStatusFabHideDelay: TimeInterval = 3
static let aiStatusFabEdgeMargin: CGFloat = 24
static let aiStatusFabCornerRadius: CGFloat = 14
static let aiStatusFabFadeDuration: Double = 0.24
```

- [ ] **Step 3: Add localization keys**

In `Resources/Localizable.xcstrings`, add two sibling entries next to the `settings.completion_flash.*` keys (match the existing JSON shape exactly):

```json
"settings.ai_status_fab.enabled" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : {
      "stringUnit" : { "state" : "translated", "value" : "Show floating AI-status button while sessions run" }
    },
    "zh-Hans" : {
      "stringUnit" : { "state" : "translated", "value" : "会话运行时显示悬浮 AI 状态按钮" }
    }
  }
},
"settings.ai_status_fab.header" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : {
      "stringUnit" : { "state" : "translated", "value" : "AI Status Button" }
    },
    "zh-Hans" : {
      "stringUnit" : { "state" : "translated", "value" : "AI 状态按钮" }
    }
  }
},
```

- [ ] **Step 4: Add the settings toggle**

In `Settings/SettingsView.swift`, immediately after the completion-flash `Section` (≈ line 118), add:

```swift
Section("settings.ai_status_fab.header") {
    Toggle("settings.ai_status_fab.enabled", isOn: Binding(
        get: { appSettings.aiStatusFabEnabled },
        set: { appSettings.aiStatusFabEnabled = $0 }
    ))
}
```

- [ ] **Step 5: Build**

Run: `xcodebuild build -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -15`
Expected: BUILD SUCCEEDED. (The toggle's `appSettings` reference resolves because the surrounding `SettingsView` already `@Environment`s `AppSettings`.)

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Models/AppSettings.swift NemoNotch/Helpers/Constants.swift NemoNotch/Resources/Localizable.xcstrings NemoNotch/Settings/SettingsView.swift
git commit -m "feat(settings): aiStatusFabEnabled flag, FAB constants, localized toggle"
```

---

## Task 5: AIStatusWindow (NSPanel) + environment key

A borderless, non-activating, draggable floating panel mirroring `QuickStartWindow`.

**Files:**
- Create: `NemoNotch/Notch/AIStatusWindow.swift`
- Modify: `NemoNotch/Notch/QuickStartWindowController.swift:184-186`

**Interfaces:**
- Consumes: nothing.
- Produces: `AIStatusWindow: NSPanel` (used by Task 6's controller); `EnvironmentValues.aiStatusController` `@Entry` (consumed by Task 7's view and Task 6's wiring).

- [ ] **Step 1: Create `AIStatusWindow.swift`**

Create `NemoNotch/Notch/AIStatusWindow.swift`:

```swift
import AppKit

/// Borderless, non-activating floating panel for the AI-status FAB. Mirrors
/// `QuickStartWindow`'s proven config: floats above the notch, never steals
/// focus, draws its own shadow in SwiftUI (native shadow would clip to a black
/// square), and disables system window animation to dodge the
/// `_NSWindowTransformAnimation` dealloc crash recorded in QuickStartWindow.
final class AIStatusWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the notch panel (.statusBar + 8) so the FAB is never occluded.
        level = .statusBar + 9
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        // Stay put across Space switches; visible on all Spaces.
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Add the `aiStatusController` environment key**

At the bottom of `Notch/QuickStartWindowController.swift`, alongside the existing `quickStartController` entry (≈ line 184), add:

```swift
extension EnvironmentValues {
    @Entry var aiStatusController: AIStatusWindowController?
}
```

(Merge it into the existing `extension EnvironmentValues { … }` block, or keep a second block — both compile.)

- [ ] **Step 3: Build (will fail until Task 6 defines the controller type)**

This step intentionally does NOT build yet — the `@Entry` references `AIStatusWindowController`, which Task 6 creates. The build is verified at the end of Task 6. Proceed to Task 6.

---

## Task 6: AIStatusWindowController + wiring (collapsed capsule working)

Implement the controller's lifecycle, 3-state machine, observation/show-hide, and position persistence; wire it into `NemoNotchApp`. At the end of this task the **collapsed capsule** appears when sessions run, is draggable, remembers its position, and toggles via the settings flag. (The expanded panel body is added in Task 7.)

**Files:**
- Create: `NemoNotch/Notch/AIStatusWindowController.swift`
- Create: `NemoNotch/Notch/AIStatusFABView.swift` (minimal collapsed capsule only — expanded added Task 7)
- Modify: `NemoNotch/NemoNotchApp.swift:191-222`

**Interfaces:**
- Consumes: `AISessionStore`, `AppSettings` (Task 4), `AIStatusWindow` (Task 5).
- Produces: `AIStatusWindowController` with `toggleExpanded()`, `collapse()`, and internal show/hide; injectable via `EnvironmentValues.aiStatusController`.

- [ ] **Step 1: Create the minimal `AIStatusFABView` (collapsed capsule)**

Create `NemoNotch/Notch/AIStatusFABView.swift`:

```swift
import SwiftUI

/// The floating AI-status button. Collapsed = a draggable capsule showing the
/// count of running sessions; expanded = a list+detail panel (added in Task 7).
/// Reads `AISessionStore` and the controller from the environment.
struct AIStatusFABView: View {
    @Environment(AISessionStore.self) var store
    @Environment(\.aiStatusController) var controller

    var body: some View {
        capsule
    }

    private var workingCount: Int {
        store.sortedSessions.filter { $0.status == .working }.count
    }

    private var capsule: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [NotchTheme.accent, NotchTheme.accentHot],
                        center: .center, startRadius: 0, endRadius: 8
                    )
                )
                .frame(width: 10, height: 10)
                .shadow(color: NotchTheme.accent.opacity(0.7), radius: 6)
                .modifier(PulseModifier(isActive: true))
            Text("\(workingCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchTheme.textPrimary)
            Text("running")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        .background(.black)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(NotchTheme.stroke, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .contentShape(Capsule())
        .onTapGesture { controller?.toggleExpanded() }
    }
}
```

- [ ] **Step 2: Create `AIStatusWindowController.swift`**

Create `NemoNotch/Notch/AIStatusWindowController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class AIStatusWindowController {
    private var window: AIStatusWindow?
    private var hostingController: NSHostingController<AIStatusFABView>?
    private var hideTask: Task<Void, Never>?
    private let store: AISessionStore
    private let appSettings: AppSettings

    init(store: AISessionStore, appSettings: AppSettings) {
        self.store = store
        self.appSettings = appSettings
        LogService.info("AIStatusWindowController init", category: "AIStatusFAB")
        observe()
    }

    deinit {
        MainActor.assumeIsolated { hideTask?.cancel() }
    }

    // MARK: - Public (called by the SwiftUI view)

    func toggleExpanded() {
        // Expanded panel is added in Task 7; for now the capsule has no expand
        // target, so this is a no-op stub that Task 7 replaces.
    }

    func collapse() {
        // Task 7 implements the expanded→collapsed transition.
    }

    // MARK: - Observation + show/hide

    private var workingCount: Int {
        store.sortedSessions.filter { $0.status == .working }.count
    }

    private func observe() {
        withObservationTracking {
            _ = store.sortedSessions.map { ($0.id, $0.status) }
            _ = appSettings.aiStatusFabEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe() // re-arm before evaluating
                self.evaluateVisibility()
            }
        }
    }

    private func evaluateVisibility() {
        guard appSettings.aiStatusFabEnabled else {
            hide(immediate: true)
            return
        }
        if workingCount > 0 {
            show()
        } else {
            scheduleHide()
        }
    }

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        guard window == nil || !window!.isVisible else { return }
        let w = window ?? AIStatusWindow()
        window = w
        if hostingController == nil {
            let host = NSHostingController(
                rootView: AIStatusFABView()
                    .environment(store)
                    .environment(appSettings)
                    .environment(\.aiStatusController, self)
            )
            host.view.wantsLayer = true
            host.view.layer?.backgroundColor = NSColor.clear.cgColor
            hostingController = host
            w.contentViewController = host
        }
        applyPosition(to: w)
        w.setContentSize(hostingController!.view.fittingSize)
        w.alphaValue = 0
        w.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NotchConstants.aiStatusFabFadeDuration
            w.animator().alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchConstants.aiStatusFabHideDelay))
            guard let self, !Task.isCancelled else { return }
            self.hide(immediate: false)
        }
    }

    private func hide(immediate: Bool) {
        hideTask?.cancel()
        guard let w = window else { return }
        if immediate {
            w.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NotchConstants.aiStatusFabFadeDuration
            w.animator().alphaValue = 0
        }, completionHandler: { [weak w] in
            w?.orderOut(nil)
        })
    }

    // MARK: - Position persistence

    private func applyPosition(to w: NSWindow) {
        // Only set position on first show; afterwards the window keeps its frame
        // (user may have dragged it).
        if w.frame.origin != .zero { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = w.frame.size
        var origin = restoreOrigin()
        // Clamp into the visible frame (slide, keep user's axis preference).
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        // First-ever launch default: top-right of the main screen.
        if origin == .zero {
            origin = CGPoint(
                x: visible.maxX - size.width - NotchConstants.aiStatusFabEdgeMargin,
                y: visible.maxY - size.height - NotchConstants.aiStatusFabEdgeMargin
            )
        }
        w.setFrame(CGRect(origin: origin, size: size), display: false)
    }

    private func restoreOrigin() -> CGPoint {
        guard let data = UserDefaults.standard.data(forKey: AppSettings.aiStatusFabPositionKey),
              let point = try? JSONDecoder().decode(CGPoint.self, from: data) else {
            return .zero
        }
        return point
    }

    /// Called by the window delegate when the user finishes dragging.
    func persistPosition(_ origin: CGPoint) {
        guard let data = try? JSONEncoder().encode(origin) else { return }
        UserDefaults.standard.set(data, forKey: AppSettings.aiStatusFabPositionKey)
    }
}
```

- [ ] **Step 3: Make the controller the window's delegate to persist drags**

In `AIStatusWindowController`, conform to `NSWindowDelegate` and wire it in `show()`. Add this extension at the bottom of the file:

```swift
extension AIStatusWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        persistPosition(w.frame.origin)
    }
}
```

And in `show()`, set the delegate right before `orderFront`:

```swift
        w.delegate = self
        w.alphaValue = 0
        w.orderFront(nil)
```

- [ ] **Step 4: Construct + inject the controller in `NemoNotchApp.swift`**

In `AppDelegate.applicationDidFinishLaunching`, beside the `quickStartController` construction (≈ line 191), add a stored property. First declare the property among the other controller properties (near `quickStartController`):

```swift
private(set) var aiStatusController: AIStatusWindowController?
```

Then in `applicationDidFinishLaunching`, after the `quickStartController = …` block (≈ line 196), add:

```swift
aiStatusController = AIStatusWindowController(
    store: aiMonitor.store,
    appSettings: settings
)
```

Then inside the `NotchCoordinator { … }` content closure (≈ line 200-222), after the `let qsController = quickStartController` line, add:

```swift
let aiController = aiStatusController
```

and inside the `AnyView(NotchView(screen: screen)…)` chain, after `.environment(\.quickStartController, qsController)` (≈ line 221), add:

```swift
            .environment(\.aiStatusController, aiController)
```

> **Note:** Verify the exact property names (`aiMonitor`, `settings`) by reading `NemoNotchApp.swift` around lines 123-196 — match the local constant names already used there. If the AI monitor service property is named `aiMonitorService` and its store is accessed differently, use that.

- [ ] **Step 5: Build**

Run: `xcodebuild build -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. If `aiMonitor.store` doesn't resolve, read `NemoNotchApp.swift` around the `AICLIMonitorService` construction and use the correct store accessor (the service exposes `var store: AISessionStore`; check whether the property is `aiMonitorService` and you need `aiMonitorService.store`).

- [ ] **Step 6: Manual verification (collapsed capsule)**

Run the app. Start a Claude Code session doing work → confirm the capsule fades in at top-right showing "1 running". Drag it → it moves and the position persists after app restart. Let the session go idle → after ~3s the capsule fades out. Toggle the settings switch off → the capsule hides immediately; on → it returns if a session is working.

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Notch/AIStatusWindow.swift NemoNotch/Notch/AIStatusWindowController.swift NemoNotch/Notch/AIStatusFABView.swift NemoNotch/Notch/QuickStartWindowController.swift NemoNotch/NemoNotchApp.swift
git commit -m "feat(fab): draggable AI-status capsule, shows while sessions run

NSPanel mirroring QuickStartWindow; observes AISessionStore working count;
3s hide delay; position persisted to UserDefaults and clamped to visibleFrame."
```

---

## Task 7: Expanded list+detail panel (layout B)

Add the expanded state: a 420px-wide panel with a left session list and a right detail pane. Toggle between collapsed/expanded with size animation.

**Files:**
- Modify: `NemoNotch/Notch/AIStatusFABView.swift` (add the panel + state)
- Modify: `NemoNotch/Notch/AIStatusWindowController.swift` (implement `toggleExpanded`/`collapse` + resize)

**Interfaces:**
- Consumes: `AISessionState` derived fields, `AIStatusWindowController` (env), the source-icon components (`ClaudeCrabIcon`, `OpencodeLogoIcon`, `ZcodeLogoIcon` — all internal `View`s with `init(size:color:)`).
- Produces: the full FAB with expand/collapse.

- [ ] **Step 1: Add `isExpanded` state to the controller**

In `AIStatusWindowController`, add a published-ish observable property (the controller is a plain `@MainActor` class — SwiftUI reads it through the env value, but the view needs to react. Use an `@Observable`-style approach by making the controller `@Observable`):

At the top of the class, change the declaration and add the flag:

```swift
@MainActor
@Observable
final class AIStatusWindowController {
    private(set) var isExpanded = false
    // … existing properties …
```

Then implement the two methods (replacing the stubs):

```swift
func toggleExpanded() {
    if isExpanded { collapse() } else { expand() }
}

func collapse() {
    guard isExpanded else { return }
        isExpanded = false
        rehostAndResize()
    }

    private func expand() {
        isExpanded = true
        rehostAndResize()
    }

    /// Rebuild the hosting root (so the view swaps capsule↔panel) and resize
    /// the window to fit, centered on the capsule's current position.
    private func rehostAndResize() {
        guard let w = window, let host = hostingController else { return }
        host.rootView = AIStatusFABView()
            .environment(store)
            .environment(appSettings)
            .environment(\.aiStatusController, self)
        let fitting = host.view.fittingSize
        // Keep the top-right anchor stable as the size changes.
        let current = w.frame
        let origin = CGPoint(
            x: current.maxX - fitting.width,
            y: current.maxY - fitting.height
        )
        w.setFrame(CGRect(origin: origin, size: fitting), display: true, animate: true)
    }
```

> Note: `@Observable` requires `import Observation` (or just `import SwiftUI` which re-exports it) — already imported via `import SwiftUI` at the top. The `@Observable` macro is available macOS 14+.

- [ ] **Step 2: Expand `AIStatusFABView` to render both states**

Replace the whole `AIStatusFABView.swift` `body` to switch on the controller's `isExpanded`, and add the panel. Full new file content:

```swift
import SwiftUI

/// The floating AI-status button. Collapsed = draggable capsule showing the
/// running-session count; expanded = a list+detail panel.
struct AIStatusFABView: View {
    @Environment(AISessionStore.self) var store
    @Environment(\.aiStatusController) var controller

    var body: some View {
        if controller?.isExpanded == true {
            panel
        } else {
            capsule
        }
    }

    // MARK: - Derived

    private var workingSessions: [AISessionState] {
        store.sortedSessions.filter { $0.status == .working }
    }

    private var workingCount: Int { workingSessions.count }

    // MARK: - Collapsed capsule

    private var capsule: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [NotchTheme.accent, NotchTheme.accentHot],
                        center: .center, startRadius: 0, endRadius: 8
                    )
                )
                .frame(width: 10, height: 10)
                .shadow(color: NotchTheme.accent.opacity(0.7), radius: 6)
                .modifier(PulseModifier(isActive: true))
            Text("\(workingCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchTheme.textPrimary)
            Text("running")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        .background(.black)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(NotchTheme.stroke, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .contentShape(Capsule())
        .onTapGesture { controller?.toggleExpanded() }
    }

    // MARK: - Expanded panel (layout B: list + detail)

    @State private var selectedSessionId: String?

    private var selectedSession: AISessionState? {
        if let id = selectedSessionId, let s = store.get(id) { return s }
        return workingSessions.first
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            Divider().background(NotchTheme.stroke)
            HStack(spacing: 0) {
                sessionList
                    .frame(width: NotchConstants.aiStatusFabListColumnWidth)
                Divider().background(NotchTheme.stroke)
                detailPane
            }
        }
        .frame(width: NotchConstants.aiStatusFabPanelWidth)
        .background(
            RoundedRectangle(cornerRadius: NotchConstants.aiStatusFabCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [NotchTheme.panelRaised, NotchTheme.panelBase],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchConstants.aiStatusFabCornerRadius, style: .continuous)
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(NotchConstants.openedShadowOpacity), radius: NotchConstants.openedShadowRadius)
        .padding(NotchConstants.openedShadowRadius + 6) // room for shadow blur
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(NotchTheme.accent)
                .frame(width: 8, height: 8)
                .shadow(color: NotchTheme.accent.opacity(0.6), radius: 4)
            Text("\(workingCount) running")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text("· AI sessions")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Spacer(minLength: 8)
            Button {
                controller?.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(NotchTheme.surface))
                    .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.6))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Collapse")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(workingSessions) { session in
                    let isSelected = session.id == selectedSession?.id
                    HStack(spacing: 7) {
                        Circle()
                            .fill(NotchTheme.accent)
                            .frame(width: 6, height: 6)
                            .shadow(color: NotchTheme.accent.opacity(0.7), radius: 3)
                        Text(session.displayTitle)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? NotchTheme.textPrimary : NotchTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? NotchTheme.accent.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedSessionId = session.id }
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let session = selectedSession {
            detailContent(session)
        } else {
            Text("No session")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func detailContent(_ session: AISessionState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                sourceIcon(session.source, size: 16)
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(2)
            }
            if let tool = session.currentTool, !tool.isEmpty {
                toolBadge(tool, tint: sourceTint(session.source))
            }
            // Context progress
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: session.contextPercent)
                    .tint(NotchTheme.accent)
                HStack {
                    Text("ctx \(String(format: "%.0f%%", session.contextPercent * 100))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Spacer()
                    Text("\(session.contextTokenDisplay) / \(session.contextLimitDisplay)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
            }
            detailRow("Model", session.displayModel ?? "—")
            detailRow("Tokens", session.tokenDisplay)
            detailRow("Folder", session.projectFolder ?? "—")
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func toolBadge(_ tool: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
            Text(tool)
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14))
        .clipShape(Capsule(style: .continuous))
    }

    // MARK: - Source icon (inlined switch; reuses the public icon components)

    @ViewBuilder
    private func sourceIcon(_ source: AISource, size: CGFloat) -> some View {
        let tint = sourceTint(source)
        switch source {
        case .claude:
            ClaudeCrabIcon(size: size, color: tint)
        case .gemini:
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(tint)
        case .opencode:
            OpencodeLogoIcon(size: size, color: tint)
        case .zcode:
            ZcodeLogoIcon(size: size, color: tint)
        }
    }

    private func sourceTint(_ source: AISource) -> Color {
        switch source {
        case .claude: NotchTheme.accentText
        case .gemini: Color(red: 0.42, green: 0.68, blue: 1.0)
        case .opencode: Color(red: 0.55, green: 0.78, blue: 0.55)
        case .zcode: Color(red: 0.11, green: 0.44, blue: 0.96)
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual verification (expanded panel)**

Run the app with ≥1 working Claude Code session. Click the capsule → it expands into the 420px list+detail panel anchored at the capsule's position. Confirm: the left list shows each session's title, clicking a row updates the right detail; the detail shows source icon, title, current tool badge, context progress bar + %, Model/Tokens/Folder rows. Click the chevron button → collapses back to the capsule. Confirm dragging the collapsed capsule still works; confirm expanding after dragging anchors to the new position.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Notch/AIStatusFABView.swift NemoNotch/Notch/AIStatusWindowController.swift
git commit -m "feat(fab): expanded list+detail panel with animated size transition

Layout B: 168px session list + detail pane (title, tool, context progress,
model/tokens/folder). Top-right-anchored resize on expand/collapse."
```

---

## Self-Review (post-write check)

**1. Spec coverage:**
- Widen models → Task 1 ✓
- currentCandidates populate → Task 2 ✓
- Two-line toast (single item, multi unchanged) → Task 3 ✓
- AppSettings flag + position key → Task 4 ✓
- Constants → Task 4 ✓
- Localization (en + zh-Hans) → Task 4 ✓
- Settings toggle → Task 4 ✓
- AIStatusWindow (NSPanel, QuickStart pattern) → Task 5 ✓
- Controller 3-state + observe/show-hide + position persistence + clamp → Task 6 ✓
- Collapsed capsule (pulse + "N running", draggable) → Task 6 ✓
- Wiring in NemoNotchApp → Task 6 ✓
- Expanded panel B (420px, list 168 + detail) → Task 7 ✓
- EnvironmentValues.aiStatusController → Task 5 ✓

**2. Placeholder scan:** None. The Task 6 `toggleExpanded`/`collapse` are implemented as real no-op stubs in Task 6 and fully replaced in Task 7 (explicitly noted). The Task 5 build-skipped step is intentional cross-task coupling, documented.

**3. Type consistency:** `CompletionItem`/`CompletionCandidate` new field names (`subtitle`, `tool`, `model`, `tokenDisplay`, `duration`) match across Tasks 1→2→3. `AIStatusWindowController.toggleExpanded`/`collapse`/`isExpanded` match across Tasks 5→6→7. `EnvironmentValues.aiStatusController` defined Task 5, used Tasks 6–7.

**4. Open risks noted inline:** Task 6 Step 5 flags the `aiMonitor.store` accessor name to verify against `NemoNotchApp.swift`. Task 7 Step 1 notes the `@Observable` requirement.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-04-ai-status-fab-and-completion-toast.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
