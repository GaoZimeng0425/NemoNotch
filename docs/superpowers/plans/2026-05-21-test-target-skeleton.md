# Test Target Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `NemoNotchTests` unit-test target to the Xcode project and seed it with Swift Testing-based tests for pure-logic code, so subsequent plans can be developed test-first.

**Architecture:** Add a single `Unit Testing Bundle` target via Xcode GUI (the only reliable way to mutate `project.pbxproj`). Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) — Apple's modern framework, simpler than XCTest. Initial tests cover `NotificationService.parseBadgeCount` (purely-functional, no UI/AppKit deps), establishing the pattern for future tests.

**Tech Stack:** Swift Testing, Xcode 26.5, xcodebuild CLI.

**Why this plan goes first:** Plans 2 and 3 list TDD steps that require this infrastructure to exist. Without a test target, those plans degrade to manual verification.

---

## File Structure

```
NemoNotchTests/                              # NEW directory, new Xcode target
├── NemoNotchTests.swift                     # smoke test confirming target builds
└── BadgeParsingTests.swift                  # tests for parseBadgeCount

NemoNotch/Services/NotificationService.swift # MODIFIED: extract parseBadgeCount to fileprivate static or expose via internal extension for testing

NemoNotch.xcodeproj/project.pbxproj          # MODIFIED by Xcode GUI when adding target
```

---

## Task 1: Add unit-test target via Xcode GUI

**Files:**
- Modify: `NemoNotch.xcodeproj/project.pbxproj` (via Xcode GUI — do not hand-edit)

This task is **user action**, not editable from CLI. Document carefully so the user can do it once.

- [ ] **Step 1: Open project in Xcode**

```bash
open NemoNotch.xcodeproj
```

- [ ] **Step 2: Add the test target**

In Xcode:
1. Menu **File → New → Target…**
2. Pick **macOS → Unit Testing Bundle**, click **Next**
3. Set:
   - **Product Name**: `NemoNotchTests`
   - **Team**: same as `NemoNotch` target
   - **Testing System**: **Swift Testing** (NOT XCTest — Swift Testing is the modern default)
   - **Language**: Swift
   - **Target to be tested**: `NemoNotch`
4. Click **Finish**

Xcode creates a `NemoNotchTests/` group with a stub `NemoNotchTests.swift` file.

- [ ] **Step 3: Verify target builds**

In Xcode: **Product → Test** (`⌘U`). Expected: build succeeds, the stub test passes.

Or from CLI:

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests
```

Expected: `** TEST SUCCEEDED **` at the end.

- [ ] **Step 4: Replace the stub with a real smoke test**

Replace the contents of `NemoNotchTests/NemoNotchTests.swift`:

```swift
import Testing
@testable import NemoNotch

@Suite("NemoNotch smoke")
struct NemoNotchSmokeTests {
    @Test("Bundle identifier resolves")
    func bundleIdentifier() {
        let bundle = Bundle(for: HookServer.self)
        #expect(bundle.bundleIdentifier?.contains("NemoNotch") == true)
    }
}
```

- [ ] **Step 5: Run the smoke test**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/NemoNotchSmokeTests
```

Expected: `Test Suite 'NemoNotch smoke' passed`.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch.xcodeproj/project.pbxproj NemoNotchTests/
git commit -m "test: add NemoNotchTests target with Swift Testing smoke"
```

---

## Task 2: Extract `parseBadgeCount` for testability

**Files:**
- Modify: `NemoNotch/Services/NotificationService.swift:156-170` (change `private func` → `static func` so tests can call it without instantiating the `@MainActor` service)

- [ ] **Step 1: Write the failing test**

Create `NemoNotchTests/BadgeParsingTests.swift`:

```swift
import Testing
@testable import NemoNotch

@Suite("DockBadge parsing")
struct BadgeParsingTests {
    @Test("Numeric label parses as integer")
    func numericLabel() {
        #expect(NotificationService.parseBadgeCount("3") == 3)
        #expect(NotificationService.parseBadgeCount("12") == 12)
        #expect(NotificationService.parseBadgeCount("  5 ") == 5)
    }

    @Test("Dot indicator parses as zero")
    func dotIndicator() {
        #expect(NotificationService.parseBadgeCount("•") == 0)
        #expect(NotificationService.parseBadgeCount("…") == 0)
    }

    @Test("Empty label parses as nil")
    func emptyLabel() {
        #expect(NotificationService.parseBadgeCount("") == nil)
        #expect(NotificationService.parseBadgeCount("   ") == nil)
    }

    @Test("Non-numeric non-dot label parses as zero (unread indicator)")
    func nonNumericLabel() {
        #expect(NotificationService.parseBadgeCount("new") == 0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/BadgeParsingTests
```

Expected: **FAIL** — `parseBadgeCount` is `private`, compiler error "'parseBadgeCount' is inaccessible due to 'private' protection level".

- [ ] **Step 3: Make `parseBadgeCount` accessible**

In `NemoNotch/Services/NotificationService.swift`, change line 156:

```swift
// Before:
private func parseBadgeCount(_ label: String) -> Int? {

// After:
static func parseBadgeCount(_ label: String) -> Int? {
```

Then change the call site at line 141:

```swift
// Before:
guard let count = parseBadgeCount(label) else {

// After:
guard let count = Self.parseBadgeCount(label) else {
```

- [ ] **Step 4: Run tests to confirm pass**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/BadgeParsingTests
```

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/NotificationService.swift NemoNotchTests/BadgeParsingTests.swift
git commit -m "test(notification): cover parseBadgeCount cases"
```

---

## Task 3: Document the testing convention

**Files:**
- Modify: `CLAUDE.md` (add a short subsection under "Development Conventions")

- [ ] **Step 1: Add testing section to CLAUDE.md**

Find the "Coding Conventions" subsection in CLAUDE.md. Add a new subsection above it:

```markdown
### Testing

- Unit tests live in `NemoNotchTests/`, written with **Swift Testing** (`import Testing`, `@Test`, `#expect`). Do not use XCTest for new code.
- Test pure logic — parsers, encoders, state transitions. Skip ScriptingBridge / AX / NSWindow integration tests (they need real macOS permissions and are flaky in CI).
- Run locally: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'`.
- New tests must pass before merging to `develop`.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document Swift Testing convention for NemoNotchTests"
```

---

## Self-Review Checklist

- [x] All file paths absolute or repo-relative with no ambiguity
- [x] Each test step shows the exact code, not a description
- [x] `xcodebuild test` invocations include `-destination` and `-only-testing` to avoid running unrelated targets
- [x] No "Add appropriate handling" / "TBD" placeholders
- [x] Task 1 explicitly notes the manual Xcode GUI step (cannot be automated reliably)

---

*Plan written 2026-05-21.*
