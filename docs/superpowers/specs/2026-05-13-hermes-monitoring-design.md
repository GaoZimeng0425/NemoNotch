# Hermes-Agent Monitoring Design

## Overview

Add Hermes-agent monitoring to NemoNotch, sharing the existing OpenClaw tab with a unified protocol and shared UI components. Both services display agents in the same tab, sectioned by source.

## Data Source

Hermes-agent monitoring connects through the **Hermes WebUI HTTP API + SSE** (default `http://127.0.0.1:8787`):

- `GET /health` — detect WebUI online status
- `GET /api/sessions` — list active sessions with state
- `GET /api/session/{id}` — session detail (tool calls, messages)
- Optional password auth via `POST /login` → HMAC cookie

## Architecture

### Unified Protocol

New file: `Models/MultiAgentMonitor.swift`

```swift
enum AgentMonitorState: String, Codable {
    case idle, working, speaking, toolCalling, error
}

struct MonitoredAgent: Identifiable {
    let id: String
    var name: String
    var emoji: String
    var state: AgentMonitorState
    var currentTool: String?
    var lastMessage: String?
    var workspace: String?
    var lastEventTime: Date
}

@Observable
protocol MultiAgentMonitor {
    var agents: [String: MonitoredAgent] { get }
    var activeAgent: MonitoredAgent? { get }
    var isOnline: Bool { get }
    var isInstalled: Bool { get }
    var displayName: String { get }
    var iconEmoji: String { get }

    func connect()
    func disconnect()
}
```

Concrete types (not associated types) so the protocol works as `any MultiAgentMonitor` in SwiftUI.

### HermesService

New file: `Services/HermesService.swift`

- `@MainActor @Observable`, implements `MultiAgentMonitor`
- Config discovery from `~/.hermes/` directory
- Health check polling → `isInstalled` / `webuiOnline`
- Session state polling (3s interval) → map to `[MonitoredAgent]`
- 5s reconnect on connection failure
- 15min TTL cleanup for stale sessions
- Optional password authentication

### State Mapping

```
Hermes WebUI session state → AgentMonitorState
├── idle / no active task  → .idle
├── generating response    → .speaking
├── executing tool         → .toolCalling
├── processing (generic)   → .working
└── error                  → .error
```

Exact mapping determined during implementation by inspecting actual API responses.

## UI

### Tab Restructure

Rename Tab enum case `.openclaw` → `.agents`.
Rename `Tabs/OpenClawTab/` → `Tabs/AgentMonitorTab/`.

The tab shows agents from all `MultiAgentMonitor` services, sectioned by source:

```
── 🦞 OpenClaw ──
  agent-1  [speaking]   当前工具: Read
  agent-2  [idle]

── 🐦 Hermes ──
  session-1  [toolCalling]  当前工具: Bash
```

States:
- Both offline / not installed → show installation hints and waiting status
- One online → show that section only
- Both online → show both sections

### Shared Components

Extract from OpenClawTab into reusable components (new file `Notch/AgentMonitorView.swift`):

- `AgentMonitorView` — receives `any MultiAgentMonitor`, renders agent list
- `AgentRowView` — emoji badge + name + state tag + tool + message preview
- `AgentStateTag` — color-coded capsule for state

Both OpenClaw and Hermes sections use the same row component, differing only in the `MultiAgentMonitor` instance passed in.

### OpenClawService Changes

`OpenClawService` conforms to `MultiAgentMonitor`:
- Internal `AgentInfo` / `AgentState` types retained (no breaking changes)
- Computed property maps `AgentInfo` → `MonitoredAgent`
- Existing WebSocket connection logic unchanged

## Integration

### NemoNotchApp Changes

- Create `HermesService` instance alongside `OpenClawService`
- Inject both via `@Environment`
- Update `autoSelectTab` to check both monitors:
  ```
  if openClaw.activeAgent != nil → .agents
  if hermes.activeAgent != nil → .agents
  ```
- Badge priority updated: Hermes active agents contribute to badge display

### Badge Priority (revised)

```
notification > openclaw active > hermes active > ai approval > ai working > media playing > calendar upcoming

All references to `.openclaw` in the codebase (Tab enum, autoSelectTab, badge logic, TabBarView) must be updated to `.agents`.
```

## Implementation Order

1. Create `MultiAgentMonitor` protocol + shared types (`Models/MultiAgentMonitor.swift`)
2. `OpenClawService` conform to protocol (add computed mapping, no behavior change)
3. Extract shared UI components to `Notch/AgentMonitorView.swift`
4. Rename Tab enum `.openclaw` → `.agents`, rename `OpenClawTab/` → `AgentMonitorTab/`, refactor to use shared components
5. Implement `HermesService` (`Services/HermesService.swift`)
6. Wire into `NemoNotchApp` (service creation, environment injection, autoSelect, badge)
7. Test with Hermes WebUI running, verify state mapping against actual API responses

## Open Questions

- Exact Hermes WebUI API response structure — to be discovered during implementation by hitting actual endpoints
- Whether Hermes WebUI SSE can be used for real-time updates instead of polling — depends on available SSE event types
- Tab icon / emoji for Hermes section header (suggested 🐦, open to change)
