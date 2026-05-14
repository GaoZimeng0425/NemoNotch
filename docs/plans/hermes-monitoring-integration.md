# Hermes Agent 监控集成方案

## 目标

为 NemoNotch 添加 Hermes Agent 的完整聊天内容监控能力，使用户能在 Notch 中实时看到 Hermes 的对话内容、工具调用、审批请求等——与现有的 Claude Code / Gemini CLI 监控体验一致。

## 背景知识

### Hermes Session 文件系统

Hermes 不管怎么用（CLI 模式、Gateway 模式），都会将完整的会话数据写入文件系统。

**路径规则：**
- Session JSON 文件：`~/.hermes/sessions/session_{session_id}.json`
- Request dump（调试用）：`~/.hermes/sessions/request_dump_{session_id}_{timestamp}.json`
- Profile 隔离：如果用户使用命名 profile，session 文件在 `~/.hermes/profiles/{name}/sessions/` 下

**Session ID 格式：** `YYYYMMDD_HHMMSS_{6位hex}`，例如 `20260416_211354_1aa7a4`

**写入时机：** `_save_session_log()` 在以下时机被调用（每次覆盖整个文件）：
1. 每次 tool call 循环迭代后（增量保存，即使中断也能看到进度）
2. 会话结束时
3. 错误退出时

这意味着：**session 文件在对话过程中是持续更新的**，每次覆盖写入，延迟约等于一个 tool call 迭代周期（通常 1-5 秒）。

### Session JSON 完整结构

```json
{
  "session_id": "20260416_211354_1aa7a4",
  "model": "glm-5.1",
  "base_url": "https://open.bigmodel.cn/api/coding/paas/v4",
  "platform": "cli",
  "session_start": "2026-04-16T21:15:05.618238",
  "last_updated": "2026-04-16T21:18:08.830007",
  "system_prompt": "...(完整 system prompt)...",
  "tools": [...(完整工具 schema 数组)...],
  "message_count": 26,
  "messages": [
    {
      "role": "user",
      "content": "如何查看之前的session"
    },
    {
      "role": "assistant",
      "content": "用 `session_search` 就行。直接给你看最近的：",
      "reasoning": "用户问如何查看之前的 session。我可以用 session_search 工具来展示最近的会话记录。",
      "finish_reason": "tool_calls",
      "tool_calls": [
        {
          "id": "call_67f1eb4768de4cc49b1deb26",
          "call_id": "call_67f1eb4768de4cc49b1deb26",
          "response_item_id": "fc_67f1eb4768de4cc49b1deb26",
          "type": "function",
          "function": {
            "name": "session_search",
            "arguments": "{}"
          }
        }
      ]
    },
    {
      "role": "tool",
      "content": "{\"success\": true, \"mode\": \"recent\", \"results\": [...]}",
      "tool_call_id": "call_67f1eb4768de4cc49b1deb26"
    },
    {
      "role": "assistant",
      "content": "这是最近的 3 个 session：...",
      "reasoning": null,
      "finish_reason": "stop"
    }
  ]
}
```

### Message 字段说明

| 字段 | 说明 | 出现条件 |
|------|------|---------|
| `role` | `user` / `assistant` / `tool` | 所有 message |
| `content` | 消息文本内容 | 所有 message（tool 的 content 是 JSON 字符串） |
| `reasoning` | 模型的思考过程（CoT） | 仅 assistant，支持 reasoning 的模型 |
| `finish_reason` | `stop`（文本回复结束）或 `tool_calls`（要调用工具） | 仅 assistant |
| `tool_calls` | 工具调用数组，每个包含 `id`, `type`, `function.name`, `function.arguments` | 仅 assistant 且 `finish_reason == "tool_calls"` |
| `tool_call_id` | 对应的 tool_call ID | 仅 tool message |

### 工具调用的三消息模式

一个完整的工具调用由 3 条 message 组成：

```
1. assistant (finish_reason=tool_calls, tool_calls=[...])  → AI 决定调工具
2. tool (tool_call_id=xxx, content=JSON result)             → 工具返回结果
3. assistant (finish_reason=stop 或继续 tool_calls)         → AI 继续或结束
```

### Hermes Shell Hooks 机制

Hermes 支持 shell hooks（类似 Claude Code 的 hooks），配置在 `~/.hermes/config.yaml`（或 profile 的 config.yaml）的 `hooks:` 块中。

**支持的 hook 事件：**
- `pre_llm_call` — 调用 LLM 之前
- `post_llm_call` — LLM 返回之后
- `pre_tool_call` — 调用工具之前
- `post_tool_call` — 工具返回之后
- `on_session_start` — 会话开始
- `on_session_end` — 会话结束

**Hook 脚本收到的 stdin（JSON）：**
```json
{
  "hook_event_name": "pre_tool_call",
  "tool_name": "terminal",
  "tool_input": {"command": "rm -rf /"},
  "session_id": "20260416_211354_1aa7a4",
  "cwd": "/Users/user/project",
  "extra": {}
}
```

**Hook 脚本的 stdout（JSON，可选）：**
```json
{"decision": "block", "reason": "Forbidden command"}
```

**NemoNotch 已有实现：** `HermesHookInstaller.swift` 已经实现了完整的 hook 安装逻辑：
- 在 `~/.nemonotch/hooks/hermes-hook-sender.sh` 创建 hook 脚本
- 脚本通过 Unix Socket (`/tmp/nemonotch-hook.sock`) 将事件推送给 NemoNotch
- Hook 脚本自动注入 `cli_source: "hermes"` 字段用于路由
- `HermesService.handleHookEvent()` 已实现事件处理（working/speaking/toolCalling 状态管理）
- 配置写入 `~/.hermes/config.yaml` 及所有 profile 的 `config.yaml`

### Webhook 机制（Gateway 模式）

Hermes Gateway 提供了 Webhook 平台适配器，可以接收外部 HTTP POST 事件并触发 agent 处理。

**配置：** `~/.hermes/config.yaml` 中：
```yaml
platforms:
  webhook:
    enabled: true
    extra:
      host: "0.0.0.0"
      port: 8644
      secret: "your-hmac-secret"
      routes:
        my-route:
          secret: "route-secret"
          events: ["push"]
          prompt: "处理 webhook 事件: {__raw__}"
          deliver: "log"
```

**动态订阅：** `hermes webhook subscribe <name>` 命令可创建运行时路由，保存在 `~/.hermes/webhook_subscriptions.json`。

**限制：** Webhook 需要 Gateway 运行 (`hermes gateway run`)，大多数 CLI 用户不会启动 Gateway。

---

## 现有架构

NemoNotch 的 AI 监控系统已经是一个成熟的分层架构：

```
AICLIMonitorService
├── HookServer (Unix Socket, /tmp/nemonotch-hook.sock)
├── ClaudeProvider
│   ├── ConversationParser (JSONL 增量解析)
│   ├── HookServer 事件处理
│   └── HookInstaller (Claude Code settings.json 注入)
├── GeminiProvider
│   ├── GeminiConversationParser (JSON 增量解析)
│   ├── HookServer 事件处理
│   └── HookInstaller (Gemini settings 注入)
└── HermesService (MultiAgentMonitor)
    ├── HermesHookInstaller (config.yaml hooks 注入)
    └── handleHookEvent() (状态管理: working/speaking/toolCalling)
```

**关键接口：**
- `ConversationParserProtocol` — 文件解析器协议，定义 `findSessionFile()` 和 `parseFull()`
- `ParsedConversation` — 通用解析结果（messages, inputTokens, outputTokens, lastModel）
- `HookServer` — Unix Socket 服务器，接收 hook 事件
- `HookEvent` — hook 事件数据结构
- `AISessionState` — 会话状态（source, messages, phase, tokens 等）
- `MultiAgentMonitor` — 多 Agent 监控协议（agents, activeAgent, isOnline 等）

**Hermes 目前只接了 Hook（实时状态），没有接聊天内容。** HermesService 只实现了 `MultiAgentMonitor` 协议（显示 agent 在工作/调工具），没有实现对话内容的读取和展示。

---

## 方案选择

### 方案 A：Session 文件监听 + Shell Hook（推荐）

**思路：** 复用现有架构模式——Hook 提供实时状态通知，Session 文件提供完整聊天内容。

**优点：**
- 不需要 Gateway，所有 Hermes 用户都能用
- 和 Claude/Gemini 的实现模式完全同构，维护成本低
- Session 文件是 Hermes 的核心机制，格式稳定

**缺点：**
- Session JSON 是每次覆盖整个文件（不是追加），需要全量解析或 diff 检测
- 延迟取决于 `_save_session_log()` 的调用频率（每个 tool call 迭代一次，通常 1-5 秒）

### 方案 B：Webhook 推送（补充方案）

**思路：** NemoNotch 起一个本地 HTTP server，注册为 Hermes webhook 接收实时事件。

**优点：**
- 实时推送，零延迟
- 结构化数据，不需要解析文件

**缺点：**
- 需要 Gateway 运行，大多数 CLI 用户不会启动
- NemoNotch 需要内嵌 HTTP server
- 需要额外的安装配置步骤

### 方案 C：双模自动切换（最终方案）

**思路：** NemoNotch 自动检测 Gateway 是否运行，动态选择最优数据源。用户无需关心底层细节。

```
Gateway 运行中 → 使用 Webhook（零延迟实时推送）
Gateway 未运行 → 使用 Session 文件监听（1-5 秒延迟）
```

**优点：**
- 所有用户都能用（不要求 Gateway）
- Gateway 用户自动获得最佳体验
- 用户零配置，NemoNotch 自己判断

### 最终建议：方案 C（双模自动切换）

理由：
1. 方案 A 覆盖 100% 用户但延迟较高，方案 B 延迟最低但需要 Gateway
2. 双模切换并不复杂——两个数据源的消费端都是同一个 `HermesService`，只是数据入口不同
3. 用户不需要理解 Gateway 是什么，NemoNotch 帮他们搞定一切

---

## 实现计划

### Step 1: 创建 HermesConversationParser

新建 `NemoNotch/Services/HermesConversationParser.swift`，实现 `ConversationParserProtocol`。

**核心逻辑：**

```swift
struct HermesConversationParser: ConversationParserProtocol {
    // Session 文件路径: ~/.hermes/sessions/session_{sessionId}.json
    // 或 profile 路径: ~/.hermes/profiles/{name}/sessions/session_{sessionId}.json
    
    static func findSessionFile(sessionId: String, cwd: String) -> String? {
        // 1. 检查 ~/.hermes/sessions/
        // 2. 扫描 ~/.hermes/profiles/*/sessions/
    }
    
    static func parseFull(filePath: String) -> ParsedConversation {
        // 解析 session JSON → ChatMessage 数组
        // 消息类型映射:
        //   role=user → .user
        //   role=assistant, finish_reason=stop → .assistant
        //   role=assistant, finish_reason=tool_calls → .assistant (带 toolCalls)
        //   role=tool → .tool
        // 
        // Token 信息: session JSON 不包含累计 token 数
        // 但可以从 system_prompt 和 messages 估算
    }
}
```

**消息解析规则：**

| Hermes message | ChatMessage 类型 | 提取内容 |
|---|---|---|
| `role: user` | `.user` | `content` |
| `role: assistant, finish_reason: stop` | `.assistant` | `content`, `reasoning` |
| `role: assistant, finish_reason: tool_calls` | `.assistantToolCall` | `content`, `tool_calls[].function.name`, `tool_calls[].function.arguments` |
| `role: tool` | `.toolResult` | `content` (JSON 字符串，可能需要格式化显示) |

**特殊处理：**
- `reasoning` 字段：如果有值，作为思考过程显示（类似 Claude 的 thinking）
- `tool_calls[].function.arguments`：是 JSON 字符串，需要解析为可读格式
- `tool` message 的 `content`：是 JSON 字符串（Hermes 工具返回值格式），需要提取关键字段

### Step 2: 扩展 HermesService，添加聊天内容监控

当前 `HermesService` 只实现了 `MultiAgentMonitor`（agent 状态），需要增加对话内容监控能力。

**两种做法（二选一）：**

**做法 A（轻量）：** 在 `HermesService` 中直接增加 session 文件扫描和解析逻辑。
- 优点：改动小，不和 AIChatTab 耦合
- 缺点：没有复用 `ConversationParserProtocol` 的全部能力

**做法 B（复用）：** 让 HermesService 也作为 AIProvider 类似的角色，通过 `AICLIMonitorService` 注册。
- 优点：完全复用现有的 AIChatTab UI
- 缺点：需要调整 `AISessionState.source` 枚举（加 `.hermes`），改动范围更大

**推荐做法 A**。原因：
1. Hermes 的聊天内容和 Claude/Gemini 的场景不同——Hermes 是多 agent 平台，可能有多个 session 同时运行
2. 现有的 `AgentMonitorTab` 已经是展示 Hermes/OpenClaw 的 UI，直接在那里扩展聊天内容更自然
3. 改动范围更小，风险更低

### Step 3: Session 发现和增量更新

**扫描策略：**

```
1. 启动时扫描 ~/.hermes/sessions/ 和 ~/.hermes/profiles/*/sessions/
2. 找到所有 session_*.json 文件，按 last_updated 排序
3. 记录每个 session 的 last_updated 时间戳
4. 定时轮询（2-3 秒）检查 last_updated 变化
5. 变化时重新解析整个 session JSON（因为 Hermes 每次覆盖写入）
```

**为什么不能增量解析：** Hermes 的 session JSON 是每次覆盖写入的（`atomic_json_write`），不是追加。所以每次变化都要全量解析。

**优化：** 检测到 `message_count` 增加时才重新解析内容，避免无意义的解析开销。

### Step 4: Profile 支持

Hermes 的多 profile 架构意味着 session 文件可能在多个目录：

```
~/.hermes/sessions/                          # default profile
~/.hermes/profiles/agent-trainer/sessions/    # named profile
~/.hermes/profiles/doctor/sessions/           # named profile
```

**扫描逻辑：**
1. 始终扫描 `~/.hermes/sessions/`（default profile）
2. 检查 `~/.hermes/profiles/` 下每个子目录的 `sessions/`
3. 每个文件的 session_id 已包含时间戳，不会跨 profile 冲突

### Step 5: Gateway 检测与管理

Hermes Gateway 是消息平台桥接服务。大多数 CLI 用户不会主动启动它，但 NemoNotch 可以帮用户管理。

#### Gateway 在 macOS 上的运行机制

Hermes 使用 macOS launchd 管理 Gateway 服务：

- **Plist 路径**：`~/Library/LaunchAgents/ai.hermes.gateway.plist`（默认 profile）
  - 命名 profile：`~/Library/LaunchAgents/ai.hermes.gateway-{profile}.plist`
- **标签**：`ai.hermes.gateway`（或 `ai.hermes.gateway-{profile}`）
- **配置**：`RunAtLoad: true`（登录自启）+ `KeepAlive.SuccessfulExit: false`（崩溃重启）
- **日志**：`~/.hermes/logs/gateway.log` + `gateway.error.log`
- **端口**：默认 `8644`（webhook 端口）
- **Webhook 路由**：`POST http://localhost:8644/webhooks/{route_name}`

#### Gateway 状态检测

```swift
// 方式 1：调 hermes CLI（推荐，跨平台兼容）
// hermes gateway status 输出中包含 service_running 字段
func checkGatewayStatus() -> Bool {
    let output = Process.run("hermes", "gateway", "status")
    // 解析输出，检查 "running" 或 "service_running: true"
}

// 方式 2：直接检查 launchd（macOS 专用，更快）
func checkGatewayStatus() -> Bool {
    // launchctl list ai.hermes.gateway 2>/dev/null
    // 如果有 PID 输出就是运行中
}

// 方式 3：检查端口（最直接）
func checkGatewayStatus() -> Bool {
    // 尝试连接 localhost:8644/health
    // 返回 {"status": "ok", "platform": "webhook"} 就是运行中
}
```

**推荐方式 3（端口探测）**。原因：
- 不依赖 hermes CLI 在 PATH 中
- 延迟最低（HTTP 请求 < 100ms）
- 能确认 Gateway 真的在响应请求（而不是"进程在但卡死了"）

#### 帮用户启动 Gateway

**不要自己拼 launchd plist。** Hermes 已经有完善的 launchd 管理（`hermes gateway install` / `start`），直接调：

```swift
func ensureGatewayRunning() async throws {
    // 1. 先检测
    if await probeGatewayHealth() { return }

    // 2. 尝试启动已安装的服务
    let startResult = Process.run("hermes", "gateway", "start")
    if startResult.isSuccess {
        // 等待健康检查通过
        try await waitForGatewayReady(timeout: 10)
        return
    }

    // 3. 服务未安装 → 安装 + 启动
    let installResult = Process.run("hermes", "gateway", "install")
    guard installResult.isSuccess else { throw GatewayError.installFailed }

    let startResult2 = Process.run("hermes", "gateway", "start")
    guard startResult2.isSuccess else { throw GatewayError.startFailed }

    try await waitForGatewayReady(timeout: 15)
}
```

**UI 交互流程：**

```
用户打开"启用 Hermes 聊天监控"开关
  → NemoNotch 检测 Gateway 状态
  → 已运行：直接启用
  → 未运行但已安装：自动启动，提示"正在启动 Gateway..."
  → 未安装：弹窗提示
      "实时聊天监控需要启动 Hermes Gateway 服务。
       Gateway 是 Hermes 的后台服务，安装后会开机自启。
       [一键安装并启动] [仅使用基础模式（延迟更高）]"
```

#### Webhook 数据源接入

Gateway 运行后，NemoNotch 需要注册一个 webhook 订阅来接收实时事件。

**注册 Webhook：**

```bash
# 创建 NemoNotch 专用 webhook
hermes webhook subscribe nemonotch \
    --secret "auto-generated-secret" \
    --events "message,user_message,assistant_message,tool_call" \
    --deliver log
```

但这种方式需要 hermes CLI，且 webhook 的事件格式是 agent 触发式的（外部 POST → agent 处理），不是我们需要的 agent 事件推送。

**实际可行的方式：Gateway 内置事件钩子**

Gateway 在处理每条消息时，会通过 hook 系统发出事件。NemoNotch 可以：

1. 在 Hermes 的 `config.yaml` 中配置 shell hook，让 Gateway 也向 NemoNotch 的 Unix Socket 推送事件（和 CLI 模式的 hook 一样）
2. 或者直接用 Session 文件监听作为 Gateway 模式的数据源（Gateway 也会写 session 文件）

**结论：Gateway 运行时，数据源仍然是 Session 文件监听。** Gateway 的优势不在于提供不同的数据格式，而在于：
- Gateway 模式下 session 文件更新更频繁（每条消息都写）
- Gateway 支持更多 hook 事件（跨平台消息通知）
- Gateway 保持常驻，session 文件不会因为 CLI 退出而停止写入

所以双模切换的实际逻辑是：

```
Gateway 运行 → session 文件更新更频繁 + 更稳定
Gateway 未运行 → 只在 CLI session 活跃时有文件更新
两种情况的解析逻辑完全一样，只是轮询频率可以不同
```

### Step 6: UI 展示

在现有的 `AgentMonitorTab` 中扩展：

1. **Agent 列表**：显示所有活跃的 Hermes session（来自 Hook 的实时状态）
2. **点击展开**：展示该 session 的最近对话内容
3. **实时更新**：Hook 事件触发状态刷新 + Session 文件解析刷新内容
4. **Gateway 状态指示**：在 Hermes 区域显示 Gateway 运行状态（绿点/灰点）

**展示内容：**
- 当前模型名称（`session.model`）
- 当前工作目录（Hook 的 `cwd`）
- 对话消息列表（解析后的 `messages`）
- 工具调用状态（正在调什么工具、返回了什么）
- Gateway 运行状态（运行中 / 未运行 / 未安装）

---

## 文件清单（预估）

| 文件 | 操作 | 说明 |
|------|------|------|
| `Services/HermesConversationParser.swift` | 新建 | Session JSON 解析器 |
| `Services/HermesService.swift` | 修改 | 增加 session 扫描、增量更新、消息解析、Gateway 管理 |
| `Services/HermesGatewayManager.swift` | 新建 | Gateway 状态检测、安装、启动、健康检查 |
| `Tabs/AgentMonitorTab.swift` | 修改 | 展示 Hermes session 的聊天内容、Gateway 状态 |

---

## Pitfalls

1. **Session JSON 覆盖写入**：不是追加，每次 `_save_session_log()` 都重写整个文件。不能用文件偏移增量读取。
2. **大文件**：`system_prompt` 和 `tools` 字段很大（system_prompt 可能 50KB+，tools 数组可能 100+ 个条目）。解析时应该跳过或只提取必要信息。
3. **JSON 嵌套**：`tool` message 的 `content` 是 JSON 字符串，需要二次解析才能提取关键字段。
4. **reasoning 字段**：只有部分模型（有 CoT 能力的）才会填充，需要 `nil` 安全处理。
5. **Profile 隔离**：必须扫描所有 profile 的 sessions 目录，不能只看 default。
6. **并发安全**：Hermes 可能在写入文件时 NemoNotch 正在读，需要处理读取失败/不完整 JSON 的情况。
7. **request_dump 文件**：这些是调试用的（API 请求/响应 dump），不需要解析。只关注 `session_*.json` 文件。
8. **message_count 守卫**：Hermes 有保护逻辑不会用更少的 message 覆盖更大的 session log，但读取端还是要处理可能的 message_count 回退。
9. **Hook 已实现**：`HermesHookInstaller` 和 `HermesService.handleHookEvent()` 已经完成了实时状态监控，不需要重写。只需要在现有基础上加聊天内容读取。
10. **Gateway install 可能需要首次配置**：`hermes gateway install` 之前可能需要 `hermes gateway setup` 配置平台。如果用户没有配置任何平台，install 可能会失败或产生空的 Gateway。NemoNotch 应该先检查 `~/.hermes/config.yaml` 中是否有 `platforms:` 配置，如果没有，可以帮用户写入最小配置（只要 webhook 平台就行）。
11. **Gateway 端口冲突**：默认端口 8644，如果被占用会启动失败。NemoNotch 应该处理这种情况，提示用户或尝试其他端口。
12. **launchd plist 更新**：Hermes 版本升级后 plist 可能过期（Python 路径变了等）。`hermes gateway status` 会检测并提示刷新，NemoNotch 可以在检测到不一致时自动调用 `hermes gateway install` 刷新。
13. **Gateway 数据源和 CLI 数据源格式完全一样**：不要为 Gateway 模式写单独的解析逻辑。Gateway 和 CLI 写的 session JSON 格式是相同的。
