# Phase 4: Advanced Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add subagent (Task/Agent tool) tracking and notification improvements (terminal focus detection, sound alerts).

**Architecture:** AgentFileWatcher monitors per-task agent JSONL files using DispatchSourceFileSystemObject. When Claude uses the Task/Agent tool, we detect it via PreToolUse events, find the agent file, parse it for nested tool calls, and display them in chat bubbles. TerminalDetector checks frontmost app to suppress sounds when user is already looking at the terminal.

**Tech Stack:** Swift 5, SwiftUI, Foundation (DispatchSource, NSWorkspace, NSSound)

**Reference:** vibe-notch at `/Users/gaozimeng/Learn/macOS/vibe-notch/`

---

### Task 1: Create SubagentState Model

Model for tracking active subagent tasks and their nested tool calls.

**Files:**
- Create: `NemoNotch/Models/SubagentState.swift`

**Step 1: Create the model**

```swift
// NemoNotch/Models/SubagentState.swift
import Foundation

struct SubagentToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let input: String
    var isCompleted: Bool
    let timestamp: Date

    var displayInput: String {
        guard !input.isEmpty else { return "" }
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
            for key in priorityKeys {
                if let value = json[key] as? String, !value.isEmpty {
                    return String(value.prefix(80))
                }
            }
        }
        return String(input.prefix(80))
    }
}

struct TaskContext: Identifiable, Equatable {
    let id: String          // taskToolId
    var agentId: String?
    var description: String?
    var tools: [SubagentToolCall]
    let startTime: Date

    var activeToolCount: Int { tools.filter { !$0.isCompleted }.count }
    var completedToolCount: Int { tools.filter { $0.isCompleted }.count }
    var totalToolCount: Int { tools.count }
}

struct SubagentState: Equatable {
    var activeTasks: [String: TaskContext] = [:]  // keyed by taskToolId

    var hasActiveTasks: Bool { !activeTasks.isEmpty }

    mutating func startTask(taskToolId: String, description: String?) {
        activeTasks[taskToolId] = TaskContext(
            id: taskToolId,
            description: description,
            tools: [],
            startTime: Date()
        )
    }

    mutating func setAgentId(taskToolId: String, agentId: String) {
        activeTasks[taskToolId]?.agentId = agentId
    }

    mutating func updateTools(taskToolId: String, tools: [SubagentToolCall]) {
        activeTasks[taskToolId]?.tools = tools
    }

    mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    func taskSummary() -> String? {
        guard !activeTasks.isEmpty else { return nil }
        let total = activeTasks.values.reduce(0) { $0 + $1.totalToolCount }
        let active = activeTasks.values.reduce(0) { $0 + $1.activeToolCount }
        if active > 0 {
            return "\(active) tools running"
        }
        return "\(total) tools completed"
    }
}
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Models/SubagentState.swift
git commit -m "feat: add SubagentState model for Task/Agent tool tracking"
```

---

### Task 2: Add Subagent State to ClaudeState

Add subagent tracking to ClaudeState so each session can track its active subagent tasks.

**Files:**
- Modify: `NemoNotch/Models/ClaudeState.swift`

**Step 1: Add subagent property**

Add a `subagentState` property to `ClaudeState`:

```swift
    var subagentState = SubagentState()
```

Add after `var lastParsedOffset: UInt64 = 0` (line 18).

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Models/ClaudeState.swift
git commit -m "feat: add subagentState to ClaudeState for per-session task tracking"
```

---

### Task 3: Create AgentFileWatcher

Watch agent JSONL files for subagent tool updates. Uses DispatchSourceFileSystemObject for real-time monitoring.

**Files:**
- Create: `NemoNotch/Services/AgentFileWatcher.swift`

**Step 1: Create the watcher**

```swift
// NemoNotch/Services/AgentFileWatcher.swift
import Foundation

final class AgentFileWatcher {
    private let filePath: String
    private let taskToolId: String
    private let onUpdate: ([SubagentToolCall]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.nemonotch.agentwatcher", qos: .utility)
    private var seenToolIds: Set<String> = []

    init(filePath: String, taskToolId: String, onUpdate: @escaping ([SubagentToolCall]) -> Void) {
        self.filePath = filePath
        self.taskToolId = taskToolId
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            self?.doStart()
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func doStart() {
        guard FileManager.default.fileExists(atPath: filePath) else {
            // File doesn't exist yet, poll briefly
            retryStart(attempt: 0)
            return
        }
        beginWatching()
    }

    private func retryStart(attempt: Int) {
        guard attempt < 10 else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if FileManager.default.fileExists(atPath: self.filePath) {
                self.beginWatching()
            } else {
                self.retryStart(attempt: attempt + 1)
            }
        }
    }

    private func beginWatching() {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return }
        self.fileHandle = handle

        let fd = handle.fileDescriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            self?.parseFile()
        }

        // Initial parse
        parseFile()
        source?.resume()
    }

    private func parseFile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let text = String(data: data, encoding: .utf8) else { return }

        var tools: [SubagentToolCall] = []
        let completedIds = parseCompletedToolIds(text)

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "tool_use",
                       let toolId = block["id"] as? String,
                       let toolName = block["name"] as? String {
                        guard !seenToolIds.contains(toolId) else { continue }
                        seenToolIds.insert(toolId)

                        let input = block["input"].flatMap {
                            try? String(data: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8)
                        } ?? ""

                        tools.append(SubagentToolCall(
                            id: toolId,
                            name: toolName,
                            input: input,
                            isCompleted: completedIds.contains(toolId),
                            timestamp: parseTimestamp(json) ?? Date()
                        ))
                    }
                }
            }
        }

        if !tools.isEmpty {
            // Also include previously seen tools
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onUpdate(Array(self.buildAllTools(newTools: tools, completedIds: completedIds)))
            }
        }
    }

    private func buildAllTools(newTools: [SubagentToolCall], completedIds: Set<String>) -> [SubagentToolCall] {
        // New tools are fresh, mark completed ones
        var result = newTools.map { tool -> SubagentToolCall in
            var t = tool
            t.isCompleted = completedIds.contains(t.id)
            return t
        }
        return result
    }

    private func parseCompletedToolIds(_ text: String) -> Set<String> {
        var ids: Set<String> = []
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "tool_result",
                   let toolUseId = block["tool_use_id"] as? String {
                    ids.insert(toolUseId)
                }
            }
        }
        return ids
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseTimestamp(_ json: [String: Any]) -> Date? {
        guard let ts = json["timestamp"] as? String else { return nil }
        return isoFormatter.date(from: ts)
    }

    deinit {
        stop()
    }
}

final class AgentFileWatcherManager {
    private var watchers: [String: AgentFileWatcher] = [:]  // keyed by "sessionId:taskToolId"

    func startWatching(sessionId: String, taskToolId: String, agentFilePath: String, onUpdate: @escaping ([SubagentToolCall]) -> Void) {
        let key = "\(sessionId):\(taskToolId)"
        let watcher = AgentFileWatcher(filePath: agentFilePath, taskToolId: taskToolId, onUpdate: onUpdate)
        watchers[key] = watcher
        watcher.start()
    }

    func stopWatching(sessionId: String, taskToolId: String) {
        let key = "\(sessionId):\(taskToolId)"
        watchers.removeValue(forKey: key)?.stop()
    }

    func stopAll(sessionId: String) {
        let prefix = "\(sessionId):"
        let matching = watchers.keys.filter { $0.hasPrefix(prefix) }
        for key in matching {
            watchers.removeValue(forKey: key)?.stop()
        }
    }
}
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Services/AgentFileWatcher.swift
git commit -m "feat: add AgentFileWatcher for real-time subagent tool tracking"
```

---

### Task 4: Update ClaudeCodeService for Subagent Tracking

Handle Task/Agent tool events, start/stop agent file watchers, update subagent state.

**Files:**
- Modify: `NemoNotch/Services/ClaudeCodeService.swift`

**Step 1: Add AgentFileWatcherManager**

Add property to ClaudeCodeService:

```swift
    private let agentWatcherManager = AgentFileWatcherManager()
```

**Step 2: Add subagent handling in handleEvent**

In the `"PreToolUse"` case, after existing code, add subagent detection:

```swift
            // Subagent tracking
            if let toolName = event.toolName, ["Task", "Agent"].contains(toolName) {
                handleSubagentStart(sessionId: sessionId, event: event)
            }
```

In the `"PostToolUse"` case, add:

```swift
            // Subagent tracking
            if let toolName = event.toolName, ["Task", "Agent"].contains(toolName) {
                handleSubagentStop(sessionId: sessionId, event: event)
            }
```

In the `"SessionEnd"` case, add before `sessions.removeValue`:

```swift
            agentWatcherManager.stopAll(sessionId: sessionId)
```

**Step 3: Add subagent helper methods**

```swift
    // MARK: - Subagent Tracking

    private func handleSubagentStart(sessionId: String, event: HookEvent) {
        let taskToolId = event.toolUseId ?? UUID().uuidString
        var description: String?
        if let input = event.message,
           let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            description = json["description"] as? String ?? json["prompt"] as? String
            if let agentId = json["agentId"] as? String ?? json["subagent_id"] as? String {
                sessions[sessionId]?.subagentState.setAgentId(taskToolId: taskToolId, agentId: agentId)
                startAgentFileWatcher(sessionId: sessionId, taskToolId: taskToolId, agentId: agentId)
            }
        }
        sessions[sessionId]?.subagentState.startTask(taskToolId: taskToolId, description: description)
    }

    private func handleSubagentStop(sessionId: String, event: HookEvent) {
        let taskToolId = event.toolUseId ?? ""
        sessions[sessionId]?.subagentState.stopTask(taskToolId: taskToolId)
        agentWatcherManager.stopWatching(sessionId: sessionId, taskToolId: taskToolId)
    }

    private func startAgentFileWatcher(sessionId: String, taskToolId: String, agentId: String) {
        guard let cwd = sessions[sessionId]?.cwd else { return }
        let dir = ConversationParser.conversationPath(sessionId: sessionId, cwd: cwd)
            .map { ($0 as NSString).deletingLastPathComponent } ?? ""

        // Try nested path first, then flat path
        let nestedPath = "\(dir)/\(sessionId)/subagents/agent-\(agentId).jsonl"
        let flatPath = "\(dir)/agent-\(agentId).jsonl"

        let filePath = FileManager.default.fileExists(atPath: nestedPath) ? nestedPath : flatPath
        guard FileManager.default.fileExists(atPath: filePath) || FileManager.default.fileExists(atPath: flatPath) else {
            // Will be created later, use nested path
            startWatcherWithRetry(sessionId: sessionId, taskToolId: taskToolId, filePath: nestedPath, flatPath: flatPath)
            return
        }

        let existingPath = FileManager.default.fileExists(atPath: nestedPath) ? nestedPath : flatPath
        agentWatcherManager.startWatching(sessionId: sessionId, taskToolId: taskToolId, agentFilePath: existingPath) { [weak self] tools in
            self?.updateSubagentTools(sessionId: sessionId, taskToolId: taskToolId, tools: tools)
        }
    }

    private func startWatcherWithRetry(sessionId: String, taskToolId: String, filePath: String, flatPath: String) {
        // AgentFileWatcher handles retry internally, pick the more likely path
        agentWatcherManager.startWatching(sessionId: sessionId, taskToolId: taskToolId, agentFilePath: filePath) { [weak self] tools in
            self?.updateSubagentTools(sessionId: sessionId, taskToolId: taskToolId, tools: tools)
        }
    }

    private func updateSubagentTools(sessionId: String, taskToolId: String, tools: [SubagentToolCall]) {
        guard sessions[sessionId] != nil else { return }
        sessions[sessionId]?.subagentState.updateTools(taskToolId: taskToolId, tools: tools)
    }
```

**Step 4: Build to verify**

**Step 5: Commit**

```bash
git add NemoNotch/Services/ClaudeCodeService.swift
git commit -m "feat: add subagent tracking to ClaudeCodeService with AgentFileWatcher"
```

---

### Task 5: Update ChatMessageView for Subagent Display

Show nested tool calls under Task/Agent tool messages in the chat view.

**Files:**
- Modify: `NemoNotch/Tabs/ChatMessageView.swift`

**Step 1: Add subagent tools display to toolBubble**

Replace `toolBubble` with enhanced version that detects Task/Agent tools and shows subagent tools:

```swift
    private var toolBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: ToolStyle.icon(message.toolName))
                    .font(.system(size: 9))
                    .foregroundStyle(ToolStyle.color(message.toolName))
                if let tool = message.toolName {
                    Text(tool)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ToolStyle.color(tool))
                }
                if let input = message.toolInput {
                    Text(String(input.prefix(80)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ToolStyle.color(message.toolName).opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Subagent tools display (passed via environment or binding)
            if let subagentTools = subagentTools, !subagentTools.isEmpty {
                subagentToolsList(subagentTools)
            }
        }
    }

    private func subagentToolsList(_ tools: [SubagentToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let displayTools = Array(tools.suffix(3))
            ForEach(displayTools) { tool in
                HStack(spacing: 4) {
                    Circle()
                        .fill(tool.isCompleted ? Color.green : Color.orange)
                        .frame(width: 4, height: 4)
                        .modifier(PulseModifier(isActive: !tool.isCompleted))
                    Text(tool.name)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                    if !tool.displayInput.isEmpty {
                        Text(tool.displayInput)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                    }
                }
            }
            if tools.count > 3 {
                Text("+\(tools.count - 3) more")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.leading, 12)
    }
```

Add a property to ChatMessageView for subagent tools:

```swift
    var subagentTools: [SubagentToolCall]? = nil
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Tabs/ChatMessageView.swift
git commit -m "feat: add subagent tools display to ChatMessageView"
```

---

### Task 6: Update ClaudeTab Chat Detail for Subagent Context

Pass subagent tools to ChatMessageView when displaying Task/Agent tool messages.

**Files:**
- Modify: `NemoNotch/Tabs/ClaudeTab.swift`

**Step 1: Update chatDetail to pass subagent tools**

In the `chatDetail` function, find the `ChatMessageView(message: msg)` line and replace:

```swift
                                ChatMessageView(message: msg, subagentTools: subagentTools(for: msg, session: session))
                                    .id(msg.id)
```

**Step 2: Add helper to extract subagent tools for a message**

```swift
    private func subagentTools(for message: ChatMessage, session: ClaudeState) -> [SubagentToolCall]? {
        guard let toolName = message.toolName, ["Task", "Agent"].contains(toolName) else { return nil }
        // Find matching task context by checking tool use ID pattern in message id
        for (_, task) in session.subagentState.activeTasks {
            if message.id.contains(task.id) || (task.description ?? "").contains(message.content) {
                return task.tools
            }
        }
        return nil
    }
```

**Step 3: Add subagent summary to session row**

In `sessionRow`, after the status dot or approval buttons section, add subagent info:

```swift
                // Subagent indicator
                if session.subagentState.hasActiveTasks {
                    Text(session.subagentState.taskSummary() ?? "")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.1))
                        .clipShape(Capsule())
                }
```

Add this before the closing of the main `HStack` in `sessionRow`, just before `Spacer(minLength: 0)` or after the approval buttons section.

Actually, add it in the metadata row (the HStack with projectFolder, timeAgo, tokenDisplay):

After `if session.totalTokens > 0 { ... }`, add:

```swift
                        if session.subagentState.hasActiveTasks {
                            Text("· \(session.subagentState.taskSummary() ?? "")")
                                .foregroundStyle(.orange.opacity(0.7))
                        }
```

**Step 4: Build to verify**

**Step 5: Commit**

```bash
git add NemoNotch/Tabs/ClaudeTab.swift
git commit -m "feat: show subagent tools in chat detail and session rows"
```

---

### Task 7: Create TerminalDetector

Detect whether the terminal is the frontmost application to suppress unnecessary notifications.

**Files:**
- Create: `NemoNotch/Services/TerminalDetector.swift`

**Step 1: Create the detector**

```swift
// NemoNotch/Services/TerminalDetector.swift
import AppKit

enum TerminalDetector {
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "com.microsoft.VSCode",       // VS Code integrated terminal
        "com.jetbrains.intellij",      // JetBrains integrated terminal
    ]

    static var isTerminalFrontmost: Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(bundleID)
    }
}
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Services/TerminalDetector.swift
git commit -m "feat: add TerminalDetector for frontmost terminal detection"
```

---

### Task 8: Add Notification Sound to CompactBadge

Play a sound when permission requests arrive and terminal is not focused.

**Files:**
- Modify: `NemoNotch/Notch/CompactBadge.swift`

**Step 1: Add sound playing on permission state change**

In CompactBadge, add state tracking for previous approval state:

```swift
    @State private var wasWaitingForApproval = false
```

In the body, add `.onChange` for approval state:

```swift
        .onChange(of: claudeService.activeSession?.phase.isWaitingForApproval == true) { _, isWaiting in
            if isWaiting && !wasWaitingForApproval && !TerminalDetector.isTerminalFrontmost {
                NSSound(named: "Pop")?.play()
            }
            wasWaitingForApproval = isWaiting
        }
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Notch/CompactBadge.swift
git commit -m "feat: play notification sound on permission request when terminal not focused"
```

---

### Task 9: Final Build Verification

**Step 1: Clean build**

```bash
xcodebuild clean -scheme NemoNotch -configuration Debug 2>&1 | tail -2
xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED with 0 errors.

**Step 2: Verify new files**

```bash
ls NemoNotch/Models/SubagentState.swift NemoNotch/Services/AgentFileWatcher.swift NemoNotch/Services/TerminalDetector.swift
```

**Step 3: Final commit if any cleanup needed**

```bash
git add -A
git commit -m "chore: Phase 4 cleanup and final integration"
```

---

## Summary

| Task | Files | Description |
|------|-------|-------------|
| 1 | `Models/SubagentState.swift` (new) | SubagentToolCall, TaskContext, SubagentState models |
| 2 | `Models/ClaudeState.swift` (modify) | Add subagentState property |
| 3 | `Services/AgentFileWatcher.swift` (new) | Real-time agent JSONL file watcher |
| 4 | `Services/ClaudeCodeService.swift` (modify) | Handle Task/Agent events, wire watchers |
| 5 | `Tabs/ChatMessageView.swift` (modify) | Subagent tools display in chat bubbles |
| 6 | `Tabs/ClaudeTab.swift` (modify) | Pass subagent context, show in session rows |
| 7 | `Services/TerminalDetector.swift` (new) | Terminal focus detection |
| 8 | `Notch/CompactBadge.swift` (modify) | Sound on permission request |
| 9 | Various | Final build verification |
