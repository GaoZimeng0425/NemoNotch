---
summary: 'macOS 下 Unix socket 服务端搭建与子进程（Process + Pipe）的核心模式'
read_when:
  - '需要监听本地 socket 接收外部进程消息'
  - '需要长期运行子进程并通过 stdin/stdout 通信'
  - '调试 "bind returns EADDRINUSE" 或 "child process ignores SIGPIPE"'
sources: ['§12 IPC & subprocess']
last_verified: { nemonotch: 'fe4e9e5' }
---

# Unix Socket 与子进程

## TL;DR

NemoNotch 早期设计使用 AF_UNIX socket，当前实现已切换到 **TCP loopback（NWListener）**，原因是 macOS 在该 bundle ID 下会对非 NemoNotch 进程隐藏 unix socket 的 VFS inode，导致 `hook-sender.sh` 无法访问（TCP loopback 绕开 VFS 层）。本文保留 AF_UNIX 的陷阱描述，方便其他场景复用，同时覆盖当前 NWListener 实现。

---

## 可复用模式

### 1. NWListener TCP loopback 服务端（当前实现）

```swift
// HookServer.swift:36-73
let params = NWParameters.tcp
params.allowLocalEndpointReuse = true
params.acceptLocalOnly = true           // 只接受本地连接
params.includePeerToPeer = false

let listener = try NWListener(using: params, on: nwPort)
listener.newConnectionHandler = { [weak self] connection in
    Task { @MainActor in self?.handleConnection(connection) }
}
listener.stateUpdateHandler = { [weak self] state in
    Task { @MainActor in self?.handleListenerState(state) }
}
listener.start(queue: .global(qos: .userInitiated))
```

**端口自动回退**：首选端口占用时，`tryNextPort()` 在 `hookServerDefaultPort ... hookServerDefaultPort + hookServerMaxPortAttempts` 范围内逐步递增，落地端口持久化到 `NotchConstants.setHookServerPort()` 并重写 `hook-sender.sh`（锚点 `HookServer.swift:115-125`）。

### 2. HTTP over TCP 请求读取

```swift
// HookServer.swift:134-150  receive(connection:accumulated:)
connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
    data, _, isComplete, error in
    var buf = accumulated
    if let data { buf.append(data) }
    if Self.hasCompleteHTTPRequest(buf) || isComplete || error != nil {
        Task { @MainActor in self?.processRequest(buf, connection: connection) }
    } else {
        Task { @MainActor in self?.receive(connection: connection, accumulated: buf) }
    }
}
```

`hasCompleteHTTPRequest` 解析 `Content-Length` 头来判断 body 是否完整（锚点 `HookServer.swift:152-167`），避免误认为 partial read 已结束。

### 3. AF_UNIX socket（参考，不再用于 hook）

```swift
// 历史模式，见 cookbook §12.1
unlink(socketPath)                          // 必须先删除残留 socket 文件
socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
// strncpy 限制 103 字节（留 1 字节 NUL）
_ = socketPath.withCString { ptr in strncpy(&addr.sun_path.0, ptr, 103) }
bind(socketFd, bindResult, socklen_t(MemoryLayout<sockaddr_un>.size))
listen(socketFd, 10)
// DispatchSource.makeReadSource 驱动 accept 循环
```

### 4. 子进程（Process + Pipe）

```swift
// NowPlayingCLI.swift（见 §7.1）
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
process.arguments = [scriptPath]
let stdin = Pipe(), stdout = Pipe()
process.standardInput = stdin
process.standardOutput = stdout
process.launch()
// 行协议：stdin 写请求 JSON + "\n"，stdout 读响应 JSON + "\n"
```

---

## 锚点（file:line）

| 位置 | 内容 |
|------|------|
| `NemoNotch/Services/HookServer.swift:36-73` | `attemptStart()` — NWListener 创建与配置 |
| `HookServer.swift:75-113` | `handleListenerState(_:)` — ready/failed/waiting 状态机 |
| `HookServer.swift:115-125` | `tryNextPort()` — 端口自动回退 |
| `HookServer.swift:134-150` | `receive(connection:accumulated:)` — 累积读取 |
| `HookServer.swift:152-167` | `hasCompleteHTTPRequest` — Content-Length 判断 |
| `HookServer.swift:169-209` | `processRequest` — 路由 GET /health / POST /hook |

---

## Pitfalls

1. **`sockaddr_un.sun_path` 104 字节上限（AF_UNIX）**：Darwin 固定 104 字节，`strncpy` 必须限制到 103（留 NUL）。`~/Library/Application Support/...` 路径通常超限，应改用 `/tmp/` 短路径。

2. **`unlink` 前置（AF_UNIX）**：`bind` 前必须 `unlink`，否则上次崩溃留下的 socket 文件导致 `EADDRINUSE`。

3. **`nonisolated(unsafe)` 边界**：socketFd / acceptSource 在 `socketQueue` 上操作，不能直接改 `@Observable` 状态；需 `DispatchQueue.main.async` 或 `Task { @MainActor in ... }` 回到主 actor（见 §15 并发规则）。

4. **子进程信号继承**：父进程 `signal(SIGPIPE, SIG_IGN)` 会被子进程继承；子进程若不主动 `signal(SIGPIPE, SIG_DFL)` 重置，写入关闭的 pipe 时会挂死而非退出。

5. **`Process.environment` 覆盖**：设置自定义 `environment` dict 后，`PATH`/`HOME`/`LANG` 等默认继承自 parent 的变量会消失，需手动 merge `ProcessInfo.processInfo.environment`。

6. **partial HTTP read**：`NWConnection.receive` 可能分多次返回数据，需检查 `Content-Length` 或 `isComplete` 后再处理，不能假设单次 receive 包含完整请求。

---

## 落地 Checklist

- [ ] TCP loopback：`acceptLocalOnly = true`，防止外部访问
- [ ] 端口冲突：实现 `tryNextPort()` 回退，并将实际端口写入 `hook-sender.sh`
- [ ] 多次 receive 累积：`accumulated` 参数传递，`hasCompleteHTTPRequest` 判断
- [ ] AF_UNIX（若使用）：`unlink` 先行；路径 ≤103 字节；`DispatchSource.makeReadSource`
- [ ] 子进程：merge parent environment；reset SIGPIPE

---

## 延伸阅读

- [hook-server.md](hook-server.md) — HookServer 协议层与 PermissionRequest waiter 模式
- [hook-installer.md](hook-installer.md) — `hook-sender.sh` 生成与 settings.json 写入
- ../private-api/ — `dlopen` / MediaRemote 等私有 API 加载
