# Structured Tool Results & Enhanced Chat — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bring NemoNotch's Claude chat view to feature parity with vibe-notch by adding structured tool result parsing, content block model, and specialized tool result views.

**Architecture:** Enhance the existing ConversationParser to extract structured tool results from JSONL `tool_result` lines. Add a `ToolResultData` enum with per-tool models. Upgrade `ChatMessage` to use content blocks (`MessageBlock`) instead of flat strings. Create specialized SwiftUI views for each tool type.

**Tech Stack:** Swift 5, SwiftUI, Foundation JSONSerialization. No new dependencies.

**Reference:** `/Users/gaozimeng/Learn/macOS/vibe-notch/ClaudeIsland/`

---

## Phase 5A: Tool Result Data Models

### Task 1: Create ToolResultData Model

**Files:**
- Create: `NemoNotch/Models/ToolResultData.swift`

**Step 1: Create the model file**

```swift
import Foundation

// MARK: - Patch Support

struct PatchHunk: Equatable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]
}

// MARK: - Individual Result Types

struct ReadResult: Equatable {
    let filePath: String
    let content: String
    let numLines: Int
    let startLine: Int
    let totalLines: Int
}

struct EditResult: Equatable {
    let filePath: String
    let oldString: String
    let newString: String
    let replaceAll: Bool
    let userModified: Bool
    let structuredPatch: [PatchHunk]?
}

struct WriteResult: Equatable {
    enum WriteType: Equatable { case create, overwrite }
    let type: WriteType
    let filePath: String
    let content: String
    let structuredPatch: [PatchHunk]?
}

struct BashResult: Equatable {
    let stdout: String
    let stderr: String
    let interrupted: Bool
    let isImage: Bool
    let returnCodeInterpretation: String?
    let backgroundTaskId: String?
}

struct GrepResult: Equatable {
    enum Mode: Equatable { case filesWithMatches, content, count }
    let mode: Mode
    let filenames: [String]
    let numFiles: Int
    let content: String?
    let numLines: Int?
    let appliedLimit: Int?
}

struct GlobResult: Equatable {
    let filenames: [String]
    let durationMs: Int
    let numFiles: Int
    let truncated: Bool
}

struct TodoItem: Equatable {
    let content: String
    let status: String
    let activeForm: String?
}

struct TodoWriteResult: Equatable {
    let oldTodos: [TodoItem]
    let newTodos: [TodoItem]
}

struct TaskResult: Equatable {
    let agentId: String
    let status: String
    let content: String
    let prompt: String?
    let totalDurationMs: Int?
    let totalTokens: Int?
    let totalToolUseCount: Int?
}

struct WebFetchResult: Equatable {
    let url: String
    let code: Int
    let codeText: String
    let bytes: Int
    let durationMs: Int
    let result: String
}

struct SearchResultItem: Equatable {
    let title: String
    let url: String
    let snippet: String
}

struct WebSearchResult: Equatable {
    let query: String
    let durationSeconds: Double
    let results: [SearchResultItem]
}

struct GenericResult: Equatable {
    let rawContent: String?
    let rawData: [String: Any]
}

// MARK: - ToolResultData

enum ToolResultData: Equatable {
    case read(ReadResult)
    case edit(EditResult)
    case write(WriteResult)
    case bash(BashResult)
    case grep(GrepResult)
    case glob(GlobResult)
    case todoWrite(TodoWriteResult)
    case task(TaskResult)
    case webFetch(WebFetchResult)
    case webSearch(WebSearchResult)
    case generic(GenericResult)
}
```

Note: `ToolResultData` conforms to `Equatable` — all nested types are `Equatable`. `GenericResult.rawData` uses `[String: Any]` which isn't directly `Equatable`; use a wrapper or skip equality on that field. For simplicity, make `ToolResultData` conform to `Equatable` by implementing `==` manually that compares only the tag, or use a simplified approach.

**Step 2: Build to verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add NemoNotch/Models/ToolResultData.swift
git commit -m "feat: add ToolResultData model for structured tool results"
```

---

### Task 2: Add Tool Result Parsing to ConversationParser

**Files:**
- Modify: `NemoNotch/Services/ConversationParser.swift`

**Step 1: Add structured result fields to ParseResult**

In `ParseResult`, add:
```swift
var toolResults: [String: ToolResultData] = [:]  // keyed by tool_use_id
```

**Step 2: Add tool result parsing methods**

Add static methods to parse each tool result type from the JSONL `tool_result` line. Key: the JSONL format has:
- `json["toolUseResult"]` — the structured result from Claude Code
- `json["toolName"]` — the tool name
- `json["message"]["content"]` — array with `tool_use_id`

```swift
private static func parseToolResultData(_ json: [String: Any]) -> (toolUseId: String, data: ToolResultData)? {
    guard let toolName = json["toolName"] as? String,
          let toolUseResult = json["toolUseResult"] as? [String: Any],
          let message = json["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]] else { return nil }

    // Extract tool_use_id from content blocks
    var toolUseId: String?
    for block in content {
        if block["type"] as? String == "tool_result",
           let id = block["tool_use_id"] as? String {
            toolUseId = id
            break
        }
    }
    guard let toolUseId else { return nil }

    let data = parseStructuredResult(toolName: toolName, toolUseResult: toolUseResult)
    return (toolUseId, data)
}

private static func parseStructuredResult(toolName: String, toolUseResult: [String: Any]) -> ToolResultData {
    switch toolName {
    case "Read": return parseReadResult(toolUseResult)
    case "Edit": return parseEditResult(toolUseResult)
    case "Write": return parseWriteResult(toolUseResult)
    case "Bash": return parseBashResult(toolUseResult)
    case "Grep": return parseGrepResult(toolUseResult)
    case "Glob": return parseGlobResult(toolUseResult)
    case "TodoWrite": return parseTodoWriteResult(toolUseResult)
    case "Task", "Agent": return parseTaskResult(toolUseResult)
    case "WebFetch": return parseWebFetchResult(toolUseResult)
    case "WebSearch": return parseWebSearchResult(toolUseResult)
    default:
        let content = toolUseResult["content"] as? String
            ?? toolUseResult["stdout"] as? String
            ?? toolUseResult["result"] as? String
        return .generic(GenericResult(rawContent: content, rawData: toolUseResult))
    }
}
```

Then implement each individual parser (see vibe-notch's `ConversationParser.swift` lines 709-960 for exact implementations).

**Step 3: Hook into the main parse loop**

In `parseIncremental`, after the existing interrupt/clear checks, add tool result extraction:

```swift
// After existing usage extraction block
if line.contains("\"tool_result\"") {
    if let (toolUseId, data) = parseToolResultData(json) {
        result.toolResults[toolUseId] = data
    }
}
```

**Step 4: Build and verify**

Run: `xcodebuild build -scheme NemoNotch -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add NemoNotch/Services/ConversationParser.swift
git commit -m "feat: add structured tool result parsing to ConversationParser"
```

---

### Task 3: Wire Tool Results into ClaudeCodeService

**Files:**
- Modify: `NemoNotch/Services/ClaudeCodeService.swift`
- Modify: `NemoNotch/Models/ClaudeState.swift`

**Step 1: Add toolResults to ClaudeState**

```swift
// In ClaudeState, add:
var toolResults: [String: ToolResultData] = [:]
```

**Step 2: Accumulate tool results in parseConversation**

In `ClaudeCodeService.parseConversation`, after existing token accumulation:

```swift
session.toolResults.merge(result.toolResults) { _, new in new }
```

**Step 3: Build and verify**

**Step 4: Commit**

```bash
git add NemoNotch/Services/ClaudeCodeService.swift NemoNotch/Models/ClaudeState.swift
git commit -m "feat: wire structured tool results into session state"
```

---

## Phase 5B: Enhanced Chat Message Model

### Task 4: Upgrade ChatMessage to Content Blocks

**Files:**
- Modify: `NemoNotch/Models/ChatMessage.swift`

**Step 1: Add MessageBlock enum and update ChatMessage**

The current model is flat (`content: String`). Upgrade to support content blocks while keeping backward compatibility:

```swift
enum MessageBlock: Identifiable {
    case text(String)
    case toolUse(ToolUseBlock)
    case thinking(String)
    case interrupted

    var id: String {
        switch self {
        case .text(let t): return "text-\(t.prefix(20).hashValue)"
        case .toolUse(let t): return "tool-\(t.id)"
        case .thinking(let t): return "think-\(t.prefix(20).hashValue)"
        case .interrupted: return "interrupted"
        }
    }
}

struct ToolUseBlock: Equatable {
    let id: String
    let name: String
    let input: [String: String]

    var preview: String {
        switch name {
        case "Read", "Write", "Edit":
            return input["file_path"].map { ($0 as NSString).lastPathComponent } ?? ""
        case "Bash":
            return input["command"] ?? ""
        case "Grep":
            return input["pattern"] ?? ""
        case "Glob":
            return input["pattern"] ?? ""
        default:
            return input.values.first { !$0.isEmpty } ?? ""
        }
    }
}
```

**Step 2: Keep backward compatibility**

Add computed property to ChatMessage for existing code that reads `content` as flat string:

```swift
// Keep existing `content: String` for backward compat
// Add blocks array for new code
var blocks: [MessageBlock] = []

// Computed: extract text from blocks
var textContent: String {
    blocks.compactMap { block in
        if case .text(let t) = block { return t }
        return nil
    }.joined(separator: "\n")
}
```

**Step 3: Build and verify**

**Step 4: Commit**

```bash
git add NemoNotch/Models/ChatMessage.swift
git commit -m "feat: add MessageBlock and ToolUseBlock to ChatMessage model"
```

---

### Task 5: Update ConversationParser for Block-Based Parsing

**Files:**
- Modify: `NemoNotch/Services/ConversationParser.swift`

**Step 1: Enhance parseAssistantMessage to extract blocks**

Instead of flattening to a single string, parse the content array into `MessageBlock` items:

```swift
private static func parseAssistantMessage(_ json: [String: Any], index: Int) -> ChatMessage? {
    guard let message = json["message"] as? [String: Any] else { return nil }

    var blocks: [MessageBlock] = []
    var flatText = ""

    if let contentArray = message["content"] as? [[String: Any]] {
        for block in contentArray {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String {
                    if text.hasPrefix("[Request interrupted by user") {
                        blocks.append(.interrupted)
                    } else {
                        blocks.append(.text(text))
                        flatText += text
                    }
                }
            case "tool_use":
                if let id = block["id"] as? String,
                   let name = block["name"] as? String {
                    var input: [String: String] = [:]
                    if let inputDict = block["input"] as? [String: Any] {
                        for (k, v) in inputDict {
                            if let s = v as? String { input[k] = s }
                            else if let i = v as? Int { input[k] = String(i) }
                            else if let b = v as? Bool { input[k] = b ? "true" : "false" }
                        }
                    }
                    blocks.append(.toolUse(ToolUseBlock(id: id, name: name, input: input)))
                    flatText += "Using \(name)"
                }
            case "thinking":
                if let text = block["thinking"] as? String {
                    blocks.append(.thinking(text))
                }
            default: break
            }
        }
    } else if let text = message["content"] as? String {
        if !text.isEmpty {
            blocks.append(.text(text))
            flatText = text
        }
    }

    guard !blocks.isEmpty else { return nil }
    return ChatMessage(
        id: "assistant-\(index)",
        role: .assistant,
        content: flatText,
        timestamp: parseTimestamp(json) ?? Date(),
        blocks: blocks
    )
}
```

**Step 2: Build and verify**

**Step 3: Commit**

```bash
git add NemoNotch/Services/ConversationParser.swift
git commit -m "feat: parse assistant messages into content blocks"
```

---

## Phase 5C: Tool Result View Components

### Task 6: Create Tool Result Views

**Files:**
- Create: `NemoNotch/Tabs/ToolResultViews.swift`

**Step 1: Create the main dispatcher and shared helpers**

```swift
import SwiftUI

struct ToolResultContent: View {
    let toolName: String
    let result: ToolResultData?
    let rawText: String?

    var body: some View {
        if let result {
            switch result {
            case .read(let r): ReadResultContent(result: r)
            case .edit(let r): EditResultContent(result: r)
            case .write(let r): WriteResultContent(result: r)
            case .bash(let r): BashResultContent(result: r)
            case .grep(let r): GrepResultContent(result: r)
            case .glob(let r): GlobResultContent(result: r)
            case .todoWrite(let r): TodoWriteResultContent(result: r)
            case .task(let r): TaskResultContent(result: r)
            case .webFetch(let r): WebFetchResultContent(result: r)
            case .webSearch(let r): WebSearchResultContent(result: r)
            case .generic(let r): GenericTextContent(text: r.rawContent ?? "")
            }
        } else if let rawText, !rawText.isEmpty {
            GenericTextContent(text: String(rawText.prefix(300)))
        }
    }
}

// Shared helper: code block with line numbers
struct CodeBlockView: View {
    let content: String
    let startLine: Int
    let maxLines: Int

    var body: some View {
        let lines = content.components(separatedBy: "\n")
        let displayed = Array(lines.prefix(maxLines))

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayed.enumerated()), id: \.offset) { idx, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(startLine + idx)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.2))
                        .frame(width: 24, alignment: .trailing)
                    Text(line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(6)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// Shared helper: file list
struct FileListView: View {
    let files: [String]
    let maxShow: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(files.prefix(maxShow).enumerated()), id: \.offset) { _, file in
                Text((file as NSString).lastPathComponent)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            if files.count > maxShow {
                Text("+\(files.count - maxShow) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

// Generic fallback
struct GenericTextContent: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(5)
    }
}
```

**Step 2: Implement individual tool result views**

Create views for each tool type. Prioritize by frequency of use:

**Read** — show filename + code with line numbers:
```swift
struct ReadResultContent: View {
    let result: ReadResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(.blue.opacity(0.7))
                Text((result.filePath as NSString).lastPathComponent)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.blue.opacity(0.7))
                Text("\(result.numLines) lines")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.3))
            }
            CodeBlockView(content: result.content, startLine: result.startLine, maxLines: 12)
        }
    }
}
```

**Edit** — show old → new diff:
```swift
struct EditResultContent: View {
    let result: EditResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 9))
                    .foregroundStyle(.green.opacity(0.7))
                Text((result.filePath as NSString).lastPathComponent)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.7))
                if result.replaceAll {
                    Text("replaceAll")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange.opacity(0.6))
                }
            }
            // Show old string (red) → new string (green)
            if !result.oldString.isEmpty {
                Text(result.oldString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineLimit(3)
                    .padding(4)
                    .background(.red.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if !result.newString.isEmpty {
                Text(result.newString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.5))
                    .lineLimit(3)
                    .padding(4)
                    .background(.green.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}
```

**Bash** — show stdout/stderr:
```swift
struct BashResultContent: View {
    let result: BashResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !result.stdout.isEmpty {
                Text(result.stdout)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(5)
                    .padding(4)
                    .background(.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if !result.stderr.isEmpty {
                Text(result.stderr)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineLimit(3)
                    .padding(4)
                    .background(.red.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if result.interrupted {
                Text("interrupted")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow.opacity(0.6))
            }
        }
    }
}
```

**Grep** — show file list or matching content:
```swift
struct GrepResultContent: View {
    let result: GrepResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(result.numFiles) files")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
            if !result.filenames.isEmpty {
                FileListView(files: result.filenames, maxShow: 5)
            }
        }
    }
}
```

**Glob, Write, TodoWrite, Task, WebFetch, WebSearch** — simpler views, follow same pattern.

**Step 3: Build and verify**

**Step 4: Commit**

```bash
git add NemoNotch/Tabs/ToolResultViews.swift
git commit -m "feat: add structured tool result view components"
```

---

### Task 7: Integrate Tool Results into ChatMessageView

**Files:**
- Modify: `NemoNotch/Tabs/ChatMessageView.swift`

**Step 1: Update tool message rendering to use structured results**

In the existing tool role handling, look up the structured result from `session.toolResults`:

```swift
// In ChatMessageView, add a toolResults parameter
struct ChatMessageView: View {
    let message: ChatMessage
    var subagentTools: [SubagentToolCall]? = nil
    var toolResult: ToolResultData? = nil  // NEW

    // In the tool role case:
    // Replace plain text with:
    if let toolResult {
        ToolResultContent(toolName: message.toolName ?? "", result: toolResult, rawText: message.content)
    } else {
        // existing fallback
    }
```

**Step 2: Update ClaudeTab to pass tool results**

In `ClaudeTab.chatDetail`, pass `toolResult` when creating `ChatMessageView`:

```swift
ChatMessageView(
    message: msg,
    subagentTools: subagentTools(for: msg, session: session),
    toolResult: toolResult(for: msg, session: session)
)
```

Add helper:
```swift
private func toolResult(for message: ChatMessage, session: ClaudeState) -> ToolResultData? {
    // For tool result messages, look up by tool_use_id stored in toolName field
    if message.role == .toolResult, let toolUseId = message.toolName {
        return session.toolResults[toolUseId]
    }
    return nil
}
```

**Step 3: Build and verify**

**Step 4: Commit**

```bash
git add NemoNotch/Tabs/ChatMessageView.swift NemoNotch/Tabs/ClaudeTab.swift
git commit -m "feat: integrate structured tool results into chat view"
```

---

## Phase 5D: ConversationInfo & Summary

### Task 8: Extract ConversationInfo from JSONL

**Files:**
- Modify: `NemoNotch/Services/ConversationParser.swift`
- Modify: `NemoNotch/Models/ClaudeState.swift`

**Step 1: Add ConversationInfo struct**

In `ClaudeState.swift`:
```swift
struct ConversationInfo {
    var summary: String?
    var firstUserMessage: String?
    var lastUserMessageDate: Date?
}
```

**Step 2: Extract summary and firstUserMessage in parser**

Add fields to `ParseResult`:
```swift
var summary: String?
var firstUserMessage: String?
```

In the parse loop, look for `type: "summary"` lines:
```swift
if json["type"] as? String == "summary", let text = json["summary"] as? String {
    result.summary = text
}
```

And extract first user message from non-meta, non-command user messages.

**Step 3: Use summary as displayTitle fallback**

In `ClaudeState.displayTitle`, prefer `conversationInfo.summary` over `firstUserMessage`.

**Step 4: Build and verify**

**Step 5: Commit**

```bash
git add NemoNotch/Services/ConversationParser.swift NemoNotch/Models/ClaudeState.swift
git commit -m "feat: extract ConversationInfo with summary from JSONL"
```

---

## Phase 5E: Thinking Block Support

### Task 9: Display Thinking Blocks

**Files:**
- Modify: `NemoNotch/Tabs/ChatMessageView.swift`

**Step 1: Add thinking block rendering**

When `MessageBlock.thinking` is present in the message blocks, show it as a collapsible section:

```swift
// In ChatMessageView, when iterating blocks:
case .thinking(let text):
    DisclosureGroup {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.3))
            .lineLimit(10)
    } label: {
        HStack(spacing: 4) {
            Image(systemName: "brain")
                .font(.system(size: 8))
            Text("thinking")
                .font(.system(size: 9))
        }
        .foregroundStyle(.purple.opacity(0.5))
    }
```

**Step 2: Build and verify**

**Step 3: Commit**

```bash
git add NemoNotch/Tabs/ChatMessageView.swift
git commit -m "feat: display thinking blocks in chat view"
```

---

## Summary

| Phase | Tasks | Description |
|-------|-------|-------------|
| 5A | 1-3 | ToolResultData models, parser, service wiring |
| 5B | 4-5 | MessageBlock model, block-based parser |
| 5C | 6-7 | Tool result view components, ChatMessageView integration |
| 5D | 8 | ConversationInfo extraction with summary |
| 5E | 9 | Thinking block display |

**Dependencies:** 5A and 5B are independent and can be done in parallel. 5C depends on both 5A and 5B. 5D and 5E are independent of 5C.

**Estimated effort:** ~9 tasks, each 15-30 minutes.
