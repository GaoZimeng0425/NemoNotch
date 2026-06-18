---
summary: 'ScreenCaptureKit（macOS 12.3+）主路径 + CGWindowList 兜底：Retina 坐标换算、多屏匹配、跨进程 flock 互斥防 replayd 竞态。'
read_when:
  - '新建屏幕/窗口截图功能，需要兼顾性能与旧版 macOS 回退'
  - '多屏 Retina 布局下坐标换算或截图结果偏移/模糊'
  - '并发调用 SCK 出现超时或 continuation 泄漏'
sources: ['P08']
last_verified:
  peekaboo: '742eadb991eec3fdf05c5092eb97e8e43d0dabfa'
  nemonotch: 'fe4e9e5'
---

# ScreenCaptureKit 主路径 + CGWindowList 回退

## TL;DR

macOS 截图优先用 **ScreenCaptureKit**（SCK，`SCShareableContent` + `SCScreenshotManager`）；旧版系统（< 12.3）或 SCK 超时时降级到 **CGWindowList + CGWindowCreateImage**。关键注意点：

- `SCScreenshotManager`（单帧截图）最低要求 **macOS 14+**（不是 12.3，见 Pitfalls）
- `SCShareableContent.current` / `excludingDesktopWindows` 最低 **macOS 12.3+**
- 多屏坐标必须从全局桌面坐标转为 **display-local 坐标**，否则截到黑边
- 并发两个 SCK 调用会卡死 `replayd`，必须用 **flock 跨进程互斥**
- `SCStreamConfiguration.width/height` 必须填**物理像素**（逻辑点 × backing scale），否则输出模糊

## 可复用模式

### Pattern 1 · API 选择决策树

```
需要截图？
├─ macOS 12.3+
│  ├─ 持续流（录屏）→ SCStream fastStream（macOS 12.3+）
│  └─ 单帧截图
│     ├─ macOS 14+ → SCScreenshotManager.captureImage (singleShot)
│     └─ macOS 12.3–13.x → SCStream + 取第一帧 + stopCapture
│     └─ SCK 失败 → 降级到 CGWindowList + CGWindowCreateImage
└─ macOS < 12.3 → CGWindowList + CGWindowCreateImage
```

环境变量强制路径：`PEEKABOO_CAPTURE_ENGINE=auto|modern|sckit|classic|cg`（优先）或 `PEEKABOO_USE_MODERN_CAPTURE=true/false`（兼容旧名）。

来源：`Services/Capture/ScreenCaptureService.swift:41`

---

### Pattern 2 · 按 windowID 精确捕获（SCK 主路径，macOS 14+）

```swift
// 骨架来自 ScreenCaptureKitOperator+Window.swift:20
let content = try await SCShareableContent.excludingDesktopWindows(
    false, onScreenWindowsOnly: false)                     // macOS 12.3+

guard let win = content.windows.first(where: { $0.windowID == targetID }) else {
    throw PeekabooError.windowNotFound(criteria: "window_id \(targetID)")
}

// resolveDisplayForWindow: 几何中心 → 最大交叉面积 → unmapped fallback
let resolution = resolveDisplayForWindow(win, displays: content.displays)
let targetDisplay = resolution?.display ?? content.displays[0]
let isMapped = resolution?.isMapped ?? false

let config = SCStreamConfiguration()
config.captureResolution = .best
config.showsCursor = false

let filter: SCContentFilter
if isMapped {
    filter = SCContentFilter(display: targetDisplay, including: [win])
    // 全局坐标 → display-local 坐标（必须减去 display.origin）
    config.sourceRect = displayLocalSourceRect(
        globalRect: win.frame, displayFrame: targetDisplay.frame)
    let scale = backingScaleFactor(for: targetDisplay.displayID)
    let px = capturePixelSize(for: win.frame, scale: scale)
    config.width = px.width; config.height = px.height
} else {
    // 无法映射 → desktop-independent filter（不抛错，保证多屏极端布局下可捕获）
    filter = SCContentFilter(desktopIndependentWindow: win)
    let filterScale = CGFloat(filter.pointPixelScale)
    let px = capturePixelSize(for: filter.contentRect, fallbackFrame: win.frame, scale: filterScale)
    config.width = px.width; config.height = px.height
}

// macOS 14+ 单帧 API
let image = try await SCScreenshotManager.captureImage(
    contentFilter: filter, configuration: config)
```

---

### Pattern 3 · 全局 → display-local 坐标换算（必做）

`SCWindow.frame` 和 `SCDisplay.frame` 都在全局桌面坐标系（左上角原点）。传给 `SCStreamConfiguration.sourceRect` **必须**减去显示器原点：

```swift
// ScreenCapturePlanner.swift:19
static func displayLocalSourceRect(globalRect: CGRect, displayFrame: CGRect) -> CGRect {
    globalRect.offsetBy(dx: -displayFrame.origin.x, dy: -displayFrame.origin.y)
}
```

左侧外接屏的 `displayFrame.origin.x` 可为负值（如 `-2560.0`）——直接用全局坐标会截到黑边。

---

### Pattern 4 · Retina/HiDPI 物理像素换算

`SCWindow.frame` 是**逻辑点**，物理像素 = 逻辑点 × backing scale factor（Retina 通常 2.0）：

```swift
// ScreenCapturePlanner.swift:23-52
static func capturePixelSize(for frame: CGRect, fallbackFrame: CGRect? = nil, scale: CGFloat) -> (width: Int, height: Int) {
    let src = isUsableCaptureSizeFrame(frame) ? frame : (fallbackFrame ?? .zero)
    let w = max(Int(src.width * scale), 1)
    let h = max(Int(src.height * scale), 1)
    return (width: w, height: h)
}
```

获取 backing scale factor 三种方式（按可靠性排序）：

```swift
// 1. 通过 CGDisplayCopyDisplayMode（推荐，可缓存，不需要 MainActor）
let mode = CGDisplayCopyDisplayMode(displayID)!
let scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)

// 2. 通过 desktopIndependentWindow filter（不依赖 display 枚举，该窗口实际所在屏）
let scale = CGFloat(filter.pointPixelScale)

// 3. 通过 NSScreen（仅 MainActor/GUI 环境，有时与 SCDisplay 不一致）
let scale = NSScreen.screens.first(where: { $0.displayID == targetDisplayID })?.backingScaleFactor ?? 2.0
```

---

### Pattern 5 · 多屏匹配策略（三级降级）

```swift
// ScreenCapturePlanner.swift:85 — matchDisplay 三级策略
// 1. 窗口几何中心所在屏 → mapped
// 2. 与窗口交叉面积最大的屏 → mapped
// 3. 没有任何显示器包含/交叉 → unmapped（主屏 origin==.zero 优先作为 fallback）
//
// unmapped 时用 SCContentFilter(desktopIndependentWindow:) 而非抛错

func matchDisplay(windowFrame: CGRect, displayFrames: [CGRect]) -> DisplayMatch {
    guard !displayFrames.isEmpty else { return .noDisplays }
    let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
    if let idx = displayFrames.firstIndex(where: { $0.contains(center) }) { return .mapped(idx) }
    var bestIdx: Int?; var bestArea: CGFloat = 0
    for (idx, frame) in displayFrames.enumerated() {
        let area = frame.intersection(windowFrame).area
        if area > bestArea { bestArea = area; bestIdx = idx }
    }
    if let idx = bestIdx { return .mapped(idx) }
    let fallback = displayFrames.firstIndex(where: { $0.origin == .zero }) ?? 0
    return .unmapped(fallbackDisplayIndex: fallback)
}
```

---

### Pattern 6 · 跨进程 flock 互斥防 replayd 竞态

两个 SCK 调用并发会使 `replayd` 的事件队列竞态，`SCScreenshotManager.captureImage` continuation 永久挂起。用两层锁解决：

```swift
// ScreenCaptureKitCaptureGate.swift:7 — 双层互斥
// 层 1：进程内 @MainActor bool flag
while Self.isCaptureActive { await Task.sleep(10ms) }
Self.isCaptureActive = true
defer { Self.isCaptureActive = false }

// 层 2：跨进程 flock
let fd = open("/tmp/myapp.sckit-capture.lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
while flock(fd, LOCK_EX | LOCK_NB) != 0 { await Task.sleep(10ms) }
defer { flock(fd, LOCK_UN); close(fd) }

// 完成后 sleep 100ms 让 replayd 内部状态归位
try? await Task.sleep(nanoseconds: 100_000_000)
```

还有操作级互斥（`sckit-operation.lock`）包裹 `shareableContent + captureImage` 组合调用，防止交叉读写卡死 SCK。

---

### Pattern 7 · CGWindowList 兜底路径（macOS < 12.3 或 SCK 失败）

```swift
// LegacyScreenCaptureOperator+Window.swift:14
// .optionAll 包含所有窗口（含非前台），避免 Electron 多进程偶发空列表
// .excludeDesktopElements 过滤桌面图标等噪声
let list = CGWindowListCopyWindowInfo(
    [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

// CGWindowCreateImageFromArray 在 macOS 14.0 被弃用，但仍可用
return CGWindowListCreateImage(
    .null, .optionIncludingWindow, windowID,
    [.boundsIgnoreFraming, .nominalResolution])
```

注意：`CGWindowListCopyWindowInfo` 在低 Screen Recording 权限下静默返回空数组——难以诊断，推荐先用 `CGPreflightScreenCaptureAccess()` 预检。

---

### Pattern 8 · smart-select 窗口过滤链（多窗口精确匹配）

`WindowFiltering.isRenderable` 按优先级过滤（`LegacyScreenCaptureOperator+Window.swift:14`）：

1. `layer == 0`（普通 app 窗口，排除 panel/HUD/menubar extra）
2. `alpha > 0.01`（排除全透明覆盖层）
3. `sharingState != .none`（排除 `NSWindow.sharingType == .none` 的系统气泡）
4. `isOnScreen == true`（排除最小化/离屏窗口）
5. `width >= 120 && height >= 90`（排除 tooltip/1px 边框）
6. 优先非空标题，按 `CGWindowID` 去重保留最大边界框

---

### Pattern 9 · 非原生环境特殊处理

**Electron（VSCode / Slack / Discord）**：多进程时序竞态，`CGWindowListCopyWindowInfo` 可能返回空。改用 `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)`（`replayd` 维护稳定列表）；必须用 CGWindowList 时加 20ms 重试。

**全屏 Space**：全屏 app 创建独立 `CGSSpaceType == kCGSSpaceFullscreen(1)` 的 Space。overlay 窗口需加 `.fullScreenAuxiliary`；截图可直接用 `SCContentFilter(desktopIndependentWindow:)` 跨 Space 捕获，无需切换 Space。

**混合分辨率多屏**：每块 `SCDisplay` 独立获取 backing scale factor（`CGDisplayCopyDisplayMode`），不用全局固定 `2.0`；`desktopIndependentWindow` filter 的 `pointPixelScale` 是该窗口实际所在屏的 scale，更准确。

**Sidecar（iPad 作副屏）**：SCK 截图正常工作；CGS Spaces API 对 Sidecar 显示器 ID 静默失败甚至崩溃，跳过 Sidecar 设备（`CGDisplayIsBuiltin == false`）的 Spaces 操作。

## 锚点（file:line）

| 符号 / 文件 | 位置 | 说明 |
|---|---|---|
| `ScreenCaptureKitOperator+Window` | `Services/Capture/ScreenCaptureKitOperator+Window.swift:20` | SCK 按 windowID 精确捕获主路径 |
| `ScreenCapturePlanner.displayLocalSourceRect` | `Services/Capture/ScreenCapturePlanner.swift:19` | 全局→本地坐标换算 |
| `ScreenCapturePlanner.capturePixelSize` | `Services/Capture/ScreenCapturePlanner.swift:23` | Retina 物理像素尺寸 |
| `ScreenCapturePlanner.matchDisplay` | `Services/Capture/ScreenCapturePlanner.swift:85` | 多屏三级匹配策略 |
| `ScreenCaptureKitCaptureGate` | `Services/Capture/ScreenCaptureKitCaptureGate.swift:7` | 双层 flock 互斥防 replayd 竞态 |
| `LegacyScreenCaptureOperator+Window` | `Services/Capture/LegacyScreenCaptureOperator+Window.swift:14` | CGWindowList 兜底路径 |
| `ScreenCaptureService` | `Services/Capture/ScreenCaptureService.swift:41` | 统一入口，环境变量切换引擎 |
| `ScreenCaptureKitOperator+Support.resolveDisplayForWindow` | `Services/Capture/ScreenCaptureKitOperator+Support.swift:81` | 多屏映射，返回 `(display, isMapped)` |

## Pitfalls

- **⚠️ 版本门槛勘误**：`SCScreenshotManager`（单帧截图 API）最低要求 **macOS 14+**，不是 12.3+。12.3–13.x 上只有 `SCStream`（需要取第一帧后 `stopCapture`）；Apple 文档中 `SCScreenshotManager` 明确标注 macOS 14.0+（[Apple Docs](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)）。源文件 08:829 的标注是正确的；08:12 TL;DR 中的"macOS 12.3+"写的是整个 SCK 框架的门槛，但被误读为 `SCScreenshotManager` 的门槛——这是**曾有的错误表述**，已在本文修正。`SCShareableContent.current` / `SCShareableContent.excludingDesktopWindows` 的门槛确实是 12.3+。

- **SCK stream 未关闭 → 内存泄漏**：进程 RSS 持续增长，`lsof -p <PID>` 显示 fd 数量不断增加。必须在 deinit 或完成 handler 中 `defer { try? stream.stopCapture() }`。

- **多屏全局坐标未转本地 → 黑边/坐标错位**：副屏（尤其布局在主屏左侧，`frame.origin.x < 0`）截图出现大面积黑边。必须调 `displayLocalSourceRect`。

- **`desktopIndependentWindow` filter 的 `contentRect` 为空 → 参数错误崩溃**：加 fallback：`if filter.contentRect.isEmpty { use window.frame }`（`ScreenCaptureKitOperator+Window.swift:268`）。

- **Retina backing scale 漏算 → 截图模糊**：截图尺寸是预期一半（1440×900 而非 2880×1800）。`SCStreamConfiguration.width/height` 必须填物理像素，通过 `CGDisplayCopyDisplayMode` 获取 scale，不要固定 `2.0`。

- **并发两个 SCK 调用 → replayd 卡死**：一个调用永远不返回，或收到权限错误（TCC 已授权）。用 flock 串行化所有 SCK 调用，释放锁后 sleep 100ms。

- **`CGWindowListCopyWindowInfo` 低权限下返回空**：先检查 `CGPreflightScreenCaptureAccess()`，重新触发 `CGRequestScreenCaptureAccess()`。

- **`CGWindowCreateImage` 在 macOS 14 被弃用**：API 仍可用，但会产生编译警告。纯新项目 deploy target ≥ 14 可直接用 SCK，不用写兜底路径。

## 落地 checklist

- [ ] 确认 Deployment Target：SCK（`SCShareableContent`）需 ≥ 12.3；`SCScreenshotManager` 单帧 API 需 ≥ **14.0**
- [ ] `Package.swift` 或 Xcode target 链接 `ScreenCaptureKit`；CGWindowList 路径依赖 `CoreGraphics`（默认已链接）
- [ ] Hardened Runtime entitlements 添加 `com.apple.security.screen-recording`
- [ ] 调用前用 `CGPreflightScreenCaptureAccess()` 预检，`CGRequestScreenCaptureAccess()` 触发弹窗（首次）
- [ ] 实现 `displayLocalSourceRect`（全局坐标减去 `display.frame.origin`）
- [ ] 实现 `capturePixelSize`（逻辑点 × scale，零尺寸返回 `(1,1)`）
- [ ] 实现三级 `matchDisplay`（几何中心 → 最大交叉面积 → unmapped fallback）
- [ ] `unmapped` 时用 `desktopIndependentWindow` filter，加 `contentRect.isEmpty` fallback
- [ ] 实现 flock 互斥（进程内 flag + 跨进程 flock），锁文件用 app bundle ID 前缀，完成后 sleep 100ms
- [ ] 实现 smart-select 过滤链（layer 0 → alpha → onScreen → 尺寸 → 标题）
- [ ] 评估私有 API 发行渠道（CGS Spaces 不可进 Mac App Store）
- [ ] 添加 `PEEKABOO_CAPTURE_ENGINE` 等价环境变量，`classic` 模式用于 CI 无权限环境

## 延伸阅读

- [窗口枚举与 Spaces 私有 API](./windows-and-spaces.md) — CGWindowList 完整枚举 + CGS 私有符号
- [../permissions/](../permissions/) — Screen Recording TCC 状态机、权限卡片 UI 模式
- [../private-api/](../private-api/) — `@_silgen_name` 动态绑定私有符号通用模式
- [../window/](../window/) — NSPanel 多屏定位、fullScreenAuxiliary
- Peekaboo 参考文档：`docs/window-screenshot-smart-select.md`、`docs/skylight-spaces-api.md`
- Apple：[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- Apple：[SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)（**macOS 14+**）
- WWDC 2022：[Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/)
- WWDC 2023：[What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/)
