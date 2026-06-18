---
summary: 'IPC、子进程、hook 安装与增量解析——NemoNotch 作为 AI CLI 事件中枢的全套技术'
last_verified: { nemonotch: 'fe4e9e5' }
---

# IPC 区块

NemoNotch 通过三种机制与外部 AI CLI（Claude Code、Gemini CLI、Hermes）通信：TCP loopback 接收 push 事件、`DispatchSourceFileSystemObject` 监听文件变化、shell hook 脚本注入 CLI 配置。

| 文档 | 内容 |
|------|------|
| [unix-socket-and-subprocess.md](unix-socket-and-subprocess.md) | `NWListener` TCP loopback 服务端与 `Process + Pipe` 子进程模式；AF_UNIX socket 陷阱（路径长度限制、stale socket、actor 边界） |
| [hook-server.md](hook-server.md) | `HookServer` 事件路由（PreToolUse / PostToolUse / PermissionRequest 等）；PermissionRequest waiter 模式（挂起连接等待用户决策 + 120s 超时）；端口自动回退与脚本同步更新 |
| [hook-installer.md](hook-installer.md) | 幂等安装/卸载 hook：Claude + Gemini JSON 写入 `settings.json`、Hermes YAML 字符串 patch；`hook-sender.sh` 生成（版本+端口双校验）；脚本权限 0755 陷阱 |
| [incremental-parsing.md](incremental-parsing.md) | `readOffset + pendingTail` 增量读取；`ConversationParser.parseIncremental`（Claude JSONL token 统计）；`InterruptWatcher`（interrupt / /clear 检测）；`AgentFileWatcher`（subagent tool_use/tool_result 实时追踪） |
