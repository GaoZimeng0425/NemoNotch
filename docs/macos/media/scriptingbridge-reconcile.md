---
summary: 'ScriptingBridge 权威播放态读取 + AppleScript set player position seek（Music/Spotify）+ 决策规则'
read_when:
  - '需要对 Music 或 Spotify 做 seek / 跳转'
  - '调试 play/pause 状态读不准（ScriptingBridge 返回值解释）'
  - '添加新的 SB 桥接 app（生成协议、AE keyword 查找）'
  - '评估该用 AppleScript 还是 MediaRemote'
sources: ['NemoNotch §7.3', 'NemoNotch §9']
last_verified: { nemonotch: 'fe4e9e5' }
---

# ScriptingBridge & AppleScript Seek Reconcile

## TL;DR

Music 和 Spotify 的播放态以 ScriptingBridge（同步进程内 AppleEvent）为权威，seek 也必须走 `setPlayerPosition`（AppleScript 语义）——MediaRemote 的 seek 命令对这两款 app 不可靠或静默失效。`osascript` 在整个 codebase 中不存在，全部用 SB 协议替代，原因是 SB 在进程内 dispatch（微秒级），而 `osascript` 每次 fork/exec（毫秒级）。

---

## 可复用模式

### 模式 1 — `SBApplication(bundleIdentifier:)` 安全解析

**必须** 先检查 app 是否在运行，否则调用 `SBApplication(bundleIdentifier:)` 会 **唤起目标 App**（出现在 Dock），这是隐形 bug。

```swift
// NemoNotch/Services/MediaBridge.swift:52-63  PlayerHandle.resolve(_:)
static func resolve(_ player: KnownPlayer) -> PlayerHandle? {
    switch player {
    case .spotify:
        guard let app: SpotifyApplication = SBApplication(bundleIdentifier: player.rawValue) else { return nil }
        (app as? SBApplication)?.delegate = PlayerEventDelegate.shared
        return .spotify(app)
    case .music:
        guard let app: MusicApplication = SBApplication(bundleIdentifier: player.rawValue) else { return nil }
        (app as? SBApplication)?.delegate = PlayerEventDelegate.shared
        return .music(app)
    }
}
```

调用前先 `guard isRunning(bundleID:)` — 见 `MediaBridge.swift:134-137`。

---

### 模式 2 — `SBApplicationDelegate` 异步错误捕获

SB 方法调用是 `Void` 返回，**没有同步错误路径**。automation 权限被拒（`-1743`）只能通过 delegate 的 `eventDidFail` 捕获。

```swift
// NemoNotch/Services/MediaBridge.swift:24-44  PlayerEventDelegate
private final class PlayerEventDelegate: NSObject, SBApplicationDelegate, @unchecked Sendable {
    static let shared = PlayerEventDelegate()          // 必须是全局单例！
    private(set) var lastErrorCode: Int = 0
    func resetLastError() { lastErrorCode = 0 }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        let code = (error as NSError).code
        lastErrorCode = code
        if code == -1743 { MediaBridge.notifyPermissionDenied() }
        return nil
    }
}
```

`SBApplication.delegate` 在 ObjC API 中是 `unowned`，delegate 如果是局部变量会立即被 ARC 释放，`eventDidFail` 永远不触发。**必须用 `static let shared` 保活。**

---

### 模式 3 — `isPlaying` via `playerState` enum

Music 有 5 个状态（stopped / playing / paused / fastForwarding / rewinding），Spotify 有 3 个（stopped / playing / paused）。

```swift
// NemoNotch/Services/MediaBridge.swift:73-80  PlayerHandle.isPlaying
var isPlaying: Bool? {
    switch self {
    case .spotify(let a): return a.playerState == .playing
    case .music(let a):
        let s = a.playerState
        return s == .playing || s == .fastForwarding || s == .rewinding
    }
}
```

写通用 isPlaying 判断时：把任何"非 stopped、非 paused"状态当作 playing，否则 Music 快进时每次 scrub 会短暂显示为 paused。

---

### 模式 4 — `setPlayerPosition` (AppleScript seek)

```swift
// NemoNotch/Services/MediaBridge.swift:103-108  PlayerHandle.setPosition(_:)
func setPosition(_ value: Double) {
    switch self {
    case .spotify(let a): a.setPlayerPosition?(value)
    case .music(let a):   a.setPlayerPosition?(value)
    }
}
```

生成的 SB 协议将 `setPlayerPosition` 标注为 `@objc optional`，调用时必须加 `?`。Spotify 的 seek **只有这条路可用**，MediaRemote 对 Spotify 静默丢弃。

---

### 模式 5 — Automation 权限探测（无 API 直查）

macOS 没有"询问是否已授权"的 API；唯一办法是发一次无害读操作，看 delegate 是否捕获 `-1743`。

```swift
// NemoNotch/Services/MediaBridge.swift:142-163  hasAutomationAccess
static func hasAutomationAccess(bundleID: String?) -> Bool {
    guard let bundleID, let player = KnownPlayer(bundleID: bundleID) else { return false }
    guard isRunning(bundleID: bundleID) else { return false }
    PlayerEventDelegate.shared.resetLastError()
    _ = PlayerHandle.resolve(player)?.position   // 无害读，触发 AE + 可能弹窗
    return PlayerEventDelegate.shared.lastErrorCode != -1743
}
```

`requestPermissionIfNeeded` 在 `UserDefaults` 记录"已弹过"，避免每次启动重复弹窗。

---

### 模式 6 — 生成 SB 协议文件

```bash
sdef /Applications/Music.app | sdp -fh --basename MusicApplication   # → MusicApplication.h (ObjC)
# 再手动把 @interface/@property 翻译为 Swift @objc protocol
```

`sdp` 只输出 Objective-C，Swift port 需手动完成，约 1 小时。生成文件放在 `NemoNotch/Services/ScriptingBridge/`。

---

### 模式 7 — Seek 决策树

| 播放器 | MediaRemote `skip` | `setElapsedTime` | AppleScript `setPlayerPosition` | 结论 |
|---|---|---|---|---|
| Music | 接受 | 接受 | 接受 | **AppleScript（最可靠）** |
| Spotify | 拒绝 | 静默失败 | 接受 | **AppleScript only** |
| Podcasts | 接受 | 接受 | 无 AS verb | MediaRemote |
| Safari/Chrome | 接受 | 部分 | 无 AS verb | MediaRemote |
| 未知播放器 | 优先尝试 | — | — | MediaRemote + fallback log |

入口：`NemoNotch/Services/MediaService.swift:160-173  seek(toAbsolute:fallbackInterval:)`

---

## 锚点（file:line）

| 代码位置 | 作用 |
|---|---|
| `NemoNotch/Services/MediaBridge.swift:24-44` | `PlayerEventDelegate` — 异步 AE 错误捕获 |
| `NemoNotch/Services/MediaBridge.swift:52-63` | `PlayerHandle.resolve(_:)` — SBApplication 解析 |
| `NemoNotch/Services/MediaBridge.swift:73-80` | `PlayerHandle.isPlaying` — playerState 映射 |
| `NemoNotch/Services/MediaBridge.swift:103-108` | `PlayerHandle.setPosition(_:)` — AppleScript seek |
| `NemoNotch/Services/MediaBridge.swift:134-137` | `isRunning(bundleID:)` — 运行前置检查 |
| `NemoNotch/Services/MediaBridge.swift:142-163` | `hasAutomationAccess` + `requestPermissionIfNeeded` |
| `NemoNotch/Services/MediaBridge.swift:191-195` | `MediaBridge.setPlayerPosition(bundleID:position:)` |
| `NemoNotch/Services/MediaBridge.swift:207-210` | `openAutomationSettings()` — 打开系统设置深链接 |
| `NemoNotch/Services/ScriptingBridge/MusicApplication.swift:24-31` | `MusicEPlS` enum（AE keyword 映射） |
| `NemoNotch/Services/ScriptingBridge/MusicApplication.swift:131-195` | `MusicApplication` Swift @objc protocol |
| `NemoNotch/Services/ScriptingBridge/SpotifyApplication.swift:28-32` | Spotify playerState enum（3 个状态） |
| `NemoNotch/Services/MediaService.swift:160-173` | `seek(toAbsolute:fallbackInterval:)` — 决策入口 |

---

## Pitfalls

1. **调用 `SBApplication(bundleIdentifier:)` 前未检查 app 是否在运行 → 会静默唤起 Music/Spotify，出现在 Dock。** 始终先 `guard isRunning(bundleID:)`。

2. **`SBApplicationDelegate` 用局部变量而非单例 → ARC 立即释放，`eventDidFail` 永远不触发，automation 拒绝无法被检测。** 必须用 `static let shared`。

3. **SB 方法调用返回 `Void`，成功和被 TCC 拒绝看起来一样。** 唯一检测路径是 delegate 的 `-1743` 错误码，没有同步 Result/Error。

4. **Spotify MediaRemote skip 静默丢弃（"never supported"），没有错误回调。** 对 Spotify 只能走 `setPlayerPosition`（AppleScript）。

5. **`@objc optional` 方法必须加 `?` 调用。** 某些 app 版本（旧版/精简版 Music binary）可能没有实现 `setPlayerPosition`，`?` 调用保证静默跳过而不 crash。

6. **AE keyword 是 4 字节大端 ASCII，自行手算易出 byte-order 错误。** 查未知 code 时用 `xxd <app>/Contents/Resources/<app>.sdef | grep <keyword>`，不要脑算。

7. **sdef 生成的头文件可能落后于目标 App 版本。** Spotify/Music 新增 AS verb 后，生成文件不会自动更新，产生无编译警告的功能缺失。定期 regenerate。

8. **`NSAppleEventsUsageDescription` 若未在 `project.pbxproj` 的 `INFOPLIST_KEY_*` 中声明，automation 弹窗永远不弹，System Settings 里也不会列出该 app。** 验证方式：`/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" <app>/Contents/Info.plist`。

9. **`hasAutomationAccess` 中的"无害读"（读 `playerPosition`）本身就会触发 automation 弹窗。** 用 `requestPermissionIfNeeded` 的 `UserDefaults` flag 确保只弹一次。

---

## 落地 checklist

- [ ] `NSAppleEventsUsageDescription` 在 `project.pbxproj` 中声明（`INFOPLIST_KEY_*`）
- [ ] 所有 SB 调用前先 `guard isRunning(bundleID:)`
- [ ] `PlayerEventDelegate.shared` 为 `static let`（全局保活）
- [ ] Music/Spotify seek 走 `MediaBridge.setPlayerPosition`，Podcasts/未知走 MediaRemote
- [ ] `@objc optional` 方法用 `?` 调用
- [ ] 初次 automation 弹窗用 `UserDefaults` flag 去重

---

## 延伸阅读

- [MediaRemote & NowPlayingCLI](mediaremote-and-nowplaying.md) — play/pause reconcile 全流程
- [权限系统](../permissions/) — TCC Automation 权限 `errAEEventNotPermitted -1743`
- [私有 API 加载](../private-api/) — MediaRemote dlopen/dlsym（§4 Pattern B）
