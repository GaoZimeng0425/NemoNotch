# OpenClaw Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an OpenClaw tab to NemoNotch that monitors Agent execution status via the OpenClaw Gateway WebSocket.

**Architecture:** New `OpenClawService` connects to `ws://localhost:18789/gateway-ws` using native `URLSessionWebSocketTask`, maintains an `agents` dictionary, and drives a new `OpenClawTab` view. Follows the same `@Observable` + `@Environment` pattern as `ClaudeCodeService`.

**Tech Stack:** Swift 5, SwiftUI, Foundation URLSessionWebSocketTask, no third-party deps.

---

### Task 1: Create OpenClawState model

**Files:**
- Create: `NemoNotch/Models/OpenClawState.swift`

**Step 1: Create the model file**

```swift
import Foundation

enum AgentState: String, Codable {
    case idle
    case working
    case speaking
    case toolCalling
    case error

    /// Normalize various input strings to canonical states.
    /// Inspired by Star Office UI's normalize_agent_state().
    static func normalize(_ raw: String) -> AgentState {
        switch raw.lowercased() {
        case "idle": return .idle
        case "working", "busy", "write", "writing": return .working
        case "speaking", "talking": return .speaking
        case "tool_calling", "toolcalling", "executing", "executing", "run", "running", "execute", "exec":
            return .toolCalling
        case "error": return .error
        default: return .idle
        }
    }

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

struct AgentInfo: Identifiable {
    let id: String
    var name: String
    var state: AgentState
    var currentTool: String?
    var lastMessage: String?
    var workspace: String?
    var lastEventTime: Date

    init(id: String, name: String = "Agent", state: AgentState = .idle) {
        self.id = id
        self.name = name
        self.state = state
        self.lastEventTime = Date()
    }
}
```

**Step 2: Add the file to the Xcode project**

In Xcode: right-click `Models` group → Add Files to "NemoNotch" → select `OpenClawState.swift`.

Or via `project.pbxproj` edit (must add file reference + build phase membership).

**Step 3: Build to verify**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add NemoNotch/Models/OpenClawState.swift
git commit -m "feat: add OpenClawState model with AgentState enum and AgentInfo"
```

---

### Task 2: Create OpenClawService

**Files:**
- Create: `NemoNotch/Services/OpenClawService.swift`
- Reference: `NemoNotch/Services/ClaudeCodeService.swift` (pattern)

**Step 1: Create the service file**

```swift
import Foundation

@Observable
final class OpenClawService {
    var agents: [String: AgentInfo] = [:]
    var activeAgent: AgentInfo?
    var gatewayOnline = false
    var isInstalled = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTimer: Timer?
    private var ttlTimer: Timer?
    private let gatewayURL: URL
    private let token: String?

    init() {
        let expanded = NSString(string: "~/.openclaw/openclaw.json").expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let gateway = json["gateway"] as? [String: Any]
            self.token = gateway?["auth"] as? [String: Any] != nil
                ? (gateway?["auth"] as? [String: Any])?["token"] as? String
                : nil
            let port = gateway?["port"] as? Int ?? 18789
            self.gatewayURL = URL(string: "ws://localhost:\(port)/gateway-ws")!
            self.isInstalled = true
        } else {
            self.gatewayURL = URL(string: "ws://localhost:18789/gateway-ws")!
            self.token = nil
            self.isInstalled = false
        }
    }

    func connect() {
        guard isInstalled else { return }
        disconnect()

        var request = URLRequest(url: gatewayURL)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        receiveMessage()
        gatewayOnline = true
        startTTLTimer()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        gatewayOnline = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        ttlTimer?.invalidate()
        ttlTimer = nil
    }

    // MARK: - WebSocket Messages

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()
            case .failure(let error):
                print("[OpenClaw] WebSocket error: \(error)")
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else { return }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? json["event"] as? String ?? ""

        switch type {
        case "agent":
            handleAgentEvent(json)
        case "health":
            gatewayOnline = true
        case "heartbeat":
            gatewayOnline = true
        case "presence":
            break
        default:
            break
        }
    }

    private func handleAgentEvent(_ json: [String: Any]) {
        guard let agentId = json["agentId"] as? String ?? json["id"] as? String else { return }
        let rawState = json["state"] as? String ?? json["status"] as? String ?? "idle"
        let state = AgentState.normalize(rawState)

        let name = json["name"] as? String ?? json["agentName"] as? String ?? "Agent \(agentId.prefix(4))"
        let tool = json["tool"] as? String ?? json["toolName"] as? String
        let message = json["message"] as? String ?? json["detail"] as? String
        let workspace = json["workspace"] as? String ?? json["cwd"] as? String

        if agents[agentId] == nil {
            agents[agentId] = AgentInfo(id: agentId, name: name, state: state)
        }

        agents[agentId]?.state = state
        agents[agentId]?.name = name
        if let tool { agents[agentId]?.currentTool = tool }
        if let message { agents[agentInfo]?.lastMessage = message }
        if let workspace { agents[agentId]?.workspace = workspace }
        agents[agentId]?.lastEventTime = Date()

        updateActiveAgent()
    }

    private func updateActiveAgent() {
        activeAgent = agents.values
            .filter { $0.state != .idle }
            .sorted { $0.lastEventTime > $1.lastEventTime }
            .first
    }

    // MARK: - TTL (5 min auto-idle, inspired by Star Office)

    private func startTTLTimer() {
        ttlTimer?.invalidate()
        ttlTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupStaleAgents()
        }
    }

    private func cleanupStaleAgents() {
        let threshold = Date().addingTimeInterval(-300) // 5 minutes
        for (id, agent) in agents {
            if agent.lastEventTime < threshold && agent.state != .idle {
                agents[id]?.state = .idle
                agents[id]?.currentTool = nil
            }
        }
        // Remove agents idle for over 30 minutes
        let removeThreshold = Date().addingTimeInterval(-1800)
        agents = agents.filter { $0.value.lastEventTime >= removeThreshold }
        updateActiveAgent()
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        gatewayOnline = false
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }
}
```

**Important note:** There is a typo on one line — `agentInfo` should be `agentId`. Fix during implementation:
```swift
if let message { agents[agentId]?.lastMessage = message }
```

**Step 2: Add to Xcode project build phase**

**Step 3: Build to verify**

**Step 4: Commit**

```bash
git add NemoNotch/Services/OpenClawService.swift
git commit -m "feat: add OpenClawService with WebSocket connection and TTL management"
```

---

### Task 3: Register OpenClaw tab in Tab enum

**Files:**
- Modify: `NemoNotch/Models/Tab.swift`

**Step 1: Add `.openclaw` case to the enum**

Add after `.claude` and before `.launcher`:

```swift
case openclaw
```

**Step 2: Add icon and title**

In the `icon` property, add:
```swift
case .openclaw: "ladybug"  // closest to lobster in SF Symbols
```

In the `title` property, add:
```swift
case .openclaw: "OpenClaw"
```

**Step 3: Build to verify**

Expected: Build will fail on `NotchView.swift` switch exhaustiveness — that's expected, fixed in Task 5.

**Step 4: Commit**

```bash
git add NemoNotch/Models/Tab.swift
git commit -m "feat: add .openclaw tab case with icon and title"
```

---

### Task 4: Create OpenClawTab view

**Files:**
- Create: `NemoNotch/Tabs/OpenClawTab.swift`
- Reference: `NemoNotch/Tabs/ClaudeTab.swift` (pattern)

**Step 1: Create the tab view file**

```swift
import SwiftUI

struct OpenClawTab: View {
    @Environment(OpenClawService.self) var openClawService

    var body: some View {
        if !openClawService.isInstalled {
            notInstalled
        } else if !openClawService.gatewayOnline {
            offline
        } else if openClawService.agents.isEmpty {
            idle
        } else {
            agentList
        }
    }

    private var notInstalled: some View {
        VStack(spacing: 10) {
            Image(systemName: "ladybug")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("OpenClaw 未安装")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            Text("npm install -g openclaw@latest")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offline: some View {
        VStack(spacing: 10) {
            Image(systemName: "ladybug")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("Gateway 离线")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("等待连接...")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Image(systemName: "ladybug")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.3))
            Text("所有 Agent 空闲")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Gateway 在线")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var agentList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(activeAgents) { agent in
                    agentRow(agent)
                }
                if !idleAgents.isEmpty {
                    Divider()
                        .overlay(.white.opacity(0.1))
                    ForEach(idleAgents) { agent in
                        agentRow(agent)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var activeAgents: [AgentInfo] {
        agents.filter { $0.state != .idle }.sorted { $0.lastEventTime > $1.lastEventTime }
    }

    private var idleAgents: [AgentInfo] {
        agents.filter { $0.state == .idle }.sorted { $0.lastEventTime > $1.lastEventTime }
    }

    private var agents: [AgentInfo] {
        Array(openClawService.agents.values)
    }

    private func agentRow(_ agent: AgentInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: agent.state.icon)
                .font(.system(size: 11))
                .foregroundStyle(stateColor(agent.state))
                .frame(width: 16)
                .modifier(PulseModifier(isActive: agent.state == .working || agent.state == .toolCalling))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    stateTag(agent.state)
                    if let tool = agent.currentTool {
                        Text(tool)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                if let msg = agent.lastMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let ws = agent.workspace {
                        Text(URL(fileURLWithPath: ws).lastPathComponent)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                    Text(timeAgo(agent.lastEventTime))
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(agent.state == .idle ? 0.5 : 1.0)
    }

    private func stateColor(_ state: AgentState) -> Color {
        switch state {
        case .idle: .gray
        case .working: .blue
        case .speaking: .green
        case .toolCalling: .orange
        case .error: .red
        }
    }

    private func stateTag(_ state: AgentState) -> some View {
        let (label, color) = stateTagStyle(state)
        return Text(label)
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.7))
            .clipShape(Capsule())
    }

    private func stateTagStyle(_ state: AgentState) -> (String, Color) {
        switch state {
        case .idle: return ("空闲", .gray)
        case .working: return ("工作中", .blue)
        case .speaking: return ("发言", .green)
        case .toolCalling: return ("工具调用", .orange)
        case .error: return ("错误", .red)
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        return "\(minutes / 60) 小时前"
    }
}
```

**Step 2: Add to Xcode project**

**Step 3: Build to verify**

**Step 4: Commit**

```bash
git add NemoNotch/Tabs/OpenClawTab.swift
git commit -m "feat: add OpenClawTab view with offline/idle/active states"
```

---

### Task 5: Wire OpenClaw tab into NotchView

**Files:**
- Modify: `NemoNotch/Notch/NotchView.swift:8,24,98-111`

**Step 1: Add environment variable**

At line 8, after the `claudeService` declaration, add:
```swift
@Environment(OpenClawService.self) var openClawService
```

**Step 2: Add badge check in `hasActiveBadge`**

After line 24 (`if claudeService.activeSession?.status == .working { return true }`), add:
```swift
if openClawService.activeAgent != nil { return true }
```

**Step 3: Add switch case in `tabContent`**

After the `.claude` case (line 104-105), add:
```swift
case .openclaw:
    OpenClawTab()
```

**Step 4: Build to verify**

**Step 5: Commit**

```bash
git add NemoNotch/Notch/NotchView.swift
git commit -m "feat: wire OpenClawTab into NotchView"
```

---

### Task 6: Wire OpenClawService into AppDelegate

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift:75-111`

**Step 1: Add service property**

After line 75 (`private(set) var claudeCodeService: ClaudeCodeCodeService?`), add:
```swift
private var openClawService: OpenClawService?
```

**Step 2: Create and start service**

After `claude.startServer()` (line 90), add:
```swift
let openClaw = OpenClawService()
openClaw.connect()
self.openClawService = openClaw
```

**Step 3: Inject into NotchView environment**

In the `NotchView()` builder (around line 108), add:
```swift
.environment(openClaw)
```

**Step 4: Add to auto-select tab**

In the `autoSelectTab` closure (around line 115), add before the return nil:
```swift
if self.openClawService?.activeAgent != nil { return .openclaw }
```

**Step 5: Build to verify**

**Step 6: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "feat: wire OpenClawService into AppDelegate lifecycle"
```

---

### Task 7: Add OpenClaw badge support in CompactBadge

**Files:**
- Modify: `NemoNotch/Notch/CompactBadge.swift`

**Step 1: Add environment**

```swift
@Environment(OpenClawService.self) var openClawService
```

**Step 2: Add badge case to BadgeInfo enum**

```swift
case openclaw(AgentState, String?)  // state, currentTool
```

**Step 3: Add to `activeBadge` priority list**

After the Claude check, add:
```swift
if let agent = openClawService.activeAgent {
    return .openclaw(agent.state, agent.currentTool)
}
```

**Step 4: Add badge rendering**

In the `label` section of the Button, add cases:
```swift
case .openclaw where side == .left:
    Image(systemName: "ladybug")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.8))
case .openclaw(let state, let tool) where side == .right:
    Image(systemName: tool != nil ? "wrench.and.screwdriver" : "ladybug")
        .modifier(PulseModifier(isActive: state == .working || state == .toolCalling))
```

**Step 5: Add to `tabFor` and `badgeColor`**

```swift
// In tabFor:
case .openclaw(_, _): return .openclaw

// In badgeColor:
case .openclaw(let state, _): return state == .error ? .red : .orange
```

**Step 6: Build to verify**

**Step 7: Commit**

```bash
git add NemoNotch/Notch/CompactBadge.swift
git commit -m "feat: add OpenClaw badge to CompactBadge"
```

---

### Task 8: Add Xcode project file references

**Files:**
- Modify: `NemoNotch.xcodeproj/project.pbxproj`

**Step 1: Add file references**

For each new file (`OpenClawState.swift`, `OpenClawService.swift`, `OpenClawTab.swift`), add:
1. A file reference in the `PBXFileReference` section
2. A child reference in the appropriate group (Models/Services/Tabs)
3. A build file in `PBXBuildFile`
4. A source reference in `PBXSourcesBuildPhase`

**Step 2: Build to verify full project compiles**

Run: `xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5`

**Step 3: Commit**

```bash
git add NemoNotch.xcodeproj/project.pbxproj
git commit -m "feat: add OpenClaw files to Xcode project"
```

---

### Task 9: Final integration test

**Step 1: Build and run the app**

Launch NemoNotch. Without OpenClaw installed, should show the "未安装" state in the OpenClaw tab.

**Step 2: Verify tab appears**

Check that the ladybug icon appears in the tab bar when the tab is enabled.

**Step 3: Verify settings**

Open Settings, confirm OpenClaw tab toggle is present and functional.

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete OpenClaw integration — tab, service, badge"
```
