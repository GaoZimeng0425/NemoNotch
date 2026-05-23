# Pomodoro Timer + TODO — PR 1 (MVP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship PR 1 (MVP) of the pomodoro + TODO feature: three independent `@Observable` services (`TaskStore`, `PomodoroHistoryStore`, `PomodoroTimerService`), a centered-draggable QuickStart `NSPanel`, a Pomodoro Tab inside the notch (idle + active states), notch badge integration (🍅 emoji + pie chart), settings page with notification `PermissionCard`, and end-of-phase alerts (sound + system notification + ring pulse). Data model includes `tags` and `dueDate` fields from day one so PR 2 needs no migration; UI for those fields is out of scope here.

**Architecture:** Three services with single-direction callbacks — `TaskStore` doesn't know `PomodoroTimerService`; the timer notifies stores via injected closures on `naturalEnd` / `completeEarly` / `abandon`. State machine: `idle` → `running` ⇄ `paused` → `justFinished` → `idle | running(nextPhase)`. `autoFlow` lives in `RunningContext` (per-session, not global). Persistence: `~/.NemoNotch/tasks.json` + `~/.NemoNotch/pomodoro-history.json` (atomic write, full reload).

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPanel`, `NSEvent` monitors, `UNUserNotificationCenter`), `KeyboardShortcuts` library, Swift Testing (`import Testing`, `@Test`, `#expect`), CocoaLumberjack via `LogService`. macOS only.

**Spec:** [`2026-05-23-pomodoro-todo-design.md`](../specs/2026-05-23-pomodoro-todo-design.md)

---

## Reading the Spec

Each task lists the spec section it implements as "(spec §X)". The spec is the source of truth for design decisions; this plan is the source of truth for execution sequence and exact code. If they disagree, fix the plan to match the spec.

## Xcode Project File Setup

`NemoNotch.xcodeproj` uses explicit file references — adding a new `.swift` file requires entries in `project.pbxproj`. The simplest path:

1. Open `NemoNotch.xcodeproj` in Xcode
2. Right-click the relevant group in Project Navigator → **Add Files to "NemoNotch"...**
3. For `NemoNotch/**` files: target membership = **NemoNotch only** (uncheck NemoNotchTests)
4. For `NemoNotchTests/**` files: target membership = **NemoNotchTests only** (uncheck NemoNotch)

Programmatic alternative: clone PBXFileReference / PBXBuildFile / PBXGroup.children / PBXSourcesBuildPhase.files entries from a sibling `.swift` file in `project.pbxproj` (4 unique UUIDs per source file, 2 per test file since tests don't go in NemoNotch target). Verify with `xcodebuild build`; missing target membership manifests as "Cannot find type 'X' in scope" build errors despite the file existing on disk.

After every "create new file" step, **run a build** to catch target-membership mistakes before they cascade into later steps.

## Running Tests

Test framework: **Swift Testing** (not XCTest). Tests use `import Testing`, `@Test func name() { #expect(...) }`.

```bash
# Single test function
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/<TestType>/<testFunction>

# Whole suite
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS'

# Build only (catches type errors without running tests)
xcodebuild build \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS'
```

**TDD scope:** Pure logic (Models, Stores, `PomodoroTimerService` state machine) gets TDD. UI views (`PomodoroTab`, `QuickStartWindow`, `PomodoroSettingsView`) get visual QA only — launch the app and verify by inspection.

## File Inventory

**New files (PR 1 only):**

| Path | Responsibility |
|---|---|
| `NemoNotch/Models/TodoTask.swift` | TODO data model (incl. tags, dueDate fields unused in PR 1 UI) |
| `NemoNotch/Models/PomodoroPhase.swift` | `enum PomodoroPhase { idle, work, shortBreak, longBreak }` |
| `NemoNotch/Models/PomodoroRecord.swift` | Single completed/partial/abandoned record |
| `NemoNotch/Services/TaskStore.swift` | Persistent TODO list |
| `NemoNotch/Services/PomodoroHistoryStore.swift` | Persistent history records |
| `NemoNotch/Services/PomodoroTimerService.swift` | State machine + tick + end-alert pipeline + sleep handler |
| `NemoNotch/Services/NotificationPermissionMonitor.swift` | `UN` permission probing + request |
| `NemoNotch/Notch/QuickStartWindow.swift` | Borderless `NSPanel` subclass |
| `NemoNotch/Notch/QuickStartWindowController.swift` | Window lifecycle, click-outside monitor, previousApp restore |
| `NemoNotch/Notch/Badge/PomodoroPieView.swift` | Pie chart drawing (reused by badge + active block) |
| `NemoNotch/Tabs/PomodoroTab.swift` | Top-level Tab view (router between idle/active states) |
| `NemoNotch/Tabs/PomodoroTab+ActiveBlock.swift` | Big pie + task info + controls when running/paused/justFinished |
| `NemoNotch/Tabs/PomodoroTab+TodoList.swift` | TODO row rendering + interactions |
| `NemoNotch/Tabs/PomodoroTab+StatsPopover.swift` | Today/Week/All numeric summary popover |
| `NemoNotch/Tabs/PomodoroTab+EditSheet.swift` | Title/priority/notes editor (tags+dueDate UI deferred to PR 2) |
| `NemoNotch/Settings/PomodoroSettingsView.swift` | Durations + interval + toggles + hotkey recorders + PermissionCard |
| `NemoNotchTests/TodoTaskTests.swift` | Codable roundtrip + v1 JSON compat |
| `NemoNotchTests/TaskStoreTests.swift` | CRUD + persistence + sortIndex |
| `NemoNotchTests/PomodoroHistoryStoreTests.swift` | append + load + stats aggregation |
| `NemoNotchTests/PomodoroTimerServiceTests.swift` | State machine transitions + autoFlow progression |
| `NemoNotchTests/PomodoroStatsTests.swift` | Today/Week/All aggregation logic |

**Modified files:**

| Path | Change |
|---|---|
| `NemoNotch/Models/Tab.swift` | Add `.pomodoro` case (icon, title key, hotkey routing) |
| `NemoNotch/Models/AppSettings.swift` | Add 6 `pomodoro.*` UserDefaults-backed fields |
| `NemoNotch/Notch/Badge/BadgeItem.swift` | Add `.pomodoro(phase:)` case; renumber priority |
| `NemoNotch/Notch/Badge/BadgeIconView.swift` | Add pomodoro renderer for compactLeft/right/row |
| `NemoNotch/Notch/Badge/BadgeViewModel.swift` | Inject `PomodoroTimerService`; include pomodoro in `activeBadgeItems` |
| `NemoNotch/Notch/NotchView.swift` | `@Environment(PomodoroTimerService.self)`; pass to `BadgeViewModel` |
| `NemoNotch/NemoNotchApp.swift` | Create 3 services + permission monitor + QuickStartWindowController; inject environment; wire hotkey callbacks; applicationWillTerminate handler |
| `NemoNotch/Services/Hotkeys.swift` | Add `openPomodoro` + `openQuickStart` (no defaults) |
| `NemoNotch/Settings/SettingsView.swift` | Add Pomodoro sidebar entry |
| `NemoNotch/Localizable.xcstrings` | Add all PR 1 keys (per spec §Localization, PR 2-only keys deferred) |
| `README.md`, `README_CN.md` | Add feature blurb |
| `CLAUDE.md` | Mention `PomodoroTimerService`, update badge-priority order, note new hotkeys |
| `docs/macos-cookbook.md` | Add entries: "NSPanel 居中可拖拽" and "SwiftUI Path arc 饼图" |

---

## Task Index

| # | Title | Adds | Tests |
|---|---|---|---|
| 1 | Models (TodoTask + Phase + Record) | 3 model files | Codable roundtrip |
| 2 | TaskStore — CRUD + persistence | TaskStore | add/update/delete/load |
| 3 | TaskStore — sortIndex helpers + v1 JSON compat | extensions | sortIndex math, v1 backcompat |
| 4 | PomodoroHistoryStore | history store | append/load/range filter |
| 5 | AppSettings — 6 pomodoro fields | settings ext | (manual) |
| 6 | NotificationPermissionMonitor | service | (manual) |
| 7 | PomodoroTimerService — state types + skeleton | service stub | initial state idle |
| 8 | PomodoroTimerService — start / pause / resume | core transitions | 6 tests |
| 9 | PomodoroTimerService — completeEarly / abandon / naturalEnd | exit transitions | 6 tests |
| 10 | PomodoroTimerService — autoFlow phase progression | `advance()` | 8 tests |
| 11 | PomodoroTimerService — covering start | re-entry rule | 2 tests |
| 12 | PomodoroTimerService — tick timer + end-alert pipeline | runtime glue | (manual: sound + notification) |
| 13 | PomodoroTimerService — system sleep handler | observer | 1 test (abandon-on-sleep simulation) |
| 14 | Tab enum + Hotkey names | enum + name regs | — |
| 15 | PomodoroTab placeholder + Tab routing | empty Tab view | (manual: visible in TabBar) |
| 16 | AppDelegate wiring + applicationWillTerminate | service assembly | (manual: launches without crash) |
| 17 | PomodoroSettingsView — durations / interval / toggles | settings UI | — |
| 18 | PomodoroSettingsView — PermissionCard + hotkey recorders + sidebar entry | settings UI | — |
| 19 | PomodoroPieView shared component | drawing | (manual: renders at 14/88pt) |
| 20 | QuickStartWindow — NSPanel class | window class | — |
| 21 | QuickStartWindow content — title + priority + duration + mode + Enter | content view | (manual) |
| 22 | QuickStartWindow content — notes expand + override warning + validation | content view | (manual) |
| 23 | QuickStartWindowController | controller | (manual) |
| 24 | Hotkey registration in AppDelegate | hotkey wiring | (manual: Settings recorder binds) |
| 25 | PomodoroTab idle — stats strip + new button | UI | (manual) |
| 26 | PomodoroTab idle — TODO list rows | UI | (manual) |
| 27 | PomodoroTab row interactions — checkbox / ▶ fast-path / ⋯ menu | UI | (manual) |
| 28 | PomodoroTab edit sheet | UI | (manual) |
| 29 | PomodoroTab active block — big pie + task info | UI | (manual) |
| 30 | PomodoroTab active controls — pause/resume/completeEarly/abandon with inline confirms | UI | (manual) |
| 31 | Notch BadgeItem + priority renumber | model + tests | — |
| 32 | Notch BadgeIconView pomodoro renderer | UI | (manual) |
| 33 | Notch BadgeViewModel integration | wiring | (manual: badge appears) |
| 34 | PomodoroTab Stats popover (numbers) | UI + aggregation | aggregation tests |
| 35 | Localization keys | xcstrings | — |
| 36 | Documentation updates | README + CLAUDE.md + cookbook | — |

---

## Task 1: Models — TodoTask, PomodoroPhase, PomodoroRecord

(spec §Data Models)

**Files:**
- Create: `NemoNotch/Models/TodoTask.swift`
- Create: `NemoNotch/Models/PomodoroPhase.swift`
- Create: `NemoNotch/Models/PomodoroRecord.swift`
- Create: `NemoNotchTests/TodoTaskTests.swift`

- [ ] **Step 1: Write failing tests for Codable roundtrip + default values**

`NemoNotchTests/TodoTaskTests.swift`:

```swift
import Foundation
import Testing
@testable import NemoNotch

struct TodoTaskTests {
    @Test func defaultsForOptionalFields() {
        let t = TodoTask(
            id: UUID(),
            title: "x",
            priority: .medium,
            notes: "",
            tags: [],
            dueDate: nil,
            completedPomodoros: 0,
            isDone: false,
            createdAt: Date(),
            sortIndex: 1.0
        )
        #expect(t.tags == [])
        #expect(t.dueDate == nil)
        #expect(t.completedPomodoros == 0)
        #expect(t.isDone == false)
    }

    @Test func codableRoundtrip() throws {
        let t = TodoTask(
            id: UUID(),
            title: "写设计文档",
            priority: .high,
            notes: "spec → plan → code",
            tags: ["notch", "spec"],
            dueDate: Date(timeIntervalSince1970: 1_700_000_000),
            completedPomodoros: 3,
            isDone: false,
            createdAt: Date(timeIntervalSince1970: 1_690_000_000),
            sortIndex: 2.5
        )
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(TodoTask.self, from: data)
        #expect(decoded == t)
    }

    @Test func phaseRoundtrip() throws {
        for phase in [PomodoroPhase.idle, .work, .shortBreak, .longBreak] {
            let data = try JSONEncoder().encode(phase)
            let decoded = try JSONDecoder().decode(PomodoroPhase.self, from: data)
            #expect(decoded == phase)
        }
    }

    @Test func recordRoundtrip() throws {
        let r = PomodoroRecord(
            id: UUID(),
            taskID: UUID(),
            phase: .work,
            plannedDuration: 1500,
            actualDuration: 1500,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_500),
            outcome: .completed
        )
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(PomodoroRecord.self, from: data)
        #expect(decoded == r)
    }

    @Test func recordWithNilTaskID() throws {
        let r = PomodoroRecord(
            id: UUID(),
            taskID: nil,
            phase: .shortBreak,
            plannedDuration: 300,
            actualDuration: 180,
            startedAt: Date(),
            endedAt: Date(),
            outcome: .partial
        )
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(PomodoroRecord.self, from: data)
        #expect(decoded.taskID == nil)
        #expect(decoded.outcome == .partial)
    }
}
```

- [ ] **Step 2: Run tests, expect failure (types not in scope)**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/TodoTaskTests
```

Expected: Build fails — `Cannot find 'TodoTask' in scope`.

- [ ] **Step 3: Create `NemoNotch/Models/PomodoroPhase.swift`**

```swift
import Foundation

enum PomodoroPhase: String, Codable, Equatable, CaseIterable {
    case idle
    case work
    case shortBreak
    case longBreak
}
```

- [ ] **Step 4: Create `NemoNotch/Models/TodoTask.swift`**

```swift
import Foundation

struct TodoTask: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var priority: Priority
    var notes: String
    var tags: [String]
    var dueDate: Date?
    var completedPomodoros: Int
    var isDone: Bool
    let createdAt: Date
    var sortIndex: Double

    enum Priority: String, Codable, CaseIterable, Hashable {
        case low
        case medium
        case high
    }
}
```

- [ ] **Step 5: Create `NemoNotch/Models/PomodoroRecord.swift`**

```swift
import Foundation

struct PomodoroRecord: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let taskID: UUID?
    let phase: PomodoroPhase
    let plannedDuration: TimeInterval
    let actualDuration: TimeInterval
    let startedAt: Date
    let endedAt: Date
    let outcome: Outcome

    enum Outcome: String, Codable, Equatable, Hashable {
        case completed
        case partial
        case abandoned
    }
}
```

- [ ] **Step 6: Add all 4 files to Xcode targets**

In Xcode: drag the 3 model files into the **Models** group with target = NemoNotch only; drag the test file into **NemoNotchTests** group with target = NemoNotchTests only.

- [ ] **Step 7: Build to verify target membership**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Expected: succeeds.

- [ ] **Step 8: Run tests, expect pass**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/TodoTaskTests
```

Expected: 5 tests pass.

- [ ] **Step 9: Commit**

```bash
git add NemoNotch/Models/TodoTask.swift NemoNotch/Models/PomodoroPhase.swift \
        NemoNotch/Models/PomodoroRecord.swift NemoNotchTests/TodoTaskTests.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): add TodoTask, PomodoroPhase, PomodoroRecord models"
```

---

## Task 2: TaskStore — CRUD + persistence

(spec §Architecture · §Persistence)

**Files:**
- Create: `NemoNotch/Services/TaskStore.swift`
- Create: `NemoNotchTests/TaskStoreTests.swift`

`TaskStore` persists to a JSON file (`~/.NemoNotch/tasks.json` by default). Tests inject a temp file URL so they don't touch the user's real data.

- [ ] **Step 1: Write failing tests for CRUD + roundtrip**

`NemoNotchTests/TaskStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import NemoNotch

@MainActor
struct TaskStoreTests {
    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    @Test func initialStateEmpty() {
        let store = TaskStore(fileURL: tempURL())
        #expect(store.tasks.isEmpty)
    }

    @Test func addAppendsAndPersists() throws {
        let url = tempURL()
        let store = TaskStore(fileURL: url)
        let id = store.add(title: "write spec", priority: .high, notes: "n", tags: ["x"], dueDate: nil)
        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.id == id)
        #expect(store.tasks.first?.title == "write spec")
        #expect(store.tasks.first?.priority == .high)
        #expect(store.tasks.first?.sortIndex == 1.0)

        // Reload from disk
        let reloaded = TaskStore(fileURL: url)
        #expect(reloaded.tasks.count == 1)
        #expect(reloaded.tasks.first?.title == "write spec")
    }

    @Test func addSecondGetsLargerSortIndex() {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        let ta = store.tasks.first { $0.id == a }!
        let tb = store.tasks.first { $0.id == b }!
        #expect(ta.sortIndex < tb.sortIndex)
    }

    @Test func updateTitleAndPriority() {
        let store = TaskStore(fileURL: tempURL())
        let id = store.add(title: "old", priority: .low, notes: "", tags: [], dueDate: nil)
        store.update(id) { $0.title = "new"; $0.priority = .high }
        let t = store.tasks.first { $0.id == id }!
        #expect(t.title == "new")
        #expect(t.priority == .high)
    }

    @Test func markDoneTogglesIsDone() {
        let store = TaskStore(fileURL: tempURL())
        let id = store.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.markDone(id, isDone: true)
        #expect(store.tasks.first { $0.id == id }?.isDone == true)
        store.markDone(id, isDone: false)
        #expect(store.tasks.first { $0.id == id }?.isDone == false)
    }

    @Test func deleteRemovesTask() {
        let store = TaskStore(fileURL: tempURL())
        let id = store.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.delete(id)
        #expect(store.tasks.isEmpty)
    }

    @Test func incrementCompletedPomodoros() {
        let store = TaskStore(fileURL: tempURL())
        let id = store.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.incrementCompletedPomodoros(id)
        store.incrementCompletedPomodoros(id)
        #expect(store.tasks.first { $0.id == id }?.completedPomodoros == 2)
    }

    @Test func deleteOfMissingIDIsNoOp() {
        let store = TaskStore(fileURL: tempURL())
        store.delete(UUID())  // doesn't crash
        #expect(store.tasks.isEmpty)
    }
}
```

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/TaskStoreTests
```

Expected: `Cannot find 'TaskStore' in scope`.

- [ ] **Step 3: Create `NemoNotch/Services/TaskStore.swift`**

```swift
import Foundation

@MainActor
@Observable
final class TaskStore {
    private(set) var tasks: [TodoTask] = []
    private let fileURL: URL

    static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".NemoNotch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    init(fileURL: URL = TaskStore.defaultURL) {
        self.fileURL = fileURL
        load()
        LogService.info("TaskStore loaded \(tasks.count) tasks from \(fileURL.path)", category: "TaskStore")
    }

    @discardableResult
    func add(
        title: String,
        priority: TodoTask.Priority,
        notes: String,
        tags: [String],
        dueDate: Date?
    ) -> UUID {
        let maxIdx = tasks.map(\.sortIndex).max() ?? 0
        let task = TodoTask(
            id: UUID(),
            title: title,
            priority: priority,
            notes: notes,
            tags: tags,
            dueDate: dueDate,
            completedPomodoros: 0,
            isDone: false,
            createdAt: Date(),
            sortIndex: maxIdx + 1.0
        )
        tasks.append(task)
        save()
        return task.id
    }

    func update(_ id: UUID, _ mutate: (inout TodoTask) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[idx])
        save()
    }

    func markDone(_ id: UUID, isDone: Bool) {
        update(id) { $0.isDone = isDone }
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    func incrementCompletedPomodoros(_ id: UUID) {
        update(id) { $0.completedPomodoros += 1 }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            tasks = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            tasks = try JSONDecoder().decode([TodoTask].self, from: data)
        } catch {
            LogService.error("TaskStore load failed: \(error)", category: "TaskStore")
            tasks = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LogService.error("TaskStore save failed: \(error)", category: "TaskStore")
        }
    }
}
```

- [ ] **Step 4: Add to Xcode targets and build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

- [ ] **Step 5: Run tests, expect pass**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/TaskStoreTests
```

Expected: 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Services/TaskStore.swift NemoNotchTests/TaskStoreTests.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): add TaskStore with persistent CRUD"
```

---

## Task 3: TaskStore — sortIndex helpers + v1 JSON compat

(spec §Sorting Model · §Persistence)

**Files:**
- Modify: `NemoNotch/Services/TaskStore.swift` — add `move`, `pinToTop`, `nextSortIndex(insertBetween:)`
- Modify: `NemoNotchTests/TaskStoreTests.swift` — add tests

PR 1 doesn't expose drag UI, but the math + persistence shape needs to be right so PR 2 just wires UI to it. Also test v1 JSON compat (decoding a `tasks.json` from before `tags`/`dueDate` existed).

- [ ] **Step 1: Append failing tests to `TaskStoreTests.swift`**

```swift
    @Test func pinToTopPlacesAboveAllOthers() {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.pinToTop(b)
        let minIdx = store.tasks.map(\.sortIndex).min()!
        #expect(store.tasks.first { $0.id == b }?.sortIndex == minIdx)
        #expect(store.tasks.first { $0.id == a }!.sortIndex > minIdx)
    }

    @Test func moveBetweenComputesMidpoint() {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        let c = store.add(title: "c", priority: .medium, notes: "", tags: [], dueDate: nil)
        // Sort order: a (1.0) < b (2.0) < c (3.0). Move c between a and b → new sort = 1.5.
        store.move(c, between: a, and: b)
        let tc = store.tasks.first { $0.id == c }!
        #expect(tc.sortIndex == 1.5)
    }

    @Test func moveToTopUsesMinMinusOne() {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.move(b, between: nil, and: a)
        let tb = store.tasks.first { $0.id == b }!
        #expect(tb.sortIndex == 0.0)  // 1.0 - 1.0
    }

    @Test func moveToBottomUsesMaxPlusOne() {
        let store = TaskStore(fileURL: tempURL())
        let a = store.add(title: "a", priority: .medium, notes: "", tags: [], dueDate: nil)
        let b = store.add(title: "b", priority: .medium, notes: "", tags: [], dueDate: nil)
        store.move(a, between: b, and: nil)
        let ta = store.tasks.first { $0.id == a }!
        #expect(ta.sortIndex == 3.0)  // 2.0 + 1.0
    }

    @Test func loadsV1JSONWithoutTagsAndDueDate() throws {
        let url = tempURL()
        // v1 JSON shape: no `tags`, no `dueDate` keys
        let v1JSON = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "old task",
            "priority": "medium",
            "notes": "",
            "completedPomodoros": 5,
            "isDone": false,
            "createdAt": 1700000000,
            "sortIndex": 1.0
          }
        ]
        """.data(using: .utf8)!
        try v1JSON.write(to: url)

        let store = TaskStore(fileURL: url)
        #expect(store.tasks.count == 1)
        #expect(store.tasks.first?.title == "old task")
        #expect(store.tasks.first?.tags == [])
        #expect(store.tasks.first?.dueDate == nil)
    }
```

- [ ] **Step 2: Run, expect failure (`pinToTop` / `move` not defined; v1 decode fails on missing keys)**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/TaskStoreTests
```

- [ ] **Step 3: Make `TodoTask` `tags` / `dueDate` decode tolerant**

Modify `NemoNotch/Models/TodoTask.swift` — add custom `init(from:)` that defaults missing fields:

```swift
struct TodoTask: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var priority: Priority
    var notes: String
    var tags: [String]
    var dueDate: Date?
    var completedPomodoros: Int
    var isDone: Bool
    let createdAt: Date
    var sortIndex: Double

    enum Priority: String, Codable, CaseIterable, Hashable {
        case low, medium, high
    }

    init(
        id: UUID,
        title: String,
        priority: Priority,
        notes: String,
        tags: [String],
        dueDate: Date?,
        completedPomodoros: Int,
        isDone: Bool,
        createdAt: Date,
        sortIndex: Double
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.notes = notes
        self.tags = tags
        self.dueDate = dueDate
        self.completedPomodoros = completedPomodoros
        self.isDone = isDone
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        priority = try c.decode(Priority.self, forKey: .priority)
        notes = try c.decode(String.self, forKey: .notes)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        completedPomodoros = try c.decode(Int.self, forKey: .completedPomodoros)
        isDone = try c.decode(Bool.self, forKey: .isDone)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        sortIndex = try c.decode(Double.self, forKey: .sortIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, priority, notes, tags, dueDate
        case completedPomodoros, isDone, createdAt, sortIndex
    }
}
```

- [ ] **Step 4: Add sortIndex helpers to `TaskStore`**

Append inside the `TaskStore` class:

```swift
    func pinToTop(_ id: UUID) {
        let minIdx = tasks.map(\.sortIndex).min() ?? 1.0
        update(id) { $0.sortIndex = minIdx - 1.0 }
    }

    /// Reorder `id` to sit between `before` and `after` (either nil → edge).
    func move(_ id: UUID, between before: UUID?, and after: UUID?) {
        let beforeIdx = before.flatMap { idx in tasks.first { $0.id == idx }?.sortIndex }
        let afterIdx = after.flatMap { idx in tasks.first { $0.id == idx }?.sortIndex }

        let newIdx: Double
        switch (beforeIdx, afterIdx) {
        case let (b?, a?):
            newIdx = (b + a) / 2
            if abs(b - a) < 1e-9 {
                LogService.warn(
                    "TaskStore.move: sortIndex underflow risk (b=\(b) a=\(a)); rebalance TODO",
                    category: "TaskStore"
                )
            }
        case let (b?, nil):
            newIdx = b + 1.0
        case let (nil, a?):
            newIdx = a - 1.0
        case (nil, nil):
            newIdx = 1.0
        }
        update(id) { $0.sortIndex = newIdx }
    }
```

- [ ] **Step 5: Run tests, expect pass**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/TaskStoreTests
```

Expected: 13 tests pass.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Models/TodoTask.swift NemoNotch/Services/TaskStore.swift \
        NemoNotchTests/TaskStoreTests.swift
git commit -m "feat(pomodoro): TaskStore sortIndex helpers + v1 JSON compat"
```

---

## Task 4: PomodoroHistoryStore

(spec §Architecture · §Persistence)

**Files:**
- Create: `NemoNotch/Services/PomodoroHistoryStore.swift`
- Create: `NemoNotchTests/PomodoroHistoryStoreTests.swift`

History is append-only, persists to `~/.NemoNotch/pomodoro-history.json`, retained permanently (per spec §Goals). On launch, full load into memory.

- [ ] **Step 1: Write failing tests**

`NemoNotchTests/PomodoroHistoryStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import NemoNotch

@MainActor
struct PomodoroHistoryStoreTests {
    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pomodoro-history.json")
    }

    private func makeRecord(
        phase: PomodoroPhase = .work,
        outcome: PomodoroRecord.Outcome = .completed,
        taskID: UUID? = nil,
        endedAt: Date = Date()
    ) -> PomodoroRecord {
        PomodoroRecord(
            id: UUID(), taskID: taskID, phase: phase,
            plannedDuration: 1500, actualDuration: 1500,
            startedAt: endedAt.addingTimeInterval(-1500), endedAt: endedAt,
            outcome: outcome
        )
    }

    @Test func initialEmpty() {
        let store = PomodoroHistoryStore(fileURL: tempURL())
        #expect(store.records.isEmpty)
    }

    @Test func appendPersistsAcrossReload() {
        let url = tempURL()
        let store = PomodoroHistoryStore(fileURL: url)
        let r = makeRecord()
        store.append(r)
        #expect(store.records.count == 1)

        let reloaded = PomodoroHistoryStore(fileURL: url)
        #expect(reloaded.records.count == 1)
        #expect(reloaded.records.first?.id == r.id)
    }

    @Test func appendKeepsInsertionOrder() {
        let store = PomodoroHistoryStore(fileURL: tempURL())
        let r1 = makeRecord(endedAt: Date(timeIntervalSince1970: 100))
        let r2 = makeRecord(endedAt: Date(timeIntervalSince1970: 200))
        let r3 = makeRecord(endedAt: Date(timeIntervalSince1970: 300))
        store.append(r1)
        store.append(r2)
        store.append(r3)
        #expect(store.records.map(\.id) == [r1.id, r2.id, r3.id])
    }

    @Test func recordsInRangeFilters() {
        let store = PomodoroHistoryStore(fileURL: tempURL())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.append(makeRecord(endedAt: base.addingTimeInterval(-86400 * 2)))  // 2 days ago
        store.append(makeRecord(endedAt: base.addingTimeInterval(-3600)))       // 1 hour ago
        store.append(makeRecord(endedAt: base.addingTimeInterval(-60)))         // 1 minute ago

        let lastDay = store.records(in: base.addingTimeInterval(-86400)...base)
        #expect(lastDay.count == 2)
    }

    @Test func completedCountForTaskIgnoresAbandonedAndBreak() {
        let store = PomodoroHistoryStore(fileURL: tempURL())
        let taskID = UUID()
        store.append(makeRecord(phase: .work, outcome: .completed, taskID: taskID))
        store.append(makeRecord(phase: .work, outcome: .partial, taskID: taskID))
        store.append(makeRecord(phase: .work, outcome: .abandoned, taskID: taskID))
        store.append(makeRecord(phase: .shortBreak, outcome: .completed, taskID: taskID))
        store.append(makeRecord(phase: .work, outcome: .completed, taskID: UUID()))  // other task

        #expect(store.completedWorkCount(for: taskID) == 2)  // completed + partial of THIS task, work phase only
    }
}
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Create `NemoNotch/Services/PomodoroHistoryStore.swift`**

```swift
import Foundation

@MainActor
@Observable
final class PomodoroHistoryStore {
    private(set) var records: [PomodoroRecord] = []
    private let fileURL: URL

    static var defaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".NemoNotch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pomodoro-history.json")
    }

    init(fileURL: URL = PomodoroHistoryStore.defaultURL) {
        self.fileURL = fileURL
        load()
        LogService.info(
            "PomodoroHistoryStore loaded \(records.count) records",
            category: "PomodoroHistoryStore"
        )
    }

    func append(_ record: PomodoroRecord) {
        records.append(record)
        save()
    }

    func records(in range: ClosedRange<Date>) -> [PomodoroRecord] {
        records.filter { range.contains($0.endedAt) }
    }

    /// Number of work-phase records (completed OR partial) for a given task.
    /// Abandoned and non-work phases are excluded.
    func completedWorkCount(for taskID: UUID) -> Int {
        records.filter {
            $0.taskID == taskID &&
            $0.phase == .work &&
            ($0.outcome == .completed || $0.outcome == .partial)
        }.count
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try JSONDecoder().decode([PomodoroRecord].self, from: data)
        } catch {
            LogService.error(
                "PomodoroHistoryStore load failed: \(error)",
                category: "PomodoroHistoryStore"
            )
            records = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LogService.error(
                "PomodoroHistoryStore save failed: \(error)",
                category: "PomodoroHistoryStore"
            )
        }
    }
}
```

- [ ] **Step 4: Add files to Xcode targets, build, run tests**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroHistoryStoreTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/PomodoroHistoryStore.swift \
        NemoNotchTests/PomodoroHistoryStoreTests.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): add PomodoroHistoryStore with stats helpers"
```

---

## Task 5: AppSettings — 6 pomodoro fields

(spec §AppSettings 新增字段)

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift`

No new tests — settings is plumbing.

- [ ] **Step 1: Add fields and initialization to `AppSettings`**

In `NemoNotch/Models/AppSettings.swift`, add 6 stored properties just below `language`:

```swift
    var pomodoroWorkDuration: TimeInterval {
        didSet { UserDefaults.standard.set(pomodoroWorkDuration, forKey: "pomodoro.workDuration") }
    }

    var pomodoroShortBreakDuration: TimeInterval {
        didSet { UserDefaults.standard.set(pomodoroShortBreakDuration, forKey: "pomodoro.shortBreakDuration") }
    }

    var pomodoroLongBreakDuration: TimeInterval {
        didSet { UserDefaults.standard.set(pomodoroLongBreakDuration, forKey: "pomodoro.longBreakDuration") }
    }

    var pomodoroLongBreakInterval: Int {
        didSet { UserDefaults.standard.set(pomodoroLongBreakInterval, forKey: "pomodoro.longBreakInterval") }
    }

    var pomodoroSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(pomodoroSoundEnabled, forKey: "pomodoro.soundEnabled") }
    }

    var pomodoroNotificationEnabled: Bool {
        didSet { UserDefaults.standard.set(pomodoroNotificationEnabled, forKey: "pomodoro.notificationEnabled") }
    }
```

- [ ] **Step 2: Initialize defaults in `init()` (append after the existing `language` init line)**

```swift
        let workDefault: TimeInterval = 25 * 60
        let shortDefault: TimeInterval = 5 * 60
        let longDefault: TimeInterval = 15 * 60
        pomodoroWorkDuration = UserDefaults.standard.object(forKey: "pomodoro.workDuration") as? TimeInterval ?? workDefault
        pomodoroShortBreakDuration = UserDefaults.standard.object(forKey: "pomodoro.shortBreakDuration") as? TimeInterval ?? shortDefault
        pomodoroLongBreakDuration = UserDefaults.standard.object(forKey: "pomodoro.longBreakDuration") as? TimeInterval ?? longDefault
        pomodoroLongBreakInterval = UserDefaults.standard.object(forKey: "pomodoro.longBreakInterval") as? Int ?? 4
        pomodoroSoundEnabled = UserDefaults.standard.object(forKey: "pomodoro.soundEnabled") as? Bool ?? true
        pomodoroNotificationEnabled = UserDefaults.standard.object(forKey: "pomodoro.notificationEnabled") as? Bool ?? true
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Models/AppSettings.swift
git commit -m "feat(pomodoro): add 6 pomodoro.* AppSettings fields"
```

---

## Task 6: NotificationPermissionMonitor

(spec §Settings, Permissions, End Alerts — 通知权限)

**Files:**
- Create: `NemoNotch/Services/NotificationPermissionMonitor.swift`

No unit tests — `UNUserNotificationCenter` is a system API; verify manually by toggling permission in System Settings.

- [ ] **Step 1: Create `NemoNotch/Services/NotificationPermissionMonitor.swift`**

```swift
import AppKit
import UserNotifications

@MainActor
@Observable
final class NotificationPermissionMonitor {
    var status: UNAuthorizationStatus = .notDetermined

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        LogService.debug(
            "NotificationPermissionMonitor.refresh → \(status.rawValue)",
            category: "NotificationPermission"
        )
    }

    func request() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            await refresh()
        } catch {
            LogService.warn(
                "Notification authorization request failed: \(error)",
                category: "NotificationPermission"
            )
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

- [ ] **Step 2: Add to Xcode target, build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/NotificationPermissionMonitor.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): add NotificationPermissionMonitor"
```

---

## Task 7: PomodoroTimerService — state types + skeleton

(spec §State Machine)

**Files:**
- Create: `NemoNotch/Services/PomodoroTimerService.swift`
- Create: `NemoNotchTests/PomodoroTimerServiceTests.swift`

Build the state types and the empty service. No transitions yet — just constructor, initial state, and dependencies. Subsequent tasks layer in behavior.

`triggerEndAlerts` is a no-op closure now; Task 12 swaps it for the real one.

- [ ] **Step 1: Write failing test for initial state**

`NemoNotchTests/PomodoroTimerServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import NemoNotch

@MainActor
struct PomodoroTimerServiceTests {
    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func makeService() -> (PomodoroTimerService, TaskStore, PomodoroHistoryStore, AppSettings) {
        let tasks = TaskStore(fileURL: tempURL("tasks.json"))
        let history = PomodoroHistoryStore(fileURL: tempURL("history.json"))
        let settings = AppSettings()
        settings.pomodoroSoundEnabled = false
        settings.pomodoroNotificationEnabled = false
        let service = PomodoroTimerService(
            taskStore: tasks,
            historyStore: history,
            appSettings: settings,
            permissionMonitor: nil
        )
        return (service, tasks, history, settings)
    }

    @Test func initialStateIsIdle() {
        let (service, _, _, _) = makeService()
        if case .idle = service.state {} else {
            Issue.record("expected idle, got \(service.state)")
        }
        #expect(service.workCounterSinceLongBreak == 0)
        #expect(service.currentPhase == .idle)
        #expect(service.remainingSeconds == 0)
        #expect(service.state.isActive == false)
    }
}
```

- [ ] **Step 2: Run, expect failure**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroTimerServiceTests/initialStateIsIdle
```

- [ ] **Step 3: Create `NemoNotch/Services/PomodoroTimerService.swift`**

```swift
import AppKit
import Foundation
import UserNotifications

@MainActor
@Observable
final class PomodoroTimerService {

    // MARK: - State types

    enum State: Equatable {
        case idle
        case running(RunningContext)
        case paused(RunningContext)
        case justFinished(FinishedContext)

        var isActive: Bool {
            switch self {
            case .idle: return false
            case .running, .paused, .justFinished: return true
            }
        }
    }

    struct RunningContext: Equatable {
        let phase: PomodoroPhase
        let taskID: UUID?
        let plannedDuration: TimeInterval
        var startedAt: Date
        var accumulatedElapsed: TimeInterval
        let autoFlow: Bool
    }

    struct FinishedContext: Equatable {
        let phase: PomodoroPhase
        let taskID: UUID?
        let outcome: PomodoroRecord.Outcome
    }

    // MARK: - Observable

    private(set) var state: State = .idle
    private(set) var workCounterSinceLongBreak: Int = 0
    private(set) var pulseToken: UUID = UUID()
    private(set) var lastUsedDuration: TimeInterval = 25 * 60

    // MARK: - Dependencies

    private let taskStore: TaskStore
    private let historyStore: PomodoroHistoryStore
    private let appSettings: AppSettings
    private let permissionMonitor: NotificationPermissionMonitor?

    // MARK: - Init

    init(
        taskStore: TaskStore,
        historyStore: PomodoroHistoryStore,
        appSettings: AppSettings,
        permissionMonitor: NotificationPermissionMonitor?
    ) {
        self.taskStore = taskStore
        self.historyStore = historyStore
        self.appSettings = appSettings
        self.permissionMonitor = permissionMonitor
        LogService.info("PomodoroTimerService init", category: "PomodoroTimer")
    }

    // MARK: - Computed

    var currentPhase: PomodoroPhase {
        switch state {
        case .idle: return .idle
        case let .running(ctx), let .paused(ctx): return ctx.phase
        case let .justFinished(ctx): return ctx.phase
        }
    }

    var remainingSeconds: Int {
        switch state {
        case .idle: return 0
        case let .running(ctx):
            let elapsed = ctx.accumulatedElapsed + Date().timeIntervalSince(ctx.startedAt)
            return max(0, Int((ctx.plannedDuration - elapsed).rounded(.up)))
        case let .paused(ctx):
            return max(0, Int((ctx.plannedDuration - ctx.accumulatedElapsed).rounded(.up)))
        case .justFinished: return 0
        }
    }
}
```

- [ ] **Step 4: Add to Xcode target, build, run test**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroTimerServiceTests/initialStateIsIdle
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/PomodoroTimerService.swift \
        NemoNotchTests/PomodoroTimerServiceTests.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): PomodoroTimerService skeleton + initial state"
```

---

## Task 8: PomodoroTimerService — start / pause / resume

(spec §State Machine — 转移表)

**Files:**
- Modify: `NemoNotch/Services/PomodoroTimerService.swift`
- Modify: `NemoNotchTests/PomodoroTimerServiceTests.swift`

- [ ] **Step 1: Append failing tests**

```swift
    @Test func startFromIdleEntersRunningWork() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        guard case let .running(ctx) = service.state else {
            Issue.record("expected running, got \(service.state)")
            return
        }
        #expect(ctx.phase == .work)
        #expect(ctx.taskID == nil)
        #expect(ctx.plannedDuration == 60)
        #expect(ctx.accumulatedElapsed == 0)
        #expect(ctx.autoFlow == true)
    }

    @Test func startWithTaskCarriesTaskID() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.start(taskID: id, duration: 60, autoFlow: false)
        guard case let .running(ctx) = service.state else {
            Issue.record("not running")
            return
        }
        #expect(ctx.taskID == id)
        #expect(ctx.autoFlow == false)
    }

    @Test func startUpdatesLastUsedDuration() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 45 * 60, autoFlow: true)
        #expect(service.lastUsedDuration == 45 * 60)
    }

    @Test func pauseFromRunningEntersPaused() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.pause()
        guard case .paused = service.state else {
            Issue.record("not paused")
            return
        }
    }

    @Test func pausePreservesPartialElapsed() async throws {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        try await Task.sleep(for: .milliseconds(30))
        service.pause()
        guard case let .paused(ctx) = service.state else {
            Issue.record("not paused")
            return
        }
        #expect(ctx.accumulatedElapsed > 0)
        #expect(ctx.accumulatedElapsed < 1.0)
    }

    @Test func resumeFromPausedEntersRunning() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.pause()
        service.resume()
        guard case .running = service.state else {
            Issue.record("not running")
            return
        }
    }

    @Test func pauseFromIdleNoOp() {
        let (service, _, _, _) = makeService()
        service.pause()
        if case .idle = service.state {} else {
            Issue.record("idle pause changed state")
        }
    }

    @Test func resumeFromIdleNoOp() {
        let (service, _, _, _) = makeService()
        service.resume()
        if case .idle = service.state {} else {
            Issue.record("idle resume changed state")
        }
    }
```

- [ ] **Step 2: Run, expect failure (`start` / `pause` / `resume` not defined)**

- [ ] **Step 3: Add `start` / `pause` / `resume` to `PomodoroTimerService`**

Append inside the class:

```swift
    // MARK: - Transitions

    func start(taskID: UUID?, duration: TimeInterval, autoFlow: Bool) {
        // If already running/paused, overwrite by writing a partial record first.
        if case .running = state {
            completeEarly()
        } else if case .paused = state {
            completeEarly()
        }
        lastUsedDuration = duration
        let ctx = RunningContext(
            phase: .work,
            taskID: taskID,
            plannedDuration: duration,
            startedAt: Date(),
            accumulatedElapsed: 0,
            autoFlow: autoFlow
        )
        state = .running(ctx)
        LogService.info(
            "Pomodoro start: phase=\(ctx.phase) duration=\(duration) autoFlow=\(autoFlow) task=\(taskID?.uuidString ?? "nil")",
            category: "PomodoroTimer"
        )
    }

    func pause() {
        guard case var .running(ctx) = state else { return }
        ctx.accumulatedElapsed += Date().timeIntervalSince(ctx.startedAt)
        state = .paused(ctx)
        LogService.debug("Pomodoro pause @ \(ctx.accumulatedElapsed)s", category: "PomodoroTimer")
    }

    func resume() {
        guard case var .paused(ctx) = state else { return }
        ctx.startedAt = Date()
        state = .running(ctx)
        LogService.debug("Pomodoro resume", category: "PomodoroTimer")
    }
```

`completeEarly()` is referenced but not yet implemented — for now, **add a placeholder** that just resets to idle so Task 8 tests pass. It'll be replaced in Task 9.

Add this above `start`:

```swift
    // Placeholder — real impl in Task 9.
    func completeEarly() {
        state = .idle
    }
```

- [ ] **Step 4: Run tests, expect pass**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroTimerServiceTests
```

Expected: 9 tests pass (1 from Task 7 + 8 new).

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/PomodoroTimerService.swift NemoNotchTests/PomodoroTimerServiceTests.swift
git commit -m "feat(pomodoro): start/pause/resume transitions"
```

---

## Task 9: PomodoroTimerService — completeEarly / abandon / naturalEnd

(spec §State Machine 转移表 — partial / abandoned / completed 写库规则)

**Files:**
- Modify: `NemoNotch/Services/PomodoroTimerService.swift`
- Modify: `NemoNotchTests/PomodoroTimerServiceTests.swift`

Three exit transitions land here. All three move state to `.justFinished(...)` with the appropriate outcome, write a `PomodoroRecord` to history, and (for work phase, non-abandoned only) bump `task.completedPomodoros`. `abandon` skips end-alerts; `completeEarly` and `naturalEnd` invoke them via the `triggerEndAlerts` no-op stub for now (Task 12 swaps it).

- [ ] **Step 1: Append failing tests**

```swift
    @Test func completeEarlyFromRunningWritesPartial() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.completeEarly()
        guard case let .justFinished(ctx) = service.state else {
            Issue.record("not justFinished")
            return
        }
        #expect(ctx.outcome == .partial)
        #expect(history.records.count == 1)
        #expect(history.records.first?.outcome == .partial)
    }

    @Test func completeEarlyOnWorkIncrementsTaskCount() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.start(taskID: id, duration: 60, autoFlow: true)
        service.completeEarly()
        #expect(tasks.tasks.first { $0.id == id }?.completedPomodoros == 1)
    }

    @Test func abandonWritesAbandonedRecord() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.abandon()
        guard case let .justFinished(ctx) = service.state else {
            Issue.record("not justFinished")
            return
        }
        #expect(ctx.outcome == .abandoned)
        #expect(history.records.first?.outcome == .abandoned)
    }

    @Test func abandonDoesNotIncrementTaskCount() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.start(taskID: id, duration: 60, autoFlow: true)
        service.abandon()
        #expect(tasks.tasks.first { $0.id == id }?.completedPomodoros == 0)
    }

    @Test func naturalEndWritesCompleted() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        guard case let .justFinished(ctx) = service.state else {
            Issue.record("not justFinished")
            return
        }
        #expect(ctx.outcome == .completed)
        #expect(history.records.first?.outcome == .completed)
        #expect(history.records.first?.actualDuration == 60)
    }

    @Test func naturalEndOnWorkIncrementsTaskCount() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        service.start(taskID: id, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        #expect(tasks.tasks.first { $0.id == id }?.completedPomodoros == 1)
    }

    @Test func breakNaturalEndDoesNotIncrementTaskCount() {
        let (service, tasks, _, _) = makeService()
        let id = tasks.add(title: "x", priority: .medium, notes: "", tags: [], dueDate: nil)
        // Start a break manually for testing
        service.startForTesting(phase: .shortBreak, taskID: id, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        #expect(tasks.tasks.first { $0.id == id }?.completedPomodoros == 0)
    }

    @Test func completeEarlyFromPausedAlsoWorks() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.pause()
        service.completeEarly()
        #expect(history.records.first?.outcome == .partial)
    }
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Replace the placeholder `completeEarly` and add `abandon` + `naturalEnd` infrastructure**

Replace the placeholder `completeEarly` and add the others. Full replacement of the transitions section:

```swift
    // MARK: - Transitions (exits)

    func completeEarly() {
        finish(outcome: .partial)
    }

    func abandon() {
        finish(outcome: .abandoned)
    }

    /// Called when the tick timer detects `elapsed >= planned`. Or from tests directly.
    private func naturalEnd() {
        finish(outcome: .completed)
    }

    /// Test hook: pretend the tick timer fired naturalEnd.
    /// Not for production callers.
    func simulateNaturalEnd() {
        naturalEnd()
    }

    /// Test hook: start in an arbitrary phase (so tests can exercise break-phase rules
    /// without having to drive a whole work→break sequence).
    func startForTesting(phase: PomodoroPhase, taskID: UUID?, duration: TimeInterval, autoFlow: Bool) {
        if case .running = state { completeEarly() }
        else if case .paused = state { completeEarly() }
        let ctx = RunningContext(
            phase: phase,
            taskID: taskID,
            plannedDuration: duration,
            startedAt: Date(),
            accumulatedElapsed: 0,
            autoFlow: autoFlow
        )
        state = .running(ctx)
    }

    private func finish(outcome: PomodoroRecord.Outcome) {
        let ctx: RunningContext
        switch state {
        case let .running(c): ctx = c
        case let .paused(c): ctx = c
        default: return
        }

        let actualElapsed: TimeInterval = {
            switch outcome {
            case .completed: return ctx.plannedDuration
            case .partial, .abandoned:
                let live: TimeInterval
                if case .running = state {
                    live = ctx.accumulatedElapsed + Date().timeIntervalSince(ctx.startedAt)
                } else {
                    live = ctx.accumulatedElapsed
                }
                return min(live, ctx.plannedDuration)
            }
        }()

        let record = PomodoroRecord(
            id: UUID(),
            taskID: ctx.taskID,
            phase: ctx.phase,
            plannedDuration: ctx.plannedDuration,
            actualDuration: actualElapsed,
            startedAt: ctx.startedAt.addingTimeInterval(-ctx.accumulatedElapsed),
            endedAt: Date(),
            outcome: outcome
        )
        historyStore.append(record)

        // Bump task counter only for work-phase non-abandoned outcomes.
        if ctx.phase == .work,
           outcome != .abandoned,
           let taskID = ctx.taskID {
            taskStore.incrementCompletedPomodoros(taskID)
        }

        state = .justFinished(FinishedContext(
            phase: ctx.phase,
            taskID: ctx.taskID,
            outcome: outcome
        ))
        LogService.info(
            "Pomodoro finish: phase=\(ctx.phase) outcome=\(outcome) actual=\(actualElapsed)",
            category: "PomodoroTimer"
        )

        // End-alerts: skipped on abandon; real impl wired in Task 12.
        if outcome != .abandoned {
            triggerEndAlerts(phase: ctx.phase, taskID: ctx.taskID, outcome: outcome)
        }
    }

    /// Stub. Task 12 replaces with sound + UN notification + pulseToken.
    private func triggerEndAlerts(
        phase: PomodoroPhase,
        taskID: UUID?,
        outcome: PomodoroRecord.Outcome
    ) {
        // no-op for now
    }
```

Now **delete the old placeholder** `completeEarly` from Task 8 — it's been replaced above.

- [ ] **Step 4: Run tests, expect pass**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroTimerServiceTests
```

Expected: 17 tests pass.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/PomodoroTimerService.swift NemoNotchTests/PomodoroTimerServiceTests.swift
git commit -m "feat(pomodoro): completeEarly/abandon/naturalEnd with history + task counter"
```

---

## Task 10: PomodoroTimerService — autoFlow phase progression

(spec §State Machine — `advance()` 规则)

**Files:**
- Modify: `NemoNotch/Services/PomodoroTimerService.swift`
- Modify: `NemoNotchTests/PomodoroTimerServiceTests.swift`

When `state == .justFinished`, the service calls `advance()` to transition to either the next phase (autoFlow=true, completed outcome) or idle. Phase rules: work → short/long break (every Nth long), short → work, long → work + reset counter. Partial / abandoned outcomes always go to idle.

- [ ] **Step 1: Append failing tests**

```swift
    @Test func advanceFromIdleNoOp() {
        let (service, _, _, _) = makeService()
        service.advance()
        if case .idle = service.state {} else {
            Issue.record("idle advance changed state")
        }
    }

    @Test func advanceAfterAbandonGoesIdle() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.abandon()
        service.advance()
        if case .idle = service.state {} else {
            Issue.record("not idle after abandon→advance")
        }
    }

    @Test func advanceAfterPartialGoesIdleEvenIfAutoFlow() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.completeEarly()
        service.advance()
        if case .idle = service.state {} else {
            Issue.record("partial advance with autoFlow should still go idle")
        }
    }

    @Test func advanceAfterCompleteWithoutAutoFlowGoesIdle() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: false)
        service.simulateNaturalEnd()
        service.advance()
        if case .idle = service.state {} else {
            Issue.record("single-mode complete advance should go idle")
        }
    }

    @Test func advanceAfterWorkCompleteWithAutoFlowGoesShortBreak() {
        let (service, _, _, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.simulateNaturalEnd()
        service.advance()
        guard case let .running(ctx) = service.state else {
            Issue.record("not running")
            return
        }
        #expect(ctx.phase == .shortBreak)
        #expect(service.workCounterSinceLongBreak == 1)
    }

    @Test func longBreakTriggeredEveryNthWork() {
        let (service, _, _, settings) = makeService()
        settings.pomodoroLongBreakInterval = 4

        for i in 1...4 {
            service.start(taskID: nil, duration: 60, autoFlow: true)
            service.simulateNaturalEnd()
            service.advance()
            if i < 4 {
                guard case let .running(ctx) = service.state else {
                    Issue.record("step \(i): not running")
                    return
                }
                #expect(ctx.phase == .shortBreak, "step \(i): expected shortBreak")
                // finish the short break to get back to work for the next iteration
                service.simulateNaturalEnd()
                service.advance()
                guard case let .running(ctx2) = service.state else {
                    Issue.record("step \(i): not running after break")
                    return
                }
                #expect(ctx2.phase == .work)
            }
        }
        guard case let .running(ctx) = service.state else {
            Issue.record("not running after 4th work")
            return
        }
        #expect(ctx.phase == .longBreak)
        #expect(service.workCounterSinceLongBreak == 4)
    }

    @Test func longBreakCompleteResetsCounter() {
        let (service, _, _, settings) = makeService()
        settings.pomodoroLongBreakInterval = 2

        // 2 work + breaks to land in longBreak
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.simulateNaturalEnd(); service.advance()  // → shortBreak (counter=1)
        service.simulateNaturalEnd(); service.advance()  // → work
        service.simulateNaturalEnd(); service.advance()  // → longBreak (counter=2)

        guard case let .running(longCtx) = service.state else {
            Issue.record("expected longBreak running")
            return
        }
        #expect(longCtx.phase == .longBreak)

        service.simulateNaturalEnd(); service.advance()  // → work, counter reset
        #expect(service.workCounterSinceLongBreak == 0)
        guard case let .running(workCtx) = service.state else {
            Issue.record("expected work running")
            return
        }
        #expect(workCtx.phase == .work)
    }
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Implement `advance()`**

Append inside the class:

```swift
    /// Drive the state machine forward from `.justFinished`. Called by Task 12's
    /// 0.6s post-finish timer, or by tests directly.
    func advance() {
        guard case let .justFinished(ctx) = state else { return }

        // Partial / abandoned → idle, regardless of autoFlow.
        guard ctx.outcome == .completed else {
            state = .idle
            return
        }

        // Need autoFlow to continue.
        // Re-fetch the autoFlow value: it was captured on the run that just finished.
        // Since we don't keep it on FinishedContext, infer from where we came from:
        // we know justFinished's predecessor was running/paused with autoFlow set.
        // Simplest: re-derive by checking the most recent run's autoFlow via lastAutoFlow.
        guard lastAutoFlow else {
            state = .idle
            return
        }

        let nextPhase: PomodoroPhase
        let nextDuration: TimeInterval
        switch ctx.phase {
        case .work:
            workCounterSinceLongBreak += 1
            if workCounterSinceLongBreak % appSettings.pomodoroLongBreakInterval == 0 {
                nextPhase = .longBreak
                nextDuration = appSettings.pomodoroLongBreakDuration
            } else {
                nextPhase = .shortBreak
                nextDuration = appSettings.pomodoroShortBreakDuration
            }
        case .shortBreak:
            nextPhase = .work
            nextDuration = appSettings.pomodoroWorkDuration
        case .longBreak:
            workCounterSinceLongBreak = 0
            nextPhase = .work
            nextDuration = appSettings.pomodoroWorkDuration
        case .idle:
            state = .idle
            return
        }

        state = .running(RunningContext(
            phase: nextPhase,
            taskID: nil,  // Subsequent phases inherit no task (break has no task)
            plannedDuration: nextDuration,
            startedAt: Date(),
            accumulatedElapsed: 0,
            autoFlow: true
        ))
        LogService.info(
            "Pomodoro advance: → \(nextPhase) (counter=\(workCounterSinceLongBreak))",
            category: "PomodoroTimer"
        )
    }
```

`lastAutoFlow` needs to be tracked: add a private stored property and set it in `start` and `finish`. Add near `lastUsedDuration`:

```swift
    private(set) var lastAutoFlow: Bool = false
```

In `start`, set `lastAutoFlow = autoFlow` after the existing `lastUsedDuration = duration`.

In `startForTesting`, also set `lastAutoFlow = autoFlow`.

In `finish`, do not modify `lastAutoFlow` (we want to preserve the value through justFinished). Actually we need to capture autoFlow at finish-time since later runs would clobber. Capture it on the running context just before transitioning to justFinished:

Actually simpler — restructure `finish` to keep autoFlow accessible. Modify the `state = .justFinished(...)` line in `finish` to **also keep `lastAutoFlow = ctx.autoFlow`** before that:

```swift
        lastAutoFlow = ctx.autoFlow
        state = .justFinished(FinishedContext(
            phase: ctx.phase,
            taskID: ctx.taskID,
            outcome: outcome
        ))
```

Done. `lastAutoFlow` is the predecessor run's flag, available to `advance()`.

- [ ] **Step 4: Run tests, expect pass**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroTimerServiceTests
```

Expected: 24 tests pass.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/PomodoroTimerService.swift NemoNotchTests/PomodoroTimerServiceTests.swift
git commit -m "feat(pomodoro): autoFlow phase progression (advance)"
```

---

## Task 11: PomodoroTimerService — covering start (re-entry)

(spec §State Machine — `start(...)` 在已 running 时先 `completeEarly()` 覆盖)

**Files:**
- Modify: `NemoNotchTests/PomodoroTimerServiceTests.swift`

`start()` already calls `completeEarly()` when state is running/paused (added in Task 8). Now verify it via tests — there were no tests for it before.

- [ ] **Step 1: Append failing tests**

```swift
    @Test func startWhileRunningOverwritesAsPartial() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.start(taskID: nil, duration: 30, autoFlow: true)  // override
        // First run should be recorded as partial.
        #expect(history.records.count == 1)
        #expect(history.records.first?.outcome == .partial)
        // New run is active.
        guard case let .running(ctx) = service.state else {
            Issue.record("not running after override")
            return
        }
        #expect(ctx.plannedDuration == 30)
    }

    @Test func startWhilePausedOverwritesAsPartial() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.pause()
        service.start(taskID: nil, duration: 30, autoFlow: true)
        #expect(history.records.count == 1)
        #expect(history.records.first?.outcome == .partial)
        guard case .running = service.state else {
            Issue.record("not running after override-from-paused")
            return
        }
    }
```

- [ ] **Step 2: Run, expect pass (already implemented in Task 8, just verifying)**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroTimerServiceTests
```

Expected: 26 tests pass.

- [ ] **Step 3: Commit**

```bash
git add NemoNotchTests/PomodoroTimerServiceTests.swift
git commit -m "test(pomodoro): covering start writes previous as partial"
```

---

## Task 12: PomodoroTimerService — tick timer + end-alert pipeline

(spec §State Machine — `justFinished` 过渡态 · §结束提醒三件套)

**Files:**
- Modify: `NemoNotch/Services/PomodoroTimerService.swift`

Two pieces wire up the runtime side:

1. **Tick timer**: a 1-second `Timer` fires while `state == .running` and calls `naturalEnd()` once `remainingSeconds == 0`. Started in `start`, stopped on every state transition that isn't `running`.
2. **End-alert pipeline**: replaces the Task 9 no-op `triggerEndAlerts` with the real `NSSound` + `UNNotificationRequest` + `pulseToken` triple. Plus a 0.6s timer that auto-advances out of `justFinished`.

No new unit tests — both pieces are runtime / system-API glue. Verified manually.

- [ ] **Step 1: Add tick + advance timers as stored properties**

Inside `PomodoroTimerService`, near the other stored properties:

```swift
    private var tickTimer: Timer?
    private var advanceTimer: Timer?
```

- [ ] **Step 2: Add timer control helpers**

Append in the class:

```swift
    // MARK: - Tick timer

    private func startTickTimer() {
        stopTickTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTick()
            }
        }
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func handleTick() {
        guard case .running = state else {
            stopTickTimer()
            return
        }
        if remainingSeconds == 0 {
            naturalEnd()
        }
    }

    // MARK: - Auto-advance out of justFinished

    private func scheduleAdvance() {
        advanceTimer?.invalidate()
        advanceTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advance()
                self?.startTickTimerIfRunning()
            }
        }
    }

    private func startTickTimerIfRunning() {
        if case .running = state {
            startTickTimer()
        }
    }
```

- [ ] **Step 3: Hook timers into transitions**

In `start` (just before the closing brace), append:

```swift
        startTickTimer()
```

In `startForTesting` (just before closing brace), append the same.

In `pause`:

```swift
        // existing body…
        stopTickTimer()
```

In `resume`:

```swift
        // existing body…
        startTickTimer()
```

In `finish` (after `state = .justFinished(...)`), append:

```swift
        stopTickTimer()
        scheduleAdvance()
```

In `advance` (just after the `state = .running(...)` branch), no change — the `scheduleAdvance`'s completion already calls `startTickTimerIfRunning`.

When advance moves us to `.idle` (partial / abandoned / autoFlow=false / non-completed), there's no running state to tick. The `startTickTimerIfRunning` after `advance()` is a no-op in that case — correct.

- [ ] **Step 4: Replace `triggerEndAlerts` stub with the real impl**

Delete the no-op `triggerEndAlerts` from Task 9 and replace with:

```swift
    private func triggerEndAlerts(
        phase: PomodoroPhase,
        taskID: UUID?,
        outcome: PomodoroRecord.Outcome
    ) {
        // 1. Sound (gated by user setting)
        if appSettings.pomodoroSoundEnabled {
            let soundName: NSSound.Name = (phase == .work) ? .init("Glass") : .init("Hero")
            NSSound(named: soundName)?.play()
        }

        // 2. System notification (gated by user setting + system permission)
        if appSettings.pomodoroNotificationEnabled,
           permissionMonitor?.status == .authorized {
            let content = UNMutableNotificationContent()
            content.title = endAlertTitle(phase: phase)
            content.body = endAlertBody(phase: phase, taskID: taskID)
            content.sound = nil  // we played NSSound ourselves
            let req = UNNotificationRequest(
                identifier: "pomodoro.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }

        // 3. Notch ring pulse
        pulseToken = UUID()
    }

    private func endAlertTitle(phase: PomodoroPhase) -> String {
        switch phase {
        case .work:
            return String(localized: "pomodoro.notification.workEnd.title")
        case .shortBreak, .longBreak:
            return String(localized: "pomodoro.notification.breakEnd.title")
        case .idle:
            return ""
        }
    }

    private func endAlertBody(phase: PomodoroPhase, taskID: UUID?) -> String {
        let minutes: Int
        switch phase {
        case .work: minutes = Int(appSettings.pomodoroWorkDuration / 60)
        case .shortBreak: minutes = Int(appSettings.pomodoroShortBreakDuration / 60)
        case .longBreak: minutes = Int(appSettings.pomodoroLongBreakDuration / 60)
        case .idle: minutes = 0
        }
        if let taskID,
           let task = taskStore.tasks.first(where: { $0.id == taskID }) {
            return String(format: String(localized: "pomodoro.notification.body.withTask"),
                          task.title, minutes)
        } else {
            return String(format: String(localized: "pomodoro.notification.body.noTask"),
                          minutes)
        }
    }
```

- [ ] **Step 5: Build + run existing tests (should still pass)**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroTimerServiceTests
```

Tests use `simulateNaturalEnd()` which bypasses the tick timer, so they remain green. Localized strings missing from `Localizable.xcstrings` won't cause test failures (Foundation falls back to the key as the resolved string).

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Services/PomodoroTimerService.swift
git commit -m "feat(pomodoro): tick timer + end-alert pipeline + auto-advance"
```

---

## Task 13: PomodoroTimerService — system sleep handler

(spec §State Machine — 系统休眠 / 唤醒)

**Files:**
- Modify: `NemoNotch/Services/PomodoroTimerService.swift`
- Modify: `NemoNotchTests/PomodoroTimerServiceTests.swift`

`NSWorkspace.willSleepNotification` → `abandon()`. No auto-resume on wake.

- [ ] **Step 1: Append failing test**

```swift
    @Test func systemSleepAbandonsRunningPomodoro() {
        let (service, _, history, _) = makeService()
        service.start(taskID: nil, duration: 60, autoFlow: true)
        service.handleSystemWillSleepForTesting()
        #expect(history.records.first?.outcome == .abandoned)
    }

    @Test func systemSleepWhenIdleNoOp() {
        let (service, _, history, _) = makeService()
        service.handleSystemWillSleepForTesting()
        #expect(history.records.isEmpty)
    }
```

- [ ] **Step 2: Run, expect failure**

- [ ] **Step 3: Wire up `NSWorkspace.willSleepNotification` observer**

In `PomodoroTimerService.init`, append after the `LogService.info(...)` line:

```swift
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWillSleep()
            }
        }
```

Add the handler methods:

```swift
    private func handleSystemWillSleep() {
        LogService.info(
            "PomodoroTimerService: system will sleep — abandoning if active",
            category: "PomodoroTimer"
        )
        switch state {
        case .running, .paused:
            abandon()
        default:
            break
        }
    }

    /// Test hook — production calls go through the observer.
    func handleSystemWillSleepForTesting() {
        handleSystemWillSleep()
    }
```

`deinit` should remove the observer. Add:

```swift
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        tickTimer?.invalidate()
        advanceTimer?.invalidate()
    }
```

Note: `removeObserver(self)` only works for selector-based observers; the block-based one returns an opaque token. Keep a reference. Replace the observer registration with token-keeping:

```swift
    private var sleepObserver: NSObjectProtocol?
```

And in init:

```swift
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWillSleep()
            }
        }
```

In `deinit`:

```swift
    deinit {
        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        tickTimer?.invalidate()
        advanceTimer?.invalidate()
    }
```

- [ ] **Step 4: Run tests, expect pass**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroTimerServiceTests
```

Expected: 28 tests pass.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/PomodoroTimerService.swift NemoNotchTests/PomodoroTimerServiceTests.swift
git commit -m "feat(pomodoro): abandon-on-system-sleep handler"
```

---

## Task 14: Tab enum + Hotkey names

(spec §Hotkey · §Pomodoro Tab)

**Files:**
- Modify: `NemoNotch/Models/Tab.swift`
- Modify: `NemoNotch/Services/Hotkeys.swift`

- [ ] **Step 1: Add `.pomodoro` to `Tab` enum**

Edit `NemoNotch/Models/Tab.swift`:

```swift
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview
    case claude
    case agents
    case launcher
    case pomodoro
    case system

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .claude: "cpu"
        case .agents: "ladybug.fill"
        case .launcher: "square.grid.2x2"
        case .pomodoro: "timer"
        case .system: "gearshape.2"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "models.tab.overview"
        case .claude: "models.tab.ai"
        case .agents: "models.tab.agents"
        case .launcher: "models.tab.launcher"
        case .pomodoro: "models.tab.pomodoro"
        case .system: "models.tab.system"
        }
    }
}

extension Tab {
    static func sorted(_ tabs: Set<Tab>) -> [Tab] {
        tabs.sorted { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
    }
}
```

- [ ] **Step 2: Add hotkey names + extend `Tab.hotkeyName`**

Edit `NemoNotch/Services/Hotkeys.swift`:

```swift
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleNotch = Self("toggleNotch")
    static let openOverview = Self("openOverview", default: .init(.one, modifiers: [.option, .command]))
    static let openAI = Self("openAI", default: .init(.two, modifiers: [.option, .command]))
    static let openAgents = Self("openAgents", default: .init(.three, modifiers: [.option, .command]))
    static let openLauncher = Self("openLauncher", default: .init(.four, modifiers: [.option, .command]))
    static let openSystem = Self("openSystem", default: .init(.five, modifiers: [.option, .command]))

    // No default bindings — user must opt in via Settings (per spec §QuickStart Hotkey).
    static let openPomodoro = Self("openPomodoro")
    static let openQuickStart = Self("openQuickStart")
}

extension Tab {
    var hotkeyName: KeyboardShortcuts.Name {
        switch self {
        case .overview: return .openOverview
        case .claude: return .openAI
        case .agents: return .openAgents
        case .launcher: return .openLauncher
        case .pomodoro: return .openPomodoro
        case .system: return .openSystem
        }
    }
}
```

- [ ] **Step 3: Update `AppSettings.defaultApps` if needed (no change — launcherApps default doesn't reference tabs)**

The existing `AppSettings.enabledTabs` defaults to `Set(Tab.allCases)`, which automatically picks up `.pomodoro`. Existing users who have a stored `enabledTabs` array will *not* get `.pomodoro` enabled by default — they need to enable it via Settings. Acceptable for MVP.

- [ ] **Step 4: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Expect: succeeds. (Some warnings about `models.tab.pomodoro` localization key being undefined — fixed in Task 35.)

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Models/Tab.swift NemoNotch/Services/Hotkeys.swift
git commit -m "feat(pomodoro): add Tab.pomodoro case + openPomodoro/openQuickStart hotkey names"
```

---

## Task 15: PomodoroTab placeholder + Tab routing

(spec §Pomodoro Tab — minimal scaffold so the Tab is reachable)

**Files:**
- Create: `NemoNotch/Tabs/PomodoroTab.swift`
- Modify: `NemoNotch/Notch/NotchView.swift` — add `.pomodoro` case in the tab routing switch

A bare placeholder. Real content lands in Tasks 25-30.

- [ ] **Step 1: Create `NemoNotch/Tabs/PomodoroTab.swift`**

```swift
import SwiftUI

struct PomodoroTab: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        VStack {
            Text("Pomodoro Tab — coming soon")
                .font(.system(size: 13))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Wire `PomodoroTab` into `NotchView`**

In `NemoNotch/Notch/NotchView.swift`, find the `switch coordinator.selectedTab` block (it routes each `Tab` case to its view). Add the `.pomodoro` case alongside the existing cases:

```swift
case .pomodoro:
    PomodoroTab()
```

The exact spelling of the surrounding switch will match the existing `.overview` / `.claude` / etc. cases — clone the pattern. If `NotchView.swift` uses `@ViewBuilder` helpers for each tab, route similarly.

- [ ] **Step 3: Add `PomodoroTab.swift` to Xcode target. Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Build will fail with "Cannot find type 'PomodoroTimerService' in scope" inside `PomodoroTab` if the Environment injection isn't yet plumbed at the call site. That's expected — fix in Task 16.

Actually `@Environment(PomodoroTimerService.self)` is just a property wrapper — the type itself resolves at compile time as long as `PomodoroTimerService.swift` is in the same target. The build should succeed. If it fails, the issue is the type isn't visible (target membership).

The runtime crash for "PomodoroTimerService not found in environment" only happens if user opens the Pomodoro tab without it injected — which Task 16 fixes before the user can test.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Tabs/PomodoroTab.swift NemoNotch/Notch/NotchView.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): empty PomodoroTab view + Tab routing"
```

---

## Task 16: AppDelegate wiring + applicationWillTerminate

(spec §Architecture · §App 退出)

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

This is where the three services + `NotificationPermissionMonitor` + `QuickStartWindowController` are instantiated and injected into the SwiftUI environment so views can `@Environment(...)` them. Plus `applicationWillTerminate` writes an `abandoned` record if a pomodoro is active.

The `QuickStartWindowController` doesn't exist yet (Task 23). Stub-instantiate it as `nil` for now and revisit in Task 24 when wiring the hotkey.

- [ ] **Step 1: Add service properties to `AppDelegate`**

In `NemoNotchApp.swift`, inside `AppDelegate` class, near the existing service declarations:

```swift
    let taskStore = TaskStore()
    let historyStore = PomodoroHistoryStore()
    let notificationPermissionMonitor = NotificationPermissionMonitor()
    lazy var pomodoroTimerService = PomodoroTimerService(
        taskStore: taskStore,
        historyStore: historyStore,
        appSettings: appSettings,
        permissionMonitor: notificationPermissionMonitor
    )
```

(`appSettings` is the existing `AppSettings` property — confirm its property name; if it's different (e.g. `settings`), match.)

- [ ] **Step 2: Inject into NotchCoordinator's environment**

Find where the existing `MediaService` / `AICLIMonitorService` etc. are passed via `.environment(...)` modifiers (likely in the content closure for `NotchCoordinator` or in `NotchView`'s host setup). Add:

```swift
.environment(taskStore)
.environment(historyStore)
.environment(pomodoroTimerService)
.environment(notificationPermissionMonitor)
```

- [ ] **Step 3: Add `applicationWillTerminate` handler**

In `AppDelegate`:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        switch pomodoroTimerService.state {
        case .running, .paused:
            pomodoroTimerService.abandon()
            LogService.info(
                "AppDelegate.applicationWillTerminate: abandoned active pomodoro",
                category: "AppDelegate"
            )
        default:
            break
        }
    }
```

- [ ] **Step 4: Build + launch app to verify no crash**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Launch the app from Xcode. Confirm:
- It boots without runtime crash
- Pomodoro Tab is selectable from TabBar (shows the placeholder text)
- Logs show `TaskStore loaded 0 tasks` / `PomodoroHistoryStore loaded 0 records` / `PomodoroTimerService init`

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "feat(pomodoro): wire services + applicationWillTerminate handler"
```

---

## Task 17: PomodoroSettingsView — durations / interval / toggles

(spec §PomodoroSettingsView)

**Files:**
- Create: `NemoNotch/Settings/PomodoroSettingsView.swift`

Render the top half: 4 duration/interval pickers + 2 toggles. PermissionCard + hotkey recorders + sidebar entry land in Task 18.

- [ ] **Step 1: Create `NemoNotch/Settings/PomodoroSettingsView.swift`**

```swift
import SwiftUI

struct PomodoroSettingsView: View {
    @Environment(AppSettings.self) var appSettings

    private let workOptions: [TimeInterval] = [5, 10, 15, 20, 25, 30, 45, 60].map { $0 * 60 }
    private let breakOptions: [TimeInterval] = [3, 5, 7, 10, 15, 20].map { $0 * 60 }
    private let longBreakOptions: [TimeInterval] = [10, 15, 20, 25, 30].map { $0 * 60 }
    private let intervalOptions: [Int] = [3, 4, 5, 6]

    var body: some View {
        @Bindable var settings = appSettings
        Form {
            Section("settings.pomodoro.title") {
                Picker("settings.pomodoro.workDuration", selection: $settings.pomodoroWorkDuration) {
                    ForEach(workOptions, id: \.self) { interval in
                        Text(durationLabel(interval)).tag(interval)
                    }
                }

                Picker("settings.pomodoro.shortBreakDuration", selection: $settings.pomodoroShortBreakDuration) {
                    ForEach(breakOptions, id: \.self) { interval in
                        Text(durationLabel(interval)).tag(interval)
                    }
                }

                Picker("settings.pomodoro.longBreakDuration", selection: $settings.pomodoroLongBreakDuration) {
                    ForEach(longBreakOptions, id: \.self) { interval in
                        Text(durationLabel(interval)).tag(interval)
                    }
                }

                Picker("settings.pomodoro.longBreakInterval", selection: $settings.pomodoroLongBreakInterval) {
                    ForEach(intervalOptions, id: \.self) { n in
                        Text(String(format: String(localized: "settings.pomodoro.longBreakInterval.unit"), n)).tag(n)
                    }
                }

                Toggle("settings.pomodoro.soundEnabled", isOn: $settings.pomodoroSoundEnabled)
                Toggle("settings.pomodoro.notificationEnabled", isOn: $settings.pomodoroNotificationEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return String(format: String(localized: "settings.pomodoro.minutes"), minutes)
    }
}
```

- [ ] **Step 2: Add to Xcode target, build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

(Localized strings missing — fine for now, Task 35 fixes.)

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Settings/PomodoroSettingsView.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): PomodoroSettingsView durations + toggles"
```

---

## Task 18: PomodoroSettingsView — PermissionCard + hotkey recorders + sidebar entry

(spec §PomodoroSettingsView — 通知权限 + 快捷键)

**Files:**
- Modify: `NemoNotch/Settings/PomodoroSettingsView.swift`
- Modify: `NemoNotch/Settings/SettingsView.swift` (sidebar entry)

- [ ] **Step 1: Add Sections to `PomodoroSettingsView`**

After the existing `Section("settings.pomodoro.title") { ... }` block, append two more sections:

```swift
            Section("settings.pomodoro.hotkeyHeader") {
                HStack {
                    Text("settings.pomodoro.hotkey.openTab")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .openPomodoro)
                }
                HStack {
                    Text("settings.pomodoro.hotkey.quickStart")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .openQuickStart)
                }
            }

            Section("settings.pomodoro.permissionHeader") {
                PermissionRow()
            }
```

Add at top:

```swift
import KeyboardShortcuts
```

Define `PermissionRow` as a subview within the same file:

```swift
private struct PermissionRow: View {
    @Environment(NotificationPermissionMonitor.self) var monitor

    var body: some View {
        if monitor.status == .authorized {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("settings.pomodoro.permission.granted")
                    .foregroundStyle(NotchTheme.textSecondary)
            }
        } else {
            PermissionCard(
                icon: "bell.badge",
                titleKey: "permission.notification.title",
                detailKey: "permission.notification.detail",
                status: monitor.status == .denied ? .denied : .notDetermined,
                primary: .programmatic { Task { await monitor.request() } },
                openSettings: { monitor.openSystemSettings() }
            )
        }
    }
}
```

(Check `PermissionCard`'s actual init signature in `NemoNotch/Helpers/PermissionCard.swift` — adjust call site to match. If `PermissionStatus` is its own enum, map accordingly: `.denied` / `.notDetermined`.)

- [ ] **Step 2: Add sidebar entry to `SettingsView.swift`**

Find `NemoNotch/Settings/SettingsView.swift`. There's a sidebar `List` with entries like "General", "Hotkeys", "Notifications", etc. Add an entry for "Pomodoro" routed to `PomodoroSettingsView()`:

The exact pattern depends on the existing `SettingsView`'s implementation. Two common shapes:

If it uses `NavigationSplitView` with `selection: $selectedSection`:

```swift
// Add `case pomodoro` to the Section enum
// Add `case .pomodoro: PomodoroSettingsView()` to the detail switch
```

If it uses a TabView with `Tab(...)` items:

```swift
Tab("settings.section.pomodoro", systemImage: "timer") {
    PomodoroSettingsView()
}
```

Inspect the file and follow the existing pattern. Order: place Pomodoro **after Notifications**, before General → match spec §PomodoroSettingsView wording.

- [ ] **Step 3: Build + launch + verify Settings page works**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Launch app → open Settings (via menu bar) → click Pomodoro section. Verify:
- Four pickers render
- Two toggles render
- Two hotkey recorders render (initially "Record Shortcut")
- PermissionCard renders below (or "granted" row if you've already authorized for this build)

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Settings/PomodoroSettingsView.swift NemoNotch/Settings/SettingsView.swift
git commit -m "feat(pomodoro): settings page PermissionCard + hotkey recorders + sidebar entry"
```

---

## Task 19: PomodoroPieView shared component

(spec §Notch Badge — 饼图绘制 · §Pomodoro Tab — 大饼图)

**Files:**
- Create: `NemoNotch/Notch/Badge/PomodoroPieView.swift`

Reusable pie chart for both the 14pt badge and the 88pt active block. Phase color is the only state-dependent input — pause / justFinished modifiers stack on the caller side.

- [ ] **Step 1: Create `NemoNotch/Notch/Badge/PomodoroPieView.swift`**

```swift
import SwiftUI

enum PomodoroPieStyle {
    case badge     // 14pt; thin background ring
    case row       // 12pt; same look as badge, smaller
    case large     // 88pt; thicker background ring, optional center text
}

struct PomodoroPieView: View {
    let remainingFraction: Double   // 0...1, clamped
    let phase: PomodoroPhase
    let style: PomodoroPieStyle
    var centerText: String? = nil

    private var size: CGFloat {
        switch style {
        case .badge: return 14
        case .row: return 12
        case .large: return 88
        }
    }

    private var ringLineWidth: CGFloat {
        switch style {
        case .badge, .row: return 1
        case .large: return 2.5
        }
    }

    private var color: Color {
        switch phase {
        case .work:
            return Color(red: 0.93, green: 0.36, blue: 0.36)
        case .shortBreak:
            return Color(red: 0.34, green: 0.78, blue: 0.51)
        case .longBreak:
            return Color(red: 0.40, green: 0.66, blue: 0.92)
        case .idle:
            return NotchTheme.textTertiary
        }
    }

    private var clamped: Double {
        max(0, min(1, remainingFraction))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: ringLineWidth)

            GeometryReader { geo in
                let radius = min(geo.size.width, geo.size.height) / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                Path { p in
                    p.move(to: center)
                    p.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * clamped),
                        clockwise: false
                    )
                    p.closeSubpath()
                }
                .fill(color)
            }

            if let centerText, style == .large {
                Text(centerText)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(NotchTheme.textPrimary)
            }
        }
        .frame(width: size, height: size)
    }
}
```

- [ ] **Step 2: Build + add to Xcode target**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

- [ ] **Step 3: Quick visual sanity check (optional but recommended)**

In Xcode, open a Preview by appending:

```swift
#Preview("Badge work 60%") {
    PomodoroPieView(remainingFraction: 0.6, phase: .work, style: .badge)
        .padding(20)
        .background(Color.black)
}

#Preview("Large work 35% with text") {
    PomodoroPieView(remainingFraction: 0.35, phase: .work, style: .large, centerText: "17:35")
        .padding(20)
        .background(Color.black)
}
```

Refresh the preview pane. Pie wedge should sweep from 12 o'clock, decreasing as fraction decreases. Remove `#Preview` blocks before committing if you prefer to keep the file clean (they're harmless either way).

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/Badge/PomodoroPieView.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): add reusable PomodoroPieView component"
```

---

## Task 20: QuickStartWindow — NSPanel class

(spec §Quick Start Window — Window 与定位)

**Files:**
- Create: `NemoNotch/Notch/QuickStartWindow.swift`

Borderless `NSPanel` with `.canBecomeKey` override so its `TextField` can receive keystrokes. Just the window shell — content view lands in Task 21.

- [ ] **Step 1: Create `NemoNotch/Notch/QuickStartWindow.swift`**

```swift
import AppKit

final class QuickStartWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 124),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .transient]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Add to Xcode target, build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Notch/QuickStartWindow.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): QuickStartWindow NSPanel subclass"
```

---

## Task 21: QuickStartWindow content — title + priority + duration + mode + Enter

(spec §Quick Start Window — 窗口内容 · §控件规格 · §验证 & 提交)

**Files:**
- Modify: `NemoNotch/Notch/QuickStartWindow.swift` (content view)

Build the default (collapsed) form. Notes expand + override warning land in Task 22.

`onConfirm` is a closure that receives the form values. The controller (Task 23) supplies it, calling `timerService.start(...)`.

- [ ] **Step 1: Add `QuickStartFormView` to `QuickStartWindow.swift`**

Append to the file (below the `QuickStartWindow` class):

```swift
import SwiftUI

struct QuickStartFormView: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(PomodoroTimerService.self) var timerService

    let onConfirm: (FormResult) -> Void
    let onDismiss: () -> Void

    @State private var title: String = ""
    @State private var priority: TodoTask.Priority = .medium
    @State private var durationSelection: TimeInterval? = nil   // nil = not selected
    @State private var customDurationMinutes: Int = 25
    @State private var showCustomDuration: Bool = false
    @State private var mode: Mode = .continuous
    @State private var showDurationError: Bool = false
    @State private var notes: String = ""
    @State private var showNotesField: Bool = false

    @FocusState private var titleFocused: Bool

    enum Mode: String, CaseIterable {
        case single, continuous
    }

    struct FormResult {
        let title: String           // possibly empty → no task is created
        let priority: TodoTask.Priority
        let duration: TimeInterval
        let mode: Mode
        let notes: String
    }

    private let presetMinutes: [Int] = [15, 25, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Override warning bar (Task 22 fills this in)

            // Title row
            HStack(spacing: 10) {
                Text("🍅")
                    .font(.system(size: 16))
                TextField("pomodoro.quick.placeholder", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .rounded))
                    .focused($titleFocused)
                    .onSubmit { submit() }
            }

            // Controls row
            HStack(spacing: 8) {
                priorityPicker
                durationPicker
                modeToggle
                Spacer()
                Image(systemName: "return")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.textTertiary)
            }

            if !showNotesField {
                Button {
                    showNotesField = true
                } label: {
                    Text("pomodoro.quick.addNotes")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { titleFocused = true }
        .onExitCommand { onDismiss() }
    }

    private var priorityPicker: some View {
        Menu {
            ForEach(TodoTask.Priority.allCases, id: \.self) { p in
                Button(priorityLabel(p)) { priority = p }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(priorityColor(priority)).frame(width: 6, height: 6)
                Text(priorityLabel(priority))
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(NotchTheme.surface, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var durationPicker: some View {
        Menu {
            ForEach(presetMinutes, id: \.self) { m in
                Button("\(m) min") {
                    durationSelection = TimeInterval(m * 60)
                    showCustomDuration = false
                    showDurationError = false
                }
            }
            Divider()
            Button("Custom…") {
                showCustomDuration = true
                showDurationError = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text(durationLabel)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(NotchTheme.surface, in: Capsule())
            .overlay(
                Capsule().stroke(showDurationError ? Color.red : Color.clear, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modeToggle: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    mode = m
                } label: {
                    Text(modeLabel(m))
                        .font(.system(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(mode == m ? NotchTheme.surfaceEmphasis : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var durationLabel: String {
        if let durationSelection {
            return "\(Int(durationSelection / 60)) min"
        }
        return String(localized: "pomodoro.quick.duration.placeholder")
    }

    private func priorityLabel(_ p: TodoTask.Priority) -> String {
        switch p {
        case .low: return String(localized: "pomodoro.priority.low")
        case .medium: return String(localized: "pomodoro.priority.medium")
        case .high: return String(localized: "pomodoro.priority.high")
        }
    }

    private func priorityColor(_ p: TodoTask.Priority) -> Color {
        switch p {
        case .low: return NotchTheme.textTertiary
        case .medium: return Color(red: 0.95, green: 0.78, blue: 0.30)
        case .high: return Color(red: 0.93, green: 0.36, blue: 0.36)
        }
    }

    private func modeLabel(_ m: Mode) -> String {
        switch m {
        case .single: return String(localized: "pomodoro.quick.mode.single")
        case .continuous: return String(localized: "pomodoro.quick.mode.continuous")
        }
    }

    private func submit() {
        guard let duration = durationSelection else {
            showDurationError = true
            // Trigger shake animation via state change
            return
        }
        onConfirm(FormResult(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            duration: duration,
            mode: mode,
            notes: notes
        ))
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Notch/QuickStartWindow.swift
git commit -m "feat(pomodoro): QuickStartFormView core (title/priority/duration/mode)"
```

---

## Task 22: QuickStartWindow content — notes expand + override warning + duration custom

(spec §Quick Start Window — 默认折叠版 + 展开版 · §已有 pomodoro 在跑)

**Files:**
- Modify: `NemoNotch/Notch/QuickStartWindow.swift`

- [ ] **Step 1: Add notes expansion and override warning to `QuickStartFormView`**

Replace the `body` property of `QuickStartFormView` with the expanded version:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if timerService.state.isActive {
                overrideWarning
            }

            // Title row
            HStack(spacing: 10) {
                Text("🍅")
                    .font(.system(size: 16))
                TextField("pomodoro.quick.placeholder", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .rounded))
                    .focused($titleFocused)
                    .onSubmit { submit() }
            }

            // Controls row
            HStack(spacing: 8) {
                priorityPicker
                durationPicker
                if showCustomDuration {
                    customDurationStepper
                }
                modeToggle
                Spacer()
                Image(systemName: "return")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.textTertiary)
            }

            if showNotesField {
                TextEditor(text: $notes)
                    .font(.system(size: 12))
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(NotchTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Button {
                    showNotesField = true
                } label: {
                    Text("pomodoro.quick.addNotes")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { titleFocused = true }
        .onExitCommand { onDismiss() }
        .modifier(ShakeOnError(triggerCount: showDurationError ? 1 : 0))
    }

    @ViewBuilder
    private var overrideWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
            Text("pomodoro.quick.overrideWarning")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var customDurationStepper: some View {
        HStack(spacing: 4) {
            Stepper(value: $customDurationMinutes, in: 1...180) {
                Text("\(customDurationMinutes) min")
                    .font(.system(size: 11))
                    .frame(width: 48, alignment: .leading)
            }
            .onChange(of: customDurationMinutes) { _, newValue in
                durationSelection = TimeInterval(newValue * 60)
            }
        }
        .padding(.horizontal, 6)
    }
```

- [ ] **Step 2: Add a `ShakeOnError` modifier (one-shot 0.5s horizontal shake when triggerCount changes)**

Append at the end of the file:

```swift
private struct ShakeOnError: ViewModifier {
    var triggerCount: Int
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: phase)
            .onChange(of: triggerCount) { _, _ in
                withAnimation(.easeInOut(duration: 0.06).repeatCount(6, autoreverses: true)) {
                    phase = 6
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    phase = 0
                }
            }
    }
}
```

- [ ] **Step 3: Update `submit()` to trigger override path**

Since Task 21's `submit()` already calls `onConfirm`, the controller (Task 23) handles the override by inspecting `timerService.state` and choosing `start()` (which itself handles re-entry). No change to `submit()` needed.

But for the duration-required validation:

```swift
    private func submit() {
        guard let duration = durationSelection else {
            showDurationError.toggle()
            // ShakeOnError uses an Int counter — increment via toggling a Bool won't shake repeatedly.
            return
        }
        onConfirm(FormResult(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            duration: duration,
            mode: mode,
            notes: notes
        ))
    }
```

Fix: change `showDurationError: Bool` to `durationErrorTrigger: Int`:

In the `@State` block, replace `@State private var showDurationError: Bool = false` with:

```swift
    @State private var durationErrorTrigger: Int = 0
```

In `durationPicker`'s overlay stroke condition, replace `showDurationError` with `durationErrorTrigger > 0` (only shows red after first attempt).

In `submit()`:

```swift
    private func submit() {
        guard let duration = durationSelection else {
            durationErrorTrigger += 1
            return
        }
        onConfirm(FormResult(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            duration: duration,
            mode: mode,
            notes: notes
        ))
    }
```

And in `body`:

```swift
        .modifier(ShakeOnError(triggerCount: durationErrorTrigger))
```

Replace the menu items that previously reset `showDurationError`:

```swift
                Button("\(m) min") {
                    durationSelection = TimeInterval(m * 60)
                    showCustomDuration = false
                }
            }
            Divider()
            Button("Custom…") {
                showCustomDuration = true
            }
```

- [ ] **Step 4: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Notch/QuickStartWindow.swift
git commit -m "feat(pomodoro): QuickStart notes expand + override warning + duration validation shake"
```

---

## Task 23: QuickStartWindowController

(spec §Quick Start Window — Controller · 居中定位 · 退出 / 失焦)

**Files:**
- Create: `NemoNotch/Notch/QuickStartWindowController.swift`

Lifecycle: lazy window creation, present (center + focus + previousApp capture + click-outside monitor), dismiss (uninstall monitor + restore previousApp). Reuses the same window instance across toggles.

- [ ] **Step 1: Create `NemoNotch/Notch/QuickStartWindowController.swift`**

```swift
import AppKit
import SwiftUI

@MainActor
final class QuickStartWindowController {
    private var window: QuickStartWindow?
    private var clickOutsideMonitor: Any?
    private var previousApp: NSRunningApplication?

    private let timerService: PomodoroTimerService
    private let taskStore: TaskStore
    private let appSettings: AppSettings
    private let notificationMonitor: NotificationPermissionMonitor
    private static let ourBundleIdentifier = Bundle.main.bundleIdentifier

    init(
        timerService: PomodoroTimerService,
        taskStore: TaskStore,
        appSettings: AppSettings,
        notificationMonitor: NotificationPermissionMonitor
    ) {
        self.timerService = timerService
        self.taskStore = taskStore
        self.appSettings = appSettings
        self.notificationMonitor = notificationMonitor
    }

    func toggle() {
        if let window, window.isVisible {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        let w = window ?? makeWindow()
        window = w
        captureFrontmostApp()
        center(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installClickOutsideMonitor(for: w)
        LogService.debug("QuickStartWindow present", category: "QuickStart")
    }

    func dismiss() {
        uninstallClickOutsideMonitor()
        window?.orderOut(nil)
        restorePreviousApp()
        LogService.debug("QuickStartWindow dismiss", category: "QuickStart")
    }

    private func makeWindow() -> QuickStartWindow {
        let w = QuickStartWindow()
        let host = NSHostingController(
            rootView: QuickStartFormView(
                onConfirm: { [weak self] result in self?.handleConfirm(result) },
                onDismiss: { [weak self] in self?.dismiss() }
            )
            .environment(timerService)
            .environment(taskStore)
            .environment(appSettings)
            .environment(notificationMonitor)
        )
        w.contentViewController = host
        return w
    }

    private func center(_ w: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let sf = screen.frame
        let size = w.frame.size
        let frame = NSRect(
            x: sf.midX - size.width / 2,
            y: sf.midY - size.height / 2 + 80,
            width: size.width,
            height: size.height
        )
        w.setFrame(frame, display: false)
    }

    private func captureFrontmostApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Self.ourBundleIdentifier {
            previousApp = frontmost
        }
    }

    private func restorePreviousApp() {
        guard let app = previousApp else { return }
        previousApp = nil
        let currentFront = NSWorkspace.shared.frontmostApplication
        if currentFront == nil || currentFront?.bundleIdentifier == Self.ourBundleIdentifier {
            app.activate()
        }
    }

    private func installClickOutsideMonitor(for window: NSWindow) {
        uninstallClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            let global = NSEvent.mouseLocation
            if !window.frame.contains(global) {
                Task { @MainActor in self.dismiss() }
            }
            _ = event  // silence unused warning
        }
    }

    private func uninstallClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Confirm

    private func handleConfirm(_ result: QuickStartFormView.FormResult) {
        var taskID: UUID? = nil
        if !result.title.isEmpty {
            taskID = taskStore.add(
                title: result.title,
                priority: result.priority,
                notes: result.notes,
                tags: [],
                dueDate: nil
            )
        }
        let autoFlow = (result.mode == .continuous)
        timerService.start(taskID: taskID, duration: result.duration, autoFlow: autoFlow)
        dismiss()
    }
}
```

- [ ] **Step 2: Instantiate `QuickStartWindowController` in `AppDelegate`**

In `NemoNotch/NemoNotchApp.swift`, add as a lazy property near `pomodoroTimerService`:

```swift
    lazy var quickStartController = QuickStartWindowController(
        timerService: pomodoroTimerService,
        taskStore: taskStore,
        appSettings: appSettings,
        notificationMonitor: notificationPermissionMonitor
    )
```

In `applicationDidFinishLaunching`, after the existing setup, **touch** the property so the controller is instantiated eagerly (avoids first-hotkey lag):

```swift
        _ = quickStartController
```

- [ ] **Step 3: Build + launch + verify**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Launch app. No hotkey wired yet (Task 24), so no way to trigger from UI. For now, verify the build succeeds and the app launches without crash.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/QuickStartWindowController.swift NemoNotch/NemoNotchApp.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): QuickStartWindowController with click-outside + previousApp restore"
```

---

## Task 24: Hotkey registration in AppDelegate

(spec §Quick Start Window — Hotkey · §Pomodoro Tab — TabBar)

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

Wire `openPomodoro` to opening the notch on the Pomodoro tab, and `openQuickStart` to `quickStartController.toggle()`.

- [ ] **Step 1: Locate existing hotkey setup in `AppDelegate`**

In `NemoNotchApp.swift`, find `setupHotkeys()` (or wherever `KeyboardShortcuts.onKeyDown(for: ...)` callbacks live). It already binds the 5 existing hotkeys to `coordinator.notchOpen(tab: ..., viaHotkey: true)`.

- [ ] **Step 2: Add bindings for the two new hotkeys**

Inside `setupHotkeys()`:

```swift
        KeyboardShortcuts.onKeyDown(for: .openPomodoro) { [weak self] in
            guard let self else { return }
            self.coordinator.notchOpen(tab: .pomodoro, viaHotkey: true)
        }

        KeyboardShortcuts.onKeyDown(for: .openQuickStart) { [weak self] in
            guard let self else { return }
            self.quickStartController.toggle()
        }
```

- [ ] **Step 3: Build + launch + manual test**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Launch app, open Settings → Pomodoro:
- Record a hotkey for "打开快速启动窗口" (e.g. ⌥⌘T)
- Press it from another app: QuickStartWindow should appear, centered, focusable
- Type a task name, pick a duration (verify validation if you skip), press Enter
- Confirm: window dismisses, previousApp regains focus, `timerService.state` is `.running` (visible from Pomodoro tab placeholder once Tab content lands)

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "feat(pomodoro): wire openPomodoro and openQuickStart hotkey callbacks"
```

---

## Task 25: PomodoroTab idle — stats strip + new button

(spec §Pomodoro Tab — Idle 状态)

**Files:**
- Modify: `NemoNotch/Tabs/PomodoroTab.swift`
- Create: `NemoNotch/Tabs/PomodoroTab+StatsPopover.swift` (popover view; numeric content lands in Task 34)

The Pomodoro Tab routes between idle and active. This task lays the idle scaffold: top stats strip + 📊 + "+ 新建" CTA. List rows come in Task 26.

The "+ 新建" CTA needs to invoke `QuickStartWindowController.toggle()` — but the tab doesn't have direct access to it via Environment (controller is in AppDelegate). Pass it via Environment.

- [ ] **Step 1: Make `QuickStartWindowController` Environment-injectable**

Wrap it in a small `@Observable` shim or just pass directly via `.environment(\.quickStartController, ...)`. Simpler: store a reference type wrapper and inject.

Add inside `QuickStartWindowController.swift`:

```swift
import SwiftUI

private struct QuickStartControllerKey: EnvironmentKey {
    static let defaultValue: QuickStartWindowController? = nil
}

extension EnvironmentValues {
    var quickStartController: QuickStartWindowController? {
        get { self[QuickStartControllerKey.self] }
        set { self[QuickStartControllerKey.self] = newValue }
    }
}
```

In `AppDelegate` (wherever environment is injected for `NotchView`), add:

```swift
.environment(\.quickStartController, quickStartController)
```

- [ ] **Step 2: Rewrite `PomodoroTab.swift` as a router**

Replace the placeholder with:

```swift
import SwiftUI

struct PomodoroTab: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(AppSettings.self) var appSettings
    @Environment(\.quickStartController) var quickStartController

    @State private var showStatsPopover = false
    @State private var showCompleted = false

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider().background(NotchTheme.stroke)
            todoListPlaceholder    // replaced in Task 26
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            statsSummary
            Spacer()
            Button {
                showStatsPopover = true
            } label: {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStatsPopover, arrowEdge: .top) {
                PomodoroStatsPopover()
                    .environment(historyStore)
                    .environment(taskStore)
            }

            Button {
                quickStartController?.toggle()
            } label: {
                Label("pomodoro.action.newPomodoro", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(NotchTheme.accent.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
    }

    private var statsSummary: some View {
        let today = todayCounts()
        let week = weekCounts()
        return HStack(spacing: 10) {
            Text(String(format: "%@ ✓%d ~%d",
                        String(localized: "pomodoro.stats.today"),
                        today.completed, today.partial))
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Text("·").foregroundStyle(NotchTheme.textTertiary)
            Text(String(format: "%@ ✓%d",
                        String(localized: "pomodoro.stats.week"),
                        week.completed))
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
        }
    }

    private var todoListPlaceholder: some View {
        Text("(TODO list — Task 26)")
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func todayCounts() -> (completed: Int, partial: Int) {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Date()
        let recs = historyStore.records(in: start...end).filter { $0.phase == .work }
        return (
            completed: recs.filter { $0.outcome == .completed }.count,
            partial: recs.filter { $0.outcome == .partial }.count
        )
    }

    private func weekCounts() -> (completed: Int, partial: Int) {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recs = historyStore.records(in: start...Date()).filter { $0.phase == .work }
        return (
            completed: recs.filter { $0.outcome == .completed }.count,
            partial: recs.filter { $0.outcome == .partial }.count
        )
    }
}
```

- [ ] **Step 3: Create `NemoNotch/Tabs/PomodoroTab+StatsPopover.swift` stub**

```swift
import SwiftUI

struct PomodoroStatsPopover: View {
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(TaskStore.self) var taskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stats — coming soon (Task 34)")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(14)
        .frame(width: 320)
    }
}
```

- [ ] **Step 4: Add new file to target, build, launch, verify header renders**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Launch, open notch, switch to Pomodoro tab. Verify:
- Top strip shows "今日 ✓0 ~0 · 本周 ✓0"
- 📊 button opens placeholder popover
- "+ 新建番茄钟" button opens QuickStartWindow

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Tabs/PomodoroTab.swift NemoNotch/Tabs/PomodoroTab+StatsPopover.swift \
        NemoNotch/Notch/QuickStartWindowController.swift NemoNotch/NemoNotchApp.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): PomodoroTab idle header (stats strip + new button)"
```

---

## Task 26: PomodoroTab idle — TODO list rows

(spec §TODO 行规格 — checkbox / priority block / title / completedPomodoros dots / ▶)

**Files:**
- Create: `NemoNotch/Tabs/PomodoroTab+TodoList.swift`
- Modify: `NemoNotch/Tabs/PomodoroTab.swift` (swap placeholder for the list)

Tag chips and dueDate label are deferred to PR 2; their fields exist on `TodoTask` already but aren't rendered.

- [ ] **Step 1: Create `NemoNotch/Tabs/PomodoroTab+TodoList.swift`**

```swift
import SwiftUI

struct PomodoroTodoListView: View {
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(AppSettings.self) var appSettings

    @Binding var showCompleted: Bool
    let onEdit: (TodoTask) -> Void
    let onStartTask: (TodoTask) -> Void

    private var visibleTasks: [TodoTask] {
        let all = taskStore.tasks.sorted { $0.sortIndex < $1.sortIndex }
        return showCompleted ? all : all.filter { !$0.isDone }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(String(format: String(localized: "pomodoro.todo.countHeader"), visibleTasks.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                Spacer()
                Toggle(isOn: $showCompleted) {
                    Text("pomodoro.todo.showCompleted")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if visibleTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleTasks) { task in
                            TodoRow(
                                task: task,
                                onEdit: onEdit,
                                onStart: onStartTask
                            )
                        }
                    }
                }
                .notchScrollEdgeShadow(.vertical, thickness: 8, intensity: 0.32)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("pomodoro.todo.empty")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TodoRow: View {
    @Environment(TaskStore.self) var taskStore
    let task: TodoTask
    let onEdit: (TodoTask) -> Void
    let onStart: (TodoTask) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                taskStore.markDone(task.id, isDone: !task.isDone)
            } label: {
                Image(systemName: task.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(task.isDone ? NotchTheme.accent : NotchTheme.textTertiary)
            }
            .buttonStyle(.plain)

            RoundedRectangle(cornerRadius: 1.5)
                .fill(priorityColor(task.priority))
                .frame(width: 3, height: 14)

            Text(task.title.isEmpty ? "(untitled)" : task.title)
                .font(.system(size: 12))
                .foregroundStyle(task.isDone ? NotchTheme.textTertiary : NotchTheme.textPrimary)
                .strikethrough(task.isDone)
                .lineLimit(1)

            Spacer()

            completedDots
                .frame(width: 50, alignment: .trailing)

            Button {
                onStart(task)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .frame(width: 18, height: 18)
                    .background(NotchTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(hovering ? NotchTheme.surfaceSubtle : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("pomodoro.todo.edit") { onEdit(task) }
            Button("pomodoro.todo.pin") { taskStore.pinToTop(task.id) }
            Divider()
            Button("pomodoro.todo.delete", role: .destructive) {
                taskStore.delete(task.id)
            }
        }
    }

    @ViewBuilder
    private var completedDots: some View {
        let n = min(task.completedPomodoros, 5)
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i < n ? NotchTheme.accent : NotchTheme.surfaceEmphasis)
                    .frame(width: 4, height: 4)
            }
            if task.completedPomodoros > 5 {
                Text("+")
                    .font(.system(size: 8))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private func priorityColor(_ p: TodoTask.Priority) -> Color {
        switch p {
        case .low: return NotchTheme.textTertiary
        case .medium: return Color(red: 0.95, green: 0.78, blue: 0.30)
        case .high: return Color(red: 0.93, green: 0.36, blue: 0.36)
        }
    }
}
```

- [ ] **Step 2: Wire `PomodoroTodoListView` into `PomodoroTab.swift`**

Replace `todoListPlaceholder` with state for the edit-sheet target and an instance of the list:

```swift
    @State private var editingTask: TodoTask?

    var body: some View {
        VStack(spacing: 10) {
            header
            Divider().background(NotchTheme.stroke)
            PomodoroTodoListView(
                showCompleted: $showCompleted,
                onEdit: { editingTask = $0 },
                onStartTask: handleStartTask(_:)
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // edit sheet wired in Task 28
    }

    private func handleStartTask(_ task: TodoTask) {
        let duration = timerService.lastUsedDuration > 0
            ? timerService.lastUsedDuration
            : appSettings.pomodoroWorkDuration
        let autoFlow = timerService.lastAutoFlow
        timerService.start(taskID: task.id, duration: duration, autoFlow: autoFlow)
    }

    private var todoListPlaceholder: some View { EmptyView() }  // remove after replacement above lands
```

Delete the `todoListPlaceholder` field reference once the new body compiles.

- [ ] **Step 3: Build + launch + verify**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Launch app, open notch, switch to Pomodoro tab. Add a task via QuickStart (Enter without duration → shake; pick 25 → submit). Verify:
- Task appears in list with title + priority block + 0 dots
- ▶ button on row starts a pomodoro on that task
- Checkbox toggles isDone (with strikethrough)
- Right-click row → menu with Edit / Pin / Delete

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Tabs/PomodoroTab.swift NemoNotch/Tabs/PomodoroTab+TodoList.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): PomodoroTab TODO list rows + interactions"
```

---

## Task 27: PomodoroTab row — fast-path start handles override prompt

(spec §TODO 行交互 — 已 running 时弹 inline 确认条 "覆盖当前番茄钟？")

**Files:**
- Modify: `NemoNotch/Tabs/PomodoroTab.swift`

The fast-path ▶ button currently just calls `timerService.start(...)` which silently overrides (writes the previous as partial). Add an inline confirmation banner that appears above the TODO list when the user clicks ▶ while another pomodoro is running.

- [ ] **Step 1: Add pending-override state to `PomodoroTab`**

```swift
    @State private var pendingFastStartTask: TodoTask?
```

- [ ] **Step 2: Update `handleStartTask` to gate on running state**

```swift
    private func handleStartTask(_ task: TodoTask) {
        if timerService.state.isActive {
            pendingFastStartTask = task
        } else {
            performStart(task)
        }
    }

    private func performStart(_ task: TodoTask) {
        let duration = timerService.lastUsedDuration > 0
            ? timerService.lastUsedDuration
            : appSettings.pomodoroWorkDuration
        let autoFlow = timerService.lastAutoFlow
        timerService.start(taskID: task.id, duration: duration, autoFlow: autoFlow)
        pendingFastStartTask = nil
    }
```

- [ ] **Step 3: Render the inline confirm banner above the TODO list**

In `body`, between `Divider()` and `PomodoroTodoListView(...)`:

```swift
            if let pending = pendingFastStartTask {
                overrideConfirmBanner(for: pending)
            }
```

Add the banner builder:

```swift
    @ViewBuilder
    private func overrideConfirmBanner(for task: TodoTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(String(format: String(localized: "pomodoro.confirm.override"), task.title))
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer()
            Button("pomodoro.action.start") {
                performStart(task)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                pendingFastStartTask = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
```

- [ ] **Step 4: Build + manual test**

Add two tasks. Start the first via ▶. Click ▶ on the second — banner appears with "覆盖当前番茄钟？" + Start / dismiss buttons. Confirm shifts the running pomodoro to partial in history.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Tabs/PomodoroTab.swift
git commit -m "feat(pomodoro): inline override confirm for fast-path ▶ start"
```

---

## Task 28: PomodoroTab — edit sheet

(spec §编辑 / 详情 Sheet)

**Files:**
- Create: `NemoNotch/Tabs/PomodoroTab+EditSheet.swift`
- Modify: `NemoNotch/Tabs/PomodoroTab.swift` (attach sheet)

PR 1 sheet shows title + priority + notes + read-only completed count + createdAt. tags + dueDate fields exist on `TodoTask` but the UI is deferred to PR 2.

- [ ] **Step 1: Create `NemoNotch/Tabs/PomodoroTab+EditSheet.swift`**

```swift
import SwiftUI

struct PomodoroEditSheet: View {
    @Environment(TaskStore.self) var taskStore
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(\.dismiss) var dismiss

    let taskID: UUID

    @State private var title: String = ""
    @State private var priority: TodoTask.Priority = .medium
    @State private var notes: String = ""
    @State private var loaded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("pomodoro.edit.title")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            Form {
                TextField("pomodoro.edit.titleField", text: $title)

                Picker("pomodoro.edit.priorityField", selection: $priority) {
                    Text("pomodoro.priority.low").tag(TodoTask.Priority.low)
                    Text("pomodoro.priority.medium").tag(TodoTask.Priority.medium)
                    Text("pomodoro.priority.high").tag(TodoTask.Priority.high)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading) {
                    Text("pomodoro.edit.notes")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textSecondary)
                    TextEditor(text: $notes)
                        .font(.system(size: 12))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(NotchTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                }

                if let task = taskStore.tasks.first(where: { $0.id == taskID }) {
                    Text(String(format: String(localized: "pomodoro.edit.completedCount"), task.completedPomodoros))
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textSecondary)
                    Text(String(format: String(localized: "pomodoro.edit.createdAt"),
                                task.createdAt.formatted(date: .abbreviated, time: .omitted)))
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("button.cancel") { dismiss() }
                Button("button.save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard !loaded, let task = taskStore.tasks.first(where: { $0.id == taskID }) else { return }
        title = task.title
        priority = task.priority
        notes = task.notes
        loaded = true
    }

    private func save() {
        taskStore.update(taskID) { task in
            task.title = title
            task.priority = priority
            task.notes = notes
        }
    }
}
```

- [ ] **Step 2: Attach `.sheet(item:)` in `PomodoroTab.swift`**

In `body`, after `.padding(12)` modifier:

```swift
        .sheet(item: $editingTask) { task in
            PomodoroEditSheet(taskID: task.id)
                .environment(taskStore)
                .environment(historyStore)
        }
```

`editingTask: TodoTask?` is already declared in Task 26. `TodoTask` conforms to `Identifiable` so `.sheet(item:)` works directly.

- [ ] **Step 3: Build + manual test**

Launch app, add a task, right-click → Edit. Sheet appears. Change title + priority + notes, click Save. Verify changes persist (reopen edit to confirm; relaunch app to verify file persistence).

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Tabs/PomodoroTab.swift NemoNotch/Tabs/PomodoroTab+EditSheet.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): edit sheet for task title/priority/notes"
```

---

## Task 29: PomodoroTab active block — big pie + task info

(spec §Pomodoro Tab — Active 状态 — Active block 部分)

**Files:**
- Create: `NemoNotch/Tabs/PomodoroTab+ActiveBlock.swift`
- Modify: `NemoNotch/Tabs/PomodoroTab.swift` (insert active block when state ≠ idle)

- [ ] **Step 1: Create `NemoNotch/Tabs/PomodoroTab+ActiveBlock.swift`**

```swift
import SwiftUI

struct PomodoroActiveBlock: View {
    @Environment(PomodoroTimerService.self) var timerService
    @Environment(TaskStore.self) var taskStore
    @Environment(AppSettings.self) var appSettings

    let onPauseResume: () -> Void
    let onCompleteEarly: () -> Void
    let onAbandon: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            PomodoroPieView(
                remainingFraction: remainingFraction,
                phase: timerService.currentPhase,
                style: .large,
                centerText: mmss(timerService.remainingSeconds)
            )
            .opacity(emojiPieOpacity)

            VStack(alignment: .leading, spacing: 4) {
                taskTitleRow
                phaseRow
                priorityAndDotsRow
                remainingLabel
            }
        }
        .padding(12)
        .background(NotchTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private var remainingFraction: Double {
        guard case let .running(ctx) = timerService.state else {
            if case let .paused(ctx) = timerService.state {
                return (ctx.plannedDuration - ctx.accumulatedElapsed) / ctx.plannedDuration
            }
            return 0
        }
        return Double(timerService.remainingSeconds) / ctx.plannedDuration
    }

    private var emojiPieOpacity: Double {
        if case .paused = timerService.state { return 0.55 }
        return 1.0
    }

    private var taskTitleRow: some View {
        let title: String = {
            if case let .running(ctx) = timerService.state,
               let id = ctx.taskID,
               let task = taskStore.tasks.first(where: { $0.id == id }) {
                return task.title
            }
            if case let .paused(ctx) = timerService.state,
               let id = ctx.taskID,
               let task = taskStore.tasks.first(where: { $0.id == id }) {
                return task.title
            }
            return String(localized: "pomodoro.active.noTask")
        }()
        return Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(NotchTheme.textPrimary)
            .lineLimit(1)
    }

    private var phaseRow: some View {
        let phaseLabel = phaseName(timerService.currentPhase)
        let counterStr: String
        let nextStr: String
        if timerService.lastAutoFlow {
            let n = timerService.workCounterSinceLongBreak + (timerService.currentPhase == .work ? 1 : 0)
            let m = appSettings.pomodoroLongBreakInterval
            counterStr = String(format: String(localized: "pomodoro.phase.counter"), n, m)
            nextStr = nextPhaseLabel()
        } else {
            counterStr = String(localized: "pomodoro.phase.singleWork")
            nextStr = ""
        }
        return HStack(spacing: 6) {
            Text(phaseLabel).font(.system(size: 11)).foregroundStyle(NotchTheme.textSecondary)
            Text("·").foregroundStyle(NotchTheme.textTertiary)
            Text(counterStr).font(.system(size: 11)).foregroundStyle(NotchTheme.textSecondary)
            if !nextStr.isEmpty {
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text(String(format: String(localized: "pomodoro.phase.next"), nextStr))
                    .font(.system(size: 11)).foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private var priorityAndDotsRow: some View {
        // Simplified: just show "priority + dots" if a task is attached.
        Group {
            if let taskID = currentTaskID,
               let task = taskStore.tasks.first(where: { $0.id == taskID }) {
                HStack(spacing: 6) {
                    Text(priorityLabel(task.priority))
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("·").foregroundStyle(NotchTheme.textTertiary)
                    completedDots(task.completedPomodoros)
                }
            } else {
                EmptyView()
            }
        }
    }

    private var remainingLabel: some View {
        Text(String(format: String(localized: "pomodoro.active.remaining"), mmss(timerService.remainingSeconds)))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(NotchTheme.textPrimary)
    }

    private var currentTaskID: UUID? {
        if case let .running(ctx) = timerService.state { return ctx.taskID }
        if case let .paused(ctx) = timerService.state { return ctx.taskID }
        return nil
    }

    private func mmss(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func phaseName(_ p: PomodoroPhase) -> String {
        switch p {
        case .work: return String(localized: "pomodoro.phase.work")
        case .shortBreak: return String(localized: "pomodoro.phase.shortBreak")
        case .longBreak: return String(localized: "pomodoro.phase.longBreak")
        case .idle: return ""
        }
    }

    private func nextPhaseLabel() -> String {
        let m = appSettings.pomodoroLongBreakInterval
        switch timerService.currentPhase {
        case .work:
            let n = timerService.workCounterSinceLongBreak + 1
            return (n % m == 0)
                ? String(localized: "pomodoro.phase.longBreak")
                : String(localized: "pomodoro.phase.shortBreak")
        case .shortBreak, .longBreak: return String(localized: "pomodoro.phase.work")
        case .idle: return ""
        }
    }

    private func priorityLabel(_ p: TodoTask.Priority) -> String {
        switch p {
        case .low: return String(localized: "pomodoro.priority.low")
        case .medium: return String(localized: "pomodoro.priority.medium")
        case .high: return String(localized: "pomodoro.priority.high")
        }
    }

    @ViewBuilder
    private func completedDots(_ n: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Circle()
                    .fill(i < min(n, 5) ? NotchTheme.accent : NotchTheme.surfaceEmphasis)
                    .frame(width: 4, height: 4)
            }
            if n > 5 {
                Text("+").font(.system(size: 8)).foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }
}
```

- [ ] **Step 2: Insert `PomodoroActiveBlock` into `PomodoroTab.swift`**

In `body`, between `header` and `Divider()`:

```swift
            if timerService.state.isActive {
                PomodoroActiveBlock(
                    onPauseResume: handlePauseResume,
                    onCompleteEarly: handleCompleteEarly,
                    onAbandon: handleAbandon
                )
            }
```

Add three handler stubs (filled in Task 30):

```swift
    private func handlePauseResume() {
        if case .running = timerService.state {
            timerService.pause()
        } else if case .paused = timerService.state {
            timerService.resume()
        }
    }

    private func handleCompleteEarly() {
        timerService.completeEarly()
    }

    private func handleAbandon() {
        timerService.abandon()
    }
```

- [ ] **Step 3: Build + manual test**

Launch, start a 1-minute pomodoro via QuickStart. Verify:
- Pomodoro tab shows active block: big pie + task title + phase row + "剩余 0:59" countdown
- Pie wedge visibly shrinks every second
- Pauses correctly visualize (opacity 0.55, ring frozen)

Note: at this point pause/complete/abandon are wired through the handlers but there are no buttons yet — that's Task 30.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Tabs/PomodoroTab.swift NemoNotch/Tabs/PomodoroTab+ActiveBlock.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): active block in Pomodoro Tab (big pie + task info)"
```

---

## Task 30: PomodoroTab active controls — pause / completeEarly / abandon with inline confirms

(spec §Pomodoro Tab — Active 状态 控制按钮 + 行内 inline confirmation)

**Files:**
- Modify: `NemoNotch/Tabs/PomodoroTab+ActiveBlock.swift`

Three buttons; `completeEarly` and `abandon` route through an inline confirmation row (NSAlert would steal notch focus and collapse it — verified by spec §Pomodoro Tab — Active block).

- [ ] **Step 1: Add controls row + inline confirm state to `PomodoroActiveBlock`**

Add state:

```swift
    @State private var pendingConfirm: ConfirmKind? = nil

    enum ConfirmKind {
        case completeEarly
        case abandon
    }
```

Replace `body` to include the controls row + confirm UI:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mainRow
            controlsRow
            if let kind = pendingConfirm {
                confirmBanner(kind)
            }
        }
        .padding(12)
        .background(NotchTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private var mainRow: some View {
        HStack(spacing: 14) {
            PomodoroPieView(
                remainingFraction: remainingFraction,
                phase: timerService.currentPhase,
                style: .large,
                centerText: mmss(timerService.remainingSeconds)
            )
            .opacity(emojiPieOpacity)

            VStack(alignment: .leading, spacing: 4) {
                taskTitleRow
                phaseRow
                priorityAndDotsRow
                remainingLabel
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button {
                onPauseResume()
            } label: {
                Label(pauseResumeLabel, systemImage: pauseResumeIcon)
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                pendingConfirm = .completeEarly
            } label: {
                Label("pomodoro.action.completeEarly", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                pendingConfirm = .abandon
            } label: {
                Label("pomodoro.action.abandon", systemImage: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var pauseResumeLabel: LocalizedStringKey {
        if case .paused = timerService.state { return "pomodoro.action.resume" }
        return "pomodoro.action.pause"
    }

    private var pauseResumeIcon: String {
        if case .paused = timerService.state { return "play.fill" }
        return "pause.fill"
    }

    @ViewBuilder
    private func confirmBanner(_ kind: ConfirmKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
            Text(confirmMessage(kind))
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer()
            Button("button.confirm") {
                switch kind {
                case .completeEarly: onCompleteEarly()
                case .abandon: onAbandon()
                }
                pendingConfirm = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("button.cancel") { pendingConfirm = nil }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func confirmMessage(_ kind: ConfirmKind) -> String {
        switch kind {
        case .completeEarly:
            let remaining = mmss(timerService.remainingSeconds)
            return String(format: String(localized: "pomodoro.confirm.completeEarly"), remaining)
        case .abandon:
            return String(localized: "pomodoro.confirm.abandon")
        }
    }
```

- [ ] **Step 2: Build + manual test**

Launch, start a pomodoro. Verify:
- ⏸ button pauses (icon flips to ▶, pie freezes)
- ▶ resumes
- ✓ 提前完成 shows yellow banner with "还有X剩余，确定提前完成？" → confirm writes partial → state goes idle (or auto-advances if autoFlow)
- ✗ 放弃 shows yellow banner "放弃当前番茄钟？" → confirm writes abandoned → state goes idle (no end-alerts)

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Tabs/PomodoroTab+ActiveBlock.swift
git commit -m "feat(pomodoro): active controls with inline confirm for completeEarly/abandon"
```

---

## Task 31: Notch BadgeItem + priority renumber

(spec §Notch Badge Integration — BadgeItem 新 case · 优先级重编号)

**Files:**
- Modify: `NemoNotch/Notch/Badge/BadgeItem.swift`

- [ ] **Step 1: Add `.pomodoro(phase:)` case + renumber priority**

Replace the existing `BadgeItem` enum (file currently at `NemoNotch/Notch/Badge/BadgeItem.swift`):

```swift
import SwiftUI

enum BadgeItem: Identifiable, Equatable {
    case notification(bundleID: String, count: Int)
    case media
    case ai(source: AISource, status: ClaudeStatus, tool: String?, waitingApproval: Bool, sessionID: String)
    case agents(agentID: String, state: AgentMonitorState, emoji: String)
    case calendar
    case pomodoro(phase: PomodoroPhase)

    var id: String {
        switch self {
        case let .notification(bundleID, _): "notification:\(bundleID)"
        case .media: "media"
        case let .ai(source, status, tool, waitingApproval, sessionID):
            "ai:\(sessionID):\(source.rawValue):\(status):\(tool ?? "nil"):\(waitingApproval)"
        case let .agents(agentID, state, emoji): "agents:\(agentID):\(state.rawValue):\(emoji)"
        case .calendar: "calendar"
        case let .pomodoro(phase): "pomodoro:\(phase.rawValue)"
        }
    }

    var tab: Tab {
        switch self {
        case .notification: .overview
        case .media: .overview
        case .ai: .claude
        case .agents: .agents
        case .calendar: .overview
        case .pomodoro: .pomodoro
        }
    }

    /// Lower value = higher priority
    var priority: Int {
        switch self {
        case let .ai(_, _, _, waitingApproval, _) where waitingApproval:
            return 0
        case .notification:
            return 1
        case .pomodoro:
            return 2
        case .agents:
            return 3
        case .ai:
            return 4
        case .media:
            return 5
        case .calendar:
            return 6
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Expected: succeeds (no callers reference old priority numbers directly — sorting uses the property).

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Notch/Badge/BadgeItem.swift
git commit -m "feat(pomodoro): add BadgeItem.pomodoro case + renumber priorities"
```

---

## Task 32: Notch BadgeIconView pomodoro renderer

(spec §Notch Badge Integration — 视觉 · 状态反馈)

**Files:**
- Modify: `NemoNotch/Notch/Badge/BadgeIconView.swift`

Add a `.pomodoro` branch in the main `switch` that renders:
- `compactLeft` → 🍅 emoji
- `compactRight` → `PomodoroPieView(style: .badge)` reading live `remainingSeconds` from `PomodoroTimerService`
- `row` → `PomodoroPieView(style: .row)`

Plus the pulse-on-`justFinished` and pause-opacity behaviors.

- [ ] **Step 1: Add `@Environment(PomodoroTimerService.self)` to `BadgeIconView`**

Near the existing environment properties (e.g. `notificationService`, `mediaService`):

```swift
    @Environment(PomodoroTimerService.self) var pomodoroService
```

If the existing `BadgeIconView` takes those services as explicit `let` params instead of `@Environment`, follow the same pattern: add `let pomodoroService: PomodoroTimerService` and pass it from `CompactBadgesView` / `BadgeRowView` (look at how `notificationService` and `mediaService` are threaded — clone the wiring).

- [ ] **Step 2: Add the `.pomodoro` case in the outer `switch item`**

Inside `body`:

```swift
        case let .pomodoro(phase):
            pomodoroBadge(phase: phase)
```

- [ ] **Step 3: Add the renderer**

Append in the file:

```swift
    @ViewBuilder
    private func pomodoroBadge(phase: PomodoroPhase) -> some View {
        switch style {
        case .compactLeft:
            Text("🍅")
                .font(.system(size: 14))
                .opacity(emojiOpacity)
                .modifier(PomodoroPulseModifier(token: pomodoroService.pulseToken))
        case .compactRight:
            PomodoroPieView(
                remainingFraction: pomodoroService.remainingFraction,
                phase: phase,
                style: .badge
            )
            .opacity(piePausedOpacity)
            .modifier(PomodoroPulseModifier(token: pomodoroService.pulseToken))
        case .row:
            PomodoroPieView(
                remainingFraction: pomodoroService.remainingFraction,
                phase: phase,
                style: .row
            )
            .opacity(piePausedOpacity)
        }
    }

    private var emojiOpacity: Double {
        if case .paused = pomodoroService.state { return 0.55 }
        return 1.0
    }

    private var piePausedOpacity: Double {
        if case .paused = pomodoroService.state { return 0.7 }
        return 1.0
    }
```

- [ ] **Step 4: Expose `remainingFraction` on `PomodoroTimerService`**

In `PomodoroTimerService.swift`, append a computed property:

```swift
    var remainingFraction: Double {
        switch state {
        case .idle: return 0
        case let .running(ctx):
            let elapsed = ctx.accumulatedElapsed + Date().timeIntervalSince(ctx.startedAt)
            return max(0, min(1, (ctx.plannedDuration - elapsed) / ctx.plannedDuration))
        case let .paused(ctx):
            return max(0, min(1, (ctx.plannedDuration - ctx.accumulatedElapsed) / ctx.plannedDuration))
        case .justFinished: return 0
        }
    }
```

- [ ] **Step 5: Add `PomodoroPulseModifier` for the justFinished blink**

Append in `BadgeIconView.swift` (or a new utility file — same scope):

```swift
private struct PomodoroPulseModifier: ViewModifier {
    let token: UUID
    @State private var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onChange(of: token) { _, _ in
                withAnimation(.easeInOut(duration: 0.15).repeatCount(4, autoreverses: true)) {
                    opacity = 0.3
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        opacity = 1.0
                    }
                }
            }
    }
}
```

- [ ] **Step 6: Build + manual test**

Launch app. Start a 1-min pomodoro via QuickStart. Collapse the notch (move mouse away). Verify:
- Left side of notch shows 🍅 emoji
- Right side shows shrinking pie
- Pause via Pomodoro tab → both fade slightly
- After 1 minute, ring blinks 2× before disappearing (or transitioning to the break ring if autoFlow)

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Notch/Badge/BadgeIconView.swift NemoNotch/Services/PomodoroTimerService.swift
git commit -m "feat(pomodoro): notch badge renderer (🍅 + pie + pulse)"
```

---

## Task 33: Notch BadgeViewModel integration

(spec §Notch Badge Integration — `BadgeViewModel.activeBadgeItems` 插入)

**Files:**
- Modify: `NemoNotch/Notch/Badge/BadgeViewModel.swift`
- Modify: `NemoNotch/Notch/NotchView.swift` (pass `pomodoroService` into `BadgeViewModel`)

- [ ] **Step 1: Update `BadgeViewModel` init + activeBadgeItems**

Modify `BadgeViewModel.swift`:

```swift
@MainActor
@Observable
final class BadgeViewModel {
    private let mediaService: MediaService
    private let calendarService: CalendarService
    private let aiService: AICLIMonitorService
    private let notificationService: NotificationService
    private let agentRegistry: AgentMonitorRegistry
    private let pomodoroService: PomodoroTimerService

    var shownHasActiveBadge: Bool = false
    var displayedBadgeItems: [BadgeItem] = []
    private var badgeTypeUpdateTask: Task<Void, Never>?
    private var wasWaitingForApproval = false

    init(
        mediaService: MediaService,
        calendarService: CalendarService,
        aiService: AICLIMonitorService,
        notificationService: NotificationService,
        agentRegistry: AgentMonitorRegistry,
        pomodoroService: PomodoroTimerService
    ) {
        self.mediaService = mediaService
        self.calendarService = calendarService
        self.aiService = aiService
        self.notificationService = notificationService
        self.agentRegistry = agentRegistry
        self.pomodoroService = pomodoroService
    }

    var activeBadgeItems: [BadgeItem] {
        var items: [BadgeItem] = []

        let activeSessions = aiService.store.sortedSessions.filter { $0.phase.isActive || $0.phase.needsAttention }

        for session in activeSessions where session.phase.isWaitingForApproval {
            items.append(.ai(
                source: session.source,
                status: .waiting,
                tool: session.phase.approvalToolName,
                waitingApproval: true,
                sessionID: session.id
            ))
        }

        if let top = notificationService.badges.values.max(by: { $0.count < $1.count }) {
            items.append(.notification(bundleID: top.bundleID, count: top.count))
        }

        if pomodoroService.state.isActive {
            items.append(.pomodoro(phase: pomodoroService.currentPhase))
        }

        for agent in agentRegistry.activeAgents {
            items.append(.agents(agentID: agent.id, state: agent.state, emoji: agent.emoji))
        }

        for session in activeSessions {
            if !session.phase.isWaitingForApproval, session.status == .working {
                items.append(.ai(
                    source: session.source,
                    status: session.status,
                    tool: session.currentTool,
                    waitingApproval: false,
                    sessionID: session.id
                ))
            }
        }

        if mediaService.playbackState.isPlaying { items.append(.media) }
        if let next = calendarService.nextEvent, !next.isPast {
            let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
            if minutes >= 0, minutes < NotchConstants.upcomingEventThresholdMinutes {
                items.append(.calendar)
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }
    }

    var hasActiveBadge: Bool {
        !activeBadgeItems.isEmpty
    }

    var hasMultipleBadges: Bool {
        displayedBadgeItems.count >= 2
    }

    func initialize() {
        shownHasActiveBadge = hasActiveBadge
        displayedBadgeItems = activeBadgeItems
        wasWaitingForApproval = aiService.activeSession?.phase.isWaitingForApproval == true
    }

    func updateDisplayedBadges(newTypes: [BadgeItem]) {
        badgeTypeUpdateTask?.cancel()
        badgeTypeUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(
                duration: NotchConstants.badgeSpringDuration,
                bounce: NotchConstants.badgeSpringBounce
            )) {
                displayedBadgeItems = newTypes
            }
        }
    }

    func updateHasActiveBadge(_ newValue: Bool) {
        withAnimation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce)) {
            shownHasActiveBadge = newValue
        }
    }

    func checkApprovalSound(isOpen: Bool) {
        let isWaiting = aiService.activeSession?.phase.isWaitingForApproval == true
        if isWaiting, !wasWaitingForApproval, !TerminalDetector.isTerminalFrontmost, !isOpen {
            NSSound(named: "Pop")?.play()
        }
        wasWaitingForApproval = isWaiting
    }
}
```

- [ ] **Step 2: Update `NotchView` to inject `pomodoroService` and pass to `BadgeViewModel`**

In `NemoNotch/Notch/NotchView.swift`, add:

```swift
    @Environment(PomodoroTimerService.self) var pomodoroService
```

Find the `initializeBadgeViewModel()` method (or wherever `BadgeViewModel` is constructed) and add `pomodoroService: pomodoroService` to the call:

```swift
    private func initializeBadgeViewModel() {
        badgeViewModel = BadgeViewModel(
            mediaService: mediaService,
            calendarService: calendarService,
            aiService: aiService,
            notificationService: notificationService,
            agentRegistry: agentRegistry,
            pomodoroService: pomodoroService
        )
        badgeViewModel?.initialize()
    }
```

- [ ] **Step 3: Build + manual test**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Start a pomodoro → 🍅 emoji + pie should appear on collapsed notch. If media is playing simultaneously, pomodoro takes the primary slot (left+right) and media shifts to the row.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/Badge/BadgeViewModel.swift NemoNotch/Notch/NotchView.swift
git commit -m "feat(pomodoro): wire BadgeViewModel + NotchView to PomodoroTimerService"
```

---

## Task 34: PomodoroTab Stats popover (numbers)

(spec §Stats Popover — PR 1 纯数字版)

**Files:**
- Modify: `NemoNotch/Tabs/PomodoroTab+StatsPopover.swift`
- Create: `NemoNotchTests/PomodoroStatsTests.swift`

Pure numeric summary: today / week / all-time + "most frequent task" + recent 5 records. Chart and segmented period selector are PR 2.

Aggregation logic deserves tests (TDD).

- [ ] **Step 1: Write failing tests for aggregation helpers**

`NemoNotchTests/PomodoroStatsTests.swift`:

```swift
import Foundation
import Testing
@testable import NemoNotch

@MainActor
struct PomodoroStatsTests {
    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemonotch-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func makeRec(
        outcome: PomodoroRecord.Outcome = .completed,
        phase: PomodoroPhase = .work,
        endedAt: Date,
        taskID: UUID? = nil
    ) -> PomodoroRecord {
        PomodoroRecord(
            id: UUID(), taskID: taskID, phase: phase,
            plannedDuration: 1500, actualDuration: 1500,
            startedAt: endedAt.addingTimeInterval(-1500), endedAt: endedAt,
            outcome: outcome
        )
    }

    @Test func todayBucketIgnoresYesterdayAndBreakRecords() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400 - 60)  // > 1 day ago
        history.append(makeRec(endedAt: now))
        history.append(makeRec(outcome: .partial, endedAt: now))
        history.append(makeRec(phase: .shortBreak, endedAt: now))   // breaks excluded
        history.append(makeRec(endedAt: yesterday))                  // yesterday excluded

        let stats = PomodoroStats(history: history)
        let today = stats.today()
        #expect(today.completed == 1)
        #expect(today.partial == 1)
        #expect(today.abandoned == 0)
    }

    @Test func weekBucketIncludesLast7Days() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let now = Date()
        for i in 0..<7 {
            history.append(makeRec(endedAt: now.addingTimeInterval(-86400 * Double(i) - 60)))
        }
        history.append(makeRec(endedAt: now.addingTimeInterval(-86400 * 8)))  // > 7 days excluded

        let stats = PomodoroStats(history: history)
        let week = stats.week()
        #expect(week.completed == 7)
    }

    @Test func allTimeIncludesAllWorkRecords() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        history.append(makeRec(outcome: .completed, endedAt: Date(timeIntervalSince1970: 100)))
        history.append(makeRec(outcome: .partial, endedAt: Date(timeIntervalSince1970: 200)))
        history.append(makeRec(outcome: .abandoned, endedAt: Date(timeIntervalSince1970: 300)))
        history.append(makeRec(phase: .longBreak, endedAt: Date(timeIntervalSince1970: 400)))  // excluded

        let stats = PomodoroStats(history: history)
        let all = stats.allTime()
        #expect(all.completed == 1)
        #expect(all.partial == 1)
        #expect(all.abandoned == 1)
    }

    @Test func mostFrequentTaskIDReturnsHighestCount() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let a = UUID(), b = UUID()
        history.append(makeRec(endedAt: Date(), taskID: a))
        history.append(makeRec(endedAt: Date(), taskID: b))
        history.append(makeRec(endedAt: Date(), taskID: a))
        history.append(makeRec(endedAt: Date(), taskID: a))

        let stats = PomodoroStats(history: history)
        #expect(stats.mostFrequentTaskID()?.taskID == a)
        #expect(stats.mostFrequentTaskID()?.count == 3)
    }

    @Test func mostFrequentTaskIDIgnoresAbandonedAndNilTaskID() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let a = UUID()
        history.append(makeRec(endedAt: Date(), taskID: nil))   // ignored
        history.append(makeRec(outcome: .abandoned, endedAt: Date(), taskID: a))  // ignored
        history.append(makeRec(endedAt: Date(), taskID: a))
        let stats = PomodoroStats(history: history)
        #expect(stats.mostFrequentTaskID()?.taskID == a)
        #expect(stats.mostFrequentTaskID()?.count == 1)
    }

    @Test func recentReturnsLastNRecordsInReverseOrder() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<7 {
            history.append(makeRec(endedAt: base.addingTimeInterval(Double(i) * 60)))
        }
        let stats = PomodoroStats(history: history)
        let recent = stats.recent(limit: 5)
        #expect(recent.count == 5)
        // Most recent first
        #expect(recent.first?.endedAt == base.addingTimeInterval(360))
    }

    @Test func emptyHistoryReturnsZeros() {
        let history = PomodoroHistoryStore(fileURL: tempURL("h.json"))
        let stats = PomodoroStats(history: history)
        let today = stats.today()
        #expect(today.completed == 0 && today.partial == 0 && today.abandoned == 0)
        #expect(stats.mostFrequentTaskID() == nil)
        #expect(stats.recent(limit: 5).isEmpty)
    }
}
```

- [ ] **Step 2: Run, expect failure (`PomodoroStats` not in scope)**

- [ ] **Step 3: Create `PomodoroStats` helper**

Add a new file `NemoNotch/Services/PomodoroStats.swift`:

```swift
import Foundation

@MainActor
struct PomodoroStats {
    let history: PomodoroHistoryStore

    struct Counts: Equatable {
        var completed: Int
        var partial: Int
        var abandoned: Int
    }

    struct TaskFrequency: Equatable {
        let taskID: UUID
        let count: Int
    }

    func today() -> Counts {
        let start = Calendar.current.startOfDay(for: Date())
        return counts(in: start...Date())
    }

    func week() -> Counts {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return counts(in: start...Date())
    }

    func allTime() -> Counts {
        let workRecords = history.records.filter { $0.phase == .work }
        return reduceCounts(workRecords)
    }

    func mostFrequentTaskID() -> TaskFrequency? {
        let workRecords = history.records.filter {
            $0.phase == .work && $0.outcome != .abandoned && $0.taskID != nil
        }
        let grouped = Dictionary(grouping: workRecords) { $0.taskID! }
        guard let top = grouped.max(by: { $0.value.count < $1.value.count }) else { return nil }
        return TaskFrequency(taskID: top.key, count: top.value.count)
    }

    func recent(limit: Int) -> [PomodoroRecord] {
        return Array(history.records.reversed().prefix(limit))
    }

    private func counts(in range: ClosedRange<Date>) -> Counts {
        let workRecords = history.records.filter {
            $0.phase == .work && range.contains($0.endedAt)
        }
        return reduceCounts(workRecords)
    }

    private func reduceCounts(_ records: [PomodoroRecord]) -> Counts {
        var c = Counts(completed: 0, partial: 0, abandoned: 0)
        for r in records {
            switch r.outcome {
            case .completed: c.completed += 1
            case .partial: c.partial += 1
            case .abandoned: c.abandoned += 1
            }
        }
        return c
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/PomodoroStatsTests
```

Expected: 7 tests pass.

- [ ] **Step 5: Replace `PomodoroStatsPopover` placeholder**

In `NemoNotch/Tabs/PomodoroTab+StatsPopover.swift`:

```swift
import SwiftUI

struct PomodoroStatsPopover: View {
    @Environment(PomodoroHistoryStore.self) var historyStore
    @Environment(TaskStore.self) var taskStore

    var body: some View {
        let stats = PomodoroStats(history: historyStore)
        VStack(alignment: .leading, spacing: 12) {
            countsSection(title: String(localized: "pomodoro.stats.today"), counts: stats.today())
            Divider()
            countsSection(title: String(localized: "pomodoro.stats.week"), counts: stats.week())
            Divider()
            allTimeSection(stats: stats)
            Divider()
            recentSection(stats: stats)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private func countsSection(title: String, counts: PomodoroStats.Counts) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold))
            HStack(spacing: 6) {
                Text("✓ \(counts.completed)")
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text("~ \(counts.partial)")
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text("✗ \(counts.abandoned)")
            }
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textSecondary)
        }
    }

    @ViewBuilder
    private func allTimeSection(stats: PomodoroStats) -> some View {
        let all = stats.allTime()
        VStack(alignment: .leading, spacing: 2) {
            Text("pomodoro.stats.all")
                .font(.system(size: 11, weight: .semibold))
            HStack(spacing: 6) {
                Text("✓ \(all.completed)")
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text("~ \(all.partial)")
                Text("·").foregroundStyle(NotchTheme.textTertiary)
                Text("✗ \(all.abandoned)")
            }
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textSecondary)
            if let freq = stats.mostFrequentTaskID(),
               let task = taskStore.tasks.first(where: { $0.id == freq.taskID }) {
                Text(String(format: String(localized: "pomodoro.stats.mostFrequent"),
                            task.title, freq.count))
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func recentSection(stats: PomodoroStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("pomodoro.stats.recent")
                .font(.system(size: 11, weight: .semibold))
            ForEach(stats.recent(limit: 5)) { r in
                recentRow(r)
            }
        }
    }

    @ViewBuilder
    private func recentRow(_ r: PomodoroRecord) -> some View {
        HStack(spacing: 6) {
            Text(r.endedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NotchTheme.textTertiary)
            Text(taskTitle(for: r))
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text(outcomeLabel(r))
                .font(.system(size: 10))
                .foregroundStyle(outcomeColor(r.outcome))
        }
    }

    private func taskTitle(for r: PomodoroRecord) -> String {
        if let id = r.taskID, let t = taskStore.tasks.first(where: { $0.id == id }) {
            return t.title
        }
        return "—"
    }

    private func outcomeLabel(_ r: PomodoroRecord) -> String {
        let minutes = Int(r.actualDuration / 60)
        switch r.outcome {
        case .completed: return "\(minutes)✓"
        case .partial: return "partial \(minutes)"
        case .abandoned: return "✗"
        }
    }

    private func outcomeColor(_ o: PomodoroRecord.Outcome) -> Color {
        switch o {
        case .completed: return NotchTheme.accent
        case .partial: return Color.orange.opacity(0.9)
        case .abandoned: return NotchTheme.textTertiary
        }
    }
}
```

- [ ] **Step 6: Build + manual test**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Run a couple of pomodoros (use 1-min duration for speed). Open the popover from the 📊 button. Verify all four sections render.

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Tabs/PomodoroTab+StatsPopover.swift NemoNotch/Services/PomodoroStats.swift \
        NemoNotchTests/PomodoroStatsTests.swift NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(pomodoro): stats popover with numeric today/week/all + recent 5"
```

---

## Task 35: Localization keys

(spec §Localization — full key table)

**Files:**
- Modify: `NemoNotch/Localizable.xcstrings`

`Localizable.xcstrings` is a structured JSON file. Best edited in Xcode's String Catalog UI (open it, click "+" to add a new key, type translations into the language columns).

Programmatic edit alternative: append to the `strings` object in the JSON file. The schema is one entry per key:

```json
"pomodoro.quick.placeholder" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "What are you working on?" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "在做什么？" } }
  }
}
```

- [ ] **Step 1: Add all PR 1 keys**

In Xcode, open `Localizable.xcstrings`. For each row below, add the key and fill English + 简体中文 columns. PR 2-only keys (search, tags, due-date) are deferred.

| Key | en | zh-Hans |
|---|---|---|
| `models.tab.pomodoro` | Pomodoro | 番茄钟 |
| `pomodoro.quick.placeholder` | What are you working on? | 在做什么？ |
| `pomodoro.quick.priority` | Priority | 优先级 |
| `pomodoro.quick.duration` | Duration | 时长 |
| `pomodoro.quick.duration.placeholder` | Duration | 时长 |
| `pomodoro.quick.mode.single` | Single | 单次 |
| `pomodoro.quick.mode.continuous` | Continuous | 持续 |
| `pomodoro.quick.notes` | Notes (optional) | 备注（可选） |
| `pomodoro.quick.addNotes` | + Add notes | + 添加备注 |
| `pomodoro.quick.overrideWarning` | Current pomodoro will be overridden (counted as partial) | 当前番茄钟将被覆盖（计为部分完成） |
| `pomodoro.priority.low` | Low | 低 |
| `pomodoro.priority.medium` | Medium | 中 |
| `pomodoro.priority.high` | High | 高 |
| `pomodoro.phase.work` | Work | 工作 |
| `pomodoro.phase.shortBreak` | Short Break | 短休息 |
| `pomodoro.phase.longBreak` | Long Break | 长休息 |
| `pomodoro.phase.next` | Next: %@ | 接下来：%@ |
| `pomodoro.phase.counter` | %d/%d | 第 %d/%d 个 |
| `pomodoro.phase.singleWork` | Single work | 单次工作 |
| `pomodoro.action.pause` | Pause | 暂停 |
| `pomodoro.action.resume` | Resume | 继续 |
| `pomodoro.action.completeEarly` | Complete Early | 提前完成 |
| `pomodoro.action.abandon` | Abandon | 放弃 |
| `pomodoro.action.start` | Start | 开始 |
| `pomodoro.action.newTask` | + New | + 新建 |
| `pomodoro.action.newPomodoro` | + New Pomodoro | + 新建番茄钟 |
| `pomodoro.confirm.completeEarly` | %@ remaining, complete early? | 还有 %@ 剩余，确定提前完成？ |
| `pomodoro.confirm.abandon` | Abandon current pomodoro? | 放弃当前番茄钟？ |
| `pomodoro.confirm.override` | Override the current pomodoro to start "%@"? | 覆盖当前番茄钟以开始"%@"？ |
| `pomodoro.todo.countHeader` | TODO (%d) | 待办 (%d) |
| `pomodoro.todo.empty` | No tasks. Use the hotkey or + New | 暂无任务，按快捷键或点击 + 新建 |
| `pomodoro.todo.showCompleted` | Show completed | 显示已完成 |
| `pomodoro.todo.edit` | Edit | 编辑 |
| `pomodoro.todo.pin` | Pin to top | 置顶 |
| `pomodoro.todo.delete` | Delete | 删除 |
| `pomodoro.active.remaining` | %@ remaining | %@ 剩余 |
| `pomodoro.active.noTask` | (No task) | （无任务） |
| `pomodoro.edit.title` | Edit Task | 编辑任务 |
| `pomodoro.edit.titleField` | Title | 标题 |
| `pomodoro.edit.priorityField` | Priority | 优先级 |
| `pomodoro.edit.notes` | Notes | 备注 |
| `pomodoro.edit.createdAt` | Created: %@ | 创建于：%@ |
| `pomodoro.edit.completedCount` | Completed: %d pomodoros | 完成情况：%d 个番茄钟 |
| `pomodoro.stats.today` | Today | 今日 |
| `pomodoro.stats.week` | Week | 本周 |
| `pomodoro.stats.all` | All | 全部 |
| `pomodoro.stats.mostFrequent` | Most frequent: %@ %d | 最常做：%@ %d |
| `pomodoro.stats.recent` | Recent 5 | 最近 5 次 |
| `pomodoro.notification.workEnd.title` | Pomodoro complete 🍅 | 番茄钟结束 🍅 |
| `pomodoro.notification.breakEnd.title` | Break over | 休息结束 |
| `pomodoro.notification.body.withTask` | %@ · %d min done | %@ · %d 分钟完成 |
| `pomodoro.notification.body.noTask` | %d min done | %d 分钟完成 |
| `permission.notification.title` | Notifications | 通知 |
| `permission.notification.detail` | Send a system notification when a pomodoro ends | 番茄钟结束时发送系统通知 |
| `settings.pomodoro.title` | Pomodoro | 番茄钟 |
| `settings.pomodoro.minutes` | %d min | %d 分钟 |
| `settings.pomodoro.workDuration` | Work duration | 工作时长 |
| `settings.pomodoro.shortBreakDuration` | Short break duration | 短休息时长 |
| `settings.pomodoro.longBreakDuration` | Long break duration | 长休息时长 |
| `settings.pomodoro.longBreakInterval` | Long break interval | 长休息间隔 |
| `settings.pomodoro.longBreakInterval.unit` | After %d work | %d 个工作后 |
| `settings.pomodoro.soundEnabled` | Play sound at end | 结束时播放声音 |
| `settings.pomodoro.notificationEnabled` | Send notification at end | 结束时发送系统通知 |
| `settings.pomodoro.hotkeyHeader` | Hotkeys | 快捷键 |
| `settings.pomodoro.hotkey.openTab` | Open Pomodoro tab | 打开番茄钟 Tab |
| `settings.pomodoro.hotkey.quickStart` | Open quick start | 打开快速启动窗口 |
| `settings.pomodoro.permissionHeader` | Notification permission | 通知权限 |
| `settings.pomodoro.permission.granted` | Notifications authorized | 已授权通知 |
| `button.cancel` | Cancel | 取消 |
| `button.save` | Save | 保存 |
| `button.confirm` | Confirm | 确认 |

(`button.cancel` / `button.save` / `button.confirm` may already exist — check before adding.)

- [ ] **Step 2: Build, launch, switch language between en / zh-Hans, verify**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

In the app: Settings → Language → switch and confirm Pomodoro UI re-localizes correctly.

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Localizable.xcstrings
git commit -m "i18n(pomodoro): add PR 1 localization keys (en + zh-Hans)"
```

---

## Task 36: Documentation updates

(spec §Architecture · CLAUDE.md badge priority order · cookbook entries)

**Files:**
- Modify: `README.md`, `README_CN.md`
- Modify: `CLAUDE.md`
- Modify: `docs/macos-cookbook.md`

- [ ] **Step 1: Add feature blurb to `README.md` and `README_CN.md`**

Find the existing feature bullet list (or feature section) and add an entry. Example for `README_CN.md`:

```markdown
- **番茄钟 + TODO**：经典周期（25 工作 / 5 休息 / 每 4 个长休息），快捷键呼出居中浮窗一键启动，notch 折叠态显示 🍅 + 饼图剩余时间。任务列表持久化，每个任务累计番茄钟数；统计页含今日 / 本周 / 全部维度。
```

For `README.md`, English equivalent:

```markdown
- **Pomodoro + TODO**: Classic cycle (25 work / 5 break / long break every 4), hotkey-summoned centered panel for one-shot start, collapsed-notch shows 🍅 + remaining-time pie. Persistent task list with per-task completed-pomodoro counts; stats popover with today / week / all-time aggregation.
```

- [ ] **Step 2: Update `CLAUDE.md`**

In the architecture section's Services list, add `PomodoroTimerService`, `TaskStore`, `PomodoroHistoryStore`, `NotificationPermissionMonitor`. In the Tabs list add `PomodoroTab`.

Update the **Badge Priority** section to the new order:

```markdown
### Badge Priority (when notch is collapsed)

```
ai approval > notification > pomodoro running > agents active > ai working > media playing > calendar upcoming
```
```

Add a brief note on the new hotkeys:

```markdown
**Pomodoro hotkeys:** `openPomodoro` opens the Pomodoro tab; `openQuickStart` toggles the centered QuickStart panel. Neither has a default binding — users must set them in Settings → Pomodoro.
```

- [ ] **Step 3: Add macOS cookbook entries**

Append to `docs/macos-cookbook.md`. Find the section header for "Window & Notch" or similar. Add:

```markdown
### Centered Draggable NSPanel

A borderless, click-outside-dismissable, all-Spaces NSPanel for quick utilities (like the Pomodoro QuickStart window). Pattern:

- `NSPanel` subclass with `styleMask: [.borderless, .nonactivatingPanel]`
- `isFloatingPanel = true`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .transient]`
- `isMovableByWindowBackground = true` — entire window is the drag handle (no titlebar needed)
- `override var canBecomeKey: Bool { true }` — required so embedded TextField receives keyboard input
- Click-outside dismiss via `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)`; uninstall on dismiss
- Restore previous-frontmost app via `previousApp?.activate()` so the user returns to their flow

Example: `NemoNotch/Notch/QuickStartWindow.swift`, controller at `QuickStartWindowController.swift`.
```

And under "SwiftUI patterns" or a new "Drawing" section:

```markdown
### Pie Chart with SwiftUI Path Arc

Draw a remaining-time pie wedge that shrinks counterclockwise as time elapses:

```swift
GeometryReader { geo in
    let radius = min(geo.size.width, geo.size.height) / 2
    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
    Path { p in
        p.move(to: center)
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),                                     // 12 o'clock start
            endAngle: .degrees(-90 + 360 * remainingFraction),
            clockwise: false
        )
        p.closeSubpath()
    }
    .fill(color)
}
```

Wrap with a background `Circle().stroke(...)` for the empty wedge. Don't drive the fraction through a `BadgeItem` Equatable case — each-second change would re-trigger the badge spring animation. Pass identity through the case; read live fraction inside the view via `@Environment(SomeService.self)`.

Example: `NemoNotch/Notch/Badge/PomodoroPieView.swift`.
```

- [ ] **Step 4: Commit**

```bash
git add README.md README_CN.md CLAUDE.md docs/macos-cookbook.md
git commit -m "docs(pomodoro): README + CLAUDE.md + macOS cookbook entries"
```

---

## Verification Pass

After all 36 tasks land, do a full-suite verification before opening PR.

- [ ] **Run the full test suite**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'
```

Expected: all tests pass (TodoTask + TaskStore + History + TimerService + Stats = 50+ tests).

- [ ] **Smoke test the feature end-to-end**

1. Quit and relaunch the app to verify persistence-on-launch works
2. Open Settings → Pomodoro, bind both hotkeys (e.g. ⌥⌘6 and ⌥⌘T)
3. Press the QuickStart hotkey → centered panel appears
4. Type a task, pick 1-min duration, hit Enter → panel dismisses, pomodoro running
5. Open notch → Pomodoro tab → active block shows pie + task + controls
6. Collapse notch → 🍅 emoji + shrinking pie visible
7. Let it run out → sound + system notification + ring blink
8. autoFlow=continuous → break phase starts; verify after 4 work cycles long break fires
9. Pause → resume → completeEarly → abandon flows all work via UI
10. Restart app → in-progress pomodoro should write `abandoned` to history (verified via stats popover)
11. Toggle "Show completed" in TODO list → see done tasks
12. Edit a task via right-click → menu → Edit → sheet works
13. System sleep → wake → confirm pomodoro is abandoned, not paused

- [ ] **Open PR**

```bash
gh pr create --title "Pomodoro Timer + TODO (PR 1 / MVP)" --body "$(cat <<'EOF'
## Summary
- Adds three independent `@Observable` services (`TaskStore`, `PomodoroHistoryStore`, `PomodoroTimerService`)
- New Pomodoro Tab inside the notch with idle (TODO list + stats) and active (big pie + controls) states
- Centered draggable `QuickStartWindow` (borderless `NSPanel`) for one-shot pomodoro start
- Notch badge: 🍅 emoji + remaining-time pie chart, slots between notification and agents in priority
- End-of-phase alerts: sound (`Glass` / `Hero`) + `UNUserNotificationCenter` push + ring pulse
- System sleep + app quit → abandon active pomodoro
- Settings page with durations, interval, sound/notification toggles, hotkey recorders, `PermissionCard` for `UN` auth
- `tags` and `dueDate` fields baked into `TodoTask` from day 1; UI deferred to PR 2

## Test plan
- [ ] Unit tests pass (50+ in TodoTask/TaskStore/History/Timer/Stats)
- [ ] Smoke test end-to-end flow (start → pause → complete → autoFlow → notification)
- [ ] Verify persistence across app relaunch
- [ ] Verify hotkey rebind in Settings works
- [ ] Verify system sleep → abandon path

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Notes for the Implementing Agent

- **Always run `xcodebuild build` after creating a new file** — target membership errors are silent until next compile
- The state machine is the trickiest piece — write the test in Task 8/9/10 BEFORE the impl, run it red, then green
- For UI tasks, take screenshots and check against spec §Pomodoro Tab sketches — visual fidelity matters for this feature
- Localization keys can be added incrementally as each task lands, but consolidating into Task 35 keeps `Localizable.xcstrings` diff clean
- If you hit a `@Environment` injection runtime crash, check `AppDelegate` is calling `.environment(...)` for all three services + the controller
- Don't commit if `xcodebuild build` fails — fix it first






