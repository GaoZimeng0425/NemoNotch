---
summary: '--uitest 自驱动确定性截图模式：无 XCUITest target、不改 project.pbxproj，shell 脚本逐 tab 截图，--flash 全屏完成闪光截图。'
read_when:
  - '为悬浮 NSPanel 或其他依赖实时外部状态的 UI 制作确定性截图'
  - '搭建 marketing screenshot 流水线，避免 XCUITest 的权限与目标依赖问题'
  - '实现 --flash 类全屏瞬态 UI 的截图捕获'
sources: ['N §20']
last_verified: { peekaboo: 'n/a', nemonotch: 'fe4e9e5' }
---

# --uitest 截图 Harness

## TL;DR

NemoNotch 的 notch panel 是悬浮无边框 `NSPanel`，内容依赖实时外部状态（日历、媒体、AI 会话、agent）。`--uitest` 模式让 app **自驱动且状态确定**，shell 脚本逐 tab 启动 → 等待 → 截图 → 关闭，无需 XCUITest target，不修改 `project.pbxproj`。

---

## 可复用模式

### 模式 1 · 参数门控（Arg gate）

```swift
// NemoNotch/Helpers/UITestMode.swift
struct UITestMode {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest")
    }
    static var tab: Tab? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--tab=") }
            .flatMap { Tab(rawValue: String($0.dropFirst(6))) }
    }
    static var flash: Bool {
        ProcessInfo.processInfo.arguments.contains("--flash")
    }
    // 纯函数 isActive(in:) / tab(in:) 供单元测试注入 args
}
```

纯函数变体 `isActive(in:)` / `tab(in:)` 接受 `[String]` 参数，可在单元测试中直接调用，不依赖真实进程 args。

### 模式 2 · 副作用抑制

`applicationDidFinishLaunching` 把所有实时子系统放在 `if !UITestMode.isActive` 门后：

- `MediaService(disableLiveUpdates:)` — 跳过 perl NowPlaying daemon + 轮询
- `HookServer.start()` — 不启动，避免与已安装 app 竞争 HookServer TCP 端口
- `OpenClaw.connect()` / `Hermes.connect()` — 不发起 WebSocket/HTTP 连接
- `MediaAutomationPermissionMonitor.startProbing()` — 不触发权限探测
- weather 网络请求 — 不发出
- `SystemService.update()` — early-return，防止 2s 采样器覆盖 seeded 进程数据

关键：第二个实例不会与已安装 app 争抢 HookServer 端口。

### 模式 3 · 状态 Seeding

```swift
// NemoNotch/Helpers/UITestSeeder.swift
// 直接写入 @Observable service 的 var 属性
// private(set) 属性通过专属 seedForUITest(...) 入口修改
// 示例：CalendarService.seedForUITest(events:)
```

关键约定：
- `TaskStore(fileURL:)` 传入临时路径，seeding 永远不触碰 `~/.NemoNotch/tasks.json`
- Agents tab 通过注册 `UITestMockAgentMonitor`（`isInstalled`/`isOnline = true`）而非 fake OpenClaw/Hermes 内部状态
- 专辑封面用 `NSGradient` + glyph 程序化绘制成 PNG，避免打包版权资产
- seeding `playbackState.appBundleIdentifier` 为 `KnownPlayer`（Music/Spotify）会触发 Automation-permission card，留 `nil` 才走 now-playing 路径

### 模式 4 · Stay-open

```swift
// NotchCoordinator.init
if !UITestMode.isActive {
    setupEventMonitoring()  // uitest 下跳过，panel 不会 mouse-outside 自动关闭
}

// UITestSeeder 中：强制打开到内置 notch 屏
notchCoordinator.notchOpen(tab: UITestMode.tab, on: NSScreen.first {
    $0.isBuiltInDisplay && $0.hasNotch
})
```

独立于鼠标光标位置，强制打开到带 notch 的内置显示器。

### 模式 5 · 捕获几何（Capture geometry）

`UITestSeeder.writeCaptureRect(for:on:)` 在 panel 打开后把 `screencapture -R` 格式的矩形写入 `/tmp/nemonotch-uitest.rect`：

```
x = screen.frame.midX - width/2
y = 0
width = overviewOpenedWidth(700) | openedWidth(560)   # 按 tab 不同
height = openedHeight(328)
```

坐标系：origin = 主显示器左上角，y 向下（screencapture 坐标系）。shell 脚本每次 tab 读取此文件，适应不同 tab 的宽度差异。

### 模式 6 · 逐 tab 截图流程（Orchestration）

`scripts/uitest-screenshots.sh` 核心流程：

```bash
# 1. 退出已安装 app（防止两个 notch overlay 叠加）
# 2. xcodebuild Debug 构建
# 3. 逐 tab 循环：
#    - 启动 NemoNotch.app --uitest --tab=<tab>
#    - osascript -e 'delay ...'   ← 用 osascript delay，不用 shell sleep
#    - read /tmp/nemonotch-uitest.rect
#    - screencapture -x -R<x,y,w,h> docs/images/tab-<tab>.png
#    - kill <instance>
# 4. 重启用户已安装的 app
```

注意：用 `osascript -e 'delay ...'` 而非 shell `sleep`，前者与 macOS run loop 更兼容，等待期间 app 可正常完成渲染。

### 模式 7 · --flash 全屏瞬态捕获

完成闪光（completion flash）是全屏 `.screen`-blended 边框光晕，无法用 tab 的矩形裁剪来捕获。`--flash` 模式让其静态且可重现：

`AppDelegate` 在 uitest + flash 模式下：
1. 构建 `CompletionFlashWindowController`（正常 uitest 下不构建）
2. 在 `.statusBar + 7`（闪光窗口 `.statusBar + 8` 之下）放一个暗色渐变 `NSWindow` 作为背景板（`makeUITestFlashBackdrop(on:)`），使加法混合 `.screen` 发光效果在深色背景上清晰呈现，无需隐藏用户其他窗口
3. 调用 `CompletionFlashService.holdForUITest(names:)`——仅 uitest 可用的入口，固定 `flashLevel = 1` + 显示 toast，无自动重置/冷却

`--flash` 刻意**不调用 `notchOpen`**，保持 notch 收起状态，匹配真实场景（编码中 notch 收起，AI 完成 → 边框闪光 + toast），toast 在收起状态下也更易读。

Seeding：`UITestSeeder.seedFlash(aiStore:)` 只 seed 一个正在工作的 Claude 会话（无媒体/日历/agent/番茄钟），使收起 notch 的主 badge 显示 Claude Code 螃蟹 + 旋转器，而非优先级更高的番茄钟/agent badge。

截图脚本 `scripts/uitest-flash-screenshot.sh`：
```bash
# 启动 NemoNotch.app --uitest --tab=claude --flash
# osascript delay
# screencapture -x <整屏截图，不裁剪>
# sips --resampleWidth 1600 docs/images/completion-flash.png
# 恢复用户已安装的 app
```

---

## 锚点（file:line）

| 锚点 | 路径 |
|------|------|
| 参数解析 | `NemoNotch/Helpers/UITestMode.swift` |
| Seeder | `NemoNotch/Helpers/UITestSeeder.swift` |
| 副作用抑制 | `NemoNotch/NemoNotchApp.swift`（`applicationDidFinishLaunching`，`if !UITestMode.isActive` 门） |
| NotchCoordinator stay-open | `NemoNotch/Notch/NotchCoordinator.swift`（`init`，跳过 `setupEventMonitoring`） |
| 捕获矩形写入 | `UITestSeeder.writeCaptureRect(for:on:)` |
| 逐 tab 截图脚本 | `scripts/uitest-screenshots.sh` |
| flash 背景板 | `NemoNotch/Helpers/UITestSeeder.swift`（`makeUITestFlashBackdrop(on:)`）或 `AppDelegate` |
| flash holdForUITest | `NemoNotch/Services/CompletionFlashService.swift`（`holdForUITest(names:)`） |
| flash 截图脚本 | `scripts/uitest-flash-screenshot.sh` |
| CompletionFlashWindow | `NemoNotch/Notch/CompletionFlashWindow.swift`（§5.10 配方） |

---

## Pitfalls

**P1：seeding appBundleIdentifier 到 KnownPlayer 触发权限卡片**
`playbackState.appBundleIdentifier` 设为 Music/Spotify 的 bundle id 时，Overview tab 渲染 Automation-permission card 而非媒体播放信息。留 `nil` 才走 MediaRemote/now-playing 路径。

**P2：两个 notch overlay 叠加**
未退出已安装 app 就启动 uitest 实例，两个 notch panel 叠加，截图包含两层 UI。脚本必须先 quit 已安装 app。

**P3：SystemService 采样器覆盖 seeded 数据**
`SystemService.update()` 有 2s 采样循环，不 early-return 的话会在截图前覆盖掉 seeded 进程列表。必须在 `UITestMode.isActive` 时 early-return。

**P4：shell sleep 与 macOS run loop 不兼容**
用 `sleep 2` 等待 app 渲染完成时，某些情况下 run loop 尚未完成布局就触发截图。改用 `osascript -e 'delay 2'`。

**P5：--flash 模式下 notchOpen 导致 toast 被遮挡**
打开 panel 后 toast 被展开的 notch content 遮住。`--flash` 路径必须跳过 `notchOpen`，让 notch 保持收起。

**P6：.screen blending 在浅色壁纸上不可见**
加法混合 `.screen` 在白色/浅色背景上接近透明。必须在闪光窗口下方（`.statusBar + 7`）放暗色背景板（`makeUITestFlashBackdrop`），不需要隐藏用户其他窗口。

---

## 落地 Checklist

- [ ] `UITestMode.swift`：纯函数 `isActive(in:)` / `tab(in:)` / `flash(in:)` + 运行时读 `ProcessInfo.processInfo.arguments`
- [ ] 单元测试覆盖纯函数（无 `--uitest` → false；有 `--uitest --tab=ai` → correct tab）
- [ ] `applicationDidFinishLaunching` 所有实时子系统放 `if !UITestMode.isActive` 门后
- [ ] `UITestSeeder`：`TaskStore` 传临时路径；专辑封面程序化生成；Agents tab 用 mock monitor
- [ ] `NotchCoordinator.init` skip `setupEventMonitoring` when uitest
- [ ] `writeCaptureRect(for:on:)` 写 `/tmp/nemonotch-uitest.rect`，shell 脚本读取
- [ ] `scripts/uitest-screenshots.sh`：quit 已安装 app → build → 逐 tab loop → restore
- [ ] `CompletionFlashService.holdForUITest(names:)`：固定 flashLevel=1，无冷却
- [ ] `makeUITestFlashBackdrop(on:)`：在 `.statusBar + 7` 放暗色窗口
- [ ] `scripts/uitest-flash-screenshot.sh`：整屏截图 + sips 缩放

---

## 延伸阅读

- [../window/](../window/) — NSPanel 窗口层级、`.statusBar + N` 层级配方（§5.10）
- [../testing/](../testing/) — 纯函数单元测试策略，`UITestMode` 的测试覆盖
- [../project-layout/](../project-layout/) — 不修改 project.pbxproj 添加源文件（auto-sync root groups）
