# Gemini CLI 兼容设计

## 目标

在 NemoNotch 中添加 Gemini CLI 监控，复用现有 Claude Code 的 hook 管道和 UI 框架。采用统一服务架构，为未来兼容更多 AI CLI 工具（Cursor、Windsurf 等）做准备。

## 前提发现

- Gemini CLI（v0.38.2）使用与 Claude Code **完全相同的 hook 配置格式**（settings.json hooks 字段）
- Hook 事件名称一致：SessionStart, SessionEnd, PreToolUse, PostToolUse, Stop, Notification, UserPromptSubmit
- Gemini CLI **没有** PermissionRequest hook → 无审批功能
- 对话文件路径：`~/.gemini/tmp/<project>/chats/session-<date>-<id>.json`
- 项目映射：`~/.gemini/projects.json`（cwd → project name）
- 对话文件格式：单个 JSON（vs Claude 的 JSONL 逐行追加）
- 消息类型：`user` / `gemini`（vs Claude 的 user/assistant/tool/toolResult）
- 每条 gemini 消息包含 `tokens`、`model`、`toolCalls` 字段
- 子代理工具：`invoke_subagent`（类似 Claude 的 Task/Agent）

## 架构

### 统一服务层

```
┌─────────────────────────────────────────────────────┐
│              AICLIMonitorService                     │
│  (owns HookServer, routes events by cli_source)     │
│                                                      │
│  ┌──────────────────┐  ┌──────────────────────┐     │
│  │ ClaudeProvider   │  │ GeminiProvider       │     │
│  │ - JSONL parsing  │  │ - JSON parsing       │     │
│  │ - subagent track │  │ - subagent track     │     │
│  │ - permission UI  │  │  (invoke_subagent)   │     │
│  └──────────────────┘  └──────────────────────┘     │
│                                                      │
│  Both produce: AIActiveSession (shared state)        │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│           AITab (共用标签页，自动切换活跃 AI)            │
│  - Badge 显示 source 图标 (C/G)                      │
└─────────────────────────────────────────────────────┘
```

### 协议定义

```swift
enum AISource: String, Codable {
    case claude, gemini
}

protocol AIProvider: AnyObject, Observable {
    var source: AISource { get }
    var activeSession: AIActiveSession? { get }
    func handleEvent(_ event: HookEvent)
    func start()
    func stop()
}
```

### 共享会话状态

将 `ClaudeState` 重构为 `AIActiveSession`：

```swift
struct AIActiveSession {
    let source: AISource
    let sessionId: String
    var phase: SessionPhase
    var messages: [ChatMessage]
    var cwd: String?
    var model: String?
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var lastContextTokens: Int = 0
    var subagentState: SubagentState
    var firstUserMessage: String?
    var lastUserMessage: String?
    var lastEventTime: Date
}
```

## Hook 事件路由

### 修改 hook-sender.sh（v5）

通过父进程检测注入 `cli_source` 字段：

```bash
#!/bin/bash
# version: 5
SOCKET="/tmp/nemonotch.sock"
[ -S "$SOCKET" ] || exit 0
INPUT=$(cat 2>/dev/null || echo '{}')

# Detect source from parent process
PARENT=$(ps -o comm= -p $PPID 2>/dev/null || echo "")
case "$PARENT" in
    *claude*)  SOURCE="claude" ;;
    *gemini*)  SOURCE="gemini" ;;
    *)         SOURCE="unknown" ;;
esac

# Inject cli_source
INPUT=$(echo "$INPUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['cli_source'] = '$SOURCE'
print(json.dumps(d))
" 2>/dev/null || echo "$INPUT")

if echo "$INPUT" | grep -q '"PermissionRequest"'; then
    echo "$INPUT" | nc -U -w 120 "$SOCKET" 2>/dev/null
else
    echo "$INPUT" | nc -U -w 1 "$SOCKET" 2>/dev/null || true
fi
exit 0
```

### HookEvent 扩展

```swift
struct HookEvent: Codable {
    // ...existing fields...
    let cliSource: String?

    enum CodingKeys: String, CodingKey {
        // ...existing keys...
        case cliSource = "cli_source"
    }
}
```

### AICLIMonitorService 路由

```swift
func handleEvent(_ event: HookEvent) {
    guard let source = event.cliSource.flatMap(AISource.init) else { return }
    providers[source]?.handleEvent(event)
}
```

## 对话文件解析

### 差异对比

| 特性 | Claude Code | Gemini CLI |
|------|------------|------------|
| 文件格式 | JSONL（每行一个 JSON） | 单文件 JSON |
| 文件路径 | `~/.claude/projects/<encoded>/<session>.jsonl` | `~/.gemini/tmp/<project>/chats/session-<date>-<id>.json` |
| 增量解析 | 按字节 offset 追加读取 | 重新解析整个 JSON |
| 消息类型 | user/assistant/tool/toolResult/system | user/gemini |
| Token 信息 | summary 消息中 | 每条 gemini 消息的 `tokens` 字段 |
| 工具调用 | 独立消息 | 嵌套在 gemini 消息的 `toolCalls[]` |

### GeminiConversationParser

每次 hook 事件触发时读取整个 JSON 文件，转换为 `[ChatMessage]`：

```swift
enum GeminiConversationParser {
    struct GeminiSession: Codable {
        let sessionId: String
        let messages: [GeminiMessage]
    }

    struct GeminiMessage: Codable {
        let type: String          // "user" | "gemini"
        let content: AnyCodable   // String 或 [{text: "..."}]
        let toolCalls: [GeminiToolCall]?
        let tokens: GeminiTokens?
        let model: String?
    }

    static func parse(filePath: String) -> (messages: [ChatMessage], tokens: TokenCounts)?
}

// 转换映射:
// Gemini "user"   → ChatMessage.role = .user
// Gemini "gemini" → ChatMessage.role = .assistant
// Gemini toolCalls[].name + args    → ChatMessage.role = .tool
// Gemini toolCalls[].result         → ChatMessage.role = .toolResult
```

### 文件发现

通过 `~/.gemini/projects.json` 映射 cwd → project name，再查找对应 session 文件：

```swift
static func findSessionFile(sessionId: String, cwd: String) -> String? {
    // 1. 读取 ~/.gemini/projects.json 获取 project name
    // 2. 在 ~/.gemini/tmp/<project>/chats/ 下查找包含 sessionId 的文件
    //    session-2026-04-20T12-24-21ef64d2.json → sessionId 含 21ef64d2
}
```

### 子代理追踪

Gemini 的 `invoke_subagent` 工具调用在 PreToolUse 事件中检测。子代理结果嵌套在主会话文件的 `toolCalls[].result` 中，无需额外的文件监控。

## UI 层

### 共用标签页

`ClaudeTab` → `AITab`：

- 标题栏根据 `activeSession.source` 显示来源图标
- `ChatMessageView` 不变（底层用统一的 `ChatMessage` 模型）
- 权限审批 UI 仅 source == .claude 时显示
- Token 统计、模型名称等通用字段直接显示

### Badge 优先级

更新为：

```
notification > openclaw active > claude approval > claude/gemini working > media playing > calendar upcoming
```

Badge 图标：Claude 显示 `C`，Gemini 显示 `G`。

## Hook 安装

### 多目标支持

```swift
struct HookTarget {
    let source: AISource
    let settingsPath: String
    let events: [String]
}

static let targets: [HookTarget] = [
    .init(source: .claude,
          settingsPath: "~/.claude/settings.json",
          events: ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse",
                   "Stop", "Notification", "UserPromptSubmit", "PermissionRequest"]),
    .init(source: .gemini,
          settingsPath: "~/.gemini/settings.json",
          events: ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse",
                   "Stop", "Notification", "UserPromptSubmit"]),
]
```

## 文件结构变化

```
Services/
├── AICLIMonitorService.swift       # 新增：中心调度
├── AIProvider.swift                # 新增：协议定义
├── HookServer.swift                # 保留不变
├── HookInstaller.swift             # 重构：支持多目标
├── ClaudeProvider.swift            # 重构自 ClaudeCodeService
├── ClaudeConversationParser.swift  # 重构自 ConversationParser
├── GeminiProvider.swift            # 新增
├── GeminiConversationParser.swift  # 新增
├── InterruptWatcher.swift          # 保留（仅 Claude 使用）
└── ...

Models/
├── AIActiveSession.swift           # 新增（或重命名 ClaudeState）
├── ChatMessage.swift               # 保留（已通用）
├── SessionPhase.swift              # 保留（已通用）
├── HookEvent.swift                 # 扩展 cliSource 字段
└── ...
```

## 实现步骤

1. **模型层重构**：创建 AIProvider 协议、AISource 枚举、AIActiveSession
2. **HookEvent 扩展**：添加 cliSource 字段
3. **hook-sender.sh 升级 v5**：父进程检测 + cli_source 注入
4. **HookInstaller 重构**：多目标安装
5. **AICLIMonitorService**：HookServer 事件路由
6. **ClaudeProvider 重构**：从 ClaudeCodeService 提取，遵循 AIProvider
7. **GeminiProvider 实现**：事件处理 + GeminiConversationParser
8. **UI 层适配**：ClaudeTab → AITab，Badge 更新
9. **NemoNotchApp 集成**：替换 ClaudeCodeService 为 AICLIMonitorService

## 不在范围内

- Gemini 权限审批（不支持 PermissionRequest hook）
- Gemini 子代理独立文件监控（嵌套在主会话中）
- /clear /compact 检测（Gemini 无 InterruptWatcher 需求）
