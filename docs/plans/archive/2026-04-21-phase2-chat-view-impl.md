# Phase 2: Chat History View Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a chat history view to the Claude tab that shows the full conversation for a selected session, with markdown rendering and auto-scroll.

**Architecture:** ClaudeTab gets navigation state (list vs detail). Clicking a session transitions to a chat detail view. ChatMessage model already exists from Phase 1. We add a lightweight markdown renderer and message bubble views. ConversationParser already populates `session.messages`.

**Tech Stack:** Swift 5, SwiftUI (ScrollViewReader, LazyVStack)

**Reference:** vibe-notch at `/Users/gaozimeng/Learn/macOS/vibe-notch/`

---

### Task 1: Create MarkdownRenderer

Lightweight markdown-to-SwiftUI renderer. Uses regex parsing and Text concatenation (not the full swift-markdown library). Supports: bold, italic, inline code, code blocks, headers, bullet lists.

**Files:**
- Create: `NemoNotch/Helpers/MarkdownRenderer.swift`

**Step 1: Create the renderer**

```swift
// NemoNotch/Helpers/MarkdownRenderer.swift
import SwiftUI

enum MarkdownRenderer {

    /// Render markdown string to SwiftUI Text view
    static func render(_ markdown: String) -> Text {
        var result = Text("")
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockContent = ""

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End code block
                    result = result + Text(codeBlockContent.trimmingCharacters(in: .newlines))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    codeBlockContent = ""
                    inCodeBlock = false
                } else {
                    // Start code block
                    if !codeBlockContent.isEmpty { result = result + Text("\n") }
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent += (codeBlockContent.isEmpty ? "" : "\n") + line
                continue
            }

            // Skip empty lines
            if line.isEmpty { continue }

            // Headers
            if line.hasPrefix("### ") {
                result = result + renderInline(String(line.dropFirst(4)))
                    .font(.system(size: 11, weight: .semibold))
                result = result + Text("\n")
                continue
            }
            if line.hasPrefix("## ") {
                result = result + renderInline(String(line.dropFirst(3)))
                    .font(.system(size: 12, weight: .bold))
                result = result + Text("\n")
                continue
            }
            if line.hasPrefix("# ") {
                result = result + renderInline(String(line.dropFirst(2)))
                    .font(.system(size: 13, weight: .bold))
                result = result + Text("\n")
                continue
            }

            // Bullet list
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result = result + Text("  • ") + renderInline(String(line.dropFirst(2)))
                result = result + Text("\n")
                continue
            }

            // Numbered list
            if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let prefix = line[match]
                let content = String(line[match.upperBound...])
                result = result + Text("  \(prefix)") + renderInline(content)
                result = result + Text("\n")
                continue
            }

            // Regular line
            result = result + renderInline(line)
            result = result + Text("\n")
        }

        return result
    }

    /// Render inline markdown (bold, italic, code) to Text
    static func renderInline(_ text: String) -> Text {
        var result = Text("")
        // Pattern: **bold**, *italic*, `code`
        let pattern = #"(\\*\\*[^*]+\\*\\*|\\*[^*]+\\*|`[^`]+`)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(text)
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var lastEnd = text.startIndex

        for match in matches {
            let range = Range(match.range, in: text)!

            // Add text before this match
            if lastEnd < range.lowerBound {
                let before = String(text[lastEnd..<range.lowerBound])
                result = result + Text(before)
            }

            let matched = String(text[range])

            if matched.hasPrefix("**") && matched.hasSuffix("**") {
                let content = String(matched.dropFirst(2).dropLast(2))
                result = result + Text(content).bold()
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") {
                let content = String(matched.dropFirst(1).dropLast(1))
                result = result + Text(content).italic()
            } else if matched.hasPrefix("`") && matched.hasSuffix("`") {
                let content = String(matched.dropFirst(1).dropLast(1))
                result = result + Text(content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.8))
            }

            lastEnd = range.upperBound
        }

        // Remaining text
        if lastEnd < text.endIndex {
            result = result + Text(String(text[lastEnd...]))
        }

        return result
    }
}
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Helpers/MarkdownRenderer.swift
git commit -m "feat: add lightweight MarkdownRenderer for chat messages"
```

---

### Task 2: Create ChatMessageView

Renders a single chat message with role-based styling.

**Files:**
- Create: `NemoNotch/Tabs/ChatMessageView.swift`

**Step 1: Create the view**

```swift
// NemoNotch/Tabs/ChatMessageView.swift
import SwiftUI

struct ChatMessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .tool:
            toolBubble
        case .toolResult:
            toolResultBubble
        case .system:
            systemBubble
        }
    }

    // MARK: - User Message

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.content)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Assistant Message

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(.white.opacity(0.3))
                .frame(width: 5, height: 5)
                .padding(.top, 4)
            MarkdownRenderer.render(message.content)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 40)
        }
    }

    // MARK: - Tool Call

    private var toolBubble: some View {
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
    }

    // MARK: - Tool Result

    private var toolResultBubble: some View {
        Text(String(message.content.prefix(200)))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(3)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }

    // MARK: - System Message

    private var systemBubble: some View {
        Text(message.content)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.3))
            .italic()
    }
}
```

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Tabs/ChatMessageView.swift
git commit -m "feat: add ChatMessageView with role-based message bubbles"
```

---

### Task 3: Add Chat Detail Navigation to ClaudeTab

Add navigation state so clicking a session opens a chat detail view. Add a back button to return to the session list.

**Files:**
- Modify: `NemoNotch/Tabs/ClaudeTab.swift`

**Step 1: Add navigation state**

At the top of `ClaudeTab`, add a state variable:

```swift
    @State private var selectedSessionId: String?
```

**Step 2: Update body to handle navigation**

Replace the entire `body` computed property with:

```swift
    var body: some View {
        if !claudeService.isHookInstalled {
            installPrompt
        } else if claudeService.sessions.isEmpty {
            idleState
        } else if let sessionId = selectedSessionId, let session = claudeService.sessions[sessionId] {
            chatDetail(session: session)
        } else {
            sessionList
        }
    }
```

**Step 3: Add chat detail view**

Add this method inside `ClaudeTab`:

```swift
    private func chatDetail(session: ClaudeState) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button {
                    selectedSessionId = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.projectFolder ?? "")
                            .foregroundStyle(.white.opacity(0.3))
                        if session.totalTokens > 0 {
                            Text("· \(session.tokenDisplay)")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .font(.system(size: 9))
                }

                Spacer(minLength: 0)

                Circle()
                    .fill(dotColor(session.status))
                    .frame(width: 6, height: 6)
                    .modifier(PulseModifier(isActive: session.status == .working))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider().background(.white.opacity(0.08))

            // Approval bar (if pending)
            if let ctx = approvalContext(for: session) {
                quickApprovalBar(session: session, ctx: ctx)
            }

            // Chat messages
            if session.messages.isEmpty {
                Spacer()
                Text("暂无消息")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(session.messages) { msg in
                                ChatMessageView(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: session.messages.count) { _, _ in
                        withAnimation {
                            proxy.scrollTo(session.messages.last?.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
```

**Step 4: Add quick approval bar**

Add this method inside `ClaudeTab`:

```swift
    private func quickApprovalBar(session: ClaudeState, ctx: PermissionContext) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("等待审批: \(ctx.toolName)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                if !ctx.displayInput.isEmpty {
                    Text(ctx.displayInput)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("拒绝") { claudeService.respondToPermission(sessionId: session.id, approved: false) }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .buttonStyle(.plain)
            Button("允许") { claudeService.respondToPermission(sessionId: session.id, approved: true) }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.9))
                .clipShape(Capsule())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
    }
```

**Step 5: Make session rows tappable**

In the `sessionRow` function, wrap the entire content in a Button that sets `selectedSessionId`:

Find the outermost `HStack` in `sessionRow` and wrap it with a Button. The existing row should become the label of a Button:

Replace the return type of `sessionRow` and wrap the HStack content. The simplest approach: change the outer `HStack { ... }` to be wrapped in:

```swift
        Button {
            selectedSessionId = session.id
        } label: {
            HStack(spacing: 8) {
                // ... existing content unchanged ...
            }
        }
        .buttonStyle(.plain)
```

Find the line `private func sessionRow(_ session: ClaudeState) -> some View {` and the HStack after it. Add the Button wrapper around the HStack, and add `.buttonStyle(.plain)` after the existing `.background(...)` modifier.

**Step 6: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add NemoNotch/Tabs/ClaudeTab.swift
git commit -m "feat: add chat detail navigation with message history and approval bar"
```

---

### Task 4: Final Build Verification

**Step 1: Clean build**

```bash
xcodebuild clean -scheme NemoNotch -configuration Debug 2>&1 | tail -2
xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED with 0 errors.

**Step 2: Verify new files exist**

```bash
ls NemoNotch/Helpers/MarkdownRenderer.swift NemoNotch/Tabs/ChatMessageView.swift
```

**Step 3: Final commit if any cleanup needed**

```bash
git add -A
git commit -m "chore: Phase 2 cleanup and final integration"
```

---

## Summary

| Task | Files | Description |
|------|-------|-------------|
| 1 | `Helpers/MarkdownRenderer.swift` (new) | Lightweight markdown renderer using regex + Text concatenation |
| 2 | `Tabs/ChatMessageView.swift` (new) | Role-based message bubbles (user, assistant, tool, result) |
| 3 | `Tabs/ClaudeTab.swift` (modify) | Navigation state, chat detail view, quick approval bar, tappable rows |
| 4 | Various | Final build verification |
