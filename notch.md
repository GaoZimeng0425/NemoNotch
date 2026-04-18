# Masko Code 对 Claude Code 的监控实现详解

## 架构总览

```
Claude Code
    │ (触发 Hook 事件)
    ▼
hook-sender.sh (Hook 脚本)
    │ (HTTP POST)
    ▼
LocalServer (本地 HTTP 服务器, 端口 49152)
    │
    ▼
EventProcessor (事件处理器)
    ├── EventStore (事件存储, 最多 1000 条)
    ├── SessionStore (会话状态追踪)
    ├── NotificationStore (通知存储)
    └── NotificationService (macOS 系统通知)
    │
    ▼
SwiftUI Views (UI 展示)
    ├── ActivityFeedView (实时事件流)
    ├── SessionListView (会话列表)
    └── StatsOverlayView (状态 HUD)
```

---

## 1. Hook 事件捕获 — HookInstaller.swift

### 核心思路

通过修改 `~/.claude/settings.json`，向 Claude Code 注册自定义 Hook 脚本，拦截其内部事件。

### 监控的 18 种事件

```swift
// Sources/Services/HookInstaller.swift
private static let hookEvents = [
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "StopFailure",
    "Notification",
    "SessionStart",
    "SessionEnd",
    "TaskCompleted",
    "PermissionRequest",
    "UserPromptSubmit",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
    "PostCompact",
    "ConfigChange",
    "TeammateIdle",
    "WorktreeCreate",
    "WorktreeRemove",
]
```

### Hook 安装机制

读取 `~/.claude/settings.json`，在 `hooks` 字段中为每个事件类型注册 `hook-sender.sh`：

```swift
// Sources/Services/HookInstaller.swift
static func install() throws {
    // 确保 hook 脚本存在
    try ensureScriptExists()

    // 读取已有配置
    var settings: [String: Any] = [:]
    if let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        settings = json
    }

    // 构建 hooks 配置
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    let hookEntry: [String: Any] = [
        "matcher": "",
        "hooks": [["type": "command", "command": hookCommand]],
    ]

    for event in hookEvents {
        var entries = hooks[event] as? [[String: Any]] ?? []
        let alreadyRegistered = entries.contains { entry in
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { ($0["command"] as? String) == hookCommand }
        }
        if !alreadyRegistered {
            entries.append(hookEntry)
        }
        hooks[event] = entries
    }

    settings["hooks"] = hooks
    try writeSettings(settings)
}
```

### Hook 脚本 (hook-sender.sh)

脚本会自动生成并保存到 `~/.masko-desktop/hooks/hook-sender.sh`，核心逻辑：

```bash
#!/bin/bash
# version: 15
# hook-sender.sh — Forwards Claude Code hook events to masko-desktop

# 1. 快速健康检查 — 如果桌面应用没运行就直接退出（避免 curl 超时延迟）
curl -s --connect-timeout 0.3 "http://localhost:49152/health" >/dev/null 2>&1 || exit 0

# 2. 读取 Claude Code 传入的事件 JSON
INPUT=$(cat 2>/dev/null || echo '{}')
EVENT_NAME=$(echo "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)

# 3. 向上遍历进程树，找到终端 PID 和 Shell PID
TERM_PID=""
LAST_SHELL=""
SHELL_PID=""
CUR=$$
while [ "$CUR" != "1" ] && [ -n "$CUR" ]; do
  PAR=$(ps -o ppid= -p "$CUR" 2>/dev/null | tr -d ' ')
  [ -z "$PAR" ] && break
  COMM=$(ps -o comm= -p "$PAR" 2>/dev/null); COMM="${COMM##*/}"
  case "$COMM" in
    zsh|bash|fish|sh|nu|pwsh|elvish|-zsh|-bash|-fish|-sh) LAST_SHELL="$PAR" ;;
    Terminal|iTerm2|wezterm-gui|kitty|Cursor|Code|Windsurf|ghostty|alacritty|Warp|Zed|pycharm|idea|webstorm|goland|clion|phpstorm|rubymine|rider|Claude) TERM_PID="$PAR"; SHELL_PID="$LAST_SHELL"; break ;;
  esac
  CUR="$PAR"
done

# 4. 注入 terminal_pid 和 shell_pid 到 JSON payload
if [ -n "$TERM_PID" ]; then
  INJECT="\"terminal_pid\":$TERM_PID"
  [ -n "$SHELL_PID" ] && INJECT="$INJECT,\"shell_pid\":$SHELL_PID"
  INPUT=$(echo "$INPUT" | sed "s/}/,$INJECT}/")
fi

# 5. 根据事件类型决定发送策略
if [ "$EVENT_NAME" = "PermissionRequest" ]; then
    # 阻塞式：等待用户决策。curl 在后台运行，trap SIGTERM/SIGHUP 确保 curl 也被杀死
    TMPFILE=$(mktemp /tmp/masko-hook.XXXXXX)
    curl -s -w "\n%{http_code}" -X POST \
      -H "Content-Type: application/json" -d "$INPUT" \
      "http://localhost:49152/hook" \
      --connect-timeout 2 >"$TMPFILE" 2>/dev/null &
    CURL_PID=$!
    trap 'kill $CURL_PID 2>/dev/null; rm -f "$TMPFILE"; exit 0' TERM HUP INT
    wait $CURL_PID
    RESPONSE=$(cat "$TMPFILE")
    rm -f "$TMPFILE"
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    [ -n "$BODY" ] && echo "$BODY"
    [ "$HTTP_CODE" = "403" ] && exit 2  # 拒绝权限
    exit 0
else
    # Fire-and-forget：普通事件直接发送，不等待响应
    curl -s -X POST -H "Content-Type: application/json" -d "$INPUT" \
      "http://localhost:49152/hook" \
      --connect-timeout 1 --max-time 2 2>/dev/null || true
    exit 0
fi
```

---

## 2. 本地 HTTP 服务器 — LocalServer.swift

### 端口与路由

- 默认端口：`49152`，备用端口范围 `49152-49161`
- 使用 Apple `NWListener`（Network framework）实现 TCP 服务

```swift
// Sources/Services/LocalServer.swift
@Observable
final class LocalServer {
    private var listener: NWListener?
    private(set) var isRunning = false
    private(set) var port: UInt16 = Constants.serverPort

    var onEventReceived: ((AgentEvent) -> Void)?
    var onPermissionRequest: ((AgentEvent, NWConnection) -> Void)?
    var onInputReceived: ((String, ConditionValue) -> Void)?
    var onInstallReceived: ((MaskoAnimationConfig) -> Void)?

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true  // 避免 TIME_WAIT 阻塞
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        listener = try NWListener(using: params, on: nwPort)

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
                // 如果端口变了，重新安装 hook 脚本
                if self?.port != Constants.serverPort {
                    Constants.setServerPort(self?.port ?? Constants.serverPort)
                    try? HookInstaller.install()
                }
            case .failed, .waiting:
                // 端口被占用，尝试下一个
                self?.tryNextPort(...)
            default: break
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }
}
```

### 请求处理路由

```swift
// Sources/Services/LocalServer.swift (简化)
private func processRequest(_ data: Data, connection: NWConnection) {
    // GET /health — 健康检查
    if firstLine.contains("GET /health") {
        sendResponse(connection: connection, status: "200 OK", body: "ok")
        return
    }

    // POST /hook — 接收 Claude Code 事件
    if firstLine.contains("POST /hook") {
        if let event = try? decoder.decode(AgentEvent.self, from: bodyData) {
            // PermissionRequest: 保持连接，等待用户决策
            if event.eventType == .permissionRequest {
                DispatchQueue.main.async { handler(event, connection) }
                // 不发送响应 — 连接保持打开
                return
            }
            // 其他事件：直接回调处理
            DispatchQueue.main.async { self?.onEventReceived?(event) }
        }
        sendResponse(connection: connection, status: "200 OK", body: "OK")
        return
    }

    // POST /input — 自定义输入
    // POST /install — 安装 mascot 配置
}
```

---

## 3. 事件处理管道 — EventProcessor.swift

事件处理的 4 步管道：

```swift
// Sources/Services/EventProcessor.swift
@MainActor func process(_ event: AgentEvent) async {
    // 1. 存储事件
    eventStore.append(event)
    // 2. 更新会话状态
    sessionStore.recordEvent(event)
    // 3 & 4. 创建通知并展示
    if let notification = createNotification(from: event) {
        notificationStore.append(notification)
        await notificationService.show(notification)
    }
}
```

### 通知生成逻辑

```swift
// Sources/Services/EventProcessor.swift
private func createNotification(from event: AgentEvent) -> AppNotification? {
    switch event.eventType {
    case .notification:
        // 权限提示、空闲提示、输入对话框
        switch event.notificationType {
        case "permission_prompt":  // 紧急
        case "idle_prompt":        // 高优先级
        case "elicitation_dialog": // 高优先级
        }
    case .permissionRequest:
        // AskUserQuestion 或工具权限请求
    case .stop:
        // 任务完成
    case .postToolUseFailure:
        // 工具调用失败
    case .taskCompleted:
        // 任务完成
    case .sessionStart, .sessionEnd:
        // 会话生命周期
    case .preCompact:
        // 上下文压缩
    }
}
```

---

## 4. 会话状态追踪 — SessionStore.swift

### 会话数据模型

```swift
// Sources/Stores/SessionStore.swift
struct AgentSession: Identifiable, Codable {
    let id: String              // session_id
    let projectDir: String?     // 工作目录
    let projectName: String?    // 项目名
    var agentSource: AgentSource // claudeCode / codex / unknown
    var status: Status           // active / ended
    var phase: Phase             // idle / running / compacting
    var eventCount: Int          // 事件总数
    var startedAt: Date
    var lastEventAt: Date?
    var lastToolName: String?
    var activeSubagentCount: Int // 并发子代理数
    var terminalPid: Int?        // 终端进程 PID
    var terminalBundleId: String? // 终端 App Bundle ID
    var shellPid: Int?           // Shell 进程 PID
    var transcriptPath: String?  // transcript JSONL 路径

    enum Status: String, Codable { case active, ended }
    enum Phase: String, Codable {
        case idle       // 等待用户输入
        case running    // 代理正在工作
        case compacting // 上下文压缩中
    }
}
```

### 状态机转换

```swift
// Sources/Stores/SessionStore.swift — recordEvent()
switch event.eventType {
case .sessionStart:
    sessions[index].status = .active
    sessions[index].phase = .idle
case .userPromptSubmit:
    sessions[index].phase = .running
case .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest:
    sessions[index].phase = .running
case .preCompact:
    sessions[index].phase = .compacting
case .postCompact:
    sessions[index].phase = .running
case .stop, .stopFailure:
    sessions[index].phase = .idle
case .sessionEnd:
    sessions[index].status = .ended
    sessions[index].phase = .idle
case .subagentStart:
    sessions[index].phase = .running
    sessions[index].activeSubagentCount += 1
case .subagentStop:
    sessions[index].activeSubagentCount = max(0, count - 1)
}
```

### 崩溃恢复（每 2 分钟）

```swift
// Sources/Stores/SessionStore.swift
private func startReconcileTimer() {
    reconcileTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
        self?.reconcileIfNeeded()
    }
}

private func applyReconciliation(hasAssistantProcess: Bool) {
    if !hasAssistantProcess {
        // 没有任何 Claude Code 进程 → 结束所有活跃会话
        for i in sessions.indices where sessions[i].status == .active {
            sessions[i].status = .ended
        }
    } else {
        // 有进程但某些会话已过期（1 小时无活动）→ 逐一结束
        for i in sessions.indices where sessions[i].status == .active {
            if let lastEvent = sessions[i].lastEventAt,
               now.timeIntervalSince(lastEvent) > 3600 {
                // 但如果 transcript 文件最近 5 分钟有修改，跳过
                if transcriptModifiedWithin5Min { continue }
                sessions[i].status = .ended
            }
        }
    }
}
```

### 中断检测（每 3 秒）

Claude Code 用户中断不会触发 Hook，但会在 transcript 文件中写入 `[Request interrupted by user]`：

```swift
// Sources/Stores/SessionStore.swift
private func startInterruptWatcher() {
    interruptWatcherTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
        self?.checkForInterrupts()
    }
}

private static func transcriptIndicatesInterrupt(path: String, since lastEventAt: Date?) -> Bool {
    // 读取 transcript 文件最后 4KB
    // 从后往前遍历 JSONL 行，跳过 progress 类型
    // 找到 type == "user" 且包含 "[Request interrupted by user]" 的条目
    // 同时检查时间戳必须比 lastEventAt 更新
}
```

---

## 5. 事件存储 — EventStore.swift

```swift
// Sources/Stores/EventStore.swift
@Observable
final class EventStore {
    private(set) var events: [AgentEvent] = []
    private let maxEvents = 1000

    // 防抖持久化 — 最快每 5 秒写一次磁盘
    private func schedulePersist() {
        isDirty = true
        guard persistTimer == nil else { return }
        persistTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.persistNow()
        }
    }

    func append(_ event: AgentEvent) {
        events.insert(event, at: 0)  // 最新的在前面
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)  // FIFO 淘汰
        }
        schedulePersist()
    }
}
```

### 本地持久化

```swift
// Sources/Utilities/LocalStorage.swift
enum LocalStorage {
    static let appSupportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("masko-desktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func save<T: Encodable>(_ value: T, to filename: String) {
        let url = appSupportDir.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = appSupportDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
```

存储位置：`~/Library/Application Support/masko-desktop/`
- `sessions.json` — 会话历史
- `events.json` — 事件日志
- `notifications.json` — 通知历史
- `mascots.json` — Mascot 配置

---

## 6. macOS 通知 — NotificationService.swift

```swift
// Sources/Services/NotificationService.swift
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    func show(_ notification: AppNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body ?? ""
        content.sound = sound(for: notification.category)  // 权限请求用 .defaultCritical
        let request = UNNotificationRequest(
            identifier: notification.id.uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    // 点击通知 → 将 App 带到前台
    func userNotificationCenter(_ center: ..., didReceive response: ...) async {
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
    }

    // 前台也能显示通知
    func userNotificationCenter(_ center: ..., willPresent notification: ...) async -> ... {
        [.banner, .sound, .badge]
    }
}
```

---

## 7. 健康诊断 — ConnectionDoctor.swift

9 项健康检查 + 自动修复：

```swift
// Sources/Services/ConnectionDoctor.swift
func runDiagnostics() async {
    checks.append(checkServerRunning())       // 1. 本地服务器是否运行
    checks.append(checkHooksInstalled())      // 2. Hook 是否注册到 settings.json
    checks.append(checkHookScriptExists())    // 3. Hook 脚本是否存在且可执行
    checks.append(checkPortMatch())           // 4. 脚本端口和服务器端口是否一致
    checks.append(checkScriptVersion())       // 5. 脚本版本是否最新
    checks.append(await checkHealthEndpoint())// 6. HTTP 健康检查端点
    checks.append(checkClaudeCodeProcess())   // 7. Claude Code 进程是否运行
    checks.append(await checkHookDelivery())  // 8. 端到端 Hook 投递测试
    checks.append(checkLastEvent())           // 9. 最后收到事件的时间
}

// 自动修复
func repairAll() async {
    if !localServer.isRunning {
        localServer.restart(port: localServer.port)
    }
    try? FileManager.default.removeItem(atPath: scriptPath) // 删除旧脚本
    try? HookInstaller.install() // 重新生成脚本 + 注册 Hook
    await runDiagnostics() // 重新检查
}
```

### 诊断报告

可以生成完整的诊断报告并上传到 masko.ai，包含：
- App 版本、OS 版本、Claude Code 版本
- 各项检查结果
- 活跃会话数、总事件数
- `~/.claude/settings.json` 中的 hooks 配置
- Claude Code debug 日志中最近的 hook 相关行（最后 50 行）
- 是否有其他 Hook 管理器冲突

---

## 8. 性能监控（仅 DEBUG） — PerfMonitor.swift

```swift
// Sources/Debug/PerfMonitor.swift
@MainActor
final class PerfMonitor {
    static let shared = PerfMonitor()

    // 监控的事件类型
    enum Event: String, CaseIterable {
        case setInput, evaluateAndFire, setFrame
        case syncPermissionPanel
        case viewBodyStateMachine, viewBodyStatsHUD, viewBodyDebugHUD
        case viewBodyPermissionStack, viewBodyStatsOverlay
    }

    struct Snapshot {
        let countsPerSecond: [Event: Int]  // 每秒事件数
        let mainThreadStallMs: Double      // 最长主线程卡顿
        let memoryMB: Double               // RSS 内存 (MB)
        let livingAVPlayers: Int           // 活跃 AVPlayer 实例数
    }

    // 主线程卡顿检测：后台线程每 200ms ping 主线程，超过 250ms 则记录
    private func startStallDetection() {
        let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler {
            let pingTime = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                let stallMs = (CFAbsoluteTimeGetCurrent() - pingTime) * 1000
                if stallMs > 250 { /* 报告卡顿 */ }
            }
        }
    }

    // 告警阈值
    // - setInput > 10/sec
    // - setFrame > 5/sec
    // - View re-renders > 5/sec
    // - Memory > 500MB
    // - AVPlayer > 2 个
    // - 主线程卡顿 > 250ms
}
```

---

## 9. 状态 HUD — StatsOverlayView.swift

```swift
// Sources/Views/Overlay/StatsOverlayView.swift
struct StatsOverlayView: View {
    var body: some View {
        HStack(spacing: 8) {
            // 活跃会话（绿点 + 数量）
            Circle().fill(.green).frame(width: 6, height: 6)
            Text("\(activeSessions)")

            // 子代理（仅 > 0 时显示，青色）
            if activeSubagents > 0 {
                Image(systemName: "arrow.branch").foregroundStyle(.cyan)
            }

            // 上下文压缩（仅 > 0 时显示，紫色）
            if compactCount > 0 {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.purple)
            }

            // 待审批权限（仅 > 0 时显示，橙色）
            if pendingPermissions > 0 {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }

            // 运行中的会话（仅 > 0 时显示，绿色闪电）
            if runningSessions > 0 {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
            }
        }
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
    }
}
```

---

## 关键设计经验总结

### 1. Hook 是最核心的切入点
Claude Code 的 Hook 机制是整个监控的基石。它允许第三方脚本在事件发生时被调用，输入是 JSON（通过 stdin），输出可以影响 Claude Code 行为（exit code 2 = 拒绝）。

### 2. 两种 Hook 模式
- **Fire-and-forget**：普通事件直接 `curl --max-time 2` 发完就走
- **Blocking**：`PermissionRequest` 保持连接，允许桌面 App 拦截并决策

### 3. 进程树遍历获取上下文
Hook 脚本在 Claude Code 的子进程中执行，通过 `ps -o ppid=` 向上遍历，可以找到：
- **终端 App**（Terminal、iTerm2、Cursor 等）的 PID → 用于聚焦窗口
- **Shell**（zsh、bash 等）的 PID → 用于标识会话

### 4. 多层可靠性保障
- **崩溃恢复**：2 分钟定时器 + `pgrep` 检测孤儿会话
- **中断检测**：3 秒轮询 transcript 文件检测 `[Request interrupted by user]`
- **端口冲突**：自动尝试 49152-49161 范围内的备用端口
- **防抖写入**：EventStore 最快 5 秒写一次磁盘，避免高频 IO

### 5. 诊断系统（ConnectionDoctor）
9 项自动检查 + 一键修复，能覆盖绝大多数"监控不工作"的场景。端到端测试（发送测试事件 → 检查是否收到）是最可靠的验证方式。

### 6. 性能监控
仅 DEBUG 构建包含（`#if DEBUG`），零 Release 开销。主线程卡顿通过"后台 ping 主线程"的方式检测，简单有效。

### 7. 状态机设计
Session 的 `Phase` 有三个状态：`idle` → `running` → `compacting`，由不同事件驱动转换。状态机使 UI 可以准确反映 Claude Code 当前在做什么。
