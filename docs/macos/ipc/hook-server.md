---
summary: 'HookServer：接收 AI CLI hook 事件的 TCP loopback 服务端，含 PermissionRequest waiter 模式'
read_when:
  - '实现或调试 hook 事件接收（PreToolUse / PostToolUse / PermissionRequest 等）'
  - '需要在 macOS app 中保持长连接等待用户决策再回复'
  - '调试 "hooks never fire" 或 PermissionRequest 超时'
sources: ['§12.1', '§13.5']
last_verified: { nemonotch: 'fe4e9e5' }
---

# HookServer — Hook 事件服务端

## TL;DR

`HookServer` 是一个 `@MainActor @Observable` 的 TCP loopback 服务端（`NWListener`），监听 `127.0.0.1:<port>`，接收 `hook-sender.sh` 发来的 HTTP POST 请求，解码为 `HookEvent` 后分发给上层（`ClaudeCodeService` / `GeminiProvider`）。**PermissionRequest** 事件使用 waiter 模式：保持 TCP 连接挂起直到用户决策或 120 秒超时。

---

## 可复用模式

### 1. 事件路由

```swift
// HookServer.swift:169-209  processRequest(_:connection:)
if firstLine.hasPrefix("GET /health") {
    sendHTTP(connection, status: "200 OK", body: "ok")
    return
}
if firstLine.hasPrefix("POST /hook") {
    // ...解码 HookEvent
    if event.hookEventName == "PermissionRequest" {
        handlePermissionRequest(event, connection: connection)
        return          // 不立即回复，保持连接
    }
    sendJSON(connection, payload: .ack)  // 普通事件立即 ACK
}
```

`hook-sender.sh` 发送前先 `GET /health`，若服务器未运行则脚本直接退出（不阻塞 CLI）。

### 2. PermissionRequest Waiter 模式

```swift
// HookServer.swift:211-226  handlePermissionRequest(_:connection:)
let waitKey = sessionId + ":" + (event.toolUseId ?? UUID().uuidString)
pendingPermissions[waitKey] = connection    // 挂起连接

DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
    guard let self else { return }
    if let conn = pendingPermissions.removeValue(forKey: waitKey) {
        sendJSON(conn, payload: .decision(.deny(reason: .timeout)))
    }
}
```

用户点击 Allow/Deny → `respondToPermission(sessionId:approved:)`（锚点 `:228-233`）→ `removeValue(forKey:)` 抢占 → 发送决策。

三条出口（用户决策 / 120s 超时 / session 取消）都竞争同一个 `removeValue`，谁抢到谁发送，天然防止重复回复。

### 3. 清理已完成的 PermissionRequest

```swift
// HookServer.swift:250-261  clearPendingPermissions(sessionId:)
// 当 PostToolUse 到达时（工具已执行），请求已无意义
// 直接 cancel 连接而不发送 decision，避免发出错误的 allow/deny
conn.cancel()
```

区分 `cancelPendingPermissions`（主动 deny）和 `clearPendingPermissions`（静默丢弃）两个 API。

### 4. Hook 事件协议

Claude hooks 事件名（`HookTarget.hookEvents`，`HookInstaller.swift:16-18`）：

| 事件 | 含义 |
|------|------|
| `PreToolUse` | 工具调用前 |
| `PostToolUse` | 工具调用后 |
| `PermissionRequest` | 请求用户授权（需 waiter） |
| `Stop` | 会话结束 |
| `SessionStart` / `SessionEnd` | 会话生命周期 |
| `Notification` | 通知 |
| `UserPromptSubmit` | 用户输入 |

Gemini 事件：`SessionStart/End`, `Notification`, `BeforeAgent/AfterAgent`, `BeforeTool/AfterTool`（`HookInstaller.swift:20-24`）。

### 5. CLI Source 检测（hook-sender.sh）

```bash
# HookInstaller.swift:162-181（生成脚本内嵌逻辑）
if [ -n "$GEMINI_SESSION_ID" ]; then
    CLI_SOURCE="gemini"
elif [ -n "$CLAUDE_SESSION_ID" ]; then
    CLI_SOURCE="claude"
else
    # fallback: 检查父进程命令行
    COMMAND_LINE=$(ps -o args= -p "$PPID" 2>/dev/null)
    ...
fi
```

环境变量优先，覆盖旧版 CLI（不设置 env var）的情况。

---

## 锚点（file:line）

| 位置 | 内容 |
|------|------|
| `NemoNotch/Services/HookServer.swift:1-20` | 类声明，`@MainActor @Observable`，`NWListener` 字段 |
| `HookServer.swift:24-73` | `start()` → `attemptStart()` — listener 创建 |
| `HookServer.swift:129-150` | `handleConnection` + `receive` — HTTP 读取循环 |
| `HookServer.swift:169-209` | `processRequest` — 路由分发 |
| `HookServer.swift:211-226` | `handlePermissionRequest` — waiter + 120s 超时 |
| `HookServer.swift:228-233` | `respondToPermission` — 用户决策路径 |
| `HookServer.swift:236-243` | `cancelPendingPermissions` — session 结束 deny |
| `HookServer.swift:250-261` | `clearPendingPermissions` — 工具完成静默丢弃 |
| `NemoNotch/Services/HookInstaller.swift:3-25` | `HookTarget` enum — settingsPath + hookEvents |
| `HookInstaller.swift:153-226` | `ensureScriptExists()` — 生成 `hook-sender.sh` |

---

## Pitfalls

1. **`hook-sender.sh` 权限必须 0755**：`String.write(to:atomically:encoding:)` 生成 0644 文件，macOS CLI 拒绝执行，表现为"hooks 从不触发"，无任何错误日志——极易误判为 socket/port 问题。锚点 `HookInstaller.swift:222-225`。

2. **payload 日志只记录 size**：`LogService.debug("Received hook message: \(bodyData.count) bytes")` — body 含对话文本和文件路径，绝不打印内容。

3. **`removeValue` 竞争防止重复回复**：三条出口（用户 / 超时 / cancel）都通过 `removeValue(forKey:)` 竞争，在 `@MainActor` 保证下不需要额外锁，但若将任何一条路径移出 MainActor，需加锁或改用 actor-isolated dict。

4. **端口落地必须重写脚本**：`HookServer.swift:83-89` — 落地端口非默认时，`NotchConstants.setHookServerPort(port)` + `HookInstaller.ensureScriptExists()` 必须一起调用，否则脚本指向旧端口。

5. **`hook-sender.sh` 健康检查是零阻塞保障**：脚本首行 `curl /health --connect-timeout 0.3` 失败即退出，确保在 NemoNotch 未运行时 CLI 不阻塞。

---

## 落地 Checklist

- [ ] `HookServer` 标注 `@MainActor @Observable`
- [ ] 端口自动回退（`tryNextPort`）并同步更新脚本
- [ ] PermissionRequest：保存 connection 到 `pendingPermissions`，120s 超时 deny
- [ ] `clearPendingPermissions` vs `cancelPendingPermissions` 区分使用
- [ ] 脚本写入后调用 `setAttributes([.posixPermissions: 0o755])`
- [ ] 日志只记录 payload size，不记录内容

---

## 延伸阅读

- [unix-socket-and-subprocess.md](unix-socket-and-subprocess.md) — NWListener / AF_UNIX 底层模式
- [hook-installer.md](hook-installer.md) — settings.json 写入与脚本安装
- ../concurrency/ — Swift 6 `@MainActor` + `nonisolated(unsafe)` 边界
