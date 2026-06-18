---
summary: 'CGWindowList 窗口枚举（元数据 + 截图兜底）与 SkyLight CGS 私有 API（Spaces 管理：枚举、切换、跨 Space 移动窗口）。'
read_when:
  - '枚举系统所有窗口（PID、bounds、title、layer）而不需要像素截图'
  - '需要切换 Space、查询窗口所在 Space、将窗口移动到另一个 Space'
  - '评估私有 CGS API 的发行渠道约束（沙盒/MAS 限制）'
sources: ['P08']
last_verified:
  peekaboo: '742eadb991eec3fdf05c5092eb97e8e43d0dabfa'
  nemonotch: 'fe4e9e5'
---

# 窗口枚举（CGWindowList）与 Spaces 私有 API（CGS）

## TL;DR

**窗口枚举**：`CGWindowListCopyWindowInfo` 是同步、零成本的轻量路径，适合只需元数据（PID、bounds、title、layer）而不需要像素的场景。截图兜底用 `CGWindowListCreateImage`（macOS 14 已弃用但仍可用）。

**Spaces 管理**：macOS **没有任何公开 API** 可以枚举 Space、查询窗口所在 Space、切换 Space、跨 Space 移动窗口。必须用 **SkyLight / CoreGraphics 私有符号**（`CGSCopySpaces`、`CGSManagedDisplaySetCurrentSpace` 等），通过 `@_silgen_name` 动态绑定，⚠️ **沙盒 / Mac App Store 不可用**。

- yabai、Amethyst、Rectangle、Scapple 等工具都依赖相同的 CGS 符号链
- `@_silgen_name` 不需要 `import` 私有 framework，运行时动态绑定
- 必须在 `@MainActor` 上调用（WindowServer 要求主线程连接）
- 发行前用 `#if !APP_STORE` 条件编译隔离，CI 检查脚本确认不误打包

## 可复用模式

### Pattern 1 · CGWindowList 窗口枚举

```swift
// LegacyScreenCaptureOperator+Window.swift:14
// .optionAll：包含非前台窗口（避免 Electron 多进程偶发空列表）
// .excludeDesktopElements：过滤桌面图标等噪声
let allWindows = CGWindowListCopyWindowInfo(
    [.optionAll, .excludeDesktopElements],
    kCGNullWindowID) as? [[String: Any]] ?? []

// 按 PID 过滤
let appWindows = allWindows.filter {
    ($0[kCGWindowOwnerPID as String] as? Int32) == targetPID
}

// 读取常用字段
for info in appWindows {
    let windowID = info[kCGWindowNumber as String] as? CGWindowID
    let title    = info[kCGWindowName   as String] as? String
    let layer    = info[kCGWindowLayer  as String] as? Int
    let alpha    = info[kCGWindowAlpha  as String] as? Double
    let onScreen = info[kCGWindowIsOnscreen as String] as? Bool

    var bounds: CGRect = .zero
    if let dict = info[kCGWindowBounds as String] as? [String: CGFloat] {
        bounds = CGRect(x: dict["X"] ?? 0, y: dict["Y"] ?? 0,
                        width: dict["Width"] ?? 0, height: dict["Height"] ?? 0)
    }
}
```

**何时用**：只需窗口元数据（PID、bounds、title）不需要截图像素——`CGWindowListCopyWindowInfo` 开销极低，无需 `await`，不触发 TCC 弹窗（但低权限下静默返回空）。

---

### Pattern 2 · CGWindowList 截图兜底

```swift
// LegacyScreenCaptureOperator+Window.swift:14（SCK 不可用时的回退路径）
// macOS 14.0 起 CGWindowCreateImageFromArray 被弃用，但仍可用
guard (allWindows.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == windowID }) else {
    return nil  // 窗口已消失
}
return CGWindowListCreateImage(
    .null,
    .optionIncludingWindow,
    windowID,
    [.boundsIgnoreFraming, .nominalResolution])
```

**注意**：
- `CGWindowListCreateImage` 在 macOS 14 被弃用（会产生编译警告），`boundsIgnoreFraming` 包含窗口阴影，`nominalResolution` 输出逻辑点分辨率而非 Retina 物理像素
- 最小化窗口返回 nil——不要继续降级到空图，向用户返回明确错误
- `CGWindowCreateImage` 在大分辨率 Retina 下可达 500ms+，SCK 主路径延迟 20–150ms

---

### Pattern 3 · CGS 私有 API 声明（`@_silgen_name`）

```swift
// SpaceCGSPrivateAPI.swift:22
// ⚠️ 私有 API — 沙盒/Mac App Store 不可用，仅限直发或 Notarization Only 渠道
// 通过 @_silgen_name 动态绑定，不需要 import 私有 framework

typealias CGSConnectionID = UInt32
typealias CGSSpaceID      = UInt64

// 获取主线程 WindowServer 连接（必须在 @MainActor 调用）
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> CGSConnectionID

// 枚举所有 Space
@_silgen_name("CGSCopySpaces")
func CGSCopySpaces(_ cid: CGSConnectionID, _ mask: Int) -> CFArray?

// 查询窗口所在的 Space ID 列表
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ windowIDs: CFArray) -> CFArray?

// 获取当前活跃 Space
@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

// 切换到指定 Space（按显示器标识符）
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)

// 跨 Space 移动窗口（先 Remove 再 Add）
@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

// 主显示器标识符常量
@_silgen_name("kCGSPackagesMainDisplayIdentifier")
var kCGSPackagesMainDisplayIdentifier: CFString

let kCGSAllSpacesMask = (1 << 0) | (1 << 1) | (1 << 2)  // User | Others | Current
```

---

### Pattern 4 · SpaceManagementService 封装

```swift
// SpaceUtilities.swift:60 — 完整封装（@MainActor，所有 CGS 操作在主线程）
@MainActor
final class SpaceManagementService {

    private lazy var connection: CGSConnectionID = {
        _ = NSApplication.shared   // 确保 NSApplication 已初始化
        let cid = _CGSDefaultConnection()
        if cid == 0 {
            // SpaceUtilities.swift:69 — 返回 0 时打印 WARNING
            print("WARNING: Failed to get CGS connection — SpaceManager will not function")
        }
        return cid
    }()

    // 枚举所有 Space ID（含全屏 Space）
    func allSpaceIDs() -> [CGSSpaceID] {
        guard connection != 0,
              let ref = CGSCopySpaces(connection, kCGSAllSpacesMask) else { return [] }
        return (ref as NSArray).compactMap { element -> CGSSpaceID? in
            if let n = element as? Int { return CGSSpaceID(n) }
            // CGSCopySpaces 返回的 CFArray 元素可能是字典
            if let d = element as? [String: Any] {
                if let n = d["ManagedSpaceID"] as? Int { return CGSSpaceID(n) }
                if let n = d["id64"]           as? Int { return CGSSpaceID(n) }
            }
            return nil
        }
    }

    // 当前活跃 Space
    func currentSpaceID() -> CGSSpaceID? {
        guard connection != 0 else { return nil }
        let id = CGSGetActiveSpace(connection)
        return id != 0 ? id : nil
    }

    // 查询窗口所在 Space 列表
    func spacesForWindow(_ windowID: CGWindowID) -> [CGSSpaceID] {
        guard connection != 0 else { return [] }
        let ids = [windowID] as CFArray
        guard let ref = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, ids) else { return [] }
        return (ref as NSArray).compactMap { $0 as? Int }.map { CGSSpaceID($0) }
    }

    // 切换 Space（主显示器），等待 300ms 动画完成
    func switchToSpace(_ spaceID: CGSSpaceID) async {
        guard connection != 0 else { return }
        CGSManagedDisplaySetCurrentSpace(connection, kCGSPackagesMainDisplayIdentifier, spaceID)
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    // 将窗口移动到指定 Space
    func moveWindow(_ windowID: CGWindowID, toSpace targetSpace: CGSSpaceID) {
        guard connection != 0 else { return }
        let currentSpaces = spacesForWindow(windowID)
        let windowArray = [windowID] as CFArray
        // 先从当前 Space 移除，再加入目标 Space
        if !currentSpaces.isEmpty {
            CGSRemoveWindowsFromSpaces(connection, windowArray, currentSpaces as CFArray)
        }
        CGSAddWindowsToSpaces(connection, windowArray, [targetSpace] as CFArray)
    }
}
```

---

### Pattern 5 · 全屏 Space 检测与处理

macOS 全屏 app 创建 `CGSSpaceType == kCGSSpaceFullscreen(1)` 的独立 Space，与普通用户 Space 完全隔离：

```swift
// 识别全屏 Space（type == 1），再切换过去截图
// ⚠️ CGSSpaceGetType 也是私有 API，同样 MAS 不可用
@_silgen_name("CGSSpaceGetType")
func CGSSpaceGetType(_ cid: CGSConnectionID, _ space: CGSSpaceID) -> Int
// type 1 = fullscreen, type 0 = user space

// 更安全的方案：用 desktopIndependentWindow filter 直接跨 Space 捕获，无需切换
let filter = SCContentFilter(desktopIndependentWindow: fullscreenAppWindow)

// overlay 窗口要出现在全屏 Space：
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
```

---

### Pattern 6 · 调试与取证命令

```bash
# 1. 检查 CGS 私有符号是否可被链接（SIP 开启时部分符号可能受限）
nm -g /System/Library/Frameworks/CoreGraphics.framework/CoreGraphics | grep CGSCopy

# 2. 检查 SIP 状态（SIP 开启不影响 @_silgen_name，但部分调试操作受限）
csrutil status

# 3. 查看 Screen Recording TCC 状态
tccutil reset ScreenCapture com.yourapp.bundleid   # 重置（开发期）

# 4. CGWindowList 枚举结果（Python 快速验证）
python3 -c "
import Quartz
windows = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionAll | Quartz.kCGWindowListExcludeDesktopElements,
    Quartz.kCGNullWindowID)
for w in windows[:10]:
    print(w.get('kCGWindowOwnerName'), w.get('kCGWindowName'), w.get('kCGWindowLayer'))
"

# 5. 验证 Screen Recording 权限（1 = 有权限）
python3 -c "import Quartz; print(Quartz.CGPreflightScreenCaptureAccess())"

# 6. replayd 日志（SCK 相关事件）
log stream --predicate 'subsystem == "com.apple.ScreenCaptureKit" OR process == "replayd"' --level info

# 7. Retina scale factor 查询
ioreg -l -d 4 | grep -E "IODisplayBacking|BackingScale"
system_profiler SPDisplaysDataType | grep -E "Resolution|Retina"
```

## 锚点（file:line）

| 符号 / 文件 | 位置 | 说明 |
|---|---|---|
| `SpaceCGSPrivateAPI` | `Utilities/SpaceCGSPrivateAPI.swift:22` | 全部 `@_silgen_name` CGS 私有符号声明 |
| `SpaceManagementService` | `Utilities/SpaceUtilities.swift:60` | Spaces 枚举/切换/窗口跨 Space 移动完整封装 |
| `_CGSDefaultConnection` 返回 0 WARNING | `Utilities/SpaceUtilities.swift:69` | 连接失败时打印警告，不抛 fatal error |
| `LegacyScreenCaptureOperator+Window` | `Services/Capture/LegacyScreenCaptureOperator+Window.swift:14` | CGWindowList 枚举 + smart-select 过滤 |
| 症状→命令→根因映射表 | 源文件 `08-screen-capture-windows-spaces.md` 调试节 | CGS 返回 nil、全屏 Space 等常见症状 |

## Pitfalls

- **CGS 私有 API — 沙盒/MAS 必然被拒**：App Review 静态扫描私有 C 符号，提交必然被拒。用 `#if !APP_STORE` 条件编译隔离；CI 加检查脚本（`nm -g` 扫描产物）确认不误打包。来源：`SpaceCGSPrivateAPI.swift:22`。

- **`_CGSDefaultConnection()` 返回 0**：纯 CLI / headless 环境未初始化 NSApplication，或在非主线程调用。处置：确认 `@MainActor` 上调用且 `_ = NSApplication.shared` 已执行。来源：`SpaceUtilities.swift:69`。

- **`CGSCopySpaces` 返回字典而非 Int**：元素类型不固定（Int 或 `[String: Any]`），需两路 compactMap（先 `as? Int`，再取 `ManagedSpaceID` / `id64`）。

- **CGS 切换 Space 需等动画完成**：`CGSManagedDisplaySetCurrentSpace` 调用后立即截图可能截到旧 Space。等待 300ms（`Task.sleep(300_000_000 ns)`）。

- **Sidecar 显示器 CGS Spaces 操作静默失败甚至崩溃**：跳过 Sidecar 设备（`CGDisplayIsBuiltin == false`）的所有 CGS Spaces 操作。SCK 截图路径不受影响。

- **CGWindowList 低权限静默返回空**：`CGWindowListCopyWindowInfo` 在未授权情况下不报错，直接返回空数组——调用前检查 `CGPreflightScreenCaptureAccess()`。

- **`CGWindowListCreateImage` macOS 14 弃用警告**：API 仍可用，生产代码应给出明确的兼容性注释；仅当 deploy target ≥ 14 时改用 SCK 主路径。

- **全屏 Space 窗口不在普通 Space 枚举结果中**：`SCShareableContent` 在当前 Space 不枚举全屏 app 的窗口；用 `SCContentFilter(desktopIndependentWindow:)` 直接捕获，或切换到全屏 Space 后再截图。

## 落地 checklist

- [ ] `SpaceCGSPrivateAPI.swift` 文件顶部标注 `// ⚠️ 私有 API — 沙盒/MAS 不可用`
- [ ] 用 `#if !APP_STORE` 条件编译隔离所有 CGS Spaces 代码
- [ ] CI 脚本验证 App Store 产物不含私有 CGS 符号：`nm -g <app>/Contents/MacOS/<binary> | grep CGSCopy`
- [ ] README / CLAUDE.md 中记录发行渠道约束（直发 / Notarization Only）
- [ ] `SpaceManagementService` 标注 `@MainActor`，确保 `NSApplication.shared` 在调用前已初始化
- [ ] CGSConnection ID 返回 0 时静默降级（返回空数组 / nil），不 crash
- [ ] `CGSCopySpaces` 返回元素的类型做两路解析（`Int` + `[String:Any]`）
- [ ] 切换 Space 后 sleep ≥ 300ms 再截图
- [ ] 跳过 Sidecar 显示器（`CGDisplayIsBuiltin == false`）的 CGS Spaces 操作
- [ ] 窗口枚举若仅需元数据（bounds/title/PID），优先 `CGWindowListCopyWindowInfo` 而非 `SCShareableContent`（后者有异步开销）

## 延伸阅读

- [ScreenCaptureKit 主路径 + CGWindowList 回退](./screencapturekit-and-fallback.md) — SCK 截图主路径、Retina 换算、flock 互斥
- [../permissions/](../permissions/) — Screen Recording TCC 状态机
- [../private-api/](../private-api/) — `@_silgen_name` 动态绑定私有符号通用模式与风险矩阵
- [../window/](../window/) — NSPanel fullScreenAuxiliary、multi-screen 定位
- Peekaboo 参考：`docs/skylight-spaces-api.md`（99KB CGS 逆向工程详尽文档）
- 同类工具参考：yabai、Amethyst、Rectangle（均依赖相同 CGS 符号链）
