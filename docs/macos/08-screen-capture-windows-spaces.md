---
summary: 'Capture screens with ScreenCaptureKit primary path and CGWindowList fallback, with SkyLight CGS for Spaces enumeration (private API risk noted).'
read_when:
  - 'building a screen-capture or window-snapshot feature that handles Retina and multi-display'
  - 'enumerating windows or switching Spaces with private CoreGraphics symbols'
---

# 08 · 屏幕捕获 + 窗口 + Spaces

## TL;DR

macOS 提供三层捕获 API，按优先级依次为：**ScreenCaptureKit**（macOS 12.3+，async/await，TCC 权限显式、性能最佳）、**CGWindowList + CGWindowCreateImage**（同步，旧版系统或 SCK 失败时兜底）、**SkyLight CGS 私有 API**（Spaces 管理，无任何公开等价物，⚠️ 沙盒/MAS 不可用）。Retina 屏幕必须区分"逻辑点"和"物理像素"，`SCWindow.frame` 和 `SCDisplay.frame` 均为全局桌面逻辑坐标，传给 `SCStreamConfiguration.sourceRect` 前必须减去显示器原点；输出像素尺寸 = 逻辑尺寸 × backing scale factor。多屏布局中，窗口几何中心所在屏决定使用哪个 `SCContentFilter`；无法映射时降级到 `desktopIndependentWindow` filter。SCK 调用与系统后台进程 `replayd` 共享连接，同一时刻两个 `SCStream` 实例并发会导致 continuation 泄漏或超时；Peekaboo 用 `flock` 跨进程互斥文件锁（`ScreenCaptureKitCaptureGate`）串行化所有 SCK 调用。CGS 私有符号通过 `@_silgen_name` 声明，运行时动态绑定，无需链接私有 framework，但沙盒/MAS 审核仍会被拒——每处使用均需标注风险，并在发行前评估渠道。

## Peekaboo 在哪里实现

- 模块：`PeekabooAutomationKit`（`Core/PeekabooAutomationKit/Sources/`）
- 关键文件：`Services/Capture/ScreenCaptureKitOperator+Window.swift:20` — SCK 按 app/windowID 精确捕获主路径，含 `resolveDisplayForWindow` 显示器映射、`captureWindowImage` 重试包装、`windowMetadata` 输出封装
- 关键文件：`Services/Capture/ScreenCapturePlanner.swift:19` — `displayLocalSourceRect` 全局→本地坐标、`matchDisplay` 几何中心优先匹配算法、`capturePixelSize` Retina 像素尺寸换算（含零尺寸防护）
- 关键文件：`Services/Capture/ScreenCaptureKitCaptureGate.swift:7` — 双层 `flock` 互斥门卫：进程内 `isCaptureActive` flag + 跨进程 `/tmp/boo.peekaboo.sckit-*.lock` 文件锁，防 `replayd` 竞态；带 3 s / 5 s 超时竞赛
- 关键文件：`Services/Capture/LegacyScreenCaptureOperator+Window.swift:14` — `CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], …)` 兜底路径，含 `firstRenderableWindowIndex` smart-select 过滤
- 关键文件：`Utilities/SpaceCGSPrivateAPI.swift:22` — `@_silgen_name` 声明 `_CGSDefaultConnection`、`CGSCopySpaces`、`CGSCopySpacesForWindows`、`CGSManagedDisplaySetCurrentSpace`、`CGSAddWindowsToSpaces`、`CGSRemoveWindowsFromSpaces` 等 ⚠️ 私有符号
- 关键文件：`Utilities/SpaceUtilities.swift:60` — `SpaceManagementService`：封装 Spaces 枚举、切换（`switchToSpace`）、窗口跨 Space 移动（`moveWindowToSpace`）完整逻辑；`SpaceUtilities.swift:69` 中 `_CGSDefaultConnection()` 返回 0 时打印 WARNING
- 关键文件：`Services/Capture/ScreenCaptureKitOperator+Support.swift:81` — `resolveDisplayForWindow` 返回 `(display, isMapped)` 元组，多屏部分枚举时仍给 fallback display 保证元数据完整
- 关键文件：`Services/Capture/ScreenCaptureService.swift:41` — `ScreenCaptureService`：通过 `PEEKABOO_CAPTURE_ENGINE=auto|modern|classic` 环境变量切换引擎，统一调用入口
- 相关 docs：`docs/window-screenshot-smart-select.md`、`docs/skylight-spaces-api.md`

## 设计动机（Why）

### 为什么 SCK 优先

ScreenCaptureKit 相比旧式 CoreGraphics 方案有三个核心优势：

1. **性能与帧率**：SCK 内部走 Metal 共享内存，支持 `fastStream`（屏幕/多屏模式）和 `singleShot`（`SCScreenshotManager.captureImage`，窗口/区域模式），延迟在 20–150 ms；`CGWindowCreateImage` 在大分辨率 Retina 下可达 500 ms+。
2. **TCC 友好**：SCK 的 Screen Recording 权限在系统 TCC 数据库中有明确条目，第一次调用会触发系统权限弹窗，用户授权后持久生效；`CGWindowListCopyWindowInfo` 在低权限下静默返回空数组，诊断困难。
3. **async/await 原生**：SCK 的 `SCShareableContent.excludingDesktopWindows` 和 `SCScreenshotManager.captureImage` 均为 async，天然适配 Swift 6 的结构化并发模型，避免回调地狱。

### 何时回退 CGWindowList

- macOS < 12.3（SCK 不可用）
- 环境变量 `PEEKABOO_CAPTURE_ENGINE=classic` 或 `cg` 强制指定
- SCK 调用在 3 s 超时后仍失败，且调用方允许降级（`PEEKABOO_USE_MODERN_CAPTURE=false`）
- 仅需窗口元数据（PID、bounds、title）而不需要截图像素：`CGWindowListCopyWindowInfo` 开销极低

### 为什么 SkyLight 私有 API 不可避免

macOS 没有任何公开 API 可以：枚举所有 Spaces 的 ID、查询窗口所在 Space、切换 Space、在 Spaces 之间移动窗口。`NSWorkspace` 和 `NSScreen` 都不提供这些接口。yabai、Amethyst、Rectangle、Scapple 等工具都依赖相同的 `CGSCopySpaces` / `CGSManagedDisplaySetCurrentSpace` 符号链。Peekaboo 通过 `@_silgen_name` 在运行时动态绑定（不需要 `import` 私有 framework），出错时返回 0 或空数组，失败安全，但⚠️ **沙盒/MAS 不可用**：MAS 审核脚本会静态扫描私有 C 符号，提交必然被拒——发行前须移除或编译条件隔离。

### ReplayD 进程级竞态

`replayd`（Screen Capture Relay Daemon）是系统级服务，所有 SCK 流共享它的 XPC 连接。当两个 `peekaboo` CLI 进程同时创建 `SCStream` 或调用 `SCShareableContent`，`replayd` 的事件队列会形成竞态，表现为：
- `SCStreamDelegate.stream(_:didStopWithError:)` 在未完成第一帧前就触发
- `SCScreenshotManager.captureImage` 的 continuation 永久挂起（内存泄漏）
- 第二个调用收到权限错误，即使 TCC 已授权

`ScreenCaptureKitCaptureGate` 用两层锁解决：进程内串行（`@MainActor isCaptureActive`）+ 跨进程 `flock`（`/tmp/boo.peekaboo.sckit-capture.lock`）。完成后额外 sleep 100 ms 让 `replayd` 内部状态归位。

## 核心模式（Pattern）

### Pattern 1 · API 选择决策树

```
需要捕获或 Spaces 操作？
├─ 屏幕/多屏区域 → SCK SCStream fastStream（ScreenCapturePlanner.frameSourcePolicy → .fastStream）
├─ 单窗口（已知 windowID 或 app）→ SCK SCScreenshotManager.captureImage（singleShot）
│   └─ SCK 不可用 / macOS < 12.3 → CGWindowListCopyWindowInfo + CGWindowCreateImage
│   └─ 窗口 ID 已知但显示器枚举残缺 → SCContentFilter(desktopIndependentWindow:)
└─ Spaces 枚举/切换/窗口跨 Space 移动
   → CGS 私有 API（SpaceCGSPrivateAPI.swift）
   ⚠️ 私有 API — 沙盒/Mac App Store 不可用，需评估发行渠道
```

环境变量 `PEEKABOO_CAPTURE_ENGINE=auto|modern|sckit|classic|cg`（优先）或 `PEEKABOO_USE_MODERN_CAPTURE=true/false`（兼容旧名）可强制路径。

### Pattern 2 · 按 windowID 精确捕获（SCK 主路径）

```swift
// ScreenCaptureKitOperator+Window.swift:20 的核心逻辑骨架
let content = try await SCShareableContent.excludingDesktopWindows(
    false, onScreenWindowsOnly: false)

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
    // display-bound filter: 需要 display-local sourceRect
    filter = SCContentFilter(display: targetDisplay, including: [win])
    config.sourceRect = ScreenCapturePlanner.displayLocalSourceRect(
        globalRect: win.frame,
        displayFrame: targetDisplay.frame)           // ← 减去 display.origin
    let scale = ScreenCaptureScaleResolver.plan(…).nativeScale
    let px = ScreenCapturePlanner.capturePixelSize(for: win.frame, scale: scale)
    config.width = px.width; config.height = px.height
} else {
    // 无法映射到任何显示器 → desktop-independent filter
    filter = SCContentFilter(desktopIndependentWindow: win)
    let filterScale = CGFloat(filter.pointPixelScale)
    let px = ScreenCapturePlanner.capturePixelSize(
        for: filter.contentRect, fallbackFrame: win.frame, scale: filterScale)
    config.width = px.width; config.height = px.height
}

// withExclusiveCaptureOperation 包含进程内 + 跨进程 flock 互斥
let image = try await ScreenCaptureKitCaptureGate.captureImage(
    contentFilter: filter, configuration: config)
```

### Pattern 3 · 多屏坐标：全局 → 本地（必做）

`SCWindow.frame` 和 `SCDisplay.frame` 都在**全局桌面坐标系**（左上角原点，非主屏中心）。传给 `SCStreamConfiguration.sourceRect` 前必须减去显示器原点：

```swift
// ScreenCapturePlanner.swift:19
public static func displayLocalSourceRect(globalRect: CGRect, displayFrame: CGRect) -> CGRect {
    globalRect.offsetBy(dx: -displayFrame.origin.x, dy: -displayFrame.origin.y)
}
```

左侧外接屏的 `displayFrame.origin.x` 可为负值（如 `-2560.0`）；直接用全局坐标会导致截到黑边或空白区域。

### Pattern 4 · smart-select 窗口过滤链

`WindowFiltering.isRenderable` 按优先级过滤（见 `docs/window-screenshot-smart-select.md`）：

1. `layer == 0`（普通 app 窗口，排除 panel / HUD / menubar extra）
2. `alpha > 0.01`（排除全透明覆盖层）
3. `sharingState != .none`（排除 `NSWindow.sharingType == .none` 的系统气泡）
4. `isOnScreen == true`（排除最小化/离屏窗口）
5. `width >= 120 && height >= 90`（排除 tooltip / 1px 边框）
6. 优先非空标题（多窗口时保留最佳候选）

多条目时按 `CGWindowID` 去重，保留最大边界框的那条（同 Chromium/WebRTC `only_zero_layer` 策略）。

### Pattern 5 · Retina/HiDPI：像素 vs 逻辑点换算

SCK 的 `SCWindow.frame` 是**逻辑点**（point），物理像素 = 逻辑点 × `backingScaleFactor`（Retina 通常为 2.0）。如果 `config.width/height` 用逻辑点而非像素，输出图像会被 SCK 内部 upscale，看起来模糊（实际只有 1× 分辨率）：

```swift
// ScreenCapturePlanner.swift:23-52
public static func capturePixelSize(
    for frame: CGRect, fallbackFrame: CGRect? = nil, scale: CGFloat
) -> (width: Int, height: Int) {
    let src = isUsableCaptureSizeFrame(frame) ? frame : (fallbackFrame ?? .zero)
    let w = max(Int(src.width * scale), 1)
    let h = max(Int(src.height * scale), 1)
    return (width: w, height: h)
}
```

获取 backing scale factor 的三种方式（按可靠性排序）：

```swift
// 1. 通过 SCDisplay → ScreenCaptureScaleResolver（推荐，缓存 CGDisplayCopyDisplayMode）
let scale = ScreenCaptureScaleResolver.plan(preference: .native, displayID: display.displayID, …).nativeScale

// 2. 通过 desktopIndependentWindow filter（不依赖 display 枚举）
let scale = CGFloat(filter.pointPixelScale)   // SCContentFilter.pointPixelScale

// 3. 通过 NSScreen（仅 MainActor/GUI 环境）
let scale = NSScreen.screens.first(where: { $0.displayID == targetDisplayID })?.backingScaleFactor ?? 2.0
```

### Pattern 6 · 多屏跨越降级

`ScreenCapturePlanner.matchDisplay` 的三级策略（`ScreenCapturePlanner.swift:85`）：

1. 窗口几何中心所在屏 → `mapped(displayIndex:)`
2. 与窗口交叉面积最大的屏 → `mapped(displayIndex:)`
3. 没有任何显示器包含/交叉（退化 frame / 枚举残缺 / 多屏极端布局）→ `unmapped(fallbackDisplayIndex:)`，主屏（`origin == .zero`）优先作为 fallback

`unmapped` 时使用 `SCContentFilter(desktopIndependentWindow:)` 而非抛错，保证多屏布局下仍可捕获。

### Pattern 7 · 跨进程 flock 互斥防 replayd 竞态

`ScreenCaptureKitCaptureGate.swift:7` 实现双层互斥：

```swift
// 层 1：进程内 @MainActor bool flag，防止同一进程内并发
while Self.isCaptureActive { await Task.sleep(10ms) }
Self.isCaptureActive = true
defer { Self.isCaptureActive = false }

// 层 2：跨进程 flock，防止多个 peekaboo CLI 并发
let fd = open("/tmp/boo.peekaboo.sckit-capture.lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
while flock(fd, LOCK_EX | LOCK_NB) != 0 { await Task.sleep(10ms) }
defer { flock(fd, LOCK_UN); close(fd) }

// 结束后 sleep 100ms 让 replayd 内部状态归位
```

另有操作级互斥（`boo.peekaboo.sckit-operation.lock`）包裹 `shareableContent` + `captureImage` 的组合调用，防止交叉读写让 SCK 卡住。

### Pattern 8 · CGS 私有 API：Space 管理（⚠️ 沙盒/MAS 不可用）

```swift
// SpaceCGSPrivateAPI.swift:22 — 全部通过 @_silgen_name 动态绑定，不链接私有 framework
// ⚠️ 私有 API — 沙盒/Mac App Store 不可用，仅限直发或 Notarization Only 渠道
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> CGSConnectionID         // 主线程 WindowServer 连接

@_silgen_name("CGSCopySpaces")
func CGSCopySpaces(_ cid: CGSConnectionID, _ mask: Int) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ windowIDs: CFArray) -> CFArray?

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)

@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)
```

使用约束（来自 `SpaceUtilities.swift:60`）：
- 必须在 `@MainActor` 上调用（WindowServer 要求主线程连接）
- `NSApplication.shared` 需先初始化，否则 `_CGSDefaultConnection()` 返回 0
- 返回 0 或 `nil` 时静默失败——调用前检查连接 ID 是否非零

## 完整代码示例（Starter Code）

> **运行要求**：macOS 14+，Screen Recording 权限，entitlements 中添加 `com.apple.security.screen-recording`（Hardened Runtime 时必须）。`SpaceManager` 中的 CGS 符号⚠️**沙盒/MAS 不可用**。

```swift
// ScreenCaptureStarterKit.swift
// macOS 14+  |  ScreenCaptureKit  |  Hardened Runtime entitlement: com.apple.security.screen-recording
// SpaceManager 中的 CGS 私有 API：⚠️ 沙盒/Mac App Store 不可用，仅限直发/Notarization Only 渠道

import AppKit
import CoreGraphics
import Darwin   // flock, open, close
import Foundation
import ScreenCaptureKit

// MARK: - Capture Target

enum CaptureTarget {
    case display(SCDisplay)
    case window(SCWindow)
    case region(CGRect, SCDisplay)   // 区域截图，坐标为全局桌面坐标
}

// MARK: - Capture Errors

enum CaptureError: Error, LocalizedError {
    case noDisplays
    case windowNotFound(CGWindowID)
    case permissionDenied
    case timeout(String)
    case cgImageConversionFailed
    case invalidFrame(CGRect)

    var errorDescription: String? {
        switch self {
        case .noDisplays:              return "No displays available for capture"
        case .windowNotFound(let id):  return "Window \(id) not found in shareable content"
        case .permissionDenied:        return "Screen Recording permission not granted"
        case .timeout(let op):         return "SCK operation timed out: \(op)"
        case .cgImageConversionFailed: return "Failed to convert captured image to CGImage"
        case .invalidFrame(let f):     return "Invalid capture frame: \(f)"
        }
    }
}

// MARK: - Retina / HiDPI Utilities

enum RetinaUtilities {
    /// 将全局逻辑坐标矩形转为 display-local 坐标（SCStreamConfiguration.sourceRect 要求）
    /// 来自 ScreenCapturePlanner.displayLocalSourceRect（ScreenCapturePlanner.swift:19）
    static func displayLocalSourceRect(globalRect: CGRect, displayFrame: CGRect) -> CGRect {
        globalRect.offsetBy(dx: -displayFrame.origin.x, dy: -displayFrame.origin.y)
    }

    /// 计算捕获所需的物理像素尺寸
    /// 来自 ScreenCapturePlanner.capturePixelSize（ScreenCapturePlanner.swift:23）
    static func pixelSize(forPoints frame: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        guard frame.isFinite, !frame.isEmpty, frame.width > 0, frame.height > 0 else {
            return (1, 1)
        }
        return (
            width:  max(Int(frame.width  * scale), 1),
            height: max(Int(frame.height * scale), 1)
        )
    }

    /// 通过 CGDisplayCopyDisplayMode 获取 backing scale factor
    static func backingScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 2.0 }
        let pixelW = CGFloat(mode.pixelWidth)
        let logicalW = CGFloat(mode.width)
        guard logicalW > 0 else { return 2.0 }
        let scale = pixelW / logicalW
        return scale.isFinite && scale > 0 ? scale : 2.0
    }
}

// MARK: - Cross-Process flock Mutex
// 来自 ScreenCaptureKitCaptureGate.swift:7

struct ScreenCaptureLock {
    private static let lockPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("myapp.sckit-capture.lock")

    /// 持有 flock 期间执行 body；防止多个进程同时访问 replayd
    static func withLock<T>(_ body: () async throws -> T) async throws -> T {
        let fd = open(Self.lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return try await body() }   // 锁文件创建失败时不阻塞业务
        defer { close(fd) }

        // 非阻塞尝试，失败则 sleep 重试（Task.sleep 让出 cooperative thread）
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                return try await body()  // 意外错误不阻塞
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        }
        defer { flock(fd, LOCK_UN) }

        let result = try await body()
        // replayd 状态归位缓冲
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
        return result
    }
}

// MARK: - Display Matching
// 多屏匹配策略，来自 ScreenCapturePlanner.matchDisplay（ScreenCapturePlanner.swift:85）

enum DisplayMatch {
    case mapped(Int)          // 找到对应 display，返回 index
    case unmapped(Int)        // 找不到，返回 fallback index（主屏优先）
    case noDisplays
}

func matchDisplay(windowFrame: CGRect, displayFrames: [CGRect]) -> DisplayMatch {
    guard !displayFrames.isEmpty else { return .noDisplays }
    let usable = !windowFrame.isNull && !windowFrame.isEmpty

    if usable {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let idx = displayFrames.firstIndex(where: { $0.contains(center) }) {
            return .mapped(idx)
        }
        var bestIdx: Int?; var bestArea: CGFloat = 0
        for (idx, frame) in displayFrames.enumerated() {
            let intersection = frame.intersection(windowFrame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea { bestArea = area; bestIdx = idx }
        }
        if let idx = bestIdx { return .mapped(idx) }
    }
    // 主屏（origin == zero）作为 fallback
    let fallback = displayFrames.firstIndex(where: { $0.origin == .zero }) ?? 0
    return .unmapped(fallbackDisplayIndex: fallback)
}

// MARK: - Legacy Capture (CGWindowList fallback)
// 来自 LegacyScreenCaptureOperator+Window.swift:14

enum LegacyCapture {
    /// CGWindowList + CGWindowCreateImage 兜底截图（macOS < 12.3 或 SCK 失败时）
    static func captureWindow(windowID: CGWindowID) -> CGImage? {
        // .optionAll 包含所有窗口（含非前台），避免 Electron 多进程偶发空列表
        // .excludeDesktopElements 过滤桌面图标等噪声
        let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] ?? []

        guard list.contains(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }) else {
            return nil
        }
        // CGWindowCreateImageFromArray 已在 macOS 14.0 弃用，但仍可用
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution])
    }

    /// 枚举指定 PID 的所有窗口，按 smart-select 规则过滤
    static func listWindows(pid: pid_t) -> [[String: Any]] {
        let all = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] ?? []

        return all.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid else { return false }
            // smart-select 过滤：layer 0 + alpha > 0.01 + on-screen
            let layer    = info[kCGWindowLayer     as String] as? Int  ?? 1
            let alpha    = info[kCGWindowAlpha     as String] as? Double ?? 0
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            // 尺寸过滤
            var width: CGFloat = 0; var height: CGFloat = 0
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] {
                width  = bounds["Width"]  ?? 0
                height = bounds["Height"] ?? 0
            }
            return layer == 0 && alpha > 0.01 && onScreen && width >= 120 && height >= 90
        }
    }
}

// MARK: - Main Capture Service

actor ScreenCaptureService {

    // MARK: Capture Display

    func captureDisplay(_ display: SCDisplay, scale: CGFloat? = nil) async throws -> CGImage {
        try await ScreenCaptureLock.withLock {
            let effectiveScale = scale ?? RetinaUtilities.backingScaleFactor(for: display.displayID)

            let config = SCStreamConfiguration()
            config.captureResolution = .best
            config.showsCursor = false
            let px = RetinaUtilities.pixelSize(forPoints: display.frame, scale: effectiveScale)
            config.width  = px.width
            config.height = px.height

            let filter = SCContentFilter(display: display, excludingWindows: [])
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        }
    }

    // MARK: Capture Window (SCK 主路径)

    func captureWindow(_ window: SCWindow, displays: [SCDisplay]) async throws -> CGImage {
        try await ScreenCaptureLock.withLock {
            let config = SCStreamConfiguration()
            config.captureResolution = .best
            config.showsCursor = false

            let displayFrames = displays.map(\.frame)
            let match = matchDisplay(windowFrame: window.frame, displayFrames: displayFrames)

            let filter: SCContentFilter
            switch match {
            case .mapped(let idx):
                let display = displays[idx]
                let scale = RetinaUtilities.backingScaleFactor(for: display.displayID)
                filter = SCContentFilter(display: display, including: [window])
                // 全局坐标 → display-local 坐标
                config.sourceRect = RetinaUtilities.displayLocalSourceRect(
                    globalRect: window.frame, displayFrame: display.frame)
                let px = RetinaUtilities.pixelSize(forPoints: window.frame, scale: scale)
                config.width = px.width; config.height = px.height

            case .unmapped, .noDisplays:
                // 多屏枚举残缺 / 窗口 frame 退化 → desktop-independent filter
                filter = SCContentFilter(desktopIndependentWindow: window)
                let filterScale = CGFloat(filter.pointPixelScale)
                let scale = filterScale.isFinite && filterScale > 0 ? filterScale : 2.0
                let effectiveFrame = filter.contentRect.isEmpty ? window.frame : filter.contentRect
                let px = RetinaUtilities.pixelSize(forPoints: effectiveFrame, scale: scale)
                config.width = px.width; config.height = px.height
            }

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        }
    }

    // MARK: Capture Region

    func captureRegion(_ rect: CGRect, on display: SCDisplay) async throws -> CGImage {
        try await ScreenCaptureLock.withLock {
            let scale = RetinaUtilities.backingScaleFactor(for: display.displayID)
            let config = SCStreamConfiguration()
            config.captureResolution = .best
            config.showsCursor = false
            config.sourceRect = RetinaUtilities.displayLocalSourceRect(
                globalRect: rect, displayFrame: display.frame)
            let px = RetinaUtilities.pixelSize(forPoints: rect, scale: scale)
            config.width = px.width; config.height = px.height

            let filter = SCContentFilter(display: display, excludingWindows: [])
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        }
    }

    // MARK: Unified Entry Point with Legacy Fallback

    func capture(_ target: CaptureTarget) async throws -> CGImage {
        do {
            switch target {
            case .display(let display):
                return try await self.captureDisplay(display)
            case .window(let window):
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                return try await self.captureWindow(window, displays: content.displays)
            case .region(let rect, let display):
                return try await self.captureRegion(rect, on: display)
            }
        } catch {
            // SCK 失败 → 降级到 CGWindowList（仅 window 目标）
            if case .window(let win) = target {
                if let legacyImage = LegacyCapture.captureWindow(windowID: win.windowID) {
                    return legacyImage
                }
            }
            throw error
        }
    }
}

// MARK: - Space Manager
// ⚠️ 以下所有 CGS 私有 API — 沙盒/Mac App Store 不可用，仅限直发/Notarization Only 渠道
// 来自 SpaceCGSPrivateAPI.swift:22 和 SpaceUtilities.swift:60

// 私有 API 类型别名
typealias CGSConnectionID = UInt32
typealias CGSSpaceID      = UInt64

// ⚠️ 私有 API — 沙盒/MAS 不可用
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> CGSConnectionID

// ⚠️ 私有 API — 沙盒/MAS 不可用
@_silgen_name("CGSCopySpaces")
func CGSCopySpaces(_ cid: CGSConnectionID, _ mask: Int) -> CFArray?

// ⚠️ 私有 API — 沙盒/MAS 不可用
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ ids: CFArray) -> CFArray?

// ⚠️ 私有 API — 沙盒/MAS 不可用
@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

// ⚠️ 私有 API — 沙盒/MAS 不可用
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)

// ⚠️ 私有 API — 沙盒/MAS 不可用
@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

// ⚠️ 私有 API — 沙盒/MAS 不可用
@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

// ⚠️ 私有 API — 沙盒/MAS 不可用
@_silgen_name("kCGSPackagesMainDisplayIdentifier")
var kCGSPackagesMainDisplayIdentifier: CFString

let kCGSAllSpacesMask = (1 << 0) | (1 << 1) | (1 << 2)  // User | Others | Current

@MainActor
final class SpaceManager {
    // ⚠️ 整个 SpaceManager 依赖私有 CGS API — 沙盒/MAS 不可用

    private var _connection: CGSConnectionID?

    private var connection: CGSConnectionID {
        if _connection == nil {
            _ = NSApplication.shared   // 确保 NSApplication 已初始化
            _connection = _CGSDefaultConnection()
            if _connection == 0 {
                print("WARNING: Failed to get CGS connection — SpaceManager will not function")
            }
        }
        return _connection!
    }

    /// 当前活跃 Space ID
    func currentSpaceID() -> CGSSpaceID? {
        guard connection != 0 else { return nil }
        let id = CGSGetActiveSpace(connection)
        return id != 0 ? id : nil
    }

    /// 枚举所有 Space ID
    func allSpaceIDs() -> [CGSSpaceID] {
        guard connection != 0 else { return [] }
        guard let ref = CGSCopySpaces(connection, kCGSAllSpacesMask) else { return [] }
        let arr = ref as NSArray
        return arr.compactMap { element -> CGSSpaceID? in
            if let n = element as? Int { return CGSSpaceID(n) }
            if let d = element as? [String: Any] {
                if let n = d["ManagedSpaceID"] as? Int { return CGSSpaceID(n) }
                if let n = d["id64"]           as? Int { return CGSSpaceID(n) }
            }
            return nil
        }
    }

    /// 查询窗口所在的 Space ID 列表
    func spacesForWindow(_ windowID: CGWindowID) -> [CGSSpaceID] {
        guard connection != 0 else { return [] }
        let ids = [windowID] as CFArray
        guard let ref = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, ids) else { return [] }
        let arr = ref as NSArray
        return arr.compactMap { $0 as? Int }.map { CGSSpaceID($0) }
    }

    /// 切换到指定 Space（主显示器）
    /// ⚠️ 私有 API — 沙盒/MAS 不可用
    func switchSpace(_ spaceID: CGSSpaceID) async {
        guard connection != 0 else { return }
        CGSManagedDisplaySetCurrentSpace(connection, kCGSPackagesMainDisplayIdentifier, spaceID)
        try? await Task.sleep(nanoseconds: 300_000_000)  // 等待动画完成
    }

    /// 将窗口移动到指定 Space
    /// ⚠️ 私有 API — 沙盒/MAS 不可用
    func moveWindow(_ windowID: CGWindowID, toSpace targetSpace: CGSSpaceID) {
        guard connection != 0 else { return }
        let currentSpaces = spacesForWindow(windowID)
        let windowArray = [windowID] as CFArray
        if !currentSpaces.isEmpty {
            CGSRemoveWindowsFromSpaces(connection, windowArray, currentSpaces as CFArray)
        }
        CGSAddWindowsToSpaces(connection, windowArray, [targetSpace] as CFArray)
    }
}

// MARK: - Usage Example

@MainActor
func exampleUsage() async throws {
    // 权限检查（见 05-permissions-state-machine.md）
    guard CGPreflightScreenCaptureAccess() else {
        CGRequestScreenCaptureAccess()
        throw CaptureError.permissionDenied
    }

    // 枚举可捕获内容
    let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false)

    let service = ScreenCaptureService()

    // 捕获主屏
    if let primaryDisplay = content.displays.first(where: { $0.frame.origin == .zero }) {
        let image = try await service.capture(.display(primaryDisplay))
        print("Display capture: \(image.width)x\(image.height) px")
    }

    // 捕获 Safari 窗口
    if let safariWin = content.windows.first(where: {
        $0.owningApplication?.bundleIdentifier == "com.apple.Safari"
    }) {
        let image = try await service.capture(.window(safariWin))
        print("Window capture: \(image.width)x\(image.height) px")
    }

    // Space 管理（⚠️ 私有 API — 沙盒/MAS 不可用）
    let spaceManager = SpaceManager()
    if let currentSpace = spaceManager.currentSpaceID() {
        print("Current Space ID: \(currentSpace)")
        let allSpaces = spaceManager.allSpaceIDs()
        print("Total Spaces: \(allSpaces.count)")
    }
}
```

## 新项目落地步骤（How to apply）

1. **链接 ScreenCaptureKit**：在 `Package.swift` 的 target 中加 `.linkedFramework("ScreenCaptureKit")`（Deployment Target ≥ 12.3）；旧版 OS 兜底路径依赖 `CoreGraphics`（已默认链接）。
2. **添加 Screen Recording 权限入口**：确保用户首次调用 `SCShareableContent` 前已授权；可用 `CGPreflightScreenCaptureAccess()` 预检、`CGRequestScreenCaptureAccess()` 触发弹窗；完整权限状态机见 [05 · 权限状态机](./05-permissions-state-machine.md)。
3. **创建 `SpaceCGSPrivateAPI.swift`**：用 `@_silgen_name` 声明所需 CGS 符号；文件顶部加 `// ⚠️ 私有 API — 沙盒/MAS 不可用` 注释；在 README / CLAUDE.md 中记录发行渠道约束（直发 / Notarization Only）。
4. **实现 `displayLocalSourceRect`**：全局坐标减去 `display.frame.origin`；非主屏的 `origin.x` 可为负值，直接用全局坐标会导致截到黑边。
5. **实现 `capturePixelSize`**：逻辑点 × backing scale factor；通过 `CGDisplayCopyDisplayMode` 获取 `pixelWidth / width`，缓存结果避免每帧调用；零尺寸或非有限值时返回 `(1, 1)` 防止 SCK 参数错误。
6. **实现 `matchDisplay`**：几何中心 → 最大交叉面积 → unmapped fallback（主屏优先）；`unmapped` 时构建 `SCContentFilter(desktopIndependentWindow:)` 而非抛错，保证多屏极端布局下仍可捕获。
7. **实现 `flock` 互斥**：锁文件路径用 app bundle ID 前缀（如 `myapp.sckit-capture.lock`）避免与其他工具冲突；操作完成后 sleep 100 ms 让 `replayd` 归位；锁文件创建失败时降级为无锁（保证捕获功能不中断）。
8. **实现 smart-select 过滤链**：封装 `WindowFiltering.isRenderable`（layer == 0 → alpha → sharing state → on-screen → 尺寸 → 标题），多窗口时按 `CGWindowID` 去重保留最大边界框。
9. **评估私有 API 发行渠道**：`SpaceManager` 用编译条件 `#if !APP_STORE` 隔离；App Store 版本中 Spaces 相关功能需禁用或移除；在 CI 中加检查脚本确保不误打包私有符号。
10. **配置 `PEEKABOO_CAPTURE_ENGINE` 等价环境变量**：提供 `auto|modern|classic` 切换，`auto` 时优先 SCK；`classic` 用于复现旧版问题或 CI 在无 Screen Recording 权限环境下运行集成测试。

## 替代方案对比（When NOT to use）

| 方案 | 最低 OS | 优点 | 缺点 / 风险 | 何时选择 |
|------|--------|------|------------|---------|
| **SCK 主 + CGWindowList 兜底**（本方案）| macOS 12.3 | 最优画质、async、TCC 友好、兜底完整 | SCK replayd 竞态需 flock 互斥；代码量较大 | 新项目默认选择 |
| 纯 ScreenCaptureKit | macOS 12.3 | 代码量最小 | 老系统无法运行；无兜底 | 已明确 macOS 13+ 发行渠道 |
| 纯 `CGWindowListCopyWindowInfo` + `CGWindowCreateImage` | macOS 10.5 | 兼容性最广、无 async 依赖 | 低权限下空列表、性能差（Retina 500ms+）；`CGWindowCreateImage` 在 macOS 14 被弃用 | 需要支持 macOS 12 以下；仅需元数据时 |
| 私有 `CGDisplayStreamCreate`（CoreGraphics 私有） | macOS 10.8 | 高帧率流，比 SCK 更底层 | 私有 API，沙盒/MAS 不可用；macOS 12.3+ 被 SCK 取代；⚠️ API 随 OS 变化风险高 | 仅极端高性能录屏场景且不进 MAS |
| FFmpeg `avfoundation`（`-f avfoundation -i "0"`） | macOS 10.7+ | 跨平台、支持录制 MP4 | 需要额外进程（spawn FFmpeg）；延迟高；输出格式受限；TCC 行为与 SCK 不同 | 需要输出视频文件而非单帧 CGImage |
| `screencapture` CLI（系统工具） | macOS 10.3+ | 无需权限代码、shell 脚本友好 | 写入磁盘才能读取；不支持截特定 windowID（需 `-l`）；输出文件 I/O 开销 | 调试验证权限是否生效；shell 脚本场景 |
| AppleScript `tell application "System Events" to ...` | macOS 10.3+ | 简单 | 不能截图像素，仅能查窗口信息；性能极差 | 仅查窗口元数据且无 AX 权限时 |
| macOS Sonoma+ ReplayKit `RPScreenRecorder` | macOS 14.0 | 官方支持录屏流 | 设计为录制而非单帧截图；需要用户确认对话框（每次会话）；延迟高 | 需要持续录制视频而非单帧截图 |

**降级策略**：SCK 失败（超时 / 权限缓存刷新中）→ `CGWindowListCopyWindowInfo` + `CGWindowCreateImage`；如果 `CGWindowCreateImage` 返回 nil（最小化窗口）→ 向用户返回明确错误，不继续降级到空图。

## 非原生环境（Non-Native Targets）

### Electron 应用（VSCode、Slack、Discord 等）

**问题**：Electron 采用多进程架构（主进程 + 多个渲染器进程），每个进程是独立的 macOS 进程。`CGWindowListCopyWindowInfo` 依赖 WindowServer 实时数据，多进程创建/销毁窗口时可能出现**时序竞态**，返回空数组或部分列表（渲染器窗口尚未注册到 WindowServer）。

**表现**：调用 `CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)` 返回零条目，但屏幕上明显有 VSCode 窗口显示。

**处置**：
1. 改用 `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` — SCK 的内容枚举使用 `replayd` 维护的稳定列表，比 `CGWindowListCopyWindowInfo` 更抗时序竞态。
2. 若必须用 `CGWindowListCopyWindowInfo`，加 `[.optionAll, .excludeDesktopElements]`（不要只用 `.optionOnScreenOnly`），并在返回空时做一次 20 ms 后重试。
3. Electron 窗口的 `kCGWindowLayer` 可能非 0（Frameless window、DevTools 等），smart-select 过滤时需宽松化 layer 条件，或用 bundle ID 精确匹配。

### Fullscreen Space（全屏应用所在的独立 Space）

**问题**：macOS 全屏应用会创建独立 `CGSSpaceType == kCGSSpaceFullscreen (1)` 的 Space，与普通用户 Space 完全隔离。overlay 窗口（`NSPanel`、`NSWindow`）默认不出现在全屏 Space，`SCShareableContent` 在另一个 Space 上不能枚举到全屏 Space 的窗口。

**表现**：`SpaceManagementService.getSpacesForWindow(windowID:)` 返回空，全屏 app 的 Space ID 出现在 `CGSSpaceType == 1` 的列表里；你的 overlay 窗口根本不显示。

**处置**：
1. 用 `CGSSpaceGetType` 识别全屏 Space（type == 1），用 `CGSManagedDisplaySetCurrentSpace` 先切换过去（⚠️ 私有 API — 沙盒/MAS 不可用），再做截图；或者
2. 让 overlay 窗口的 `collectionBehavior` 包含 `.fullScreenAuxiliary`（公开 API），这样窗口可以出现在全屏 Space：
   ```swift
   panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
   ```
3. 截图本身可以用 `SCContentFilter(desktopIndependentWindow:)` 直接捕获全屏 app 的窗口，无需切换 Space。

### Sidecar / iPad as Display

**问题**：通过 Sidecar 将 iPad 用作副屏时，系统在 `SCShareableContent.displays` 中列出 Sidecar 虚拟显示器，但 `CGSCopyManagedDisplaySpaces` 可能**不识别**该显示器 ID——返回的 display 标识符与 `SCDisplay.displayID` 不匹配。

**表现**：`CGSManagedDisplaySetCurrentSpace` 对 Sidecar 显示器 ID 静默失败；`ioreg -l | grep -i "sidecar"` 可以看到设备但私有 API 无法操作它。

**处置**：
1. Sidecar 屏截图走 `SCContentFilter(display:including:)` 可以正常工作（公开 SCK 路径）；
2. Spaces 操作跳过 Sidecar 显示器（按 `CGDirectDisplayID` 过滤，Sidecar 的 `CGDisplayIsBuiltin` 返回 false 且 `CGDisplayIsOnline` 可能返回 true）；
3. 切勿对 Sidecar 显示器调用私有 CGS Spaces API——可能静默失败或崩溃。

### 混合分辨率多屏（Retina 主屏 + 非 Retina 副屏 + 4K 外接）

**问题**：三块屏幕的 backing scale factor 各不相同（1×、2×、2×），全局坐标系统使用**逻辑点**，而 SCK 输出像素尺寸必须用**物理像素**。用单一全局 scale factor（如固定 `2.0`）会导致非 Retina 屏输出图像尺寸错误（2× 分辨率截到 1× 内容）或 4K 屏欠采样。

**表现**：非主屏截图尺寸异常，或截图内容被拉伸/压缩。

**处置**：
1. 每块 `SCDisplay` 独立获取 backing scale factor（`CGDisplayCopyDisplayMode` → `pixelWidth / width`），而不用全局 `NSScreen.backingScaleFactor`。
2. `desktopIndependentWindow` filter 的 `filter.pointPixelScale` 是**该窗口实际所在屏**的 scale，比 `NSScreen` 更准确。
3. 多屏混合布局下，同一个逻辑坐标系中 `x=2560` 可能是主屏右边缘，也可能是副屏左边缘；匹配显示器时用 `SCDisplay.frame` 而非 `NSScreen.frame`（两者有时不一致）。

## 调试与取证（Debug & Forensics）

### 关键命令速查

```bash
# 1. 监听 SCK / replayd 日志（权限错误、stream 事件、超时）
log stream \
  --predicate 'subsystem == "com.apple.ScreenCaptureKit" OR process == "replayd"' \
  --level info

# 2. 验证 Screen Recording 权限是否生效（返回 1 = 有权限）
osascript -e 'tell application "System Events" to get processes whose name is "Finder"' && \
  python3 -c "import ctypes; print(ctypes.cdll.LoadLibrary('').CGPreflightScreenCaptureAccess())"

# 3. 系统 screencapture CLI 验证权限（成功 = TCC 已授权）
screencapture -T 0 /tmp/test_capture.png && echo "OK" || echo "PERMISSION DENIED"

# 4. 查看 SCStream fd 泄漏（每次截图后 fd 数量应归零）
lsof -p <your_pid> | grep -E "SCK|replayd|sckit"
lsof -p <your_pid> | wc -l   # 监控总 fd 数，持续增长说明泄漏

# 5. 查询 Retina 缩放因子（ioreg）
ioreg -l -d 4 | grep -E "IODisplayBacking|BackingScale|PixelEncoding"

# 6. 查看所有显示器的分辨率信息
system_profiler SPDisplaysDataType | grep -E "Resolution|Retina|Display Type"

# 7. 检查 replayd TCC 缓存状态
defaults read com.apple.replayd 2>/dev/null || echo "no replayd prefs"

# 8. 重置 Screen Recording TCC 条目（开发期调试用，需 SIP off）
tccutil reset ScreenCapture com.yourapp.bundleid

# 9. iOS Simulator 截图（验证 xcrun 路径是否有权限）
xcrun simctl io booted screenshot /tmp/sim_shot.png

# 10. CGS / SkyLight 私有 API 符号是否可用（SIP 开启时某些符号可能被隐藏）
nm -g /System/Library/Frameworks/CoreGraphics.framework/CoreGraphics | grep CGSCopy
```

### 症状 → 命令 → 根因映射表

| 症状 | 诊断命令 | 根因 |
|------|---------|------|
| `CGPreflightScreenCaptureAccess()` 返回 true 但 SCK 仍报权限错误 | `log stream --predicate 'process == "replayd"' --level debug` | TCC ScreenRec 与 replayd 二级缓存不同步；杀 replayd（`sudo pkill replayd`）让其重启刷新 |
| 截图全黑（windowID 正确但像素全零） | `ioreg -l | grep BackingScale` + 检查 `config.width/height` 是否 > 0 | backing scale 换算错误或 `capturePixelSize` 返回 (0,0)；检查 frame 是否有效 |
| Electron 窗口列表为空 | `CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)` 加 20ms 重试 | 多进程时序竞态；改用 `SCShareableContent.excludingDesktopWindows` |
| CGS 调用返回 nil / CGSConnection == 0 | 检查 SIP 状态：`csrutil status`；检查沙盒：`codesign -d --entitlements - /path/to/app` | 私有 API 在沙盒/MAS 环境不可用；SIP 开启时部分符号受限 |
| SCStream 内存泄漏（RSS 持续增长） | `lsof -p <pid>` 查 fd 数量 + Instruments Leaks template | 没有 `defer { try? stream.stopCapture() }` 或 SCStream 的 continuation 未 resume |
| 全屏 app overlay 不显示 | 检查 `NSWindow.collectionBehavior` 是否含 `.fullScreenAuxiliary` | 默认 fullscreen Space 屏蔽非 `.fullScreenAuxiliary` 的窗口 |
| 副屏截图坐标错位（截到黑边） | `print(display.frame)` 确认 origin.x 是否为负 | 未调用 `displayLocalSourceRect`，直接用全局坐标作为 sourceRect |
| SCScreenshotManager 超时无响应 | `log stream --predicate 'subsystem == "com.apple.ScreenCaptureKit"' --level debug` | 并发两个 SCK 调用使 replayd 卡死；加 flock 互斥或串行化调用 |
| `CGSSpaceCopyName` crash | 检查是否在主线程调用：`Thread.isMainThread` | CGS 函数要求主线程（`@MainActor`）调用 |

## 常见陷阱（Pitfalls）

- **SCK stream 未关闭导致内存泄漏** — 可观测信号：进程 RSS 随时间持续增长，`lsof -p <PID>` 显示 stream fd 数量不断增加；处理：在 `SCKStreamSession` 的 deinit 或完成 handler 中用 `defer { try? stream.stopCapture() }` 确保资源释放；来源：`ScreenCaptureKitFrameSource+StreamSession.swift`。

- **多屏全局坐标未转本地坐标** — 可观测信号：副屏截图出现大面积黑边或坐标错位，尤其是布局在主屏左侧的外接屏（`frame.origin.x < 0`）；处理：调用 `displayLocalSourceRect(globalRect:displayFrame:)` 减去显示器原点；来源：`ScreenCapturePlanner.swift:19`。

- **CGSDefaultConnection 返回 0 / Spaces 操作静默失败** — 可观测信号：`SpaceManagementService.getAllSpaces()` 返回空数组，日志输出 "WARNING: Failed to get CGS connection"；处理：确认在 `@MainActor` 上调用且 `NSApplication.shared` 已初始化，在纯 CLI 环境中提前触发 `_ = NSApplication.shared`；来源：`SpaceUtilities.swift:69`。

- **CGWindowListCopyWindowInfo 低权限下返回空** — 可观测信号：`CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)` 返回零条目但屏幕有可见窗口；处理：检查 `CGPreflightScreenCaptureAccess()` 返回值，重新触发权限弹窗（`CGRequestScreenCaptureAccess()`）；来源：`LegacyScreenCaptureOperator+Window.swift:14`。

- **私有 API 在 App Store 审核被拒** — 可观测信号：App Review 邮件反馈"使用了非公开 API `_CGSDefaultConnection` / `CGSCopySpaces`"；处理：评估发行渠道（直发 / Notarization Only），用 `#if !APP_STORE` 条件编译隔离 Spaces 功能；来源：`SpaceCGSPrivateAPI.swift:22`。

- **Retina backing scale 漏算导致截图模糊** — 可观测信号：截图打开后像素化，实际尺寸是预期的一半（如 1440×900 而非 2880×1800）；处理：确认 `SCStreamConfiguration.width/height` 使用的是物理像素（逻辑点 × scale），通过 `CGDisplayCopyDisplayMode` 而非固定 `2.0` 获取 scale；来源：`ScreenCapturePlanner.swift:23`。

- **跨进程 ReplayD 竞态（同时启动两个 SCStream 卡死）** — 可观测信号：两个并发的 `peekaboo image` 命令，其中一个永远不返回，或收到权限错误（尽管 TCC 已授权）；处理：用跨进程 `flock` 串行化所有 SCK 调用，并在锁释放后 sleep 100 ms；来源：`ScreenCaptureKitCaptureGate.swift:7`。

- **`desktopIndependentWindow` filter 的 `contentRect` 为空** — 可观测信号：使用 `filter.contentRect` 计算像素尺寸时得到 (0,0)，导致 SCK 参数错误崩溃；处理：加 fallback `if filter.contentRect.isEmpty { use window.frame }`；来源：`ScreenCaptureKitOperator+Window.swift:268`（`capturePixelSize(for:fallbackFrame:scale:)` 的 fallback 参数）。

## 延伸阅读

- Peekaboo：`docs/window-screenshot-smart-select.md`（smart-select 过滤链完整说明）
- Peekaboo：`docs/skylight-spaces-api.md`（CGS 私有 API 逆向工程参考，99 KB 详尽文档）
- Apple：[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- Apple：[SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)（单帧捕获，macOS 14+）
- Apple WWDC 2022：[Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/)
- Apple WWDC 2023：[What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/)
- 其它 playbook：[05 · 权限状态机](./05-permissions-state-machine.md)（Screen Recording TCC 管理）、[10 · Visualizer overlay](./10-visualizer-overlay.md)（NSPanel fullScreenAuxiliary 配置）

---
*Last verified against Peekaboo @ `742eadb991eec3fdf05c5092eb97e8e43d0dabfa`*
