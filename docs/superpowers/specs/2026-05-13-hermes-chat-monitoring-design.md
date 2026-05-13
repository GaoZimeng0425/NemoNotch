# Hermes Chat Content Monitoring Design

## Goal

Add conversation content monitoring to HermesService so users can see Hermes agent chat messages, tool calls, and results in the Notch's AgentMonitorTab — complementing the existing real-time status from shell hooks.

## Approach

Extend HermesService with session file scanning and parsing. Display message summaries in AgentMonitorTab via expandable agent rows. No Gateway dependency, no AIChatTab integration.

## Components

### 1. HermesConversationParser

New file: `Services/HermesConversationParser.swift`

Implements `ConversationParserProtocol`:

- `findSessionFile(sessionId:cwd:)` — scans `~/.hermes/sessions/` and `~/.hermes/profiles/*/sessions/` for `session_{id}.json`
- `parseFull(filePath:)` — parses session JSON into `ParsedConversation`

Message mapping:

| Hermes JSON | ChatMessage |
|---|---|
| `role: user` | `.user` |
| `role: assistant, finish_reason: stop` | `.assistant` |
| `role: assistant, finish_reason: tool_calls` | `.assistant` with `toolName`/`toolInput` from first tool_call |
| `role: tool` | `.toolResult` |

Special handling:
- `reasoning` field: prepend to content with `> ` prefix
- `tool` message content: attempt JSON parse to extract key fields, fallback to raw string
- Skip `system_prompt` and `tools` fields (large, unused)
- Token counts return 0 (session JSON doesn't contain cumulative tokens)

### 2. HermesService Extensions

Add to existing `HermesService`:

New properties:
- `sessionMessages: [String: [ChatMessage]]` — last 20 messages per session
- `lastMessageCounts: [String: Int]` — guard to skip unchanged files

Scan strategy (in `connect()`):
1. 3-second polling timer calls `refreshSessions()`
2. Scan all profile `sessions/` directories for `session_*.json`
3. Quick-read `message_count` from each file, compare with stored count
4. Only re-parse when `message_count` increased
5. Parse via `HermesConversationParser`, keep last 20 messages
6. Clean up entries for disappeared files

Hook collaboration:
- Hook events provide real-time state (unchanged)
- Session files provide chat content (new)
- Both run independently, linked by session_id

Error handling:
- Incomplete JSON from concurrent writes: try-catch returns empty, retry next poll
- No file locks needed

### 3. AgentMonitorTab UI

Expandable agent rows with message preview.

Interaction:
- Tap agent row to expand/collapse message preview
- Only one agent expanded at a time
- Only Hermes agents with `sessionMessages` data show expand capability

Expanded area layout (indented below agent row):
- `.user` messages: `👤` prefix, content truncated 80 chars
- `.assistant` messages: `🤖` prefix, content truncated 80 chars
- `.assistant` with toolName: `🔧` prefix, show `toolName: toolInput` truncated
- `.toolResult`: `📋` prefix, extract key fields or truncate content
- Max 10 messages shown, single line each

State:
- `@State var expandedAgentId: String?` in AgentMonitorTab
- Read from `HermesService.sessionMessages[agentId]`

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `Services/HermesConversationParser.swift` | New | Session JSON parser |
| `Services/HermesService.swift` | Modify | Add session scanning, polling, message storage |
| `Tabs/AgentMonitorTab.swift` | Modify | Expandable rows with message preview |

## Out of Scope

- Gateway detection/management (YAGNI — same data source, only polling frequency differs)
- AIChatTab integration (Hermes multi-session doesn't fit single-session chat UI)
- Token counting (session JSON doesn't provide this)
- OpenClaw message preview (can be added later following same pattern)
