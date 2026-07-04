# Single-Row Stacked Collapsed Badges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-row collapsed-notch badge display with a single notch-flanking row of grouped, stacked logos (left) and their corresponding statuses with count chips (right).

**Architecture:** A new pure function `BadgeGrouping` folds the priority-sorted `activeBadgeItems` into `BadgeGroup`s keyed by icon identity, then caps them into a `BadgeCluster` (visible groups + "+K" overflow). `CompactBadgesView` renders the cluster as a mirrored fan (highest priority hugs the notch on both wings); `BadgeRowView` and the collapsed-notch vertical growth are removed.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`).

## Global Constraints

- Tests use **Swift Testing** (`@testable import NemoNotch`, `@Test`, `#expect`) — never XCTest.
- Only test pure logic (`BadgeGrouping`); do not add tests for SwiftUI views or `@Observable` services.
- Match existing style in `NemoNotch/Notch/Badge/`. Add `LogService` calls only where the existing badge code already logs (it does not — no logging needed here).
- Never edit `project.pbxproj` to add source files — the project auto-syncs root groups (new files under `NemoNotch/` and `NemoNotchTests/` are picked up automatically).
- Git: work on `develop`. Commit messages in English.
- After code lands, update `README.md`, `README_CN.md`, `CLAUDE.md` (project convention).

---

### Task 1: Pure grouping logic — `BadgeGroup`, `BadgeCluster`, `BadgeGrouping`

**Files:**
- Create: `NemoNotch/Notch/Badge/BadgeGrouping.swift`
- Test: `NemoNotchTests/BadgeGroupingTests.swift`

**Interfaces:**
- Consumes: `BadgeItem` (existing enum, `NemoNotch/Notch/Badge/BadgeItem.swift`), `BadgeItem.priority`, `AISource`, `ClaudeStatus`, `AgentMonitorState`, `PomodoroPhase`.
- Produces:
  - `struct BadgeGroup: Identifiable, Equatable { let key: String; let representative: BadgeItem; let count: Int; var id: String; var priority: Int }`
  - `struct BadgeCluster: Equatable { let groups: [BadgeGroup]; let overflow: Int }`
  - `enum BadgeGrouping { static func key(for:) -> String; static func group(_:) -> [BadgeGroup]; static func cluster(_:cap:) -> BadgeCluster }`

- [ ] **Step 1: Write the failing tests**

Create `NemoNotchTests/BadgeGroupingTests.swift`:

```swift
@testable import NemoNotch
import Testing

@Suite("Badge grouping")
struct BadgeGroupingTests {
    private func ai(
        _ source: AISource = .claude,
        _ status: ClaudeStatus = .working,
        approval: Bool = false,
        id: String
    ) -> BadgeItem {
        .ai(source: source, status: status, tool: nil, waitingApproval: approval, sessionID: id)
    }

    private func agent(_ emoji: String, id: String) -> BadgeItem {
        .agents(agentID: id, state: .working, emoji: emoji)
    }

    @Test("Single item → one group, count 1")
    func single() {
        let g = BadgeGrouping.group([ai(id: "s1")])
        #expect(g.count == 1)
        #expect(g[0].key == "ai:claude")
        #expect(g[0].count == 1)
    }

    @Test("Multiple same program → one group, count = members")
    func multipleSame() {
        let g = BadgeGrouping.group([ai(id: "s1"), ai(id: "s2"), ai(id: "s3")])
        #expect(g.count == 1)
        #expect(g[0].count == 3)
    }

    @Test("Multiple different programs → one group each, order preserved")
    func multipleDifferent() {
        let g = BadgeGrouping.group([ai(id: "s1"), .media, .calendar])
        #expect(g.map(\.key) == ["ai:claude", "media", "calendar"])
        #expect(g.allSatisfy { $0.count == 1 })
    }

    @Test("Mixed with duplicates → dup group carries count, others 1")
    func mixedWithDuplicates() {
        let g = BadgeGrouping.group([ai(id: "s1"), ai(id: "s2"), .media])
        #expect(g.count == 2)
        #expect(g[0].key == "ai:claude")
        #expect(g[0].count == 2)
        #expect(g[1].key == "media")
        #expect(g[1].count == 1)
    }

    @Test("Representative is the first (highest-priority) member")
    func representative() {
        // Caller passes already priority-sorted items; approval sorts ahead of working.
        let approval = ai(.waiting, approval: true, id: "s1")
        let working = ai(.working, id: "s2")
        let g = BadgeGrouping.group([approval, working])
        #expect(g.count == 1)
        #expect(g[0].representative == approval)
        #expect(g[0].count == 2)
    }

    @Test("Agents group by emoji icon identity")
    func agentsByEmoji() {
        let g = BadgeGrouping.group([agent("🤖", id: "a1"), agent("🤖", id: "a2"), agent("🦀", id: "a3")])
        #expect(g.count == 2)
        #expect(g.first { $0.key == "agents:🤖" }?.count == 2)
        #expect(g.first { $0.key == "agents:🦀" }?.count == 1)
    }

    @Test("Overflow beyond cap collapses remainder to +K")
    func overflow() {
        let items: [BadgeItem] = [
            ai(id: "s1"), .media, .calendar, .pomodoro(phase: .work), agent("🤖", id: "a1"),
        ]
        // 5 distinct groups, cap 4 → show first 3, overflow 2
        let c = BadgeGrouping.cluster(items, cap: 4)
        #expect(c.groups.count == 3)
        #expect(c.overflow == 2)
    }

    @Test("Under cap → no overflow")
    func underCap() {
        let c = BadgeGrouping.cluster([ai(id: "s1"), .media], cap: 4)
        #expect(c.groups.count == 2)
        #expect(c.overflow == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/BadgeGroupingTests 2>&1 | tail -20`
Expected: FAIL to compile — `cannot find 'BadgeGrouping' in scope`.

- [ ] **Step 3: Write the implementation**

Create `NemoNotch/Notch/Badge/BadgeGrouping.swift`:

```swift
import Foundation

/// A run of active badge items sharing one icon identity (e.g. all Claude
/// sessions). Rendered as a single left logo + one right status; `count`
/// drives the right-side count chip when > 1.
struct BadgeGroup: Identifiable, Equatable {
    /// Stable icon-identity key — used as SwiftUI identity so the group's
    /// slot animates in place as its representative's status changes.
    let key: String
    /// The group's highest-priority member (input is priority-sorted, so the
    /// first member seen for a key). Drives the logo, status, and tap target.
    let representative: BadgeItem
    /// Total members in the group.
    let count: Int

    var id: String { key }
    var priority: Int { representative.priority }
}

/// The capped, display-ready badge layout: the visible groups plus the number
/// of groups folded into the trailing "+K" overflow chip.
struct BadgeCluster: Equatable {
    let groups: [BadgeGroup]
    /// K for the "+K" chip; 0 when nothing overflowed.
    let overflow: Int
}

enum BadgeGrouping {
    /// Icon-identity key: items sharing this key render the same left logo.
    /// AI groups by source, agents by emoji (empty emoji → shared Hermes icon),
    /// everything else is a singleton category.
    static func key(for item: BadgeItem) -> String {
        switch item {
        case let .ai(source, _, _, _, _): "ai:\(source.rawValue)"
        case let .agents(_, _, emoji): "agents:\(emoji)"
        case .notification: "notification"
        case .media: "media"
        case .pomodoro: "pomodoro"
        case .calendar: "calendar"
        }
    }

    /// Groups priority-sorted `items` by icon identity, preserving first-seen
    /// order. Precondition: `items` is already sorted by priority (as produced
    /// by `BadgeViewModel.activeBadgeItems`), so each key's first member is its
    /// highest-priority representative.
    static func group(_ items: [BadgeItem]) -> [BadgeGroup] {
        var order: [String] = []
        var reps: [String: BadgeItem] = [:]
        var counts: [String: Int] = [:]
        for item in items {
            let k = key(for: item)
            if reps[k] == nil {
                reps[k] = item
                order.append(k)
            }
            counts[k, default: 0] += 1
        }
        return order.map { BadgeGroup(key: $0, representative: reps[$0]!, count: counts[$0]!) }
    }

    /// Applies the display cap. When the group count exceeds `cap`, keeps the
    /// first `cap - 1` groups and reports the remainder as `overflow`.
    static func cluster(_ items: [BadgeItem], cap: Int) -> BadgeCluster {
        let all = group(items)
        guard all.count > cap else { return BadgeCluster(groups: all, overflow: 0) }
        let visible = Array(all.prefix(cap - 1))
        return BadgeCluster(groups: visible, overflow: all.count - visible.count)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/BadgeGroupingTests 2>&1 | tail -20`
Expected: PASS — all 8 tests green.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Notch/Badge/BadgeGrouping.swift NemoNotchTests/BadgeGroupingTests.swift
git commit -m "feat(badge): add pure BadgeGrouping logic for stacked collapsed badges"
```

---

### Task 2: Single-row cluster UI (atomic swap)

Rewrite `CompactBadgesView` to render the mirrored fan from a `BadgeCluster`, delete `BadgeRowView` and the collapsed-notch vertical growth, and remove the now-dead `.row` render style. This task is atomic — every change below ships in one commit so the target keeps compiling.

**Files:**
- Modify: `NemoNotch/Helpers/Constants.swift` (add cluster constants, remove row constants)
- Modify: `NemoNotch/Notch/Badge/BadgeViewModel.swift` (add `badgeCluster`, remove `hasMultipleBadges`)
- Modify: `NemoNotch/Notch/Badge/BadgeIconView.swift` (rewrite `CompactBadgesView`, delete `BadgeRowView`, remove `.row` from `BadgeRenderStyle` and its per-badge branches)
- Modify: `NemoNotch/Notch/NotchView.swift:64-129` (collapsed height = hardware height; pass `badgeCluster`; remove `BadgeRowView` block)

**Interfaces:**
- Consumes: `BadgeCluster`, `BadgeGroup`, `BadgeGrouping.cluster(_:cap:)` (Task 1); existing `BadgeIconView`, `NotchConstants`, `handleBadgeTap`.
- Produces:
  - `NotchConstants.badgeGroupCap: Int`, `badgeStackStep: CGFloat`, `badgeStatusStep: CGFloat`
  - `BadgeViewModel.badgeCluster: BadgeCluster` (computed from `displayedBadgeItems`)
  - `CompactBadgesView(cluster:shownHasActiveBadge:notchLeftEdge:notchRightEdge:notchCenterY:onBadgeTap:notificationService:mediaService:pomodoroService:)`

- [ ] **Step 1: Update constants**

In `NemoNotch/Helpers/Constants.swift`, **remove** these two lines (the `// Badge row` block):

```swift
    // Badge row
    static let badgeRowHeight: CGFloat = 24
    static let badgeRowSpacing: CGFloat = 10
```

And **add** to the `// Badge` block (next to `badgeSpread`):

```swift
    /// Max badge groups shown collapsed; extras fold into a "+K" chip.
    static let badgeGroupCap: Int = 4
    /// Horizontal step between overlapping left logos (smaller than a logo → fan overlap).
    static let badgeStackStep: CGFloat = 11
    /// Horizontal step between right-side status indicators.
    static let badgeStatusStep: CGFloat = 15
```

- [ ] **Step 2: Add `badgeCluster` to the view model and remove `hasMultipleBadges`**

In `NemoNotch/Notch/Badge/BadgeViewModel.swift`, **replace** the `hasMultipleBadges` computed property:

```swift
    var hasMultipleBadges: Bool {
        displayedBadgeItems.count >= 2
    }
```

with:

```swift
    /// Display-ready grouped/capped layout for the collapsed compact badges.
    var badgeCluster: BadgeCluster {
        BadgeGrouping.cluster(displayedBadgeItems, cap: NotchConstants.badgeGroupCap)
    }
```

- [ ] **Step 3: Rewrite `CompactBadgesView` and delete `BadgeRowView`**

In `NemoNotch/Notch/Badge/BadgeIconView.swift`:

(a) **Remove** `.row` from the render-style enum:

```swift
enum BadgeRenderStyle {
    case compactLeft
    case compactRight
}
```

(b) **Delete** the `.row` branch from every `switch style` in `BadgeIconView` — merge each into its `.compactLeft` sibling. Concretely:
- `notificationBadge`: change `case .compactLeft, .row:` → `case .compactLeft:`
- `mediaBadge`: change `case .compactLeft, .row:` → `case .compactLeft:` and replace `size: style == .row ? 18 : 20` → `size: 20`
- `aiBadge`: delete the `case .row:` line and its `aiSourceIcon(...)` body (the `.compactLeft` case already calls it)
- `agentsBadge`: change `case .compactLeft, .row:` → `case .compactLeft:`, and replace the two `style == .row ? A : B` sizes with the `B` value (`14`→ use `13`; frame `14/13`→`13`)
- `pomodoroBadge`: delete the `case .row:` branch (the `.compactRight` case already renders the pie)

(c) **Replace** the entire `CompactBadgesView` struct (lines 231–296) with:

```swift
// MARK: - CompactBadgesView

struct CompactBadgesView: View {
    let cluster: BadgeCluster
    let shownHasActiveBadge: Bool
    let notchLeftEdge: CGFloat
    let notchRightEdge: CGFloat
    let notchCenterY: CGFloat
    let onBadgeTap: (BadgeItem) -> Void
    let notificationService: NotificationService
    let mediaService: MediaService
    let pomodoroService: PomodoroTimerService

    /// Tapping anywhere opens the highest-priority group's tab.
    private var primary: BadgeItem? { cluster.groups.first?.representative }

    var body: some View {
        let spread: CGFloat = shownHasActiveBadge ? NotchConstants.badgeSpread : 0
        ZStack {
            leftFan(spread: spread)
            rightFan(spread: spread)
        }
        .opacity(shownHasActiveBadge ? 1 : 0)
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: spread
        )
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: shownHasActiveBadge
        )
    }

    // Left: overlapping logos. Highest priority (index 0) hugs the notch and is
    // frontmost; lower-priority logos fan leftward behind it. A trailing "+K"
    // chip sits at the far (backmost) end when groups overflowed.
    @ViewBuilder
    private func leftFan(spread: CGFloat) -> some View {
        ForEach(Array(cluster.groups.enumerated()), id: \.element.id) { index, group in
            Button { primary.map(onBadgeTap) } label: {
                BadgeIconView(
                    item: group.representative, style: .compactLeft,
                    notificationService: notificationService,
                    mediaService: mediaService,
                    pomodoroService: pomodoroService
                )
            }
            .buttonStyle(.plain)
            .zIndex(Double(cluster.groups.count - index))
            .position(
                x: notchLeftEdge - spread - CGFloat(index) * NotchConstants.badgeStackStep,
                y: notchCenterY
            )
            .transition(.opacity.combined(with: .offset(x: NotchConstants.badgeSpread)))
        }
        if cluster.overflow > 0 {
            BadgeCountChip(text: "+\(cluster.overflow)")
                .position(
                    x: notchLeftEdge - spread - CGFloat(cluster.groups.count) * NotchConstants.badgeStackStep,
                    y: notchCenterY
                )
        }
    }

    // Right: statuses in priority order, highest hugging the notch. A count chip
    // overlays any group with more than one member.
    @ViewBuilder
    private func rightFan(spread: CGFloat) -> some View {
        ForEach(Array(cluster.groups.enumerated()), id: \.element.id) { index, group in
            Button { primary.map(onBadgeTap) } label: {
                BadgeIconView(
                    item: group.representative, style: .compactRight,
                    notificationService: notificationService,
                    mediaService: mediaService,
                    pomodoroService: pomodoroService
                )
                .overlay(alignment: .bottomTrailing) {
                    if group.count > 1 {
                        BadgeCountChip(text: "\(group.count)")
                    }
                }
            }
            .buttonStyle(.plain)
            .position(
                x: notchRightEdge + spread + CGFloat(index) * NotchConstants.badgeStatusStep,
                y: notchCenterY
            )
            .transition(.opacity.combined(with: .offset(x: -NotchConstants.badgeSpread)))
        }
    }
}

// MARK: - BadgeCountChip

/// Small rounded count pill, matching the notification badge count style.
private struct BadgeCountChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 2)
            .padding(.vertical, 0.5)
            .background(NotchTheme.accent)
            .clipShape(Capsule())
    }
}
```

(d) **Delete** the entire `// MARK: - BadgeRowView` struct (old lines 298–332).

- [ ] **Step 4: Update `NotchView`**

In `NemoNotch/Notch/NotchView.swift`, the collapsed branch of `notchSize` (lines 66–74) becomes:

```swift
        case .closed:
            let hasBadge = badgeViewModel?.shownHasActiveBadge ?? false
            let extraWidth: CGFloat = hasBadge ? NotchConstants.badgePadding * 2 : 0
            return CGSize(
                width: hardwareNotchSize.width - NotchConstants.closedWidthInset + extraWidth,
                height: hardwareNotchSize.height
            )
```

And the collapsed rendering block (lines 103–130) becomes:

```swift
            if effectiveStatus == .closed {
                CompactBadgesView(
                    cluster: badgeViewModel?.badgeCluster ?? BadgeCluster(groups: [], overflow: 0),
                    shownHasActiveBadge: shown,
                    notchLeftEdge: notchLeftEdge,
                    notchRightEdge: notchRightEdge,
                    notchCenterY: hardwareNotchSize.height / 2,
                    onBadgeTap: handleBadgeTap,
                    notificationService: notificationService,
                    mediaService: mediaService,
                    pomodoroService: pomodoroService
                )
                .zIndex(1)
            }
```

(This removes the `BadgeRowView` block and its `if badgeViewModel?.hasMultipleBadges == true` guard.)

- [ ] **Step 5: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. If a `.row` reference or `hasMultipleBadges`/`badgeRowHeight`/`badgeRowSpacing` usage remains, the error names the exact file:line — remove that reference.

- [ ] **Step 6: Manual visual verification**

Launch the app (`./build.sh` output or run from Xcode). Confirm on the collapsed notch:
1. **One active thing** → one logo left, one status right (unchanged from before); notch does **not** grow a second row.
2. **Several Claude sessions** → one crab logo left, one spinner right with a count chip (e.g. `3`).
3. **Different apps active** (e.g. Claude + media + pomodoro) → logos fan on the left with the highest-priority one hugging the notch/frontmost; statuses fan on the right, highest-priority hugging the notch.
4. **5+ distinct groups** → left shows 3 logos + a `+K` chip; right shows 3 statuses.

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Helpers/Constants.swift NemoNotch/Notch/Badge/BadgeViewModel.swift NemoNotch/Notch/Badge/BadgeIconView.swift NemoNotch/Notch/NotchView.swift
git commit -m "feat(badge): single-row stacked collapsed badges, drop second row"
```

---

### Task 3: Documentation

**Files:**
- Modify: `CLAUDE.md` (Badge Priority section + Empty-collapse debounce section)
- Modify: `README.md`, `README_CN.md` (collapsed-badge feature description, if present)

- [ ] **Step 1: Update `CLAUDE.md`**

In the **"Badge Priority (when notch is collapsed)"** section, add a paragraph after the priority list describing the single-row model:

```markdown
**Single-row stacked layout:** The collapsed notch never grows a second row. `activeBadgeItems` (priority-sorted) is folded by `BadgeGrouping.group` (`NemoNotch/Notch/Badge/BadgeGrouping.swift`) into `BadgeGroup`s keyed by **icon identity** (AI by source, agents by emoji, media/notification/pomodoro/calendar each their own key); each group's highest-priority member is its `representative` and `count` is its size. `BadgeGrouping.cluster(_:cap:)` caps the visible groups at `NotchConstants.badgeGroupCap` (4), folding extras into a `+K` chip (`BadgeCluster.overflow`). `CompactBadgesView` renders a **mirror fan**: left = overlapping logos (highest priority frontmost, hugging the notch), right = corresponding statuses (highest priority hugging the notch), with a count chip on any right status whose group `count > 1`. A single group of one is pixel-identical to the old single-item look. Tapping anywhere opens the highest-priority group's tab. `BadgeRowView` and the collapsed-notch vertical growth (`extraHeight`) were removed.
```

In the **"Empty-collapse debounce"** section, replace any mention of `displayedBadgeItems` driving a second row / `hasMultipleBadges` with the note that `displayedBadgeItems` now feeds `BadgeViewModel.badgeCluster`; the debounce behavior itself is unchanged.

- [ ] **Step 2: Update READMEs**

Search both READMEs for the collapsed-badge / notch-badge feature description:

Run: `grep -n "badge\|徽章\|收起\|collapsed" README.md README_CN.md`

Update any description of the collapsed badges to say a single stacked row (grouped logos + counts) instead of two rows. If neither README describes this, skip — no change needed.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md README_CN.md
git commit -m "docs: describe single-row stacked collapsed badges"
```

---

## Self-Review

**Spec coverage:**
- Grouping by icon identity → Task 1 `BadgeGrouping.key` / `group`. ✓
- `BadgeGroup` representative + count rule → Task 1 (`group` first-seen representative, tested). ✓
- Mirror layout (highest priority hugs notch both wings) → Task 2 `leftFan`/`rightFan` positions + z-index. ✓
- Count chip on right when count > 1 → Task 2 `rightFan` overlay. ✓
- Single group / count 1 identical to today → Task 2 (one logo left + one status right; verified in Step 6.1). ✓
- Overflow cap + "+K" → Task 1 `cluster` + Task 2 left `+K` chip. ✓
- Tap opens highest-priority group's tab → Task 2 `primary` + both fans call `onBadgeTap(primary)`. ✓
- Remove `BadgeRowView` + vertical growth → Task 2 Steps 3d, 4. ✓
- Files touched list (BadgeGrouping, BadgeViewModel, BadgeIconView, NotchView, Constants, tests, docs) → all covered by Tasks 1–3. ✓
- Verification (unit tests + manual) → Task 1 Step 4, Task 2 Step 6. ✓

**Placeholder scan:** No TBD/TODO; all code steps show complete code. ✓

**Type consistency:** `BadgeGroup`/`BadgeCluster`/`BadgeGrouping.cluster(_:cap:)` defined in Task 1 and consumed with matching names/signatures in Task 2. `BadgeViewModel.badgeCluster` produced in Task 2 Step 2, consumed in Task 2 Step 4. `CompactBadgesView` new `cluster:` parameter matches the call site. Removed symbols (`hasMultipleBadges`, `badgeRowHeight`, `badgeRowSpacing`, `.row`, `BadgeRowView`) are all deleted within Task 2's single atomic commit. ✓
