---
summary: '增量 JSONL/JSON 会话解析：offset + pendingTail + DispatchSource 文件监听，含 InterruptWatcher 与 AgentFileWatcher'
read_when:
  - '实现对 Claude JSONL 或 Gemini JSON 对话文件的实时增量读取'
  - '调试"文件轮转后 watcher 失聋"或"截断后 readOffset 超出 EOF"'
  - '需要检测 /clear、/compact 或"interrupted by user"等会话状态变化'
sources: ['§12.3', '§12.4', '§12.5']
last_verified: { nemonotch: 'fe4e9e5' }
---

# 增量解析 — JSONL/JSON 会话文件实时读取

## TL;DR

三个协作组件：
1. **`DispatchSourceFileSystemObject`**（`.write/.extend`）— 文件有新数据时触发回调
2. **`readOffset + pendingTail`** — 只读新增字节，partial line 留存到下次拼接
3. **`ConversationParser.parseIncremental`** — Claude JSONL token 统计与消息解析；**`InterruptWatcher`** — 专门检测 interrupt/clear 信号；**`AgentFileWatcher`** — subagent tool_use/tool_result 实时追踪

---

## 可复用模式

### 1. DispatchSource 文件监听

```swift
// AgentFileWatcher.swift:55-72  beginWatching()
source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd,
    eventMask: [.write, .extend],
    queue: queue
)
source?.setEventHandler { [weak self] in self?.parseFile() }
parseFile()   // 立即解析已有内容（文件可能在 watcher 启动前已有数据）
source?.resume()
```

**文件不存在时重试**：`retryStart(attempt:)` 最多重试 10 次，每次间隔 0.5s（锚点 `AgentFileWatcher.swift:43-53`）。

### 2. readOffset + pendingTail 增量读取

```swift
// AgentFileWatcher.swift:74-114  parseFile()
try handle.seek(toOffset: readOffset)
guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }
readOffset += UInt64(chunk.count)

var buffer = pendingTail     // 上次未完整的行尾
buffer.append(chunk)
pendingTail.removeAll(keepingCapacity: true)

// 按 '\n' 分割，不完整的末尾行存回 pendingTail
var lineStart = buffer.startIndex
for i in buffer.indices {
    if buffer[i] == UInt8(ascii: "\n") {
        processLine(buffer.subdata(in: lineStart..<i))
        lineStart = buffer.index(after: i)
    }
}
if lineStart < buffer.endIndex {
    pendingTail = buffer.subdata(in: lineStart..<buffer.endIndex)
}
```

`keepingCapacity: true` 复用已分配内存，高频触发时减少 malloc。

### 3. ConversationParser.parseIncremental（Claude JSONL）

```swift
// ConversationParser.swift:44-113  parseIncremental(filePath:fromOffset:)
if fromOffset > 0 { try? fileHandle.seek(toOffset: fromOffset) }
guard let data = try? fileHandle.readToEnd() else { return result }
result.newOffset = fromOffset + UInt64(data.count)

for line in text.components(separatedBy: "\n") {
    guard !line.isEmpty else { continue }
    let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
    if json["type"] == "assistant", let usage = json["message"]["usage"] {
        result.inputTokens += usage["input_tokens"] ?? 0
        result.outputTokens += usage["output_tokens"] ?? 0
        result.cacheReadTokens += usage["cache_read_input_tokens"] ?? 0   // 可选
        result.cacheCreationTokens += usage["cache_creation_input_tokens"] ?? 0  // 可选
    }
    // 同时检测 interrupt / clear
}
```

`newOffset` 返回给调用方，下次以此为起点，避免重扫全文。

### 4. InterruptWatcher — 检测 interrupt / /clear

```swift
// InterruptWatcher.swift:19-31  start()
let fileSize = attributesOfItem[.size] as? UInt64 ?? 0
lastOffset = fileSize   // 从文件末尾开始，只看新增内容

source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd, eventMask: .write, queue: queue
)
source?.setEventHandler { [weak self] in self?.checkForChanges() }
source?.resume()
```

**从末尾起始**：`InterruptWatcher` 的目的是检测"从现在起"的中断信号，不需要回溯历史。

中断检测逻辑（`InterruptWatcher.swift:71-96`）：

```swift
private static let interruptPatterns = [
    "interrupted by user",
    "user doesn't want to proceed",
    "[request interrupted by user",
]

// isInterruptLine: 匹配 assistant message content 中的以上文本
// isClearLine: 匹配 user message content 包含 "/clear" 或 "/compact"
```

`InterruptWatcherManager`（锚点 `:99-123`）管理多 session 的 watcher 生命周期，`startWatching(sessionId:cwd:)` 通过 `ConversationParser.findSessionFile` 定位 JSONL 文件。

### 5. AgentFileWatcher — subagent tool_use/tool_result

```swift
// AgentFileWatcher.swift:118-153  processLine(_:)
// tool_use: 新增 SubagentToolCall，标记 isCompleted=false
if type == "tool_use", !seenToolIds.contains(toolId) {
    seenToolIds.insert(toolId)
    allTools.append(SubagentToolCall(...))
    changed = true
}
// tool_result: 匹配 tool_use_id，标记 isCompleted=true
if type == "tool_result", !completedIds.contains(toolUseId) {
    completedIds.insert(toolUseId)
    allTools[idx].isCompleted = true
    changed = true
}
```

状态变化后才调用 `DispatchQueue.main.async { onUpdate(allTools) }`，减少不必要的 UI 刷新。

`AgentFileWatcherManager`（锚点 `:171-193`）用 `"sessionId:taskToolId"` 作为 key 管理多 watcher，`stopAll(sessionId:)` 批量清理某 session 的所有 subagent watcher。

### 6. 文件路径解析（Claude session file）

```swift
// ConversationParser.swift:117-123  claudeProjectsDir(for:)
// cwd "/Users/foo/bar" → "~/.claude/projects/-Users-foo-bar/sessionId.jsonl"
let encoded = "-" + cwd.trimmingCharacters(in: .../"/")
    .replacingOccurrences(of: "/", with: "-")
return "~/.claude/projects/\(encoded)/\(sessionId).jsonl"
```

---

## 锚点（file:line）

| 位置 | 内容 |
|------|------|
| `NemoNotch/Services/AgentFileWatcher.swift:35-53` | `doStart` + `retryStart` — 文件不存在时重试 |
| `AgentFileWatcher.swift:55-72` | `beginWatching()` — DispatchSource 创建 |
| `AgentFileWatcher.swift:74-114` | `parseFile()` — readOffset + pendingTail 核心 |
| `AgentFileWatcher.swift:118-153` | `processLine(_:)` — tool_use/tool_result 解析 |
| `AgentFileWatcher.swift:171-193` | `AgentFileWatcherManager` — 多 watcher 管理 |
| `NemoNotch/Services/ConversationParser.swift:44-113` | `parseIncremental` — Claude JSONL 全量解析逻辑 |
| `ConversationParser.swift:117-123` | `claudeProjectsDir` — session 文件路径生成 |
| `ConversationParser.swift:215-235` | `isInterruptLine` / `isClearLine` — 状态检测 |
| `NemoNotch/Services/InterruptWatcher.swift:19-31` | `start()` — 末尾起始 + DispatchSource |
| `InterruptWatcher.swift:40-68` | `checkForChanges()` — 新增行扫描 |
| `InterruptWatcher.swift:71-96` | interrupt / clear 检测逻辑 |
| `InterruptWatcher.swift:99-123` | `InterruptWatcherManager` — 多 session 管理 |

---

## Pitfalls

1. **文件截断后 readOffset 超过 EOF**：`readToEnd()` 返回空，watcher 永久失聋。在 `parseFile()` 入口处先 `stat` 文件大小，若 `fileSize < readOffset`，则 `readOffset = 0; pendingTail.removeAll()`（cookbook §12.4 gotcha）。

2. **`O_EVTONLY` + 文件替换**：若用 `O_EVTONLY` 打开，文件被原子 rename（日志轮转）后旧 inode 消失，source 停止触发。需订阅 `.delete / .rename` 事件并重新打开（本工程用普通 `FileHandle` 规避）。

3. **`assistant` 事件才有 usage block**：`cache_read_input_tokens` / `cache_creation_input_tokens` 是可选字段；非缓存调用或旧版本会话中缺失该字段——不要强制解包，默认 0。

4. **partial line 跨 chunk 边界**：JSONL 一行可能被 `DispatchSource` 触发时切断，`pendingTail` 必须保留未遇到 `\n` 的末尾字节，下次 chunk 前缀拼入，再扫描 `\n`。

5. **InterruptWatcher 从文件末尾起始**：`lastOffset = fileSize`（start 时），避免把历史会话内容误判为新的中断信号。

6. **`@unchecked Sendable`**：`AgentFileWatcher` 和 `InterruptWatcher` 都标注 `@unchecked Sendable`，因为内部 state（seenToolIds / readOffset）只在专属 `queue` 上访问，Swift 6 编译器无法静态验证——必须确保 `beginWatching`、`parseFile`、`processLine` 都在同一 `queue` 上执行（见 §15）。

7. **GeminiConversationParser 文件格式不同**：Gemini 使用 `~/.gemini/tmp/*/chats/` 下的 JSON（非 JSONL），解析结构不同（`GeminiSession.messages[]`），不共用 `ConversationParser`，通过 `ConversationParserProtocol` 统一接口。

---

## 落地 Checklist

- [ ] `DispatchSource` 创建后立即调用一次 `parseFile()`（文件可能已有内容）
- [ ] `readOffset` 初始化为 0（`AgentFileWatcher`）或文件末尾（`InterruptWatcher`），按需选择
- [ ] `pendingTail` 跨 chunk 拼接，遇 `\n` 才处理一行
- [ ] 文件截断检测：`stat fileSize < readOffset` → reset
- [ ] 订阅 `.delete/.rename` 或用普通 `FileHandle`（非 `O_EVTONLY`）防止 inode 失效
- [ ] `cache_read_input_tokens` / `cache_creation_input_tokens` 可选字段默认 0
- [ ] 所有 watcher 内部 state 只在专属 queue 访问，`@unchecked Sendable` 要有 queue 保护

---

## 延伸阅读

- [hook-server.md](hook-server.md) — HookServer hook 事件接收（push 模式，与此处 pull/watch 互补）
- ../concurrency/ — Swift 6 `@unchecked Sendable`、`nonisolated(unsafe)`、actor 隔离边界
- ../architecture/ — AISessionStore 与 ConversationParser 的数据流关系
