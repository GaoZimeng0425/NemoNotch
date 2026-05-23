# HookServer Codable Response Envelope

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ad-hoc JSON-string literals in `HookServer.swift` (e.g. `#"{"decision":"deny","reason":"timeout"}"#`) with typed `Codable` response models, so the hook protocol shape is checked by the compiler and easier to evolve.

**Architecture:** Introduce two response types in `NemoNotch/Models/HookResponse.swift`: `HookAck` (`{"status":"ok"}`) and `HookDecision` (`{"decision":"allow"|"deny","reason":"timeout"|...}`). `HookServer` serializes via a single `JSONEncoder` and a `sendJSON(_:)` helper that replaces the existing `sendHTTP(... body:)` String form. Wire format stays byte-identical so the `hook-sender.sh` script continues to work unchanged.

**Tech Stack:** Swift 6, `Foundation.JSONEncoder`, `Codable`.

**Depends on:** `2026-05-21-test-target-skeleton.md` for unit tests.

---

## File Structure

```
NemoNotch/Models/HookResponse.swift          # NEW: Codable response types
NemoNotch/Services/HookServer.swift          # MODIFIED: replace string literals; add sendJSON
NemoNotchTests/HookResponseTests.swift       # NEW: encoding round-trip + wire format tests
```

---

## Task 1: Define Codable response types

**Files:**
- Create: `NemoNotch/Models/HookResponse.swift`

- [ ] **Step 1: Write the failing test**

Create `NemoNotchTests/HookResponseTests.swift`:

```swift
import Foundation
import Testing
@testable import NemoNotch

@Suite("HookResponse encoding")
struct HookResponseTests {
    @Test("Ack encodes to {\"status\":\"ok\"}")
    func ack() throws {
        let data = try JSONEncoder().encode(HookResponse.ack)
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"status":"ok"}"#)
    }

    @Test("Allow decision encodes without reason field")
    func allow() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.allow))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"allow"}"#)
    }

    @Test("Deny decision encodes with reason field")
    func denyTimeout() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.deny(reason: .timeout)))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"deny","reason":"timeout"}"#)
    }

    @Test("Deny with sessionEnded reason")
    func denySessionEnded() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.deny(reason: .sessionEnded)))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"deny","reason":"session ended"}"#)
    }

    @Test("Deny with noSessionId reason")
    func denyNoSessionId() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.deny(reason: .noSessionId)))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"deny","reason":"no session id"}"#)
    }

    @Test("Deny without explicit reason omits reason field")
    func denyNoReason() throws {
        let data = try JSONEncoder().encode(HookResponse.decision(.deny(reason: nil)))
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"decision":"deny"}"#)
    }
}
```

- [ ] **Step 2: Run test to verify failure**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/HookResponseTests
```

Expected: **FAIL** — "Cannot find type 'HookResponse' in scope".

- [ ] **Step 3: Implement the types**

Create `NemoNotch/Models/HookResponse.swift`:

```swift
import Foundation

/// Response sent from HookServer back to the hook-sender.sh shell script.
/// Wire format is JSON over HTTP/1.1; shapes must stay byte-stable so the
/// shell-side parser (jq-based) continues to work.
enum HookResponse: Codable, Equatable {
    case ack
    case decision(Decision)

    enum Decision: Codable, Equatable {
        case allow
        case deny(reason: DenyReason?)
    }

    /// Stable string values consumed by hook-sender.sh — do not rename without
    /// updating the shell script in lockstep.
    enum DenyReason: String, Codable {
        case timeout
        case sessionEnded = "session ended"
        case noSessionId = "no session id"
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .ack:
            var container = encoder.container(keyedBy: AckKeys.self)
            try container.encode("ok", forKey: .status)
        case .decision(let decision):
            var container = encoder.container(keyedBy: DecisionKeys.self)
            switch decision {
            case .allow:
                try container.encode("allow", forKey: .decision)
            case .deny(let reason):
                try container.encode("deny", forKey: .decision)
                if let reason {
                    try container.encode(reason.rawValue, forKey: .reason)
                }
            }
        }
    }

    init(from decoder: Decoder) throws {
        // Decoding is not exercised in this codebase — shell script only emits
        // requests, not responses. Provide a minimal stub so Codable compiles.
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "HookResponse is encode-only"
        ))
    }

    private enum AckKeys: String, CodingKey { case status }
    private enum DecisionKeys: String, CodingKey { case decision, reason }
}
```

- [ ] **Step 4: Add file to Xcode target**

Drag `HookResponse.swift` into the `Models` group in Project Navigator; confirm Target Membership = `NemoNotch`.

- [ ] **Step 5: Run tests to verify pass**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/HookResponseTests
```

Expected: all 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Models/HookResponse.swift \
        NemoNotchTests/HookResponseTests.swift \
        NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat(hook): add Codable HookResponse model"
```

---

## Task 2: Add `sendJSON` helper in HookServer

**Files:**
- Modify: `NemoNotch/Services/HookServer.swift:245-256`

- [ ] **Step 1: Add the helper**

In `HookServer.swift`, find the `sendHTTP(_:status:body:)` method at line 245. Add a new method **above** it:

```swift
private func sendJSON(_ connection: NWConnection,
                     status: String = "200 OK",
                     payload: HookResponse) {
    do {
        let data = try JSONEncoder().encode(payload)
        let bodyString = String(data: data, encoding: .utf8) ?? "{}"
        sendHTTP(connection, status: status, body: bodyString)
    } catch {
        LogService.error(
            "HookServer: failed to encode response \(payload): \(error)",
            category: "HookServer"
        )
        sendHTTP(connection, status: "500 Internal Server Error", body: #"{"status":"error"}"#)
    }
}
```

- [ ] **Step 2: Build to verify no syntax errors**

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/HookServer.swift
git commit -m "feat(hook): add typed sendJSON helper"
```

---

## Task 3: Replace ad-hoc string literals with `sendJSON`

**Files:**
- Modify: `NemoNotch/Services/HookServer.swift:200-203, 213, 222-223, 229, 240`

- [ ] **Step 1: Replace ack responses**

In `processRequest` around line 200, find:

```swift
sendHTTP(connection, status: "200 OK", body: #"{"status":"ok"}"#)
```

(There are two occurrences — line 200 and 203.) Replace both with:

```swift
sendJSON(connection, payload: .ack)
```

- [ ] **Step 2: Replace `handlePermissionRequest` deny path**

In `handlePermissionRequest` around line 212-215, find:

```swift
guard let sessionId = event.sessionId else {
    sendHTTP(connection, status: "200 OK", body: #"{"decision":"deny","reason":"no session id"}"#)
    return
}
```

Replace with:

```swift
guard let sessionId = event.sessionId else {
    sendJSON(connection, payload: .decision(.deny(reason: .noSessionId)))
    return
}
```

Then around line 222-223 (timeout fallback), find:

```swift
sendHTTP(conn, status: "200 OK", body: #"{"decision":"deny","reason":"timeout"}"#)
```

Replace with:

```swift
sendJSON(conn, payload: .decision(.deny(reason: .timeout)))
```

- [ ] **Step 3: Replace `respondToPermission`**

Around line 229, find:

```swift
let body = #"{"decision":"\#(approved ? "allow" : "deny")"}"#
if let key = pendingPermissions.keys.first(where: { $0.hasPrefix(sessionId + ":") }),
   let conn = pendingPermissions.removeValue(forKey: key) {
    sendHTTP(conn, status: "200 OK", body: body)
}
```

Replace with:

```swift
let decision: HookResponse.Decision = approved ? .allow : .deny(reason: nil)
if let key = pendingPermissions.keys.first(where: { $0.hasPrefix(sessionId + ":") }),
   let conn = pendingPermissions.removeValue(forKey: key) {
    sendJSON(conn, payload: .decision(decision))
}
```

- [ ] **Step 4: Replace `cancelPendingPermissions`**

Around line 240, find:

```swift
sendHTTP(conn, status: "200 OK", body: #"{"decision":"deny","reason":"session ended"}"#)
```

Replace with:

```swift
sendJSON(conn, payload: .decision(.deny(reason: .sessionEnded)))
```

- [ ] **Step 5: Build to verify nothing else still references the old strings**

```bash
grep -n '"decision"' NemoNotch/Services/HookServer.swift
```

Expected: no output (all literals replaced).

```bash
xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run all HookResponse tests + smoke test**

```bash
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/HookResponseTests \
  -only-testing:NemoNotchTests/NemoNotchSmokeTests
```

Expected: all tests pass.

- [ ] **Step 7: End-to-end manual verification**

Run NemoNotch. Trigger Claude Code with a pending permission (e.g., a tool that requests approval). Verify:
1. The HookServer logs receive the request
2. The shell script `hook-sender.sh` parses the response (`jq -r '.decision'` should still extract `allow` / `deny`)
3. No regressions in approval UI

Quick local probe (replace `<port>` with the value from `Console.app` filter `category=HookServer`):

```bash
curl -s http://127.0.0.1:<port>/health
# Expected: ok

curl -s -X POST http://127.0.0.1:<port>/hook \
  -H 'Content-Type: application/json' \
  -d '{"hookEventName":"Notification","sessionId":"test-123"}'
# Expected: {"status":"ok"}
```

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Services/HookServer.swift
git commit -m "refactor(hook): replace ad-hoc JSON literals with typed HookResponse"
```

---

## Self-Review Checklist

- [x] Wire format byte-stable — `DenyReason.rawValue` matches existing strings exactly (including "session ended" with space, "no session id" with spaces)
- [x] Encoder produces compact form (no whitespace) so byte-identical with literals
- [x] Decoding stubbed because the shell script never sends responses to us
- [x] No new HTTP semantics — `sendJSON` defaults to `200 OK` like the existing literal sites
- [x] Tests cover every existing literal shape (6 cases)
- [x] Step 5 grep search confirms no straggler string literals

---

## Out-of-Scope

- Adding a request-side `Codable HookRequest` model — `HookEvent` already exists and works.
- Renaming `DenyReason` rawValues to be more idiomatic (e.g. `session_ended`) — would break `hook-sender.sh`.
- Streaming responses — `HookServer` is one-request-one-response.

---

*Plan written 2026-05-21.*
