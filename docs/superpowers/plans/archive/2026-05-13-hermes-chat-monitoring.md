# Hermes Chat Content Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add session file parsing and message display to HermesService so users see chat content in AgentMonitorTab.

**Architecture:** HermesConversationParser parses session JSON files from `~/.hermes/sessions/`. HermesService polls every 3 seconds, detecting changes via `message_count`. AgentMonitorTab expands agent rows on tap to show last 10 messages.

**Tech Stack:** Swift 6, SwiftUI, Foundation (FileManager, JSONSerialization)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `NemoNotch/Services/HermesConversationParser.swift` | Create | Parse Hermes session JSON → `ParsedConversation` |
| `NemoNotch/Services/HermesService.swift` | Modify | Add session scanning, polling, message storage |
| `NemoNotch/Tabs/AgentMonitorTab.swift` | Modify | Expandable agent rows with message preview |

---

### Task 1: HermesConversationParser

**Files:**
- Create: `NemoNotch/Services/HermesConversationParser.swift`

- [ ] **Step 1: Create HermesConversationParser.swift**

```swift
import Foundation

enum HermesConversationParser: ConversationParserProtocol {

    // MARK: - ConversationParserProtocol

    static func findSessionFile(sessionId: String, cwd: String) -> String? {
        let hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        let fm = FileManager.default

        // Default profile
        let defaultPath = "\(hermesDir)/sessions/session_\(sessionId).json"
        if fm.fileExists(atPath: defaultPath) { return defaultPath }

        // Named profiles
        let profilesDir = "\(hermesDir)/profiles"
        guard let profiles = try? fm.contentsOfDirectory(atPath: profilesDir) else { return nil }
        for name in profiles {
            let path = "\(profilesDir)/\(name)/sessions/session_\(sessionId).json"
            if fm.fileExists(atPath: path) { return path }
        }

        return nil
    }

    static func parseFull(filePath: String) -> ParsedConversation {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ParsedConversation()
        }

        guard let rawMessages = json["messages"] as? [[String: Any]] else {
            return ParsedConversation(lastModel: json["model"] as? String)
        }

        var messages: [ChatMessage] = []
        for (index, msg) in rawMessages.enumerated() {
            guard let role = msg["role"] as? String else { continue }
            switch role {
            case "user":
                if let m = parseUserMessage(msg, index: index) { messages.append(m) }
            case "assistant":
                if let m = parseAssistantMessage(msg, index: index) { messages.append(m) }
            case "tool":
                if let m = parseToolMessage(msg, index: index) { messages.append(m) }
            default:
                break
            }
        }

        return ParsedConversation(
            messages: messages,
            lastModel: json["model"] as? String
        )
    }

    // MARK: - Session Discovery

    /// Scan all profile directories for session files, returning (path, sessionId) pairs.
    static func findAllSessionFiles() -> [(path: String, sessionId: String)] {
        let hermesDir = NSString(string: "~/.hermes").expandingTildeInPath
        let fm = FileManager.default
        var results: [(path: String, sessionId: String)] = []

        func scanDirectory(_ dir: String) {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for file in files where file.hasPrefix("session_") && file.hasSuffix(".json") {
                let sessionId = String(file.dropFirst("session_".count).dropLast(".json".count))
                results.append((path: "\(dir)/\(file)", sessionId: sessionId))
            }
        }

        // Default profile
        scanDirectory("\(hermesDir)/sessions")

        // Named profiles
        let profilesDir = "\(hermesDir)/profiles"
        if let profiles = try? fm.contentsOfDirectory(atPath: profilesDir) {
            for name in profiles {
                scanDirectory("\(profilesDir)/\(name)/sessions")
            }
        }

        return results
    }

    /// Quick-read the message_count from a session file without full parsing.
    static func readMessageCount(filePath: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["message_count"] as? Int
    }

    // MARK: - Private Parsing

    private static func parseUserMessage(_ msg: [String: Any], index: Int) -> ChatMessage? {
        guard let content = msg["content"] as? String, !content.isEmpty else { return nil }
        return ChatMessage(
            id: "hermes-user-\(index)",
            role: .user,
            content: content,
            timestamp: parseTimestamp(msg) ?? Date()
        )
    }

    private static func parseAssistantMessage(_ msg: [String: Any], index: Int) -> ChatMessage? {
        let content = msg["content"] as? String ?? ""
        let reasoning = msg["reasoning"] as? String
        let finishReason = msg["finish_reason"] as? String
        let toolCalls = msg["tool_calls"] as? [[String: Any]]

        // Has tool calls
        if finishReason == "tool_calls", let firstTool = toolCalls?.first,
           let function = firstTool["function"] as? [String: Any],
           let toolName = function["name"] as? String {
            let toolInput = function["arguments"] as? String
            return ChatMessage(
                id: "hermes-tool-\(index)",
                role: .assistant,
                content: content.isEmpty ? "Using \(toolName)" : content,
                toolName: toolName,
                toolInput: toolInput,
                timestamp: parseTimestamp(msg) ?? Date()
            )
        }

        // Regular assistant message
        var displayContent = content
        if let reasoning, !reasoning.isEmpty {
            displayContent = "> \(reasoning.prefix(200))\n\(content)"
        }
        guard !displayContent.isEmpty else { return nil }
        return ChatMessage(
            id: "hermes-assistant-\(index)",
            role: .assistant,
            content: displayContent,
            timestamp: parseTimestamp(msg) ?? Date()
        )
    }

    private static func parseToolMessage(_ msg: [String: Any], index: Int) -> ChatMessage? {
        guard let content = msg["content"] as? String else { return nil }

        // Try to extract a summary from JSON content
        let summary = summarizeToolContent(content)

        return ChatMessage(
            id: "hermes-result-\(index)",
            role: .toolResult,
            content: String(summary.prefix(500)),
            timestamp: parseTimestamp(msg) ?? Date()
        )
    }

    /// Extract key fields from tool result JSON string for display.
    private static func summarizeToolContent(_ content: String) -> String {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return content
        }

        // Check for success/error pattern
        if let success = json["success"] as? Bool {
            if success {
                if let results = json["results"] {
                    return "success - \(results)"
                }
                return "success"
            } else {
                return "error: \(json["error"] as? String ?? content)"
            }
        }

        // Fallback: compact JSON
        if let compact = try? String(data: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), encoding: .utf8) {
            return String(compact.prefix(200))
        }

        return content
    }

    private static func parseTimestamp(_ msg: [String: Any]) -> Date? {
        guard let ts = msg["timestamp"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: ts)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add NemoNotch/Services/HermesConversationParser.swift
git commit -m "feat: add HermesConversationParser for session JSON parsing"
```

---

### Task 2: HermesService Session Scanning & Polling

**Files:**
- Modify: `NemoNotch/Services/HermesService.swift`

- [ ] **Step 1: Add session scanning properties and timer to HermesService**

Add these properties after `private let hermesDir: String` (line 15):

```swift
    /// sessionId → recently parsed messages (max 20)
    var sessionMessages: [String: [ChatMessage]] = [:]
    private var lastMessageCounts: [String: Int] = [:]
    private var pollTimer: Timer?
```

- [ ] **Step 2: Replace connect() and disconnect() with polling logic**

Replace the existing `connect()` (line 27-29) and `disconnect()` (line 31-34) with:

```swift
    func connect() {
        guard isInstalled else { return }
        LogService.info("Starting Hermes monitoring (hook + session polling)", category: "HermesService")
        refreshSessions()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSessions()
            }
        }
    }

    func disconnect() {
        pollTimer?.invalidate()
        pollTimer = nil
        sessionMessages = [:]
        lastMessageCounts = [:]
        isOnline = false
        LogService.info("Disconnected from Hermes monitoring", category: "HermesService")
    }
```

- [ ] **Step 3: Add refreshSessions() method**

Add this method before the `// MARK: - Hook Install / Uninstall` section:

```swift
    // MARK: - Session File Polling

    private func refreshSessions() {
        let files = HermesConversationParser.findAllSessionFiles()

        var currentSessionIds: Set<String> = []
        for file in files {
            currentSessionIds.insert(file.sessionId)

            guard let count = HermesConversationParser.readMessageCount(filePath: file.path) else { continue }
            let lastCount = lastMessageCounts[file.sessionId] ?? 0

            if count > lastCount {
                let parsed = HermesConversationParser.parseFull(filePath: file.path)
                let recent = Array(parsed.messages.suffix(20))
                sessionMessages[file.sessionId] = recent
                lastMessageCounts[file.sessionId] = count

                // Update lastMessage on the agent if it exists
                if let lastMsg = recent.last?.content {
                    updateAgentLastMessage(sessionId: file.sessionId, message: lastMsg)
                }

                if !recent.isEmpty {
                    LogService.debug("Parsed \(recent.count) messages for session \(file.sessionId)", category: "HermesService")
                }
            }
        }

        // Clean up disappeared sessions
        let stale = lastMessageCounts.keys.filter { !currentSessionIds.contains($0) }
        for id in stale {
            lastMessageCounts.removeValue(forKey: id)
            sessionMessages.removeValue(forKey: id)
        }
    }

    private func updateAgentLastMessage(sessionId: String, message: String) {
        guard var agent = agents[sessionId] else { return }
        agent.lastMessage = String(message.prefix(100))
        agents[sessionId] = agent
    }
```

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Services/HermesService.swift
git commit -m "feat: add session file polling to HermesService for chat content"
```

---

### Task 3: AgentMonitorTab Expandable Message Preview

**Files:**
- Modify: `NemoNotch/Tabs/AgentMonitorTab.swift`

- [ ] **Step 1: Add expandedAgentId state to AgentMonitorTab**

In `AgentMonitorTab` struct (line 3), add a state property after the environment variables:

```swift
    @State private var expandedAgentId: String?
```

So the top of the struct becomes:

```swift
struct AgentMonitorTab: View {
    @Environment(OpenClawService.self) var openClawService
    @Environment(HermesService.self) var hermesService
    @State private var expandedAgentId: String?
```

- [ ] **Step 2: Pass expandedAgentId and messages to AgentMonitorSection**

Replace `AgentMonitorSection(monitor: monitor)` calls (line 63) with:

```swift
                    AgentMonitorSection(
                        monitor: monitor,
                        expandedAgentId: $expandedAgentId,
                        sessionMessages: monitor is HermesService ? (monitor as! HermesService).sessionMessages : nil
                    )
```

- [ ] **Step 3: Update AgentMonitorSection to accept expansion parameters**

Replace the `AgentMonitorSection` struct (lines 75-122) with:

```swift
struct AgentMonitorSection: View {
    let monitor: any MultiAgentMonitor
    @Binding var expandedAgentId: String?
    let sessionMessages: [String: [ChatMessage]]?

    private var partitionedAgents: (active: [MonitoredAgent], idle: [MonitoredAgent]) {
        let sorted = monitor.agents.values.sorted { $0.lastEventTime > $1.lastEventTime }
        let active = sorted.filter { $0.state != .idle }
        let idle = sorted.filter { $0.state == .idle }
        return (active, idle)
    }

    var body: some View {
        VStack(spacing: 4) {
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
                AgentRowView(
                    agent: agent,
                    isExpanded: expandedAgentId == agent.id,
                    messages: sessionMessages?[agent.id]
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedAgentId == agent.id {
                            expandedAgentId = nil
                        } else if sessionMessages?[agent.id] != nil {
                            expandedAgentId = agent.id
                        }
                    }
                }
            }

            if !idle.isEmpty {
                HStack {
                    Text("agents.idle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textMuted)
                    Divider()
                        .background(NotchTheme.stroke)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            ForEach(idle) { agent in
                AgentRowView(
                    agent: agent,
                    isExpanded: false,
                    messages: nil
                )
                .opacity(0.5)
            }
        }
    }
}
```

- [ ] **Step 4: Update AgentRowView to support expansion**

Replace the `AgentRowView` struct (lines 126-196) with:

```swift
struct AgentRowView: View {
    let agent: MonitoredAgent
    let isExpanded: Bool
    let messages: [ChatMessage]?

    var body: some View {
        VStack(spacing: 0) {
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

                        if messages != nil && !messages!.isEmpty {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(NotchTheme.textTertiary)
                        }
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

            if isExpanded, let messages {
                AgentMessagePreview(messages: messages)
            }
        }
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
```

- [ ] **Step 5: Add AgentMessagePreview view**

Add after `AgentRowView` (before `AgentStateTag`):

```swift
struct AgentMessagePreview: View {
    let messages: [ChatMessage]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
                .background(NotchTheme.stroke)
                .padding(.horizontal, 8)

            ForEach(Array(messages.suffix(10)), id: \.id) { msg in
                HStack(alignment: .top, spacing: 4) {
                    Text(iconForRole(msg))
                        .font(.system(size: 9))
                        .frame(width: 14)
                    Text(displayContent(for: msg))
                        .font(.system(size: 9))
                        .foregroundStyle(colorForRole(msg))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 6)
    }

    private func iconForRole(_ msg: ChatMessage) -> String {
        switch msg.role {
        case .user: "\u{1F464}"
        case .assistant: msg.toolName != nil ? "\u{1F527}" : "\u{1F916}"
        case .tool, .toolResult: "\u{1F4CB}"
        case .system: "\u{2139}\u{FE0F}"
        }
    }

    private func colorForRole(_ msg: ChatMessage) -> Color {
        switch msg.role {
        case .user: NotchTheme.textPrimary
        case .assistant: msg.toolName != nil ? NotchTheme.accent : NotchTheme.textSecondary
        case .tool, .toolResult: NotchTheme.textTertiary
        case .system: NotchTheme.textMuted
        }
    }

    private func displayContent(for msg: ChatMessage) -> String {
        if let toolName = msg.toolName {
            let input = msg.toolInput.map { " \u{2026}" } ?? ""
            return "\(toolName)\(input)"
        }
        return String(msg.content.prefix(80))
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Tabs/AgentMonitorTab.swift
git commit -m "feat: add expandable message preview to AgentMonitorTab"
```

---

### Task 4: Build Verification

- [ ] **Step 1: Build the project**

Run: `xcodebuild -project NemoNotch.xcodeproj -scheme NemoNotch -configuration Debug build 2>&1 | tail -20`

Expected: `** BUILD SUCCEEDED **`

If build fails, fix type errors and retry.

- [ ] **Step 2: Commit any build fixes (if needed)**

```bash
git add -u
git commit -m "fix: resolve build errors from Hermes chat monitoring"
```
