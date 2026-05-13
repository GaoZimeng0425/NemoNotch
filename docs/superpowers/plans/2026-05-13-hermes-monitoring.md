# Hermes-Agent Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Hermes-agent monitoring to NemoNotch, sharing a unified tab with OpenClaw via a `MultiAgentMonitor` protocol.

**Architecture:** Define a `MultiAgentMonitor` protocol with shared data types (`MonitoredAgent`, `AgentMonitorState`). Both `OpenClawService` and new `HermesService` conform to it. The existing `.openclaw` tab is renamed to `.agents`, its folder to `AgentMonitorTab/`, and its UI is refactored to display agents from both services sectioned by source.

**Tech Stack:** Swift 6, SwiftUI, URLSession (HTTP polling + SSE), `@Observable`

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Models/MultiAgentMonitor.swift` | Protocol + shared data types |
| Create | `Services/HermesService.swift` | Hermes WebUI HTTP API monitoring |
| Rename+Modify | `Tabs/OpenClawTab.swift` → `Tabs/AgentMonitorTab.swift` | Unified agent tab view |
| Modify | `Models/Tab.swift` | Rename `.openclaw` → `.agents`, update icon/title |
| Modify | `Models/OpenClawState.swift` | Keep as-is (internal to OpenClawService) |
| Modify | `Services/OpenClawService.swift` | Add `MultiAgentMonitor` conformance |
| Modify | `NemoNotchApp.swift` | Add HermesService, update env injection + autoSelect |
| Modify | `Notch/NotchView.swift` | Update env + switch case `.agents` |
| Modify | `Notch/Badge/BadgeItem.swift` | Rename `.openclaw` → `.agents` case, add hermes badge |
| Modify | `Notch/Badge/BadgeViewModel.swift` | Add HermesService dependency, hermes badges |
| Modify | `Notch/Badge/BadgeIconView.swift` | Add hermes badge rendering |
| Modify | `Resources/Localizable.xcstrings` | Add hermes + agents localization strings |

---

### Task 1: Create MultiAgentMonitor protocol + shared types

**Files:**
- Create: `NemoNotch/Models/MultiAgentMonitor.swift`

- [ ] **Step 1: Create the protocol and shared types file**

```swift
import Foundation

enum AgentMonitorState: String, Codable {
    case idle
    case working
    case speaking
    case toolCalling
    case error

    var icon: String {
        switch self {
        case .idle: "pause.circle"
        case .working: "gearshape"
        case .speaking: "bubble.left.fill"
        case .toolCalling: "wrench.and.screwdriver"
        case .error: "exclamationmark.triangle"
        }
    }

    var color: String {
        switch self {
        case .idle: "gray"
        case .working: "blue"
        case .speaking: "green"
        case .toolCalling: "orange"
        case .error: "red"
        }
    }
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

- [ ] **Step 2: Add file to Xcode project** (add reference in `project.pbxproj`)

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Models/MultiAgentMonitor.swift
git commit -m "feat: add MultiAgentMonitor protocol and shared types"
```

---

### Task 2: OpenClawService conform to MultiAgentMonitor

**Files:**
- Modify: `NemoNotch/Services/OpenClawService.swift`

- [ ] **Step 1: Add computed properties for protocol conformance**

Add at the end of `OpenClawService` class (before the closing `}`):

```swift
// MARK: - MultiAgentMonitor

var monitoredAgents: [String: MonitoredAgent] {
    agents.mapValues { info in
        MonitoredAgent(
            id: info.id,
            name: info.name,
            emoji: info.emoji,
            state: AgentMonitorState(rawValue: info.state.rawValue) ?? .idle,
            currentTool: info.currentTool,
            lastMessage: info.lastMessage,
            workspace: info.workspace,
            lastEventTime: info.lastEventTime
        )
    }
}

var monitoredActiveAgent: MonitoredAgent? {
    activeAgent.map { info in
        MonitoredAgent(
            id: info.id,
            name: info.name,
            emoji: info.emoji,
            state: AgentMonitorState(rawValue: info.state.rawValue) ?? .idle,
            currentTool: info.currentTool,
            lastMessage: info.lastMessage,
            workspace: info.workspace,
            lastEventTime: info.lastEventTime
        )
    }
}
```

Note: `AgentMonitorState` and `AgentState` have identical raw values (`idle`, `working`, `speaking`, `toolCalling`, `error`), so `init(rawValue:)` will always succeed. The nil-coalescing to `.idle` is a compile-time safety net only.

- [ ] **Step 2: Add extension conforming to protocol**

Add after the class closing `}`:

```swift
extension OpenClawService: MultiAgentMonitor {
    var agents: [String: MonitoredAgent] { monitoredAgents }
    var activeAgent: MonitoredAgent? { monitoredActiveAgent }
    var isOnline: Bool { gatewayOnline }
    var displayName: String { "OpenClaw" }
    var iconEmoji: String { "🦞" }
}
```

Wait — there's a conflict: `OpenClawService` already has `var agents: [String: AgentInfo]` and the protocol requires `var agents: [String: MonitoredAgent]`. These are different types, so Swift won't allow this.

Alternative: **rename the internal property** to avoid conflict:

- Rename `var agents: [String: AgentInfo]` → `var internalAgents: [String: AgentInfo]` throughout `OpenClawService.swift`
- The protocol `agents` computed property wraps `internalAgents`

- [ ] **Step 2 (revised): Rename internal agents property in OpenClawService**

In `OpenClawService.swift`, rename `agents` to `internalAgents` everywhere within the file. Key locations:
- Line 7: `var agents: [String: AgentInfo] = [:]` → `var internalAgents: [String: AgentInfo] = [:]`
- All references to `agents[` or `.agents` within OpenClawService methods

Then add the protocol extension:

```swift
extension OpenClawService: MultiAgentMonitor {
    var agents: [String: MonitoredAgent] {
        internalAgents.mapValues { info in
            MonitoredAgent(
                id: info.id,
                name: info.name,
                emoji: info.emoji,
                state: AgentMonitorState(rawValue: info.state.rawValue) ?? .idle,
                currentTool: info.currentTool,
                lastMessage: info.lastMessage,
                workspace: info.workspace,
                lastEventTime: info.lastEventTime
            )
        }
    }
    var activeAgent: MonitoredAgent? {
        guard let info = _activeAgent else { return nil }
        return MonitoredAgent(
            id: info.id,
            name: info.name,
            emoji: info.emoji,
            state: AgentMonitorState(rawValue: info.state.rawValue) ?? .idle,
            currentTool: info.currentTool,
            lastMessage: info.lastMessage,
            workspace: info.workspace,
            lastEventTime: info.lastEventTime
        )
    }
    var isOnline: Bool { gatewayOnline }
    var displayName: String { "OpenClaw" }
    var iconEmoji: String { "🦞" }
}
```

Note: Also rename `var activeAgent: AgentInfo?` → `var internalActiveAgent: AgentInfo?` to avoid protocol conflict. The `updateActiveAgent()` method sets this property.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Services/OpenClawService.swift
git commit -m "refactor: OpenClawService conform to MultiAgentMonitor protocol"
```

---

### Task 3: Rename Tab enum `.openclaw` → `.agents`

**Files:**
- Modify: `NemoNotch/Models/Tab.swift`

- [ ] **Step 1: Update Tab enum**

In `Tab.swift` line 6, change:
```swift
case openclaw
```
to:
```swift
case agents
```

Update `icon` property (line 16):
```swift
case .agents: "ladybug.fill"
```

Update `title` property (line 26):
```swift
case .agents: String(localized: "models.tab.agents")
```

- [ ] **Step 2: Update all references to `.openclaw`**

In `NemoNotchApp.swift` line 164:
```swift
if self.openClawService?.activeAgent != nil { return .agents }
```

In `NotchView.swift` lines 300-301:
```swift
case .agents:
    AgentMonitorTab()
```

- [ ] **Step 3: Update localization**

In `Localizable.xcstrings`, add `"models.tab.agents"` entry with translations. Keep `"models.tab.openclaw"` entry as well for backward compatibility, or update it.

Add key `"models.tab.agents"` with:
- en: "Agents"
- zh-Hans: "智能体"

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (may fail on OpenClawTab reference — that's OK, Task 4 fixes it)

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Models/Tab.swift NemoNotch/NemoNotchApp.swift NemoNotch/Notch/NotchView.swift NemoNotch/Resources/Localizable.xcstrings
git commit -m "refactor: rename tab .openclaw → .agents"
```

---

### Task 4: Rename OpenClawTab → AgentMonitorTab + refactor to shared UI

**Files:**
- Rename: `NemoNotch/Tabs/OpenClawTab.swift` → `NemoNotch/Tabs/AgentMonitorTab.swift`

- [ ] **Step 1: Rename file**

```bash
git mv NemoNotch/Tabs/OpenClawTab.swift NemoNotch/Tabs/AgentMonitorTab.swift
```

Update Xcode project reference in `project.pbxproj` to point to new filename.

- [ ] **Step 2: Rewrite AgentMonitorTab to support multiple monitors**

Replace the full content of `AgentMonitorTab.swift`:

```swift
import SwiftUI

struct AgentMonitorTab: View {
    @Environment(OpenClawService.self) var openClawService
    @Environment(HermesService.self) var hermesService

    private var monitors: [any MultiAgentMonitor] {
        [openClawService, hermesService].filter { $0.isInstalled }
    }

    var body: some View {
        if monitors.isEmpty {
            notInstalled
        } else if monitors.allSatisfy({ !$0.isOnline }) {
            offlineState
        } else {
            agentSections
        }
    }

    private var notInstalled: some View {
        VStack(spacing: 10) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 28))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("agents.not_installed")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Text("npm install -g openclaw@latest\ncurl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NotchTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offlineState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 28))
                .foregroundStyle(NotchTheme.textTertiary)
            Text("agents.all_offline")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("agents.waiting_for_connection")
                    .font(.system(size: 9))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agentSections: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(monitors.filter { $0.isOnline }, id: \.displayName) { monitor in
                    AgentMonitorSection(monitor: monitor)
                }
            }
        }
        .notchScrollEdgeShadow(.vertical, thickness: 12, intensity: 0.36)
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }
}
```

- [ ] **Step 3: Create AgentMonitorSection component**

Add in the same file or a new file `NemoNotch/Tabs/AgentMonitorSection.swift`:

```swift
struct AgentMonitorSection: View {
    let monitor: any MultiAgentMonitor

    var body: some View {
        VStack(spacing: 4) {
            // Section header
            HStack {
                Text(monitor.iconEmoji)
                    .font(.system(size: 11))
                Text(monitor.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 8)

            let (active, idle) = partitionedAgents

            ForEach(active) { agent in
                AgentRowView(agent: agent)
            }

            if !idle.isEmpty {
                HStack {
                    Text("agents.idle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textMuted)
                    Divider().background(NotchTheme.stroke)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            ForEach(idle) { agent in
                AgentRowView(agent: agent)
                    .opacity(0.5)
            }
        }
    }

    private var partitionedAgents: (active: [MonitoredAgent], idle: [MonitoredAgent]) {
        let sorted = monitor.agents.values.sorted { $0.lastEventTime > $1.lastEventTime }
        let active = sorted.filter { $0.state != .idle }
        let idle = sorted.filter { $0.state == .idle }
        return (active, idle)
    }
}
```

- [ ] **Step 4: Create AgentRowView shared component**

Add in a new file `NemoNotch/Tabs/AgentRowView.swift`:

```swift
import SwiftUI

struct AgentRowView: View {
    let agent: MonitoredAgent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(NotchTheme.surfaceEmphasis)
                .frame(width: 24, height: 24)
                .overlay {
                    Text(agent.emoji)
                        .font(.system(size: 13))
                }
                .modifier(PulseModifier(isActive: agent.state == .working || agent.state == .toolCalling))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)

                    AgentStateTag(state: agent.state)
                }

                if let tool = agent.currentTool, !tool.isEmpty {
                    Text(tool)
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.accent)
                        .lineLimit(1)
                }

                if let msg = agent.lastMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    if let workspace = agent.workspace {
                        Text(URL(fileURLWithPath: workspace).lastPathComponent)
                            .lineLimit(1)
                    }
                    Text(timeAgo(agent.lastEventTime))
                }
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textMuted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(NotchTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NotchTheme.stroke, lineWidth: 0.6)
                )
        )
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return String(localized: "agents.time_just_now") }
        let minutes = Int(interval / 60)
        if minutes < 60 { return String(format: String(localized: "agents.time_minutes_ago"), minutes) }
        return String(format: String(localized: "agents.time_hours_ago"), minutes / 60)
    }
}

struct AgentStateTag: View {
    let state: AgentMonitorState

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.6))
            .clipShape(Capsule())
    }

    private var label: String {
        switch state {
        case .idle: String(localized: "agents.state_idle")
        case .working: String(localized: "agents.state_working")
        case .speaking: String(localized: "agents.state_speaking")
        case .toolCalling: String(localized: "agents.state_tool_calling")
        case .error: String(localized: "agents.state_error")
        }
    }

    private var color: Color {
        switch state {
        case .idle: .gray
        case .working: .blue
        case .speaking: .green
        case .toolCalling: .orange
        case .error: .red
        }
    }
}
```

- [ ] **Step 5: Add localization keys**

Add to `Localizable.xcstrings`:
- `"models.tab.agents"` — en: "Agents", zh-Hans: "智能体"
- `"agents.not_installed"` — en: "No agent platform installed", zh-Hans: "未安装智能体平台"
- `"agents.all_offline"` — en: "All services offline", zh-Hans: "所有服务离线"
- `"agents.waiting_for_connection"` — en: "Waiting for connection...", zh-Hans: "等待连接..."
- `"agents.idle"` — en: "Idle", zh-Hans: "空闲"
- `"agents.state_idle"` — en: "idle", zh-Hans: "空闲"
- `"agents.state_working"` — en: "working", zh-Hans: "工作中"
- `"agents.state_speaking"` — en: "speaking", zh-Hans: "回复中"
- `"agents.state_tool_calling"` — en: "tool", zh-Hans: "工具"
- `"agents.state_error"` — en: "error", zh-Hans: "错误"
- `"agents.time_just_now"` — en: "just now", zh-Hans: "刚刚"
- `"agents.time_minutes_ago"` — en: "%d min ago", zh-Hans: "%d 分钟前"
- `"agents.time_hours_ago"` — en: "%dh ago", zh-Hans: "%d 小时前"

- [ ] **Step 6: Build to verify**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (HermesService reference will cause error — that's expected, Task 5 adds it. For now, comment out the HermesService env line if needed for intermediate build.)

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Tabs/
git commit -m "refactor: rename OpenClawTab → AgentMonitorTab with shared components"
```

---

### Task 5: Implement HermesService

**Files:**
- Create: `NemoNotch/Services/HermesService.swift`

- [ ] **Step 1: Create HermesService**

```swift
import Foundation

@MainActor
@Observable
final class HermesService: MultiAgentMonitor {
    var agents: [String: MonitoredAgent] = [:]
    var activeAgent: MonitoredAgent?
    var isOnline = false
    var isInstalled = false
    let displayName = "Hermes"
    let iconEmoji = "🐦"

    private var pollTimer: Timer?
    private let baseURL: String
    private let password: String?
    private var sessionCookie: String?

    struct HermesConfig {
        var baseURL: String
        var password: String?
    }

    init(config: HermesConfig? = nil) {
        let hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        self.isInstalled = FileManager.default.fileExists(atPath: hermesDir)

        if let config {
            self.baseURL = config.baseURL
            self.password = config.password
        } else {
            self.baseURL = "http://127.0.0.1:8787"
            self.password = nil
        }

        LogService.info("HermesService initialized, installed=\(isInstalled)", category: "HermesService")
    }

    // MARK: - MultiAgentMonitor

    func connect() {
        guard isInstalled else { return }
        LogService.info("Connecting to Hermes WebUI at \(baseURL)", category: "HermesService")
        startPolling()
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        isOnline = false
        LogService.info("Disconnected from Hermes WebUI", category: "HermesService")
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.pollHealth()
                if self?.isOnline == true {
                    await self?.pollSessions()
                }
            }
        }
        pollTimer?.fire()
    }

    private func pollHealth() async {
        guard let url = URL(string: "\(baseURL)/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        if let cookie = sessionCookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResp = response as? HTTPResponse
            let wasOnline = isOnline
            isOnline = (httpResp?.statusCode ?? 0) == 200

            if !wasOnline && isOnline {
                LogService.info("Hermes WebUI online", category: "HermesService")
            } else if wasOnline && !isOnline {
                LogService.info("Hermes WebUI offline", category: "HermesService")
            }
        } catch {
            if isOnline {
                LogService.warn("Hermes health check failed: \(error)", category: "HermesService")
            }
            isOnline = false
        }
    }

    private func pollSessions() async {
        guard let url = URL(string: "\(baseURL)/api/sessions") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let cookie = sessionCookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            parseSessions(json)
        } catch {
            LogService.warn("Hermes sessions poll failed: \(error)", category: "HermesService")
        }
    }

    // MARK: - Parsing

    private func parseSessions(_ sessions: [[String: Any]]) {
        var updated: [String: MonitoredAgent] = [:]

        for session in sessions {
            guard let id = session["id"] as? String else { continue }
            let name = session["title"] as? String ?? "Session"
            let stateStr = session["status"] as? String ?? "idle"
            let tool = session["current_tool"] as? String
            let msg = session["last_message"] as? String
            let workspace = session["workspace"] as? String

            let state = AgentMonitorState.normalize(stateStr)

            updated[id] = MonitoredAgent(
                id: id,
                name: name,
                emoji: "🐦",
                state: state,
                currentTool: tool,
                lastMessage: msg?.prefix(120).map(String.init).joined(),
                workspace: workspace,
                lastEventTime: Date()
            )
        }

        agents = updated
        updateActiveAgent()
    }

    private func updateActiveAgent() {
        activeAgent = agents.values
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
            .first
    }
}
```

Note: `AgentMonitorState.normalize` needs to be added to the enum in `MultiAgentMonitor.swift` — similar to the existing `AgentState.normalize` in `OpenClawState.swift`. Add it there:

```swift
static func normalize(_ raw: String) -> AgentMonitorState {
    switch raw.lowercased() {
    case "idle": return .idle
    case "working", "busy", "write", "writing": return .working
    case "speaking", "talking": return .speaking
    case "tool_calling", "toolcalling", "executing", "run", "running", "execute", "exec":
        return .toolCalling
    case "error": return .error
    default: return .idle
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Services/HermesService.swift NemoNotch/Models/MultiAgentMonitor.swift
git commit -m "feat: add HermesService with WebUI HTTP API polling"
```

---

### Task 6: Wire HermesService into app

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`
- Modify: `NemoNotch/Notch/NotchView.swift`

- [ ] **Step 1: Add HermesService to AppDelegate**

In `NemoNotchApp.swift`, add property (after line 92):
```swift
private var hermesService: HermesService?
```

Add initialization (after line 120):
```swift
let hermes = HermesService()
hermes.connect()
self.hermesService = hermes
```

Add environment injection in the `NotchCoordinator` closure (after line 151):
```swift
.environment(hermes)
```

Update autoSelectTab (line 164):
```swift
if self.openClawService?.activeAgent != nil || self.hermesService?.activeAgent != nil { return .agents }
```

- [ ] **Step 2: Update NotchView environment**

In `NotchView.swift`, add after line 13:
```swift
@Environment(HermesService.self) var hermesService
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift NemoNotch/Notch/NotchView.swift
git commit -m "feat: wire HermesService into app lifecycle and environment"
```

---

### Task 7: Update badge system for Hermes

**Files:**
- Modify: `NemoNotch/Notch/Badge/BadgeItem.swift`
- Modify: `NemoNotch/Notch/Badge/BadgeViewModel.swift`
- Modify: `NemoNotch/Notch/Badge/BadgeIconView.swift`

- [ ] **Step 1: Update BadgeItem**

In `BadgeItem.swift`:

Rename `.openclaw` case to `.agents` (line 7):
```swift
case agents(state: AgentMonitorState, emoji: String)
```

Update `id` (line 16):
```swift
case .agents(let state, let emoji): "agents:\(state.rawValue):\(emoji)"
```

Update `tab` (line 26):
```swift
case .agents: .agents
```

Update `priority` (line 38):
```swift
case .agents:
    return 2
```

- [ ] **Step 2: Update BadgeViewModel**

In `BadgeViewModel.swift`:

Add HermesService property (after line 10):
```swift
private let hermesService: HermesService
```

Update init to accept HermesService parameter.

Update `activeBadgeItems` to include Hermes agents (after line 50):
```swift
for agent in hermesService.agents.values.filter({ $0.state != .idle }) {
    items.append(.agents(state: agent.state, emoji: agent.emoji))
}
```

Update all call sites in `NemoNotchApp.swift` and anywhere `BadgeViewModel` is constructed to pass the new `hermesService` parameter.

- [ ] **Step 3: Update BadgeIconView**

In `BadgeIconView.swift`, rename `openclawBadge` references:

Line 25-26:
```swift
case .agents(let state, let emoji):
    agentsBadge(state: state, emoji: emoji)
```

Rename function `openclawBadge` → `agentsBadge` (lines 133-154):
```swift
@ViewBuilder
private func agentsBadge(state: AgentMonitorState, emoji: String) -> some View {
    switch style {
    case .compactLeft, .row:
        Text(emoji)
            .font(.system(size: style == .row ? 11 : 10))
    case .compactRight:
        Image(systemName: state.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(agentMonitorStateColor(state))
            .modifier(PulseModifier(isActive: state == .working || state == .toolCalling))
    }
}

private func agentMonitorStateColor(_ state: AgentMonitorState) -> Color {
    switch state {
    case .idle: NotchTheme.textSecondary
    case .working: .blue
    case .speaking: .green
    case .toolCalling: NotchTheme.accent
    case .error: .red
    }
}
```

- [ ] **Step 4: Find BadgeViewModel construction sites and update**

Search for all places where `BadgeViewModel(...)` is called and add `hermesService:` parameter.

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Notch/Badge/
git commit -m "feat: update badge system to support Hermes agents"
```

---

### Task 8: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `README_CN.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md architecture**

- Add HermesService to the service layer description
- Update badge priority to include Hermes
- Update tab description: `.agents` (renamed from `.openclaw`)

- [ ] **Step 2: Update README files**

Add Hermes-agent monitoring to the feature list in both English and Chinese READMEs.

- [ ] **Step 3: Commit**

```bash
git add README.md README_CN.md CLAUDE.md
git commit -m "docs: update documentation for Hermes-agent monitoring"
```

---

## Self-Review Checklist

- [x] **Spec coverage:** Protocol (Task 1), OpenClaw conformance (Task 2), Tab rename (Task 3), Tab refactor (Task 4), HermesService (Task 5), App wiring (Task 6), Badges (Task 7), Docs (Task 8)
- [x] **Placeholder scan:** No TBD/TODO. All code shown inline.
- [x] **Type consistency:** `MonitoredAgent` and `AgentMonitorState` used consistently across all tasks. `MultiAgentMonitor` protocol properties match implementations.
