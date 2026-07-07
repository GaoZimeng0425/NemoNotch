# SwarmAgents → NemoNotch notch 提醒集成 — 设计

日期：2026-07-06
状态：已确认，待实现

## 背景

SwarmAgents（`/Users/gaozimeng/Learn/macOS/SwarmAgents`，Electron 桌面应用）已实现一套
Claude-Code-style 的 hook dispatch（`apps/desktop/src/service/hooks/dispatcher.ts`，提交
`ca30e79`）：当内部 `run.*` 事件触发时，映射到 Claude 事件名并 spawn `~/.swarm-agents/hooks.json`
里配置的命令，payload 以单行 JSON 从 stdin 传入（纯通知语义，退出码/输出不影响 run）。

目标：让 SwarmAgents 运行时像 Claude Code 一样在 NemoNotch 的 notch 上弹提醒（badge / activity
glow / completion flash / toast / AI tab 状态卡）。

## 关键发现（为什么不是"零改动"）

zcode 能近乎零改动接入，是因为它本身就吐 Claude 形状的 hook（`hook_event_name` 字段 +
`$ZCODE_SESSION_ID` 环境变量），现成的 `hook-sender.sh` 直接能认。

SwarmAgents 的 dispatcher 吐的是另一套形状（`dispatcher.ts:111`）：

```js
stdinPayload = { sessionId, runId, parentRunId, seq, ts, kind, event: claudeName, hookEventName: runKind }
```

而 NemoNotch 的 `HookEvent`（`Models/HookEvent.swift`）解码要求 snake_case，且 `hook_event_name`
必填（缺失直接 throw）。三处错位：

| NemoNotch 要 | SwarmAgents 给 | 问题 |
|---|---|---|
| `hook_event_name` = Claude 名 | `event` = Claude 名；`hookEventName` = `run.*` kind | 字段名 + 值都错位 |
| `session_id` | `sessionId` | 大小写 |
| `cli_source` | 无 | hook-sender.sh 靠环境变量/父进程识别源，SwarmAgents 是 Electron 派生进程识别不出来 → `unknown` → fallback 成 `.claude` 幽灵会话 |

因此这是**跨两个仓库**的改动。

## 决策（已与用户确认）

1. **翻译放在 SwarmAgents 源头**：dispatcher 直接吐 Claude 兼容的 snake_case payload 并自打
   `cli_source: 'swarmagents'`。好处：payload 从源头就标准，任何 hook 消费者都能用；代价是
   SwarmAgents 需重新构建。
2. **source 标识符 = `swarmagents`**（cli_source 字符串 / `AISource` case / 各处图标 key）。
3. **权限请求显示「待批准」badge**：注册 `PermissionRequest`/`Notification` → `phase =
   waitingForApproval`，触发最高优先级橙色待批准 badge/glow。`respondToPermission` 为 no-op，点击
   只打开 AI tab —— 真正批准仍在 SwarmAgents 自己的 UI。
4. **hooks.json 由 NemoNotch 一键安装**（同 zcode 写入 `~/.swarm-agents/hooks.json`）。
5. **Logo 先用 SF Symbol 占位**，有 brand mark 再换。

## 整体链路（与 zcode 同一条管道）

```
SwarmAgents dispatcher.ts (run.* → Claude 名 + 标准 snake_case payload + cli_source)
  → ~/.swarm-agents/hooks.json 配置的 command
  → ~/.NemoNotch/hooks/hook-sender.sh   (健康检查 + 转发，保留已有 cli_source)
  → HookServer (127.0.0.1 loopback)
  → routeEvent("swarmagents") → SwarmAgentsProvider
  → AISessionStore → badge / glow / completion flash / toast / AI tab
```

## SwarmAgents 侧改动（`apps/desktop`，需重新构建）

`dispatcher.ts` 的 `stdinPayload` 改为 Claude 兼容 + 自打标签：

```js
const stdinPayload = {
  ...ctx,
  session_id: ctx.sessionId,        // snake_case
  hook_event_name: claudeName,      // Claude 名塞进 hook_event_name
  cli_source: 'swarmagents',        // 自我标识
  cwd: ctx.cwd, model: ctx.model,   // 若 payload 里有（见下方开放项）
  event: claudeName, hookEventName, // 保留原字段，向后兼容其它消费者
}
```

**开放项**：实现时确认 dispatcher 收到的 `run.*` payload 里是否带 `cwd`/`model`（需看
`session-service.ts` 发出的事件结构）。没有就不填，session 用 sessionId 兜底显示。

## NemoNotch 侧改动

### 新增文件（2）

**`Services/SwarmAgentsProvider.swift`** —— 照抄 `ZcodeProvider` 结构（`AIProvider` 实现、
`isHookInstalled`、stale-session 超时清理三段阈值、`respondToPermission` no-op）。

事件映射（`handleEvent`）：

| hook_event_name | phase | 说明 |
|---|---|---|
| `UserPromptSubmit` | `.processing` | `mutateOrCreate` 首次建会话 |
| `PostToolUse` | `.processing` | 清 currentTool / approval |
| `PermissionRequest` / `Notification` | `.waitingForApproval` | 触发橙色待批准 badge/glow |
| `Stop` | `.waitingForInput` | 顶层 turn 结束 |

- 不注册 `SubagentStart`/`SubagentStop`：单会话 phase 模型下，子 agent 结束不应把父会话翻成
  waiting；子 agent 活动已被 UserPromptSubmit/PostToolUse 覆盖。
- SwarmAgents 不发 `PreToolUse`/`SessionStart`（dispatcher 无对应映射），故会话由
  `UserPromptSubmit` 经 `mutateOrCreate` 首次创建（同 opencode/zcode）。
- `waitingForApproval` 需要一个 `PermissionContext`（见 `SessionPhase.swift`）—— notify-only 场景
  用一个最小/占位的 context。

**`Helpers/SwarmAgentsLogoIcon.swift`** —— 品牌矢量图标（同 `ZcodeLogoIcon` 结构）。先用 SF Symbol
占位（如 `point.3.filled.connected.trianglepath.dotted`）。

### 改动文件（加 `.swarmagents` case）

- **`Models/AIProvider.swift`** — `AISource` enum 加 `case swarmagents`；`displayModel` switch 加
  `formatSwarmModel`（通用格式化，SwarmAgents 可跑多种模型）。
- **`Services/HookInstaller.swift`** — 加 `HookTarget.swarmagents`：
  - `settingsPath = ~/.swarm-agents/hooks.json`
  - `hookEvents = [UserPromptSubmit, PostToolUse, Notification, PermissionRequest, Stop]`
  - **第三种文件形状**：整个文件根就是 events map（无 `hooks` 包裹，也非 zcode 的 `hooks.events`
    嵌套）。加一个形状标志（如 `rootLevelEvents`），让 `readEvents` 直接返回整个 settings dict、
    `writeEvents` 直接替换根。复用现有 `applyInstall`/`applyUninstall`/`detectInstalled`。
  - hook-sender.sh 注释里补一句 SwarmAgents。
- **`Services/HookServer.swift`** —— 关键改动：阻塞式许可只对 claude 生效。
  `processRequest` 里改为
  `if event.hookEventName == "PermissionRequest", event.cliSource == "claude" { handlePermissionRequest(...) ; return }`
  否则走 `sendJSON(.ack)` 立即返回。SwarmAgents notify-only，不能被 hold 120s（`onEventReceived`
  已在分支前调用，provider 照常收到并置 waitingForApproval）。当前只有 claude 发
  PermissionRequest 经此路径，故 gate 保持现有行为不变。
- **`hook-sender.sh`（在 `HookInstaller.ensureScriptExists` 里的字符串）** —— 保留已有 cli_source：
  python 注入处改为 `d['cli_source'] = d.get('cli_source') or '$CLI_SOURCE'`，`scriptVersion` +1
  （触发启动时自动刷新脚本）。
- **`Services/AICLIMonitorService.swift`** — 加 `swarmAgentsProvider` 属性 / init / `setHookServer`
  / `anyHookInstalled` / `installHooks` / `routeEvent` 的 `"swarmagents"` case /
  `respondToPermission` case / 默认 fallback 的 `.swarmagents` case /
  `handleServerReady` 里按 `swarmagentsEnabled && FileManager 存在 ~/.swarm-agents/` 自动安装。
- **`Models/AppSettings.swift`** — `swarmagentsEnabledKey` + `swarmagentsEnabled`（默认 true）。
- **`Notch/Badge/BadgeIconView.swift` + `BadgeViewModel.swift`** — badge logo / source 分支。
- **`Notch/CompletionToastView.swift`** — toast logo（`CompletionSource.ai(.swarmagents)`）。
- **`Tabs/AIChatTab.swift`** — AI tab source 图标 + provider 恢复卡片。
- **`Settings/SettingsView.swift` + `Notch/MenuBar/HooksSection.swift`** — provider 卡片
  （install/reinstall/uninstall）+ "Install SwarmAgents hooks" 菜单项。

## 测试（Swift Testing）

- `SwarmAgentsProvider` 事件 → phase 映射（含 `PermissionRequest → waitingForApproval`、
  `Stop → waitingForInput`、`UserPromptSubmit` 首次 `mutateOrCreate` 建会话）。
- `HookInstaller` 对 `.swarmagents` 根级 events 形状的 install/uninstall/detect 幂等
  （尤其：install 后根是 events map，uninstall 后干净移除，检测只认我们的 command）。
- `HookServer` PermissionRequest 非 claude 源立即 ack、不进 `pendingPermissions`；claude 源仍进
  pending（回归保护）。
- `routeEvent` 把 `cli_source:"swarmagents"` 路由到 `swarmAgentsProvider`。

## 文档

- 更新 `README.md` / `README_CN.md` / `CLAUDE.md`（AI 架构段加第五个 provider：SwarmAgents，
  说明其 dispatcher 吐标准形状、notify + 状态 + 待批准提醒、无对话/token 解析、无 usage quota）。

## 分支

- NemoNotch：`feature/swarmagents-provider`（本仓库）。
- SwarmAgents：其 `feat/hooks-dispatch` 或新分支（另一仓库，需重新构建生效）。

## 明确不做（scope）

- 无对话/token 解析（不转发 messages）。
- 无 notch 侧真正批准（`respondToPermission` no-op；批准归 SwarmAgents 自己 UI）。
- 无 usage quota。
- 不注册 SubagentStart/SubagentStop（避免单会话 phase 被子 agent 结束误翻）。
