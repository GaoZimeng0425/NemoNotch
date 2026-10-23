# Usage Quota Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persistent edge-bar cards when a quota window passes the user's threshold (and when it recovers), dismissed only by a 知道了 click.

**Architecture:** A pure detector folds quota readings into exceed/recover events; a pure list fold keeps one pending alert per (provider, window); `QuotaAlertMonitor` observes the quota service (self-polling every 5 min while the feature and the edge bar are on) and owns the pending list; the edge bar reuses its approval auto-card machinery — arrival-triggered open, held-open bar, geometry-routed button — for the alert card.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-23-quota-alert-design.md`

## Global Constraints

- Everything happens in this worktree (`.worktree/quota-alert`, branch `feature/quota-alert`). **Never run `./build.sh`** (it deploys to /Applications — the main session merges) and **never merge or run `git feat-done`**.
- Tests: Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`). Run with `sh scripts/test.sh --only <SuiteName>` from the worktree root. The first run is a cold build (several minutes); if the host crashes with 0 tests executed the script retries once — a *real* red test is never retried.
- All UI strings go into `NemoNotch/Resources/Localizable.xcstrings` via `python3 scripts/xcstrings.py set <key> --en "…" --zh "…"` (en + zh-Hans, both required). Never hand-edit the JSON.
- Swift 6 strict concurrency: new types are `@MainActor` classes or `Sendable` value types exactly as specified.
- Minimal change: no drive-by refactors, no formatting of untouched lines. Lint runs via pre-commit on `git commit` (SwiftFormat auto-fixes and re-stages; SwiftLint errors must be fixed in your own code).
- Commit after every task with the message given in the task's last step.

## Review Focus

Inputs/failure modes no unit-test pins end-to-end; the reviewer should check them in the diff, the last two live in the deployed app:

1. **Threshold changed while a window is over the old threshold** — must restart detection, never emit "recovered" for a bar that merely moved (Task 3's `threshold != current` branch; untestable without I/O seams — verify by reading).
2. **Alert arriving mid-drag** — consumed silently (the arrival edge passes while `isDragging`); acceptable per spec, but must not corrupt `knownAlerts` (Task 5's `defer` updates it anyway).
3. **Approval answered while an alert is pending** — the alert card must come back on the next exit/open, not strand a held-open bar with an unreachable card (Task 5 exit/open reclaim paths).
4. **Feature or edge bar toggled off while alerts pending** — monitor clears state; the bar must stop being held (auto-opened bars self-close on the next refresh since `alerts.alerts.isEmpty`).
5. **Live check after deployment:** over-threshold window opens the bar once (not on every refresh); recovery card appears after the window resets; 知道了 is the only thing that takes each card down.

---

### Task 1: Pure model — readings, detector, pending-alert fold

**Files:**
- Create: `NemoNotch/Models/QuotaAlert.swift`
- Test: `NemoNotchTests/QuotaAlertTests.swift`

**Interfaces (later tasks rely on these exactly):**

```swift
struct QuotaAlertKey: Hashable, Sendable {
    let provider: QuotaProvider
    let window: QuotaWindow
    var id: String                       // "claude:5h", "gemini:2.5 Pro", "codex:300m"
}
struct QuotaReading: Equatable, Sendable {
    let key: QuotaAlertKey
    let utilization: Double              // raw percent, not clamped
    let resetsAt: Date?
}
enum QuotaAlertDetector {                // pure, no UI imports needed beyond Foundation
    enum Event: Equatable { case exceeded(QuotaReading); case recovered(QuotaReading) }
    struct Outcome: Equatable { var events: [Event]; var above: Set<QuotaAlertKey> }
    static let hysteresis: Double = 5
    static func readings(from quotas: [QuotaProvider: ProviderUsageQuota]) -> [QuotaReading]
    static func plan(readings: [QuotaReading], above: Set<QuotaAlertKey>, threshold: Double) -> Outcome
}
struct QuotaAlert: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case exceeded, recovered }
    let key: QuotaAlertKey
    let kind: Kind
    let utilization: Double
    let resetsAt: Date?
    let threshold: Double
    let firedAt: Date
    var id: String { "\(key.id):\(kind.rawValue)" }   // "claude:5h:exceeded"
}
enum QuotaAlerts {                       // pure fold of the pending list
    static func apply(_ events: [QuotaAlertDetector.Event], to alerts: [QuotaAlert], threshold: Double, now: Date) -> [QuotaAlert]
    static func acknowledging(_ id: String, in alerts: [QuotaAlert]) -> [QuotaAlert]
}
```

`QuotaAlertKey.id` window text: `.fiveHour`→`"5h"`, `.sevenDay`→`"7d"`, `.sevenDayOpus`→`"7d-opus"`, `.sevenDaySonnet`→`"7d-sonnet"`, `.rolling(m)`→`"\(m)m"`, `.gemini(label)`→`label`.
`QuotaAlertKey` needs no custom Hashable — both fields are Hashable.

`readings(from:)`: iterate `QuotaProvider.allCases`; include a provider only when `quota.status == .valid && !quota.tiers.isEmpty`; map tiers in order.

`plan`: for each reading in order — if `!above.contains(key) && utilization >= threshold` → append `.exceeded`, insert key; else if `above.contains(key) && utilization < threshold - Self.hysteresis` → append `.recovered`, remove key. Keys absent from `readings` keep their membership. Write the two comparisons literally as `utilization >= threshold` and `utilization < threshold - Self.hysteresis`, each on its own line — Task 6's mutation checks target those exact strings.

`apply`: for each event in order, drop any alert in `alerts` whose `key` equals the event reading's key, then append `QuotaAlert(key:…, kind:…, utilization:…, resetsAt:…, threshold: threshold, firedAt: now)`. `acknowledging`: `alerts.filter { $0.id != id }`.

- [ ] **Step 1: Write the failing tests** — create `NemoNotchTests/QuotaAlertTests.swift` with exactly these two suites:

```swift
import Foundation
@testable import NemoNotch
import Testing

/// `QuotaAlertDetector`: edges of a window's share used against the
/// threshold — exceeded on the way up (arrival included), recovered only
/// once it is `hysteresis` under; a window missing from a reading changes nothing.
@Suite("QuotaAlertDetector")
struct QuotaAlertDetectorTests {
    private let claude5h = QuotaAlertKey(provider: .claude, window: .fiveHour)
    private let claude7d = QuotaAlertKey(provider: .claude, window: .sevenDay)

    private func reading(_ key: QuotaAlertKey, _ utilization: Double, resetsAt: Date? = nil) -> QuotaReading {
        QuotaReading(key: key, utilization: utilization, resetsAt: resetsAt)
    }

    @Test func crossingUpFiresExceededOnce() {
        let first = QuotaAlertDetector.plan(readings: [reading(claude5h, 79.9)], above: [], threshold: 80)
        #expect(first.events.isEmpty)
        #expect(first.above.isEmpty)
        let second = QuotaAlertDetector.plan(readings: [reading(claude5h, 80)], above: first.above, threshold: 80)
        #expect(second.events == [.exceeded(reading(claude5h, 80))])
        #expect(second.above == [claude5h])
        let third = QuotaAlertDetector.plan(readings: [reading(claude5h, 91)], above: second.above, threshold: 80)
        #expect(third.events.isEmpty)
        #expect(third.above == [claude5h])
    }

    @Test func aFirstReadingAlreadyOverFires() {
        let outcome = QuotaAlertDetector.plan(readings: [reading(claude5h, 95)], above: [], threshold: 80)
        #expect(outcome.events == [.exceeded(reading(claude5h, 95))])
    }

    @Test func recoveryNeedsTheHysteresis() {
        let wobble = QuotaAlertDetector.plan(readings: [reading(claude5h, 76)], above: [claude5h], threshold: 80)
        #expect(wobble.events.isEmpty)
        #expect(wobble.above == [claude5h])
        let reset = QuotaAlertDetector.plan(readings: [reading(claude5h, 74.9)], above: [claude5h], threshold: 80)
        #expect(reset.events == [.recovered(reading(claude5h, 74.9))])
        #expect(reset.above.isEmpty)
    }

    @Test func aMissingWindowKeepsItsState() {
        let outcome = QuotaAlertDetector.plan(readings: [], above: [claude5h], threshold: 80)
        #expect(outcome.events.isEmpty)
        #expect(outcome.above == [claude5h])
    }

    @Test func windowsAreIndependentAndOrdered() {
        let outcome = QuotaAlertDetector.plan(
            readings: [reading(claude5h, 85), reading(claude7d, 40)],
            above: [claude7d],
            threshold: 80
        )
        #expect(outcome.events == [.exceeded(reading(claude5h, 85)), .recovered(reading(claude7d, 40))])
        #expect(outcome.above == [claude5h])
    }

    @Test func aFullThresholdFiresOnlyAtOneHundred() {
        let near = QuotaAlertDetector.plan(readings: [reading(claude5h, 99.9)], above: [], threshold: 100)
        #expect(near.events.isEmpty)
        let full = QuotaAlertDetector.plan(readings: [reading(claude5h, 100)], above: [], threshold: 100)
        #expect(full.events == [.exceeded(reading(claude5h, 100))])
    }

    @Test func readingsComeOnlyFromValidQuotasWithTiers() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let quotas: [QuotaProvider: ProviderUsageQuota] = [
            .claude: ProviderUsageQuota(provider: .claude, status: .valid, tiers: [
                QuotaTier(window: .fiveHour, utilization: 81, resetsAt: reset),
                QuotaTier(window: .sevenDay, utilization: 12, resetsAt: nil),
            ]),
            .codex: ProviderUsageQuota(provider: .codex, status: .expired, tiers: [
                QuotaTier(window: .rolling(minutes: 300), utilization: 99, resetsAt: nil),
            ]),
            .gemini: ProviderUsageQuota(provider: .gemini, status: .valid, tiers: [], errorMessage: "timeout"),
        ]
        #expect(QuotaAlertDetector.readings(from: quotas) == [
            QuotaReading(key: claude5h, utilization: 81, resetsAt: reset),
            QuotaReading(key: claude7d, utilization: 12, resetsAt: nil),
        ])
    }
}

/// `QuotaAlerts`: the pending list — one alert per window, the newest
/// event speaks for it; acknowledging removes it.
@Suite("QuotaAlerts")
struct QuotaAlertsTests {
    private let claude5h = QuotaAlertKey(provider: .claude, window: .fiveHour)
    private let codex5h = QuotaAlertKey(provider: .codex, window: .rolling(minutes: 300))
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func anEventBecomesAPendingAlert() {
        let reading = QuotaReading(key: claude5h, utilization: 83, resetsAt: t0.addingTimeInterval(3600))
        let alerts = QuotaAlerts.apply([.exceeded(reading)], to: [], threshold: 80, now: t0)
        #expect(alerts == [QuotaAlert(
            key: claude5h, kind: .exceeded, utilization: 83,
            resetsAt: t0.addingTimeInterval(3600), threshold: 80, firedAt: t0
        )])
        #expect(alerts[0].id == "claude:5h:exceeded")
    }

    @Test func recoveryReplacesTheWindowsExceededAlert() {
        let exceeded = QuotaAlerts.apply(
            [.exceeded(QuotaReading(key: claude5h, utilization: 83, resetsAt: nil))],
            to: [], threshold: 80, now: t0
        )
        let later = t0.addingTimeInterval(600)
        let alerts = QuotaAlerts.apply(
            [.recovered(QuotaReading(key: claude5h, utilization: 2, resetsAt: nil))],
            to: exceeded, threshold: 80, now: later
        )
        #expect(alerts == [QuotaAlert(key: claude5h, kind: .recovered, utilization: 2, resetsAt: nil, threshold: 80, firedAt: later)])
    }

    @Test func windowsQueueOldestFirstAndAReplacedOneMovesLast() {
        let a = QuotaAlerts.apply([.exceeded(QuotaReading(key: claude5h, utilization: 83, resetsAt: nil))], to: [], threshold: 80, now: t0)
        let b = QuotaAlerts.apply([.exceeded(QuotaReading(key: codex5h, utilization: 90, resetsAt: nil))], to: a, threshold: 80, now: t0.addingTimeInterval(60))
        #expect(b.map(\.id) == ["claude:5h:exceeded", "codex:300m:exceeded"])
        let c = QuotaAlerts.apply([.recovered(QuotaReading(key: claude5h, utilization: 1, resetsAt: nil))], to: b, threshold: 80, now: t0.addingTimeInterval(120))
        #expect(c.map(\.id) == ["codex:300m:exceeded", "claude:5h:recovered"])
    }

    @Test func acknowledgingRemovesOnlyThatAlert() {
        let a = QuotaAlerts.apply(
            [.exceeded(QuotaReading(key: claude5h, utilization: 83, resetsAt: nil)),
             .exceeded(QuotaReading(key: codex5h, utilization: 90, resetsAt: nil))],
            to: [], threshold: 80, now: t0
        )
        #expect(QuotaAlerts.acknowledging("claude:5h:exceeded", in: a).map(\.id) == ["codex:300m:exceeded"])
        #expect(QuotaAlerts.acknowledging("nobody", in: a) == a)
    }

    @Test func keyIDsNameTheWindow() {
        #expect(QuotaAlertKey(provider: .claude, window: .sevenDayOpus).id == "claude:7d-opus")
        #expect(QuotaAlertKey(provider: .gemini, window: .gemini(label: "2.5 Pro")).id == "gemini:2.5 Pro")
        #expect(QuotaAlertKey(provider: .zcode, window: .rolling(minutes: 10080)).id == "zcode:10080m")
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `sh scripts/test.sh --only QuotaAlertDetectorTests` → compile error (no `QuotaAlertKey`).
- [ ] **Step 3: Implement `NemoNotch/Models/QuotaAlert.swift`** per the Interfaces block; the file needs only `import Foundation`. Doc comments in the house style (what it decides, the sharp edges — mirror `WaitingReminderMonitor.swift`'s pure `WaitingReminder` enum tone).
- [ ] **Step 4: Run both suites green** — `sh scripts/test.sh --only QuotaAlertDetectorTests` and `sh scripts/test.sh --only QuotaAlertsTests` → PASS (exit 0, quote the counts).
- [ ] **Step 5: Commit** — `git add NemoNotch/Models/QuotaAlert.swift NemoNotchTests/QuotaAlertTests.swift && git commit -m "feat(quota): pure alert detector and pending-alert fold"`

### Task 2: Settings — keys, defaults, Alerts page section

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift` (keys after `waitingReminderMinutesKey`; stored props after `waitingReminderMinutes`; loads in `init` after the `waitingReminderMinutes` load)
- Modify: `NemoNotch/Settings/Pages/AlertsSettingsPage.swift` (new section after the waiting-reminder section)
- Modify: `NemoNotch/Resources/Localizable.xcstrings` (via the script)

**Interfaces:**

```swift
static let quotaAlertEnabledKey = "quotaAlertEnabled"
static let quotaAlertThresholdKey = "quotaAlertThreshold"
/// Edge-bar cards when a quota window passes `quotaAlertThreshold` (and when
/// it recovers), held until acknowledged. Default off — alerts are opt-in,
/// like `waitingReminderEnabled`.
var quotaAlertEnabled: Bool   // didSet persists; loads `?? false`
/// Percent used (50...100) that fires the alert. Loads `?? 80`.
var quotaAlertThreshold: Int  // didSet persists
```

- [ ] **Step 1: Add the AppSettings properties** exactly as above (three insertion sites: key constants, stored properties with didSet, `init` loads using `object(forKey:) as? Int / as? Bool` like the neighbours).
- [ ] **Step 2: Add the settings section** in `AlertsSettingsPage` after the `settings.waiting_reminder.header` section:

```swift
Section("settings.quota_alert.header") {
    Toggle("settings.quota_alert.enabled", isOn: Binding(
        get: { appSettings.quotaAlertEnabled },
        set: { appSettings.quotaAlertEnabled = $0 }
    ))
    .toggleStyle(.switch)
    Picker("settings.quota_alert.threshold", selection: Binding(
        get: { appSettings.quotaAlertThreshold },
        set: { appSettings.quotaAlertThreshold = $0 }
    )) {
        ForEach([50, 60, 70, 80, 90, 100], id: \.self) { percent in
            Text(verbatim: "\(percent)%").tag(percent)
        }
    }
    if !appSettings.aiStatusFabEnabled {
        Text("settings.quota_alert.needs_bar")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 3: Add the localization keys** (from the worktree root):

```sh
python3 scripts/xcstrings.py set settings.quota_alert.header --en "Usage alerts" --zh "用量提醒"
python3 scripts/xcstrings.py set settings.quota_alert.enabled --en "Alert when a quota window passes the threshold" --zh "配额用量超过阈值时提醒"
python3 scripts/xcstrings.py set settings.quota_alert.threshold --en "Threshold" --zh "阈值"
python3 scripts/xcstrings.py set settings.quota_alert.needs_bar --en "Alerts appear as cards on the edge bar, which is off." --zh "提醒以边栏卡片显示；边栏当前已关闭。"
python3 scripts/xcstrings.py check
```

- [ ] **Step 4: Verify it compiles** — `sh scripts/test.sh --only QuotaAlertsTests` → PASS (the run builds the app target; the settings page is compiled by it).
- [ ] **Step 5: Commit** — `git commit -am "feat(quota): usage-alert settings (default off, threshold picker)"`

### Task 3: QuotaAlertMonitor + composition root

**Files:**
- Create: `NemoNotch/Services/QuotaAlertMonitor.swift`
- Modify: `NemoNotch/Helpers/AppDependencies.swift`

**Interfaces (Task 5 relies on these exactly):**

```swift
@MainActor @Observable
final class QuotaAlertMonitor {
    /// Not yet acknowledged, oldest first.
    private(set) var alerts: [QuotaAlert] = []
    /// On while the alerts and the edge bar (their only surface) are on.
    var isActive: Bool { appSettings.quotaAlertEnabled && appSettings.aiStatusFabEnabled }
    init(usageQuota: UsageQuotaService, appSettings: AppSettings)
    func start()             // idempotent; no-op under UITestMode.isActive / UITestMode.isTestHost
    func acknowledge(_ id: String)
}
```

- [ ] **Step 1: Implement the monitor** in the shape of `WaitingReminderMonitor` (read it first): `start()` guards test modes then calls `observe()`; `observe()` re-arms `withObservationTracking` over `usageQuota.quotas`, `appSettings.quotaAlertEnabled`, `appSettings.aiStatusFabEnabled`, `appSettings.quotaAlertThreshold` and re-runs `evaluate()` on change (re-arm BEFORE acting, exactly like `WaitingReminderMonitor.observe`). `evaluate()`:
  - `syncPolling(active:)`: while active and no timer, start `Timer(timeInterval: usageQuota.refreshInterval, repeats: true)` whose block does `Task { @MainActor [weak self] in await self?.usageQuota.refresh(force: false) }` (tolerance 30, `.common` mode) and fire one immediate `Task { await usageQuota.refresh(force: false) }`; while inactive, invalidate the timer. Mirror `UsageQuotaService`'s timer/deinit style (`deinit` invalidates under `MainActor.assumeIsolated`).
  - When inactive: clear `alerts` and the private `above` set when non-empty (log `.info`, category `"QuotaAlert"`) and return.
  - Track the last-evaluated threshold privately; when `appSettings.quotaAlertThreshold` differs, clear `above` and `alerts` (restart detection — a raised threshold must not emit "recovered").
  - `let outcome = QuotaAlertDetector.plan(readings: QuotaAlertDetector.readings(from: usageQuota.quotas), above: above, threshold: Double(appSettings.quotaAlertThreshold))`; adopt `outcome.above`; when events are non-empty fold them with `QuotaAlerts.apply(…, now: Date())` and log each at `.info` (key id, kind, rounded utilization).
  - `acknowledge(_:)` = `alerts = QuotaAlerts.acknowledging(id, in: alerts)` + `.info` log.
  - `LogService.info("QuotaAlertMonitor init", category: "QuotaAlert")` in init, mirroring the house pattern.
- [ ] **Step 2: Wire the composition root** in `AppDependencies.build()` right after `let usageQuota = UsageQuotaService()`: `let quotaAlerts = QuotaAlertMonitor(usageQuota: usageQuota, appSettings: settings)`; call `quotaAlerts.start()` (self-guarding — safe unconditionally); add `let quotaAlerts: QuotaAlertMonitor` to the struct under "AI-derived events" and to the memberwise `AppDependencies(...)` initializer call. Do NOT pass it to `EdgeBarController` yet (Task 5).
- [ ] **Step 3: Verify it compiles** — `sh scripts/test.sh --only QuotaAlertsTests` → PASS.
- [ ] **Step 4: Commit** — `git commit -am "feat(quota): QuotaAlertMonitor observes and polls while enabled"`

### Task 4: Edge bar pure decisions — card ids, auto plan, reclaim

**Files:**
- Create: `NemoNotch/Notch/EdgeBar/EdgeBarAlertCard.swift` (only the `EdgeBarAlertCards` enum in this task; the view comes in Task 5)
- Test: `NemoNotchTests/EdgeBarAlertCardsTests.swift`

**Interfaces (Task 5 relies on these exactly):**

```swift
/// When a quota alert brings its card up on its own — decided apart from
/// the controller, like `EdgeBarAutoCard`.
enum EdgeBarAlertCards {
    struct Decision: Equatable { var open = false; var select: String? }
    static func cardID(_ alert: QuotaAlert) -> String        // "alert:" + alert.id
    static func alertID(ofCardID id: String) -> String?      // strips "alert:", else nil
    /// Open the closed bar for a newly arrived alert; take the card on an open
    /// one — never from a selected approval. Old alerts never reopen a folded
    /// bar; they only fill a free card.
    static func plan(previous: [String], pending: [String], isOpen: Bool, selectedRow: String?, approvalSelected: Bool) -> Decision
    /// The pending alert to bring back when the cursor leaves (or the bar opens
    /// by hover) and nothing else has the card: oldest pending, none when an
    /// approval holds the card or a pending alert already does.
    static func reclaim(pending: [String], selectedRow: String?, approvalSelected: Bool) -> String?
}
```

`plan` semantics: `arrived = pending.filter { !previous.contains($0) }`; with an arrival and a closed bar → `Decision(open: true, select: arrived.first)`; with an arrival and an open bar → `approvalSelected ? Decision() : Decision(select: arrived.first)`; without an arrival → `Decision(select: isOpen && selectedRow == nil ? reclaim(pending: pending, selectedRow: nil, approvalSelected: approvalSelected) : nil)`.

- [ ] **Step 1: Write the failing tests** — create `NemoNotchTests/EdgeBarAlertCardsTests.swift`:

```swift
import Foundation
@testable import NemoNotch
import Testing

/// `EdgeBarAlertCards`: when a quota alert brings its card up on its own —
/// only on arrival (a folded bar stays folded for alerts it already showed),
/// never over a held approval; a pending alert is reclaimed when nothing is up.
@Suite("EdgeBarAlertCards")
struct EdgeBarAlertCardsTests {
    private let a = "alert:claude:5h:exceeded"
    private let b = "alert:codex:300m:exceeded"

    @Test func anArrivalOpensTheClosedBar() {
        let decision = EdgeBarAlertCards.plan(previous: [], pending: [a], isOpen: false, selectedRow: nil, approvalSelected: false)
        #expect(decision == EdgeBarAlertCards.Decision(open: true, select: a))
    }

    @Test func anArrivalTakesTheCardOnAnOpenBar() {
        let decision = EdgeBarAlertCards.plan(previous: [a], pending: [a, b], isOpen: true, selectedRow: "session-1", approvalSelected: false)
        #expect(decision == EdgeBarAlertCards.Decision(open: false, select: b))
    }

    @Test func anArrivalWaitsBehindAHeldApproval() {
        let decision = EdgeBarAlertCards.plan(previous: [], pending: [a], isOpen: true, selectedRow: "session-1", approvalSelected: true)
        #expect(decision == EdgeBarAlertCards.Decision())
    }

    @Test func oldAlertsNeverReopenAFoldedBar() {
        let decision = EdgeBarAlertCards.plan(previous: [a], pending: [a], isOpen: false, selectedRow: nil, approvalSelected: false)
        #expect(decision == EdgeBarAlertCards.Decision())
    }

    @Test func aFreeCardOnAnOpenBarIsReclaimed() {
        let decision = EdgeBarAlertCards.plan(previous: [a, b], pending: [a, b], isOpen: true, selectedRow: nil, approvalSelected: false)
        #expect(decision == EdgeBarAlertCards.Decision(open: false, select: a))
    }

    @Test func aCardAlreadyUpIsLeftAlone() {
        let decision = EdgeBarAlertCards.plan(previous: [a, b], pending: [a, b], isOpen: true, selectedRow: b, approvalSelected: false)
        #expect(decision == EdgeBarAlertCards.Decision())
    }

    @Test func nothingPendingDecidesNothing() {
        #expect(EdgeBarAlertCards.plan(previous: [a], pending: [], isOpen: true, selectedRow: nil, approvalSelected: false) == EdgeBarAlertCards.Decision())
    }

    @Test func reclaimPicksTheOldestUnlessOneIsUpOrAnApprovalIs() {
        #expect(EdgeBarAlertCards.reclaim(pending: [a, b], selectedRow: "session-1", approvalSelected: false) == a)
        #expect(EdgeBarAlertCards.reclaim(pending: [a, b], selectedRow: b, approvalSelected: false) == nil)
        #expect(EdgeBarAlertCards.reclaim(pending: [a, b], selectedRow: "session-1", approvalSelected: true) == nil)
        #expect(EdgeBarAlertCards.reclaim(pending: [], selectedRow: nil, approvalSelected: false) == nil)
    }

    @Test func cardIDsRoundTrip() {
        let alert = QuotaAlert(
            key: QuotaAlertKey(provider: .claude, window: .fiveHour),
            kind: .exceeded, utilization: 90, resetsAt: nil, threshold: 80,
            firedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(EdgeBarAlertCards.cardID(alert) == a)
        #expect(EdgeBarAlertCards.alertID(ofCardID: a) == "claude:5h:exceeded")
        #expect(EdgeBarAlertCards.alertID(ofCardID: "usage:claude") == nil)
        #expect(EdgeBarAlertCards.alertID(ofCardID: "abc123") == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `sh scripts/test.sh --only EdgeBarAlertCardsTests` → compile error.
- [ ] **Step 3: Implement `EdgeBarAlertCards`** (the enum only, in `EdgeBarAlertCard.swift`) per the Interfaces block. Keep the arrival filter one literal line — `let arrived = pending.filter { !previous.contains($0) }` — the Task 6 mutation targets it.
- [ ] **Step 4: Run green** — `sh scripts/test.sh --only EdgeBarAlertCardsTests` → PASS.
- [ ] **Step 5: Commit** — `git add NemoNotch/Notch/EdgeBar/EdgeBarAlertCard.swift NemoNotchTests/EdgeBarAlertCardsTests.swift && git commit -m "feat(quota): edge-bar alert card decisions (pure)"`

### Task 5: Alert card view + controller wiring

**Files:**
- Modify: `NemoNotch/Notch/EdgeBar/EdgeBarAlertCard.swift` (add the view)
- Modify: `NemoNotch/Notch/EdgeBar/EdgeBarController.swift`
- Modify: `NemoNotch/Notch/EdgeBar/EdgeBarCard.swift` (two spots)
- Modify: `NemoNotch/Helpers/AppDependencies.swift` (EdgeBarController call site)
- Modify: `NemoNotch/Resources/Localizable.xcstrings` (via the script)

**Interfaces consumed:** everything from Tasks 1–4.

- [ ] **Step 1: Add the `EdgeBarAlertCard` view** to `EdgeBarAlertCard.swift`, styled after `EdgeBarUsageCard` (same `ground`, `secondary`, padding 18, corner 16, `EdgeBarMetrics.cardWidth` frame, `clipShape` + `strokeBorder` + `shadow`, `EdgeBarMotion.cardContent` animation on `alert`). Body = `TimelineView(.everyMinute)` holding a `VStack(alignment: .leading, spacing: 14)`:
  - header: `Text(verbatim: EdgeBarUsage.heading(alert.key.provider))` (9 pt semibold, secondary, kerning 0.5) + `Spacer` + kind title (10 pt semibold; exceeded → `EdgeBarUsageLevel.critical.color`, recovered → `EdgeBarPalette.green`; text from the new keys).
  - window block: `Text(verbatim: EdgeBarUsageCardText.name(alert.key.window))` (13 pt semibold) + `Spacer` + `Text(verbatim: "\(Int(alert.utilization.rounded()))%")` (monospaced digit 18 pt semibold, colour `EdgeBarUsageLevel(percent: alert.utilization).color`); then a meter (copy `EdgeBarUsageCard.meter`'s capsule drawing, private is fine); then `Text` of `String(format: String(localized: "edge_bar.alert.threshold_fmt"), Int(alert.threshold))` (11 pt, secondary); then `EdgeBarUsageCardText.reset(alert.resetsAt, now:)` when non-nil (11 pt monospaced digit, secondary).
  - button: a loud card button — `String(localized: "edge_bar.alert.acknowledge")`, 12 pt semibold black on `EdgeBarPalette.amber.opacity(hovered ? 1 : 0.9)`, height 32, corner 9, hover/press treatment copied from `EdgeBarCard.cardButton(_:title:loud:)`, ending in `.reportingFrame(.acknowledge, to: bar)`. `@Environment(EdgeBarController.self) private var bar`.
- [ ] **Step 2: Expose `reportingFrame`** — in `EdgeBarCard.swift` change `private extension View` (the one defining `reportingFrame`) to `extension View` so the alert card file can use it. No other change to that block.
- [ ] **Step 3: Render the card** — in `EdgeBarCardLayer.card(_:)` (`EdgeBarCard.swift`), before the `usage:` branch: `if let alert = bar.alert(ofCardID: id) { EdgeBarAlertCard(alert: alert).transition(EdgeBarMotion.cardTransition(bar.side)) } else if let provider = …` (keep the existing branches as the else-chain).
- [ ] **Step 4: Wire the controller** (`EdgeBarController.swift`; read `refresh`, `autoCard`, `pointer`, `openBar`, `select`, `revalidateSelection`, `perform` first):
  - `enum CardButton`: add `/// Acknowledges a quota alert (its card goes).` `case acknowledge`.
  - New stored dependency `@ObservationIgnored private let alerts: QuotaAlertMonitor` + init parameter `alerts: QuotaAlertMonitor,` (after `usageQuota:`); update `AppDependencies.build()`'s `EdgeBarController(...)` call to pass `alerts: quotaAlerts`.
  - `observe()`: track `_ = alerts.alerts` alongside `usageQuota.quotas`.
  - `@ObservationIgnored private var knownAlerts: [String] = []` — the alert cards the last refresh saw; arrivals are measured against it.
  - `refresh()`: call `autoAlert()` right after `autoCard(previous:next:)`.
  - New `// MARK: - Alerts` section with:
    - `private var pendingAlertCards: [String] { alerts.alerts.map(EdgeBarAlertCards.cardID) }`
    - `private var approvalSelected: Bool { selectedRow.flatMap { store.get($0)?.phase.isWaitingForApproval } ?? false }`
    - `/// An open bar with an alert pending does not fold on an exit — the alert must be seen and acknowledged.` `private var holdsBarForAlert: Bool { isOpen && !alerts.alerts.isEmpty }`
    - `func alert(ofCardID id: String) -> QuotaAlert?` — first pending whose `cardID` equals `id`.
    - `private func alertLevel(_ alert: QuotaAlert) -> CGFloat` — `EdgeBarUsage.sectionTop(of: alert.key.provider, in: usageLines, rows: content.rows.count) ?? EdgeBarUsage.top(rows: content.rows.count)` (a section cut for room puts the card at the block's top).
    - `private func autoAlert()` — mirror `autoCard`'s structure: `let pending = pendingAlertCards; defer { knownAlerts = pending }`; `guard !UITestMode.isActive, !isDragging else { return }`; run `EdgeBarAlertCards.plan(previous: knownAlerts, pending: pending, isOpen: isOpen, selectedRow: selectedRow, approvalSelected: approvalSelected)`; on `decision.open` (with a select) do `hover.openNow()`, `autoOpened = true`, `.info` log "Auto-opened the bar: quota alert \(id)" (category `"EdgeBar"`), `select(id)`; else on `decision.select` log + `select(id)`.
  - `autoCard`'s auto-close line `if autoOpened, !next.rows.contains(where: \.phase.isWaitingForApproval) {` gains `, alerts.alerts.isEmpty` and its log becomes `"Auto-closed the bar: no approval waiting, no alert pending"`.
  - `pointer(.exited)`: replace `if !holdsBarForApproval { hover.pointerExited() }` with:
    ```swift
    if holdsBarForApproval || holdsBarForAlert {
        // A held bar is not the cursor's to fold. Leaving it with an alert
        // pending brings the alert's card back (a hovered row's card had it).
        if let id = EdgeBarAlertCards.reclaim(pending: pendingAlertCards, selectedRow: selectedRow, approvalSelected: approvalSelected) {
            select(id)
        }
    } else {
        hover.pointerExited()
    }
    ```
  - `openBar()`: after `updateBeat()`, before the still-cursor row block: `if let id = EdgeBarAlertCards.reclaim(pending: pendingAlertCards, selectedRow: selectedRow, approvalSelected: approvalSelected) { select(id) }` (a hover-opened bar shows the pending alert when nothing else is up).
  - `select(_ id:)`: before the `usage:` branch —
    ```swift
    if let alert = alert(ofCardID: id) {
        // An alert card has one button of its own; none of a session card's may linger.
        buttonRects = [:]
        hoveredButton = nil
        pressedButton = nil
        cardLevel = alertLevel(alert)
        selectedRow = id
        return
    }
    ```
  - `revalidateSelection()`: before the `usage:` branch — if the selected id is an alert card (`EdgeBarAlertCards.alertID(ofCardID:) != nil`): when the alert is still pending `setIfChanged(\.cardLevel, alertLevel(alert))`, else `deselect()`.
  - `perform(_:sessionId:)`: at the top —
    ```swift
    if let alertID = EdgeBarAlertCards.alertID(ofCardID: sessionId) {
        if button == .acknowledge { alerts.acknowledge(alertID) }
        return
    }
    ```
    and add `case .acknowledge: break` to the switch (session cards never draw it).
- [ ] **Step 5: Add the card strings**:

```sh
python3 scripts/xcstrings.py set edge_bar.alert.exceeded --en "Over the threshold" --zh "用量超过阈值"
python3 scripts/xcstrings.py set edge_bar.alert.recovered --en "Quota recovered" --zh "额度已恢复"
python3 scripts/xcstrings.py set edge_bar.alert.threshold_fmt --en "Threshold %d%%" --zh "阈值 %d%%"
python3 scripts/xcstrings.py set edge_bar.alert.acknowledge --en "Got it" --zh "知道了"
python3 scripts/xcstrings.py check
```

- [ ] **Step 6: Verify** — `sh scripts/test.sh --only EdgeBarAutoCardTests` (approval behaviour untouched) and the full suite `sh scripts/test.sh` → PASS (full log path is printed; quote the counts).
- [ ] **Step 7: Commit** — `git commit -am "feat(quota): persistent edge-bar alert card, held until acknowledged"`

### Task 6: Mutation checks, docs

**Files:**
- Modify: `AGENTS.md` (one bullet under "### Edge Bar"), `README.md`, `README_CN.md` (one sentence each)

- [ ] **Step 1: Mutation-verify the detector's teeth** (each must exit 0 = the suite turns red):

```sh
sh scripts/mutate.sh NemoNotch/Models/QuotaAlert.swift 'utilization >= threshold' 'utilization > threshold' --only QuotaAlertDetectorTests
sh scripts/mutate.sh NemoNotch/Models/QuotaAlert.swift 'threshold - Self.hysteresis' 'threshold' --only QuotaAlertDetectorTests
sh scripts/mutate.sh NemoNotch/Notch/EdgeBar/EdgeBarAlertCard.swift '!previous.contains($0)' 'true' --only EdgeBarAlertCardsTests
```

  If a check exits 1 (mutation survived) or 2 (nothing ran), fix the test or the filter — do not proceed.
- [ ] **Step 2: AGENTS.md** — append this bullet at the end of the "### Edge Bar" section (keep it pitfalls/invariants only):

  > - **用量阈值提醒卡**(`QuotaAlertMonitor` 观察 + 纯 `QuotaAlertDetector`/`QuotaAlerts`/`EdgeBarAlertCards`,均单测;设置 → 提醒与动效,**默认关**,阈值 50–100 默认 80):窗口用量 ≥ 阈值发「超过阈值」卡,回落到阈值−5 以下发「额度已恢复」卡,卡**只由「知道了」撤下**。不变量:(1) `UsageQuotaService.setActive` 是视图生命周期(AI tab 可见才轮询),监控器**自带 5 分钟定时器**调 `refresh(force: false)`,别搭 setActive;(2) 每个 (provider, window) 最多一张卡、新事件顶旧卡,**卡 id 带 kind**(`alert:claude:5h:recovered`),exceeded→recovered 算新到达、会重开栏;(3) 开栏只在**到达边沿**(`knownAlerts` 对比),拖拽折起的栏不会被旧卡重开——悬停开栏/光标离开栏时 `reclaim` 把待确认卡顶回来(悬停的行卡优先,审批卡永不被顶);(4) 栏开着且有待确认卡即按住不折(`holdsBarForAlert`,不依赖 `autoOpened`),审批自动开栏的自动收起也要等卡清空;(5) 阈值改动/功能关/边栏关都清空状态重来(抬高阈值绝不误报「恢复」);边栏是唯一提醒面,关了就没有提醒。

- [ ] **Step 3: README.md** — append to the **AI Status Bar** bullet (the long one ending "— Claude Code only."): ` Optional usage alerts (Settings → 提醒与动效, off by default): when a provider's quota window passes your threshold (50–100%, default 80%) the bar opens with an alert card that stays until you press Got it — and the window's recovery is announced the same way.`
- [ ] **Step 4: README_CN.md** — append to the **AI 状态栏** bullet (the one ending "仅限 Claude Code。"): `可选的用量提醒(设置 → 提醒与动效,默认关):某个 provider 的配额窗口用量超过阈值(50–100%,默认 80%)时,状态栏自动展开并弹出提醒卡,点「知道了」才消失;额度恢复后同样提醒。`
- [ ] **Step 5: Full suite once more** — `sh scripts/test.sh` → PASS; `git status` clean of strays.
- [ ] **Step 6: Commit** — `git commit -am "docs(quota): usage alert card invariants and READMEs"`
