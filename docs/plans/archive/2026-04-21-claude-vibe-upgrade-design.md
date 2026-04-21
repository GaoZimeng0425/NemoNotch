# Claude Integration Upgrade — Vibe-Notch Feature Parity

Inspired by [vibe-notch (Claude Island)](/Users/gaozimeng/Learn/macOS/vibe-notch), bringing its best Claude monitoring features into NemoNotch's architecture.

## Phase 1: Foundation — Transport & State

### Unix Domain Socket (replace TCP)

Replace the TCP-based `HookServer` (port 49200–49209) with a Unix domain socket at `/tmp/nemonotch.sock`.

- Eliminates port conflicts and simplifies startup
- Enables two-way communication needed for permission approval (Phase 3)
- Hook installer updates shell script to use `nc -U /tmp/nemonotch.sock` instead of `curl`
- GCD-based non-blocking I/O via `DispatchSourceRead`

### SessionPhase State Machine

Replace the simple `ClaudeStatus` enum (`idle/working/waiting`) with a proper state machine:

```
idle → processing → waitingForInput
                  → waitingForApproval → processing
     → compacting → processing
ended ← (any state)
```

- Each transition is validated — illegal transitions are logged but ignored
- Prevents UI glitches from out-of-order events

### ConversationParser

Add incremental JSONL parser in `ClaudeCodeService`:

- Reads `~/.claude/projects/*/conversation-*.jsonl` files
- Only parses new lines since last sync for performance
- Stores parsed `ChatMessage` objects per session
- Powers both chat view (Phase 2) and interrupt detection

### Interrupt Detection

- Monitor JSONL for interrupt patterns (user pressing Escape)
- Detect `/clear` command — reset UI state while keeping session alive
- Transition session to idle on interrupt

### Files to modify/create:

- `Services/HookServer.swift` — rewrite for Unix socket
- `Services/HookInstaller.swift` — update hook script for `nc -U`
- `Models/ClaudeState.swift` — add `SessionPhase`, transition validation
- `Services/ConversationParser.swift` — new file, incremental JSONL parser
- `Services/InterruptWatcher.swift` — new file, interrupt/clear detection

---

## Phase 2: Chat History View

### Navigation

Claude tab has two modes:
1. **Session list** (default) — existing view, enhanced with token usage and subagent indicators
2. **Chat detail** — full conversation for the selected session

Click a session → opens chat detail. Back button or swipe → returns to list.

### ChatMessage Model

```swift
enum ChatMessageRole { case user, assistant, tool, toolResult, system }

struct ChatMessage: Identifiable {
    let id: String
    let role: ChatMessageRole
    let content: String
    let toolName: String?
    let toolInput: [String: Any]?
    let timestamp: Date
}
```

### Markdown Renderer

Lightweight SwiftUI renderer supporting: bold, italic, code blocks (with syntax highlighting), headers, bullet lists, links. Adapted from vibe-notch's `MarkdownRenderer` — converts markdown to `Text`/`AttributedString` views.

### Auto-scroll

- New messages auto-scroll to bottom
- User scrolls up → auto-scroll pauses, shows "new messages" indicator
- Tap indicator → scrolls back down

### Quick Approval Bar

When session has a pending permission, show inline approve/deny bar at top of chat view.

### Files to modify/create:

- `Tabs/ClaudeTab.swift` — add navigation state, chat detail view
- `Views/ClaudeChatView.swift` — new file, chat history list
- `Views/ChatMessageView.swift` — new file, message bubble renderer
- `Helpers/MarkdownRenderer.swift` — new file, markdown to SwiftUI
- `Models/ChatMessage.swift` — new file, message model

---

## Phase 3: Permission Approval

### Two-Way Communication

Hook script becomes request-response instead of fire-and-forget:

1. Claude Code triggers tool needing permission → `PermissionRequest` hook fires
2. Hook script sends event to Unix socket, **waits for response**
3. Notch UI expands showing permission request with approve/deny buttons
4. User taps approve/deny in notch badge or Claude tab
5. App writes decision back to socket
6. Hook script reads response, returns to Claude Code

### PermissionContext Model

```swift
struct PermissionContext {
    let toolUseId: String
    let toolName: String
    let toolInput: [String: Any]?
    let receivedAt: Date
}
```

### Notch Badge Interaction

- Pending permission → compact badge shows amber state with approve/deny buttons
- Clicking either sends response immediately
- Full Claude tab also shows inline approval UI

### AskUserQuestion Handling

- When Claude uses `AskUserQuestion`, show "Needs your input"
- Button to open terminal or chat view

### Files to modify/create:

- `Services/HookServer.swift` — add request-response protocol
- `Services/HookInstaller.swift` — update script to read response
- `Models/PermissionContext.swift` — new file
- `Notch/CompactBadge.swift` — add permission badge state
- `Tabs/ClaudeTab.swift` — add inline approval UI
- `Views/PermissionApprovalView.swift` — new file

---

## Phase 4: Advanced Features

### Subagent (Task Tool) Tracking

- When Claude spawns a subagent, show as nested entry in session list and chat view
- Display subagent description and tool execution status
- Parse agent JSON files for tool list

### Token Usage Tracking

- Parse usage info from conversation data (`usage.inputTokens`, `usage.outputTokens`)
- Display as small token count badge in session row (e.g., "12.4k tok")

### Better Session Sorting

Priority-based sorting:
1. Active (approval/processing/compacting) — highest
2. Waiting for input — medium
3. Idle — lowest
- Secondary sort by last user message date for stability

### Notification Improvements

- Suppress notifications when terminal is already focused
- Play sound when permission request arrives and terminal not focused

### Files to modify/create:

- `Services/AgentFileWatcher.swift` — new file, subagent tracking
- `Services/ClaudeCodeService.swift` — add token tracking, priority sorting
- `Tabs/ClaudeTab.swift` — subagent display, token badges
- `Services/TerminalDetector.swift` — new file, terminal focus detection

---

## Implementation Order

1. Phase 1 (Foundation) — everything else depends on this
2. Phase 3 (Permission Approval) — high impact, needs socket from Phase 1
3. Phase 2 (Chat View) — needs parser from Phase 1
4. Phase 4 (Advanced) — polish layer

## Key Reference Files from vibe-notch

| Feature | Reference File |
|---------|---------------|
| Unix socket server | `ClaudeIsland/Services/HookSocketServer.swift` |
| Session state machine | `ClaudeIsland/Models/SessionPhase.swift` |
| JSONL parser | `ClaudeIsland/Services/ConversationParser.swift` |
| Interrupt detection | `ClaudeIsland/Services/JSONLInterruptWatcher.swift` |
| Permission handling | `ClaudeIsland/Models/SessionEvent.swift` |
| Chat view | `ClaudeIsland/UI/ChatView.swift` |
| Markdown renderer | `ClaudeIsland/UI/MarkdownRenderer.swift` |
| Subagent tracking | `ClaudeIsland/Services/AgentFileWatcher.swift` |
