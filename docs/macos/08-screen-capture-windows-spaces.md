---
summary: 'Capture screens and windows with ScreenCaptureKit, fall back to CGWindowList, and manage Spaces via private CGS APIs.'
read_when:
  - 'implementing screen capture or window enumeration in a macOS app'
  - 'handling multi-monitor layouts, Retina scaling, or cross-Space window operations'
---

# 08 · 屏幕捕获 + 窗口 + Spaces

## TL;DR

macOS 提供三层捕获 API：ScreenCaptureKit（macOS 12.3+，async，权限显式）、CGWindowList/CGDisplayCreateImage（旧式同步，低版本兼容）、CGS 私有 API（Spaces 管理，无公开替代）。新项目优先用 ScreenCaptureKit；旧版 OS 或 SCK 降级时回退 CGWindowList；Spaces 窗口归属与跨桌面移动只能走 CGS 私有符号，必须评估发行渠道风险。

## Peekaboo 在哪里实现

- 模块：`PeekabooAutomationKit`（`Core/PeekabooAutomationKit/Sources/`）
- 关键文件：`Services/Capture/ScreenCaptureKitOperator+Window.swift:20` — SCK 按 app/windowID 精确捕获主路径，含显示器映射与 Retina 缩放计划
- 关键文件：`Services/Capture/ScreenCapturePlanner.swift:19` — `displayLocalSourceRect` / `matchDisplay` / `capturePixelSize`，全局坐标转显示器本地坐标及像素尺寸计算
- 关键文件：`Services/Capture/ScreenCaptureKitCaptureGate.swift:7` — SCK 跨进程互斥锁门卫，防 replayd 竞态
- 关键文件：`Utilities/SpaceCGSPrivateAPI.swift:22` — CGS 私有符号声明，`_CGSDefaultConnection`、`CGSCopySpaces`、`CGSManagedDisplaySetCurrentSpace` 等
- 关键文件：`Utilities/SpaceUtilities.swift:60` — `SpaceManagementService`，封装 Spaces 枚举、切换、窗口移动逻辑
- 相关 docs：`docs/window-screenshot-smart-select.md`、`docs/skylight-spaces-api.md`

## 设计动机（Why）

Peekaboo 需要在命令行与 Agent 运行时中精确捕获指定应用的指定窗口，同时支持多屏、Retina、多 Space 场景。ScreenCaptureKit 提供了原生 async 接口和最佳画质，但 SCK 与系统后台进程 replayd 共享连接，并发调用容易死锁；为此加了跨进程 `flock` 门卫（`ScreenCaptureKitCaptureGate`）。旧版 macOS 或 SCK 失败时回退到 `CGWindowListCopyWindowInfo` + `CGWindowCreateImage`，两条路径统一通过 `ScreenCaptureService` 的 `PEEKABOO_CAPTURE_ENGINE` 环境变量切换。Spaces 管理完全没有公开 API，只能依赖 CGS 私有符号；工具链（yabai、Rectangle 等）的通行做法亦如此，但需明确规避 App Store。

## 核心模式（Pattern）

### API 选择决策树

```
需要捕获？
├─ 屏幕/多屏区域：SCK SCStream fast-stream（fastStream 策略）
├─ 单窗口（已知 windowID 或 app）：SCK SCScreenshotManager.captureImage（singleShot 策略）
│   └─ SCK 不可用 / macOS < 12.3：CGWindowListCopyWindowInfo + CGWindowCreateImage
└─ Spaces 枚举/切换/窗口跨 Space 移动：CGS 私有 API
   （私有 API，沙盒/Mac App Store 提交不可用，需评估发行渠道）
```

环境变量 `PEEKABOO_CAPTURE_ENGINE=auto|modern|classic` 可强制路径，`auto` 时优先 SCK。

### 按 windowID 精确捕获最小骨架

```swift
// 1. 枚举可捕获内容（需 Screen Recording 权限）
let content = try await SCShareableContent.excludingDesktopWindows(
    false, onScreenWindowsOnly: false)

// 2. 匹配目标窗口
guard let win = content.windows.first(where: { $0.windowID == targetID }) else {
    throw PeekabooError.windowNotFound(criteria: "window_id \(targetID)")
}

// 3. 选择 filter 策略
let filter: SCContentFilter
if let display = resolveDisplay(for: win, displays: content.displays) {
    // 全局坐标 → 显示器本地坐标（ScreenCapturePlanner.displayLocalSourceRect）
    filter = SCContentFilter(display: display, including: [win])
} else {
    // 无法映射到显示器时使用独立 filter（多屏枚举残缺场景）
    filter = SCContentFilter(desktopIndependentWindow: win)
}

// 4. 配置像素尺寸（含 Retina 缩放）
let scale = display.backingScaleFactor // 或 filter.pointPixelScale
let config = SCStreamConfiguration()
config.captureResolution = .best
config.width  = Int(win.frame.width  * scale)
config.height = Int(win.frame.height * scale)

// 5. 单次捕获
let image = try await SCScreenshotManager.captureImage(
    contentFilter: filter, configuration: config)
```

### 多屏 / Retina 缩放处理

- `SCWindow.frame` 和 `SCDisplay.frame` 均为**全局桌面逻辑坐标**（左下角原点，非主屏中心）；传给 `SCStreamConfiguration.sourceRect` 前必须用 `ScreenCapturePlanner.displayLocalSourceRect` 减去 `display.frame.origin`。
- 像素尺寸 = 逻辑尺寸 × backing scale factor（Retina 为 2.0）；`ScreenCapturePlanner.capturePixelSize` 封装了这一换算并处理了零尺寸边界情况。
- 窗口跨越两块屏时，取**几何中心所在屏**；中心落在两屏外（极端多屏布局）时降级为 `desktopIndependentWindow` filter。

### SkyLight / CGS 私有 API 使用边界

Peekaboo 用 `@_silgen_name` 声明 `_CGSDefaultConnection`、`CGSCopySpaces`、`CGSCopySpacesForWindows`、`CGSManagedDisplaySetCurrentSpace`、`CGSAddWindowsToSpaces`、`CGSRemoveWindowsFromSpaces` 等符号。使用约束：

- 必须在 `@MainActor` 上调用（WindowServer 要求主线程连接）。
- `NSApplication.shared` 需先初始化，否则 `_CGSDefaultConnection()` 返回 0。
- **(私有 API，沙盒/Mac App Store 提交不可用，需评估发行渠道)** — 在提交 App Store 之前须移除或用公开替代（目前无等价公开 API）。

### smart-select 窗口自动识别策略

`WindowFiltering.isRenderable` 按顺序过滤：layer == 0 → alpha > 0.01 → 非 `.sharingNone` → isOnScreen → 宽 ≥ 120 && 高 ≥ 90 → 优先非空标题。多条目时按 `CGWindowID` 去重，保留最大边界框。见 `docs/window-screenshot-smart-select.md`。

## 新项目落地步骤（How to apply）

1. 在 `Package.swift` 中链接 `ScreenCaptureKit`（Deployment Target ≥ 12.3）；旧版 OS 降级路径链接 `CoreGraphics`。
2. 添加 Screen Recording 权限请求入口，保证用户在首次捕获前已授权（参考 [05 · 权限状态机](./05-permissions-state-machine.md)）。
3. 创建 `SpaceCGSPrivateAPI.swift`，用 `@_silgen_name` 声明所需 CGS 符号；标注私有 API 风险注释并在 README 中记录发行渠道约束。
4. 实现显示器映射函数（几何中心优先 → 最大交叉面积 → unmapped 降级），返回 `display` 或 `desktopIndependentWindow` 两种 filter。
5. 封装 `capturePixelSize(frame:scale:)` 换算工具，处理零尺寸和非有限值边界。
6. 用进程级互斥锁（`flock` + 临时文件）串行化 SCK 调用，防止 replayd 并发死锁。
7. 封装 `WindowFiltering.isRenderable` 过滤链，在捕获前剔除透明/不可共享/过小窗口。

## 常见陷阱（Pitfalls）

- **SCK stream 未关闭导致进程内存泄漏** — 可观测信号：进程 RSS 随时间持续增长，`lsof -p <PID>` 显示 stream fd 不释放；处理：在 `SCKStreamSession` 的 deinit 或 `stop` 路径用 `defer { try? stream.stopCapture() }` 确保资源释放；来源：`ScreenCaptureKitFrameSource+StreamSession.swift` stream 会话管理逻辑。

- **多屏全局坐标未转本地坐标** — 可观测信号：副屏截图捕获到屏幕外黑边或坐标错位，尤其左侧外接屏（frame.origin.x < 0）；处理：调用 `displayLocalSourceRect(globalRect:displayFrame:)` 减去显示器原点；来源：`ScreenCapturePlanner.swift:19`。

- **CGSDefaultConnection 返回 0 / Spaces 操作静默失败** — 可观测信号：`SpaceManagementService.getAllSpaces()` 返回空数组，日志输出 "WARNING: Failed to get CGS connection"；处理：确认在 `@MainActor` 上调用且 `NSApplication.shared` 已初始化，在非 GUI 环境（纯 CLI）中提前触发 `_ = NSApplication.shared`；来源：`SpaceUtilities.swift:69`。

- **CGWindowListCopyWindowInfo 低权限下返回空** — 可观测信号：`CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)` 返回零条目，但系统有可见窗口；处理：检查 Screen Recording 权限实际是否生效（`CGPreflightScreenCaptureAccess()` 返回 false），重新触发权限弹窗；来源：`LegacyScreenCaptureOperator+Window.swift:14`。

- **私有 API 在 App Store 审核被拒** — 可观测信号：App Review 邮件反馈"使用了非公开 API `_CGSDefaultConnection` / `CGSCopySpaces`"；处理：评估发行渠道（直发 / Notarization Only），Spaces 功能在 App Store 版本中需禁用或移除；来源：`SpaceCGSPrivateAPI.swift:22`。

## 延伸阅读

- Peekaboo：`docs/window-screenshot-smart-select.md`、`docs/skylight-spaces-api.md`
- Apple：[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)、[SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- 其它 playbook：[05 · 权限状态机](./05-permissions-state-machine.md)、[10 · Visualizer overlay](./10-visualizer-overlay.md)

---
*Last verified against Peekaboo @ `2d98e638d386f3aa63e89a54e95d058cba2b584d`*
