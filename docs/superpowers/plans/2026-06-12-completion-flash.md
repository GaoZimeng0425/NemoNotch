# Completion Flash + Session Toast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an AI session finishes a turn (working→idle) or an agent finishes (active→idle), play a one-shot full-screen accent-orange edge glow on all screens plus a HUD-style toast near the notch showing the finished project name(s); rapid completions are throttled and their names merge into one toast.

**Architecture:** A new `@Observable CompletionFlashService` observes the existing `AISessionStore` and `AgentMonitorRegistry` via Observation, detects active→idle edges with a pure `CompletionDetector`, and drives two pieces of UI state (`flashActive`, `toastNames`/`toastVisible`). A per-screen `CompletionFlashWindowController` owns transparent non-interactive overlay windows hosting `CompletionFlashView` (the edge glow). `NotchView` mounts `CompletionToastView` next to the existing volume/brightness HUD. No provider code is touched.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSWindow`/`NSHostingView`), Observation (`withObservationTracking`), Swift Testing.

---

## File Structure

**New files:**
- `NemoNotch/Services/CompletionDetector.swift` — pure edge-detection + name-merge logic (no UI, no actor state). Testable.
- `NemoNotch/Services/CompletionFlashService.swift` — `@MainActor @Observable` service: observation loop, throttle/cooldown, published UI state.
- `NemoNotch/Notch/CompletionFlashWindow.swift` — `NSWindow` subclass (transparent, click-through) + `CompletionFlashWindowController` (per-screen lifecycle).
- `NemoNotch/Notch/CompletionFlashView.swift` — SwiftUI full-screen four-edge glow.
- `NemoNotch/Notch/CompletionToastView.swift` — SwiftUI HUD-style capsule listing project name(s).
- `NemoNotchTests/CompletionDetectorTests.swift` — Swift Testing for the pure logic.

**Modified files:**
- `NemoNotch/Helpers/Constants.swift` — new `NotchConstants` tunables.
- `NemoNotch/Models/AppSettings.swift` — `completionFlashEnabled` flag.
- `NemoNotch/Notch/NotchView.swift` — mount the toast; new `@Environment`.
- `NemoNotch/NemoNotchApp.swift` — construct/own/inject the service + window controller.
- `NemoNotch/Settings/SettingsView.swift` — toggle in the tab-management form.
- `NemoNotch/Localizable.xcstrings` — settings strings.
- `README.md`, `README_CN.md`, `CLAUDE.md`, `docs/macos-cookbook.md` — docs.

> New `.swift` files are picked up automatically by Xcode's root-group file sync — **do not** edit `project.pbxproj` to register them.

---

## Task 1: AppSettings flag

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift`
- Test: `NemoNotchTests/CompletionDetectorTests.swift` (created in Task 2; the flag itself needs no test — it follows the exact pattern of existing flags whose persistence is already trusted)

- [ ] **Step 1: Add the stored property**

In `AppSettings`, after the `hermesEnabled` block (around line 100-102), add:

```swift
    // MARK: - Completion flash

    static let completionFlashEnabledKey = "completionFlashEnabled"

    var completionFlashEnabled: Bool {
        didSet { UserDefaults.standard.set(completionFlashEnabled, forKey: Self.completionFlashEnabledKey) }
    }
```

- [ ] **Step 2: Initialize it (default true)**

In `init()`, after the `hermesEnabled = ...` assignment (around line 162-163), add:

```swift
        completionFlashEnabled = UserDefaults.standard
            .object(forKey: Self.completionFlashEnabledKey) as? Bool ?? true
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Models/AppSettings.swift
git commit -m "feat(flash): add completionFlashEnabled setting (default on)"
```

---

## Task 2: CompletionDetector pure logic (TDD)

**Files:**
- Create: `NemoNotch/Services/CompletionDetector.swift`
- Test: `NemoNotchTests/CompletionDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `NemoNotchTests/CompletionDetectorTests.swift`:

```swift
import Testing
@testable import NemoNotch

@Suite("CompletionDetector")
struct CompletionDetectorTests {
    private func c(_ key: String, _ name: String, _ active: Bool) -> CompletionCandidate {
        CompletionCandidate(key: key, name: name, isActive: active)
    }

    @Test("first sample never reports completions")
    func firstSampleNoCompletion() {
        var d = CompletionDetector()
        let result = d.step([c("ai:1", "Proj", false), c("ai:2", "Other", true)])
        #expect(result.isEmpty)
    }

    @Test("active then idle reports the name once")
    func activeToIdleCompletes() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", true)])
        let result = d.step([c("ai:1", "Proj", false)])
        #expect(result == ["Proj"])
    }

    @Test("idle staying idle does not report")
    func idleStaysIdle() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", false)])
        let result = d.step([c("ai:1", "Proj", false)])
        #expect(result.isEmpty)
    }

    @Test("working staying working does not report")
    func workingStaysWorking() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", true)])
        let result = d.step([c("ai:1", "Proj", true)])
        #expect(result.isEmpty)
    }

    @Test("idle then working (new turn) does not report")
    func idleToWorking() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", false)])
        let result = d.step([c("ai:1", "Proj", true)])
        #expect(result.isEmpty)
    }

    @Test("multiple simultaneous completions all reported")
    func multipleCompletions() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "A", true), c("agent:x", "B", true)])
        let result = d.step([c("ai:1", "A", false), c("agent:x", "B", false)])
        #expect(Set(result) == ["A", "B"])
    }

    @Test("a removed session is not a completion")
    func removedSessionNoCompletion() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "A", true)])
        let result = d.step([])  // session disappeared
        #expect(result.isEmpty)
    }

    @Test("merge dedups preserving order")
    func mergeDedups() {
        let merged = CompletionFlashNames.merge(existing: ["A", "B"], new: ["B", "C"])
        #expect(merged == ["A", "B", "C"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/CompletionDetectorTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'CompletionCandidate' / 'CompletionDetector' / 'CompletionFlashNames' in scope`.

- [ ] **Step 3: Write the implementation**

Create `NemoNotch/Services/CompletionDetector.swift`:

```swift
import Foundation

/// One observed unit of work (an AI session or an agent) at a point in time.
struct CompletionCandidate: Equatable {
    /// Namespaced unique id, e.g. "ai:<sessionID>" or "agent:<agentID>".
    let key: String
    /// Human-facing name shown in the toast (project folder / agent name).
    let name: String
    /// True while the unit is doing work.
    let isActive: Bool
}

/// Detects active→idle transitions by diffing successive snapshots.
/// Pure value type — no actor isolation, no UI. The first `step` only
/// records a baseline, so units already active at startup never false-fire.
struct CompletionDetector {
    private var prior: [String: Bool] = [:]

    /// Returns the names of units that went active→idle since the last call.
    /// A unit that disappears (e.g. session removed) is dropped, not reported.
    mutating func step(_ candidates: [CompletionCandidate]) -> [String] {
        var completed: [String] = []
        var next: [String: Bool] = [:]
        for candidate in candidates {
            next[candidate.key] = candidate.isActive
            if prior[candidate.key] == true, !candidate.isActive {
                completed.append(candidate.name)
            }
        }
        prior = next
        return completed
    }
}

/// Name-list helpers for the toast.
enum CompletionFlashNames {
    /// Append `new` names to `existing`, skipping duplicates, preserving order.
    static func merge(existing: [String], new: [String]) -> [String] {
        var result = existing
        for name in new where !result.contains(name) {
            result.append(name)
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/CompletionDetectorTests 2>&1 | tail -20`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/CompletionDetector.swift NemoNotchTests/CompletionDetectorTests.swift
git commit -m "feat(flash): completion edge-detection + name-merge logic with tests"
```

---

## Task 3: NotchConstants tunables

**Files:**
- Modify: `NemoNotch/Helpers/Constants.swift`

- [ ] **Step 1: Add the constants**

In `NotchConstants`, immediately after the activity-glow block (after `glowPulseMax` at line 62), add:

```swift
    // Completion flash (full-screen edge glow on AI/agent completion)
    /// Cooldown window: the first completion flashes; further completions
    /// within this window merge into the visible toast without re-flashing.
    static let completionFlashThrottle: TimeInterval = 2.0
    static let completionFlashFadeIn: Double = 0.18
    static let completionFlashHold: Double = 0.15
    static let completionFlashFadeOut: Double = 0.55
    /// Thickness (points) of the accent band fading inward from each screen edge.
    static let completionGlowWidth: CGFloat = 120
    static let completionGlowBlur: CGFloat = 60
    /// Peak opacity of the edge glow at the top of the flash.
    static let completionGlowOpacity: Double = 0.55
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Helpers/Constants.swift
git commit -m "feat(flash): add completion flash tunables to NotchConstants"
```

---

## Task 4: CompletionFlashService

**Files:**
- Create: `NemoNotch/Services/CompletionFlashService.swift`

This service has no unit test — its observation loop and throttle timers need the real run loop and `@Observable` stores (project convention skips such integration tests). Its pure pieces are already covered in Task 2.

- [ ] **Step 1: Write the service**

Create `NemoNotch/Services/CompletionFlashService.swift`:

```swift
import SwiftUI

/// Watches the AI session store and agent registry for work-completion edges
/// (working→idle / active→idle) and drives the full-screen edge glow + toast.
/// Throttles: the first completion flashes and shows a toast; completions
/// arriving during the cooldown merge their names into the visible toast
/// without replaying the flash.
@MainActor
@Observable
final class CompletionFlashService {
    /// Drives the edge-glow window opacity. Set inside `withAnimation`.
    private(set) var flashActive = false
    /// Project/agent names shown in the current toast.
    private(set) var toastNames: [String] = []
    /// Whether the toast is currently shown.
    private(set) var toastVisible = false

    private let store: AISessionStore
    private let registry: AgentMonitorRegistry
    private let settings: AppSettings

    private var detector = CompletionDetector()
    private var inCooldown = false
    private var cooldownTask: Task<Void, Never>?
    private var flashResetTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?

    init(store: AISessionStore, registry: AgentMonitorRegistry, settings: AppSettings) {
        self.store = store
        self.registry = registry
        self.settings = settings
        LogService.info("CompletionFlashService init", category: "CompletionFlash")
        // Prime the detector so units already active at launch don't flash.
        _ = detector.step(currentCandidates())
        observe()
    }

    // MARK: - Snapshot

    private func currentCandidates() -> [CompletionCandidate] {
        var result: [CompletionCandidate] = []
        for session in store.sortedSessions {
            result.append(CompletionCandidate(
                key: "ai:\(session.id)",
                name: session.projectFolder ?? session.displayTitle,
                isActive: session.status == .working
            ))
        }
        for monitor in registry.installedMonitors {
            for agent in monitor.agents.values {
                result.append(CompletionCandidate(
                    key: "agent:\(agent.id)",
                    name: agent.name,
                    isActive: agent.state != .idle
                ))
            }
        }
        return result
    }

    // MARK: - Observation

    private func observe() {
        withObservationTracking {
            // Touch the tracked state so onChange fires on any mutation.
            _ = store.sortedSessions.map { ($0.id, $0.status) }
            for monitor in registry.installedMonitors {
                _ = monitor.agents.mapValues { $0.state }
            }
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.evaluate()
                self.observe() // re-arm for the next change
            }
        }
    }

    private func evaluate() {
        let completed = detector.step(currentCandidates())
        guard !completed.isEmpty else { return }
        guard settings.completionFlashEnabled else {
            LogService.debug("Completion ignored — flash disabled", category: "CompletionFlash")
            return
        }
        LogService.debug("Completion detected: \(completed)", category: "CompletionFlash")
        handle(names: completed)
    }

    // MARK: - Throttle / merge

    private func handle(names: [String]) {
        if inCooldown {
            toastNames = CompletionFlashNames.merge(existing: toastNames, new: names)
            restartToastDismiss()
            LogService.debug("Merged into active toast: \(toastNames)", category: "CompletionFlash")
        } else {
            triggerFlash()
            toastNames = CompletionFlashNames.merge(existing: [], new: names)
            showToast()
            startCooldown()
        }
    }

    private func triggerFlash() {
        flashResetTask?.cancel()
        withAnimation(.easeOut(duration: NotchConstants.completionFlashFadeIn)) {
            flashActive = true
        }
        flashResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(NotchConstants.completionFlashFadeIn + NotchConstants.completionFlashHold)
            )
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: NotchConstants.completionFlashFadeOut)) {
                self.flashActive = false
            }
        }
    }

    private func showToast() {
        toastVisible = true
        restartToastDismiss()
    }

    private func restartToastDismiss() {
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchConstants.hudDismissDelay))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: NotchConstants.hudDismissDuration)) {
                self.toastVisible = false
            }
        }
    }

    private func startCooldown() {
        inCooldown = true
        cooldownTask?.cancel()
        cooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashThrottle))
            guard let self, !Task.isCancelled else { return }
            self.inCooldown = false
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/CompletionFlashService.swift
git commit -m "feat(flash): CompletionFlashService observes stores, throttles, drives UI state"
```

---

## Task 5: CompletionFlashView (full-screen edge glow)

**Files:**
- Create: `NemoNotch/Notch/CompletionFlashView.swift`

- [ ] **Step 1: Write the view**

Create `NemoNotch/Notch/CompletionFlashView.swift`:

```swift
import SwiftUI

/// Full-screen accent glow hugging all four screen edges, fading inward.
/// Opacity is driven by `service.flashActive` (animated by the service via
/// `withAnimation`). Purely visual — never intercepts events.
struct CompletionFlashView: View {
    let service: CompletionFlashService

    var body: some View {
        let band = NotchConstants.completionGlowWidth
        ZStack {
            edgeBand(.top)
            edgeBand(.bottom)
            edgeBand(.leading)
            edgeBand(.trailing)
        }
        .blur(radius: NotchConstants.completionGlowBlur)
        .blendMode(.screen)
        .opacity(service.flashActive ? NotchConstants.completionGlowOpacity : 0)
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .modifier(BandWidth(band: band))
    }

    /// One edge's accent→clear gradient, pinned to that edge.
    @ViewBuilder
    private func edgeBand(_ edge: Edge) -> some View {
        let accent = NotchTheme.accent
        switch edge {
        case .top:
            LinearGradient(colors: [accent, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: NotchConstants.completionGlowWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .bottom:
            LinearGradient(colors: [accent, .clear], startPoint: .bottom, endPoint: .top)
                .frame(height: NotchConstants.completionGlowWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case .leading:
            LinearGradient(colors: [accent, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: NotchConstants.completionGlowWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .trailing:
            LinearGradient(colors: [accent, .clear], startPoint: .trailing, endPoint: .leading)
                .frame(width: NotchConstants.completionGlowWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}

/// No-op layout modifier kept so `band` is read (avoids an unused warning if
/// the constant is later inlined). Stretches content to fill the window.
private struct BandWidth: ViewModifier {
    let band: CGFloat
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

> Note: the `band` local and `BandWidth` modifier are only to keep the file self-documenting; if the compiler flags `band` as unused, delete the `let band` line and the `.modifier(BandWidth(...))` call — the `edgeBand` cases reference the constant directly.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (fix any unused-variable warning per the note above).

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Notch/CompletionFlashView.swift
git commit -m "feat(flash): full-screen edge-glow view"
```

---

## Task 6: CompletionFlashWindow + per-screen controller

**Files:**
- Create: `NemoNotch/Notch/CompletionFlashWindow.swift`

- [ ] **Step 1: Write the window and controller**

Create `NemoNotch/Notch/CompletionFlashWindow.swift`:

```swift
import SwiftUI

/// Borderless, transparent, click-through window covering one full screen.
/// Hosts the edge-glow overlay. Sits at the notch level and joins all Spaces
/// so the glow shows over fullscreen apps too.
final class CompletionFlashWindow: NSWindow {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 8
        ignoresMouseEvents = true
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one `CompletionFlashWindow` per connected screen and keeps them in
/// sync with display changes. All windows share the same `CompletionFlashService`,
/// so a single completion flashes every screen at once.
@MainActor
final class CompletionFlashWindowController {
    private var windows: [UInt32: CompletionFlashWindow] = [:]
    private let service: CompletionFlashService

    init(service: CompletionFlashService) {
        self.service = service
        LogService.info("CompletionFlashWindowController init", category: "CompletionFlash")
        rebuild()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        rebuild()
    }

    private func rebuild() {
        let currentIDs = Set(NSScreen.screens.map(\.displayID))
        for (id, window) in windows where !currentIDs.contains(id) {
            window.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        for screen in NSScreen.screens {
            let id = screen.displayID
            if let existing = windows[id] {
                existing.setFrame(screen.frame, display: true)
            } else {
                windows[id] = makeWindow(for: screen)
            }
        }
    }

    private func makeWindow(for screen: NSScreen) -> CompletionFlashWindow {
        let window = CompletionFlashWindow(rect: screen.frame)
        let host = NSHostingView(rootView: CompletionFlashView(service: service))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        window.contentView = host
        window.orderFrontRegardless()
        return window
    }
}
```

> `NSScreen.displayID` already exists in this codebase (used by `NotchCoordinator.rebuildSlots`). No new extension needed.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Notch/CompletionFlashWindow.swift
git commit -m "feat(flash): per-screen transparent overlay windows for the edge glow"
```

---

## Task 7: CompletionToastView + mount in NotchView

**Files:**
- Create: `NemoNotch/Notch/CompletionToastView.swift`
- Modify: `NemoNotch/Notch/NotchView.swift`

- [ ] **Step 1: Write the toast view**

Create `NemoNotch/Notch/CompletionToastView.swift`:

```swift
import SwiftUI

/// HUD-style capsule shown near the notch when a session/agent finishes.
/// Matches `HUDOverlayView`'s black-capsule styling. Lists one or more
/// project/agent names; when more than one, appends a count chip.
struct CompletionToastView: View {
    let names: [String]

    private var displayText: String {
        names.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NotchTheme.accent)
                .frame(width: 18, alignment: .center)

            Text(displayText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if names.count > 1 {
                Text("\(names.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.accent)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, NotchConstants.hudHorizontalPadding)
        .frame(height: NotchConstants.hudHeight)
        .frame(maxWidth: 320)
        .background(.black)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }
}
```

- [ ] **Step 2: Add the environment dependency in NotchView**

In `NemoNotch/Notch/NotchView.swift`, after the `@Environment(PomodoroTimerService.self) var pomodoroService` line (line 16), add:

```swift
    @Environment(CompletionFlashService.self) var completionFlash
```

- [ ] **Step 3: Mount the toast next to the HUD overlay**

In `NotchView.body`, immediately after the HUD overlay `if` block (closes at line 167, before the `}` that closes the `ZStack` at line 168), add:

```swift
            // Completion toast — reuses the HUD anchor/position, only on the
            // HUD screen. Rendered above the HUD overlay if both are visible.
            if isHUDScreen, completionFlash.toastVisible, !completionFlash.toastNames.isEmpty {
                CompletionToastView(names: completionFlash.toastNames)
                    .zIndex(4)
                    .position(
                        x: notchCenterX,
                        y: hardwareNotchSize.height + NotchConstants.hudTopPadding + NotchConstants.hudHeight / 2
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
```

- [ ] **Step 4: Animate the toast transition**

In `NotchView.body`, find the existing `.animation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08), value: hudService.activeHUD)` line (line 177) and add directly below it:

```swift
        .animation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08), value: completionFlash.toastVisible)
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD will fail with a missing-environment error at runtime only — at compile time it should succeed. If it fails to compile because `CompletionFlashService` isn't injected yet, that's expected; it resolves in Task 8. Confirm the error (if any) is about environment injection, not a syntax error.

Expected: `** BUILD SUCCEEDED **` (the `@Environment` is resolved at runtime; compilation succeeds).

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Notch/CompletionToastView.swift NemoNotch/Notch/NotchView.swift
git commit -m "feat(flash): completion toast view mounted in NotchView"
```

---

## Task 8: Wire into AppDelegate

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: Add stored properties**

In the `AppDelegate` class, alongside the other service properties (find `var hudService: HUDService?` — it lives in the stored-property block near the top of the class), add:

```swift
    var completionFlashService: CompletionFlashService?
    var completionFlashWindowController: CompletionFlashWindowController?
```

- [ ] **Step 2: Construct the service**

In `applicationDidFinishLaunching`, after the HUD assembly block (lines 163-164, `let hud = HUDService(); hudService = hud`), add:

```swift
        let completionFlash = CompletionFlashService(
            store: aiMonitor.store,
            registry: registry,
            settings: settings
        )
        completionFlashService = completionFlash
```

> `registry`, `aiMonitor`, and `settings` are all already defined above this point (lines 112-142).

- [ ] **Step 3: Inject into NotchView**

In the `NotchCoordinator { coordinator, screen in ... }` content builder (lines 191-214), add a `.environment(completionFlash)` line alongside the other `.environment(...)` calls — e.g. directly after `.environment(hud)` (line 207):

```swift
                    .environment(completionFlash)
```

- [ ] **Step 4: Create the overlay windows (skip in UI-test mode)**

In `applicationDidFinishLaunching`, after `coordinator = notchCoordinator` (line 232) and before `setupHotkeys(coordinator: notchCoordinator)` (line 234), add:

```swift
        if !UITestMode.isActive {
            completionFlashWindowController = CompletionFlashWindowController(service: completionFlash)
        }
```

- [ ] **Step 5: Build to verify it compiles and links**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual smoke test**

Run the app (`./build.sh` output or run from Xcode). Trigger an AI completion (e.g. let a Claude Code turn finish, or toggle an agent to idle). Confirm: the screen edges glow once in orange on every connected display, and a black capsule with the project name appears under the notch for ~2s. Run two completions within 2s and confirm the second name merges into the same capsule (count chip shows "2") without a second flash.

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "feat(flash): assemble CompletionFlashService + overlay windows in AppDelegate"
```

---

## Task 9: Settings toggle + localization

**Files:**
- Modify: `NemoNotch/Settings/SettingsView.swift`
- Modify: `NemoNotch/Localizable.xcstrings`

- [ ] **Step 1: Add the toggle Section**

In `SettingsView.tabManagementView`'s `Form`, after the `Section("settings.language") { ... }` block (closes at line 107), add a new section:

```swift
            Section("settings.completion_flash.header") {
                Toggle("settings.completion_flash.enabled", isOn: Binding(
                    get: { appSettings.completionFlashEnabled },
                    set: { appSettings.completionFlashEnabled = $0 }
                ))
            }
```

- [ ] **Step 2: Add localization keys**

In `NemoNotch/Localizable.xcstrings`, add two string entries following the existing native-format structure (each key has a `localizations` map with `en` and `zh-Hans` `stringUnit` values). Add:

- Key `settings.completion_flash.header`: en = `"Completion Flash"`, zh-Hans = `"完成闪烁"`
- Key `settings.completion_flash.enabled`: en = `"Flash screen edges when AI/agent finishes"`, zh-Hans = `"AI/Agent 执行结束时全屏边缘闪烁"`

Match the exact JSON shape of an existing entry such as `settings.pomodoro.notificationEnabled` (copy its structure, swap the key and string values). Keep keys sorted as Xcode writes them (the file was normalized in commit `23c01a7`; opening and editing in Xcode's String Catalog editor is the safest way to preserve format).

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Verify the toggle**

Open Settings → first tab. Confirm a "Completion Flash" section with the toggle (on by default). Toggle off, trigger a completion, confirm no flash/toast. Toggle on, confirm it returns.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Settings/SettingsView.swift NemoNotch/Localizable.xcstrings
git commit -m "feat(flash): settings toggle for completion flash"
```

---

## Task 10: Documentation

**Files:**
- Modify: `README.md`, `README_CN.md`, `CLAUDE.md`, `docs/macos-cookbook.md`

- [ ] **Step 1: Update READMEs**

In `README.md` and `README_CN.md`, in the feature list, add a bullet describing the completion flash: a full-screen accent edge glow + a name toast when an AI session or agent finishes, throttled and merged for rapid completions, toggleable in Settings. Match each file's existing wording/language and section placement (near the AI monitoring / notch features).

- [ ] **Step 2: Update CLAUDE.md**

In `CLAUDE.md`:
- In the architecture overview's Service Layer list, add `CompletionFlashService` (observes `AISessionStore` + `AgentMonitorRegistry`, drives the completion flash/toast).
- Add a short subsection after the "Activity Glow" section describing the **Completion Flash**: triggers (working→idle / active→idle), full-screen per-screen overlay windows (`CompletionFlashWindow`/`CompletionFlashWindowController`), the throttle/merge toast (`CompletionToastView` reusing the HUD anchor), the `completionFlashEnabled` setting, and the `NotchConstants.completionFlash*` / `completionGlow*` tunables.

- [ ] **Step 3: Update the cookbook**

In `docs/macos-cookbook.md`, under the "Notch & window" section, add a technique entry: **full-screen transparent click-through overlay window, per display** — `NSWindow` borderless + `isOpaque = false` + `backgroundColor = .clear` + `ignoresMouseEvents = true` + `level = .statusBar + 8` + `collectionBehavior` joining all Spaces, one per `NSScreen` rebuilt on `didChangeScreenParametersNotification`, hosting a SwiftUI `.blendMode(.screen)` edge gradient. Anchor it to `NemoNotch/Notch/CompletionFlashWindow.swift` (`file:line`).

- [ ] **Step 4: Commit**

```bash
git add README.md README_CN.md CLAUDE.md docs/macos-cookbook.md
git commit -m "docs(flash): document completion flash feature"
```

---

## Task 11: Final verification

- [ ] **Step 1: Full test suite**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -20`
Expected: all tests pass, including `CompletionDetectorTests`.

- [ ] **Step 2: Full build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: End-to-end manual check**

- AI session finishes → one flash on all screens + toast with project name.
- Agent goes idle → flash + toast with agent name.
- Two completions within 2s → one flash, toast lists both names + count chip.
- Setting off → nothing fires.
- Disconnect/reconnect an external display → flash still works on remaining/again-present screens (window controller rebuilt).

---

## Self-Review Notes

- **Spec coverage:** triggers (Task 4 `currentCandidates`), all-screens glow (Task 6), accent color (Tasks 5/7 use `NotchTheme.accent`), throttle+merge toast (Tasks 2/4), HUD-style toast anchored like volume HUD (Task 7), settings toggle default-on (Tasks 1/9), tunables (Task 3), tests for pure logic (Task 2), docs (Task 10) — all present.
- **Type consistency:** `CompletionCandidate`, `CompletionDetector.step`, `CompletionFlashNames.merge`, `CompletionFlashService` published `flashActive`/`toastNames`/`toastVisible`, `CompletionFlashWindow`/`CompletionFlashWindowController(service:)`, `CompletionFlashView(service:)`, `CompletionToastView(names:)`, `AppSettings.completionFlashEnabled`, and the `NotchConstants.completion*` names are used identically across all tasks.
- **Known acceptable limitations:** if the volume/brightness HUD and the completion toast are visible simultaneously they overlap at the same anchor (toast on top, zIndex 4) — acceptable for now. Removed-while-active sessions don't flash (by design).
