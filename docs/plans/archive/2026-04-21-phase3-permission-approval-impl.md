# Phase 3: Permission Approval Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable users to approve/deny Claude Code tool permissions directly from the notch, with inline approve/deny buttons and tool-specific context display.

**Architecture:** The Unix socket already supports request-response (built in Phase 1). We enhance the hook script to wait for responses on PermissionRequest events, add approval UI to both CompactBadge and ClaudeTab, and add cleanup for pending permissions on session end.

**Tech Stack:** Swift 5, SwiftUI, Foundation (Unix sockets), Bash (hook script)

**Reference:** vibe-notch at `/Users/gaozimeng/Learn/macOS/vibe-notch/`

---

### Task 1: Update Hook Script for Permission Response

The current script uses `nc -U -w 1` which only waits 1 second. For permission requests, Claude Code waits for the hook's stdout to decide approval. The script must wait longer and print the response.

**Files:**
- Modify: `NemoNotch/Services/HookInstaller.swift` (script template)

**Step 1: Update the script template in ensureScriptExists()**

Replace the script template in HookInstaller.swift. Find the `let script = """` block and replace with:

```swift
        let script = """
        #!/bin/bash
        \(scriptVersion)
        SOCKET="\(socketPath)"
        [ -S "$SOCKET" ] || exit 0
        INPUT=$(cat 2>/dev/null || echo '{}')
        if echo "$INPUT" | grep -q '"PermissionRequest"'; then
            echo "$INPUT" | nc -U -w 120 "$SOCKET" 2>/dev/null
        else
            echo "$INPUT" | nc -U -w 1 "$SOCKET" 2>/dev/null || true
        fi
        exit 0
        """
```

Key change: PermissionRequest events wait up to 120s for a response (which goes to stdout → Claude Code reads it). All other events fire-and-forget with 1s timeout.

Also bump the version to force script regeneration:

```swift
    private static let scriptVersion = "# version: 4"
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add NemoNotch/Services/HookInstaller.swift
git commit -m "feat: update hook script with long timeout for PermissionRequest events"
```

---

### Task 2: Enhance HookEvent with tool_use_id

Claude Code sends `tool_use_id` in PermissionRequest events. We need this to properly identify which tool is awaiting approval.

**Files:**
- Modify: `NemoNotch/Models/HookEvent.swift`

**Step 1: Add toolUseId field**

Replace the entire HookEvent.swift:

```swift
import Foundation

struct HookEvent: Codable {
    let hookEventName: String
    let sessionId: String?
    let toolName: String?
    let toolUseId: String?
    let message: String?
    let cwd: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case toolName = "tool_name"
        case toolUseId = "tool_use_id"
        case message
        case cwd
        case source
    }
}
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Models/HookEvent.swift
git commit -m "feat: add toolUseId field to HookEvent for permission correlation"
```

---

### Task 3: Enhance PermissionContext with Tool-Specific Formatting

Add formatted input display that shows the most relevant info per tool type (bash commands, file paths, etc.).

**Files:**
- Modify: `NemoNotch/Models/SessionPhase.swift`

**Step 1: Update PermissionContext**

Replace the `PermissionContext` struct (everything after line 70) with:

```swift
struct PermissionContext: Equatable {
    let toolUseId: String
    let toolName: String
    let toolInput: String?
    let receivedAt: Date

    var displayInput: String {
        guard let input = toolInput, !input.isEmpty else { return "" }

        // Try to parse as JSON for tool-specific formatting
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return formattedToolInput(toolName: toolName, json: json)
        }

        // Fallback: plain string
        if input.count > 120 {
            return String(input.prefix(120)) + "..."
        }
        return input
    }

    var isInteractiveTool: Bool {
        toolName == "AskUserQuestion"
    }

    private func formattedToolInput(toolName: String, json: [String: Any]) -> String {
        // Bash: show command
        if toolName == "Bash", let cmd = json["command"] as? String {
            return truncate(cmd, limit: 100)
        }
        // Write/Edit/Read: show file path
        if ["Write", "Edit", "Read"].contains(toolName), let path = json["file_path"] as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        // Grep/Glob: show pattern
        if toolName == "Grep", let pattern = json["pattern"] as? String {
            return "pattern: \(truncate(pattern, limit: 80))"
        }
        if toolName == "Glob", let pattern = json["pattern"] as? String {
            return truncate(pattern, limit: 80)
        }
        // Web: show url
        if toolName.hasPrefix("Web"), let url = json["url"] as? String {
            return truncate(url, limit: 100)
        }
        // Default: show first meaningful value
        let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = json[key] as? String, !value.isEmpty {
                return truncate(value, limit: 100)
            }
        }
        return ""
    }

    private func truncate(_ str: String, limit: Int) -> String {
        str.count > limit ? String(str.prefix(limit)) + "..." : str
    }

    static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        lhs.toolUseId == rhs.toolUseId
    }
}
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Models/SessionPhase.swift
git commit -m "feat: add tool-specific input formatting to PermissionContext"
```

---

### Task 4: Add cancelPendingPermissions to HookServer

When a session ends or times out, we must close any pending permission sockets to prevent FD leaks.

**Files:**
- Modify: `NemoNotch/Services/HookServer.swift`

**Step 1: Add cancelPendingPermissions method**

Add this method to HookServer, after `respondToPermission`:

```swift
    func cancelPendingPermissions(sessionId: String) {
        socketQueue.async { [weak self] in
            guard let self else { return }
            // Timeout handler will clean up — just remove the waiter so it sends deny
            if self.responseWaiters[sessionId] != nil {
                let waiter = self.responseWaiters.removeValue(forKey: sessionId)
                waiter?(#"{"decision":"deny","reason":"session ended"}"#)
            }
        }
    }
```

**Step 2: Update PermissionRequest handler to key by toolUseId**

The current implementation keys `responseWaiters` by `sessionId`, but a session can have multiple pending permissions. Update `handlePermissionRequest` to use a composite key. Find the `handlePermissionRequest` method and replace:

```swift
    private func handlePermissionRequest(_ event: HookEvent, fd: Int32) {
        guard let sessionId = event.sessionId else {
            sendResponse(fd: fd, response: #"{"decision":"deny","reason":"no session id"}"#)
            return
        }

        let waitKey = sessionId + ":" + (event.toolUseId ?? UUID().uuidString)
        responseWaiters[waitKey] = { [weak self] response in
            self?.sendResponse(fd: fd, response: response)
        }

        socketQueue.asyncAfter(deadline: .now() + 120) { [weak self] in
            if let waiter = self?.responseWaiters.removeValue(forKey: waitKey) {
                waiter(#"{"decision":"deny","reason":"timeout"}"#)
            }
        }
    }
```

Also update `respondToPermission` to find the matching key:

```swift
    func respondToPermission(sessionId: String, approved: Bool) {
        let response = #"{"decision":"\#(approved ? "allow" : "deny")"}"#
        socketQueue.async { [weak self] in
            guard let self else { return }
            // Find the first waiter matching this session
            if let key = self.responseWaiters.keys.first(where: { $0.hasPrefix(sessionId + ":") }) {
                self.responseWaiters.removeValue(forKey: key)?(response)
            }
        }
    }
```

And update `cancelPendingPermissions` to match the composite key pattern:

```swift
    func cancelPendingPermissions(sessionId: String) {
        socketQueue.async { [weak self] in
            guard let self else { return }
            let matching = self.responseWaiters.keys.filter { $0.hasPrefix(sessionId + ":") }
            for key in matching {
                self.responseWaiters.removeValue(forKey: key)?(#"{"decision":"deny","reason":"session ended"}"#)
            }
        }
    }
```

**Step 3: Build to verify**

**Step 4: Commit**

```bash
git add NemoNotch/Services/HookServer.swift
git commit -m "feat: add cancelPendingPermissions and composite key for response waiters"
```

---

### Task 5: Update ClaudeCodeService for Permission Context

Use the new `toolUseId` from HookEvent and add cleanup on SessionEnd.

**Files:**
- Modify: `NemoNotch/Services/ClaudeCodeService.swift`

**Step 1: Update PermissionRequest handler**

Find the `"PermissionRequest"` case in `handleEvent` and replace:

```swift
        case "PermissionRequest":
            ensureSession()
            let ctx = PermissionContext(
                toolUseId: event.toolUseId ?? event.toolName ?? "unknown",
                toolName: event.toolName ?? "unknown",
                toolInput: event.message,
                receivedAt: now
            )
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .waitingForApproval(ctx)) ?? .waitingForApproval(ctx)
            updateContext()
            sessions[sessionId]?.lastEventTime = now
            LogService.info("Permission request: \(ctx.toolName) (\(ctx.toolUseId)) for session \(sessionId.prefix(8))", category: "ClaudeCode")
```

**Step 2: Add cancelPendingPermissions to SessionEnd**

Find the `"SessionEnd"` case and update:

```swift
        case "SessionEnd":
            hookServer.cancelPendingPermissions(sessionId: sessionId)
            watcherManager.stopWatching(sessionId: sessionId)
            sessions.removeValue(forKey: sessionId)
```

**Step 3: Update respondToPermission to handle nil session gracefully**

Find `respondToPermission` and update:

```swift
    func respondToPermission(sessionId: String, approved: Bool) {
        hookServer.respondToPermission(sessionId: sessionId, approved: approved)
        if sessions[sessionId] != nil {
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .processing) ?? .processing
            updateActiveSession()
        }
    }
```

This is already correct — no change needed. Just verify it compiles.

**Step 4: Build to verify**

**Step 5: Commit**

```bash
git add NemoNotch/Services/ClaudeCodeService.swift
git commit -m "feat: use toolUseId in PermissionContext, cancel pending permissions on SessionEnd"
```

---

### Task 6: Add Permission Approval UI to ClaudeTab

Add inline approve/deny buttons in the session row when waiting for approval, with tool info display.

**Files:**
- Modify: `NemoNotch/Tabs/ClaudeTab.swift`

**Step 1: Add helper to extract PermissionContext from session**

Add this computed property inside `ClaudeTab`:

```swift
    private func approvalContext(for session: ClaudeState) -> PermissionContext? {
        if case .waitingForApproval(let ctx) = session.phase { return ctx }
        return nil
    }
```

**Step 2: Add approval buttons to session row**

In the `sessionRow` function, find the rightmost section (the `Spacer` + status dot `Circle`). Replace the section starting from `Spacer(minLength: 0)` with:

```swift
            Spacer(minLength: 0)

            if let ctx = approvalContext(for: session) {
                // Permission approval buttons
                approvalButtons(for: session, ctx: ctx)
            } else {
                // Normal status dot
                Circle()
                    .fill(dotColor(session.status))
                    .frame(width: 6, height: 6)
                    .modifier(PulseModifier(isActive: session.status == .working))
            }
```

**Step 3: Add approvalButtons view**

Add this function inside `ClaudeTab`:

```swift
    private func approvalButtons(for session: ClaudeState, ctx: PermissionContext) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Tool info
            HStack(spacing: 4) {
                Text(ctx.toolName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))
                if !ctx.displayInput.isEmpty {
                    Text(ctx.displayInput)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            // Buttons
            HStack(spacing: 4) {
                if ctx.isInteractiveTool {
                    // AskUserQuestion: just show "Needs input"
                    Text("需要输入")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08))
                        .clipShape(Capsule())
                } else {
                    Button {
                        claudeService.respondToPermission(sessionId: session.id, approved: false)
                    } label: {
                        Text("拒绝")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        claudeService.respondToPermission(sessionId: session.id, approved: true)
                    } label: {
                        Text("允许")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.9))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
```

**Step 4: Update session row background for approval state**

In `sessionRow`, update the background to highlight approval state. Find the `.background(` modifier and replace:

```swift
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(approvalContext(for: session) != nil ? .orange.opacity(0.08) : .white.opacity(0.06))
        )
```

**Step 5: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add NemoNotch/Tabs/ClaudeTab.swift
git commit -m "feat: add inline permission approval buttons to ClaudeTab session rows"
```

---

### Task 7: Update CompactBadge for Approval Interaction

Show a more prominent indicator when approval is needed, with tap-to-approve flow.

**Files:**
- Modify: `NemoNotch/Notch/CompactBadge.swift`

**Step 1: Update claude badge right side for approval**

Find the `.claude(let status, let tool, let isPre)` case in the `body` view builder where `side == .right`. Replace just that case:

```swift
                    case .claude(let status, let tool, let isPre) where side == .right:
                        if status == .waiting && claudeService.activeSession?.phase.isWaitingForApproval == true {
                            // Approval needed: amber circle with exclamation
                            Circle()
                                .fill(Color.orange.opacity(0.3))
                                .frame(width: 16, height: 16)
                                .overlay {
                                    Image(systemName: "exclamationmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.orange)
                                }
                                .modifier(PulseModifier(isActive: true))
                        } else {
                            Image(systemName: ToolStyle.icon(tool))
                                .foregroundStyle(ToolStyle.color(tool).opacity(0.9))
                                .modifier(PulseModifier(isActive: status == .working))
                                .overlay {
                                    if isPre {
                                        Circle()
                                            .stroke(ToolStyle.color(tool), lineWidth: 1.5)
                                            .frame(width: 16, height: 16)
                                            .modifier(GlowPulseModifier())
                                    }
                                }
                        }
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Notch/CompactBadge.swift
git commit -m "feat: add approval indicator to CompactBadge with amber pulse"
```

---

### Task 8: Final Build & Cleanup

**Step 1: Clean build**

```bash
xcodebuild clean -scheme NemoNotch -configuration Debug 2>&1 | tail -2
xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED with 0 errors.

**Step 2: Manual verification**

After launching the app:
1. [ ] Install hooks → check `~/.nemonotch/hooks/hook-sender.sh` has PermissionRequest handling
2. [ ] Start Claude Code → session appears
3. [ ] Trigger a tool needing permission → session row shows approve/deny buttons
4. [ ] Tap "允许" → tool executes, session returns to processing
5. [ ] Tap "拒绝" → tool denied, session returns to processing
6. [ ] CompactBadge shows amber pulse when approval pending
7. [ ] Permission times out after 120s → auto-denied
8. [ ] Session end → pending permissions cleaned up

**Step 3: Remove the old hook script to force regeneration**

```bash
rm -f ~/.nemonotch/hooks/hook-sender.sh
```

The app will regenerate on next install.

**Step 4: Final commit**

```bash
git add -A
git commit -m "chore: Phase 3 cleanup and final integration"
```

---

## Summary

| Task | Files | Description |
|------|-------|-------------|
| 1 | `Services/HookInstaller.swift` | Smart hook script: 120s timeout for PermissionRequest |
| 2 | `Models/HookEvent.swift` | Add toolUseId field |
| 3 | `Models/SessionPhase.swift` | Tool-specific input formatting in PermissionContext |
| 4 | `Services/HookServer.swift` | cancelPendingPermissions, composite key for response waiters |
| 5 | `Services/ClaudeCodeService.swift` | Use toolUseId, cancel permissions on SessionEnd |
| 6 | `Tabs/ClaudeTab.swift` | Inline approve/deny buttons with tool info |
| 7 | `Notch/CompactBadge.swift` | Amber pulse indicator for pending approvals |
| 8 | Various | Final build verification and cleanup |
