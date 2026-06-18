---
summary: 'MediaRemote 私有 API + NowPlayingCLI perl daemon 提取路径 + play/pause reconcile 流程'
read_when:
  - '实现 Now Playing 信息获取（标题/艺术家/封面/进度）'
  - '发送播放控制命令（play/pause/next/prev/skip）'
  - '调试"信息丢失"或 UI 闪烁/卡在乐观状态'
  - '需要理解 optimistic UI + authoritative guard 模式'
sources: ['NemoNotch §7']
last_verified: { nemonotch: 'fe4e9e5' }
---

# MediaRemote & NowPlayingCLI

## TL;DR

Now Playing 元数据（标题/艺术家/封面/时长/进度）通过 **NowPlayingCLI perl daemon** 获取；播放控制命令通过 **MediaRemote 私有 framework** 发送；play/pause 真实状态以 **ScriptingBridge 查询结果为权威**，通过 optimistic UI + `reconcileExpectedIsPlaying` guard 融合三者。

---

## 可复用模式

### 模式 1 — Gzipped dylib 提取到 Application Support

Bundle 里不能直接 `dlopen` 可执行 bundle（read-only 沙箱），需要在首次启动时将压缩 dylib 解压到 `~/Library/Application Support/<AppName>/` 后再使用。

```swift
// NemoNotch/Services/NowPlayingCLI.swift:309-387  extractDylib(gzPath:)
private static func extractDylib(gzPath: String) -> String? {
    let dest = (supportDir as NSString).appendingPathComponent("MediaRemoteMini.dylib")
    if FileManager.default.fileExists(atPath: dest) { return dest }
    // 写到临时路径，再 moveItem → dest（原子替换）
    // run /usr/bin/gunzip -c gzPath > dest + ".tmp"
    // FileManager.default.moveItem(atPath: tmp, toPath: dest)
}
```

关键点：先写 `.tmp`，成功后再 `moveItem`；失败路径删除临时文件，避免半写 dylib 留在磁盘。

---

### 模式 2 — Process + Pipe daemon 长连接协议

daemon 一次性启动，通过 stdin/stdout 收发行分隔 JSON，避免每次请求都 fork/exec。

```swift
// NemoNotch/Services/NowPlayingCLI.swift:80-118  startDaemon()
process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
process.arguments = [script, dylib, "adapter_get_env", "--daemon"]

let stdinPipe  = Pipe(); let stdoutPipe = Pipe(); let stderrPipe = Pipe()
process.standardInput  = stdinPipe
process.standardOutput = stdoutPipe
process.standardError  = stderrPipe
try process.run()

daemonStdin  = stdinPipe.fileHandleForWriting
daemonStdout = stdoutPipe.fileHandleForReading
daemonStdout?.readabilityHandler = { [weak self] handle in /* 逐行解帧 */ }
```

请求：写一个 `\n` 到 stdin；响应：daemon 返回一个 JSON 对象 + `\n`。

---

### 模式 3 — MediaRemote `skip(interval:)` 发送跳转命令

```swift
// NemoNotch/Services/MediaRemote.swift:141-165
func skip(interval: Double) -> Bool {
    let options: [AnyHashable: Any] = [
        "kMRMediaRemoteOptionSkipInterval": NSNumber(value: abs(interval)),
    ]
    if sendCommand(interval > 0 ? .skipForward : .skipBackward, options: options) { return true }
    return sendCommand(interval > 0 ? .skipForward15 : .skipBackward15)
}
```

优先带 interval 的泛型命令，失败才降级到固定 15s 命令。**Music / Spotify 不走此路径**，走 ScriptingBridge — 见 [seek 决策树](#锚点fileline)。

---

### 模式 4 — Optimistic UI + Guard Reconcile

play/pause 三阶段融合：① 即时 flip UI + 设 guard；② 0.5s 后 ScriptingBridge 查权威态；③ CLI 轮询时只要与 guard 不符就丢弃 CLI 值，相符则清 guard。

```swift
// 阶段 1：NemoNotch/Services/MediaService.swift:56-69  togglePlayPause()
playbackState.isPlaying    = target   // 乐观翻转
reconcileExpectedIsPlaying = target   // 装甲 guard
scheduleReconcile(after: 0.5)

// 阶段 2：NemoNotch/Services/MediaService.swift:113-132  reconcilePlayState()
if let playing = MediaBridge.isPlaying(bundleID: bundleID) {
    playbackState.isPlaying    = playing
    reconcileExpectedIsPlaying = playing   // 以 SB 结果重置 guard
} else {
    reconcileExpectedIsPlaying = nil       // 未知 app → 清 guard
    updateNowPlaying()
}

// 阶段 3：NemoNotch/Services/MediaService.swift:287-306  applyInfo(_:)
if let expected = reconcileExpectedIsPlaying {
    if cliPlaying == expected {
        reconcileExpectedIsPlaying = nil   // CLI 跟上了 → 清 guard
        resolvedIsPlaying = cliPlaying
    } else {
        resolvedIsPlaying = expected       // CLI 仍旧 stale → 忽略
    }
} else {
    resolvedIsPlaying = cliPlaying         // 无 guard → 信任 CLI
}
```

---

## 锚点（file:line）

| 代码位置 | 作用 |
|---|---|
| `NemoNotch/Services/NowPlayingCLI.swift:38-54` | `init()` — bundle 资源路径查找 |
| `NemoNotch/Services/NowPlayingCLI.swift:80-118` | `startDaemon()` — Process+Pipe 启动 |
| `NemoNotch/Services/NowPlayingCLI.swift:141-189` | `fetchViaDaemon(completion:)` + `handleDaemonData(_:)` — 请求/响应帧 |
| `NemoNotch/Services/NowPlayingCLI.swift:207-298` | `fetchUsingFallbacks` + `runProcess` — 一次性 fallback + semaphore 超时 |
| `NemoNotch/Services/NowPlayingCLI.swift:309-387` | `extractDylib(gzPath:)` — dylib 解压 |
| `NemoNotch/Services/MediaRemote.swift:141-165` | `sendCommand` / `skip(interval:)` |
| `NemoNotch/Services/MediaRemote.swift:169-174` | `setElapsedTime(_:)` — 绝对位置 seek |
| `NemoNotch/Services/MediaService.swift:26-31` | `reconcileExpectedIsPlaying` 属性定义 |
| `NemoNotch/Services/MediaService.swift:56-69` | `togglePlayPause()` |
| `NemoNotch/Services/MediaService.swift:113-132` | `reconcilePlayState()` |
| `NemoNotch/Services/MediaService.swift:160-173` | `seek(toAbsolute:fallbackInterval:)` — seek 决策入口 |
| `NemoNotch/Services/MediaService.swift:287-306` | `applyInfo(_:)` isPlaying 解析块 |
| `NemoNotch/NemoNotchApp.swift:26` | `signal(SIGPIPE, SIG_IGN)` 注册 |

---

## Pitfalls

1. **不 retain `Process` 实例 → ARC 释放后 daemon 被 reap，下一次请求挂起在死管道。** 必须把 `Process` 存为属性（`daemonProcess`）。

2. **未安装 `signal(SIGPIPE, SIG_IGN)` → perl daemon 退出时 write 到关闭的 pipe，父进程收到 SIGPIPE 被直接 kill，无 crash log。** 在 app entry point 一行修复。

3. **daemon 请求不能并发。** `pendingCompletion` 是单槽，并发写 stdin 会乱帧。所有调用方必须排队到同一个 `queue`。

4. **响应缓冲区以 `0x0A`（`\n`）为唯一分隔符。** 不要换成带换行的 pretty-printed JSON，会导致帧错位。

5. **daemon 超时后必须 restart，不能 recover。** 无消息边界就无法丢弃半包。`handleDaemonTimeout()` → `restartDaemon()`，无捷径。

6. **MediaRemote `setElapsedTime` 的 Bool 返回值只表示"符号加载成功"，不表示命令被执行。** Music/Spotify 上静默 no-op；需要走 ScriptingBridge。

7. **MediaRemote `SkipForward/SkipBackward` 在 Spotify 上返回"never supported"（无错误信号）。** 永远不要对 Music/Spotify 直接调用 `skip(interval:)`，走 `MediaBridge.setPlayerPosition`。

8. **`reconcileExpectedIsPlaying` 是 `Bool?`，不是 `Bool`。** `nil` = 无 guard，直接信任 CLI。混淆 `false` 与 `nil` 会导致首次轮询值被丢弃，UI 永远不更新。

9. **`MediaBridge.isPlaying(bundleID:)` 在未知 app 或离线 app 上返回 `nil`，不是 `false`。** `reconcilePlayState` 必须处理 nil 分支（清 guard + 重新拉取），不能直接解包。

10. **0.5s reconcile 延迟是经验值。** 更短则 CLI 尚未跟上，`reconcilePlayState` 会用 stale 值重置 guard；更长则快速双击时 UI 抖动。

---

## 落地 checklist

- [ ] `signal(SIGPIPE, SIG_IGN)` 在 app entry point 注册
- [ ] `NowPlayingCLI` 持有 `daemonProcess`（强引用属性）
- [ ] dylib 解压到 `~/Library/Application Support/<AppName>/` 而非 bundle 内部
- [ ] daemon 请求通过单一串行 queue 序列化
- [ ] reconcile guard 初始值为 `nil`（非 `false`）
- [ ] Music / Spotify 的 seek 走 `MediaBridge.setPlayerPosition`，其他播放器走 MediaRemote
- [ ] `NSAppleEventsUsageDescription` 已在 `project.pbxproj` 的 `INFOPLIST_KEY_*` 中声明（否则 Automation 弹窗永远不出现）— 详见 [../permissions/](../permissions/)

---

## 延伸阅读

- [ScriptingBridge & seek 决策](scriptingbridge-reconcile.md) — Music/Spotify 权威态与 AppleScript seek
- [私有 API 加载（§4 Pattern B/C）](../private-api/) — MediaRemote dlopen/dlsym 与 15.4+ MRNowPlayingController fallback
- [权限系统](../permissions/) — `NSAppleEventsUsageDescription` / Automation TCC
