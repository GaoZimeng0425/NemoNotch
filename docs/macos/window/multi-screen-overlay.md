---
summary: '多屏 overlay 窗口：per-screen WindowController、屏幕变化重建、"看得见点不到不抢焦点"；两种 overlay level 并列（.screenSaver vs .statusBar+8）'
read_when:
  - '需要在每块屏幕上创建独立 overlay 窗口'
  - '处理显示器插拔 / 分辨率变化后窗口需要重建'
  - '确保 overlay 在全屏 App 内仍然可见'
  - '选择 overlay 的 NSWindow.Level'
  - '调试 NSScreen.main 导致 overlay 出现在错误屏幕'
sources: ['NemoNotch §5.4–§5.6 §5.10', 'Peekaboo P10', 'P09']
last_verified: { peekaboo: 'n/a', nemonotch: 'fe4e9e5' }
---
# 多屏 Overlay 窗口

## TL;DR

每块 `NSScreen` 创建一个对应的 overlay window，用 `CGDirectDisplayID` 为 key 存入字典；监听 `NSApplication.didChangeScreenParametersNotification` 做差集更新（关闭移除的、创建新增的）。"看得见点不到不抢焦点"：纯视觉窗口用 `ignoresMouseEvents = true` + `canBecomeKey/Main → false`；交互窗口用 `PassThroughView` 按区域选择性放行。

---

## 可复用模式

### 1. Per-screen 窗口字典

```swift
// CompletionFlashWindowController（伪码）
var windows: [UInt32: CompletionFlashWindow] = [:]    // key = screen.displayID

private func makeWindow(for screen: NSScreen) -> CompletionFlashWindow {
    let window = CompletionFlashWindow(rect: screen.frame)
    window.orderFront(nil)
    return window
}
```

`displayID` 来源：

```swift
// ScreenExtensions.swift:~30
var displayID: UInt32 {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    guard let number = deviceDescription[key] as? NSNumber else { return 0 }
    return number.uint32Value
}
```

两块屏 `displayID` 都是 `0` 会碰撞 → `rebuildSlots()` 里需容错（实际上 `CGDirectDisplayID` 对真实 display 都唯一，仅在测试环境可能为 0）。

### 2. `didChangeScreenParametersNotification` 差集重建

```swift
// NotchCoordinator.swift:81-93 & 244-252
NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
    name: NSApplication.didChangeScreenParametersNotification, object: nil)

@objc private func screenParametersChanged() {
    notchSize = Self.resolveUnifiedNotchSize()
    rebuildSlots()
    if let active = activeScreen, slots[active.displayID] == nil {
        activeScreen = nil
        status = .closed     // 防止悬空引用
    }
}

// CompletionFlashWindowController.rebuild()
private func rebuild() {
    let currentIDs = Set(NSScreen.screens.map(\.displayID))
    for (id, window) in windows where !currentIDs.contains(id) {
        window.orderOut(nil); window.close()
        windows.removeValue(forKey: id)
    }
    for screen in NSScreen.screens {
        let id = screen.displayID
        if let existing = windows[id] {
            existing.setFrame(screen.frame, display: true)
        } else {
            windows[id] = makeWindow(for: screen)
        }
    }
}
```

**关键点：** Notification 在插拔、分辨率变更、缩放变更、睡眠唤醒时都会触发，必须**幂等且轻量**。

### 3. "看得见点不到不抢焦点" — 两种实现

#### 方案 A：`ignoresMouseEvents = true`（纯视觉 overlay，NemoNotch §5.10）

```swift
window.ignoresMouseEvents = true   // AppKit 窗口级开关，路由所有鼠标事件穿透
window.canBecomeKey  → false
window.canBecomeMain → false
```

AppKit 窗口级开关，无需子视图 override，也不怕 SwiftUI 子视图意外重新启用 hit-testing。**用于：** completion flash、visualizer overlay 等纯视觉动画。

#### 方案 B：`PassThroughView.hitTest` 按区域放行（交互窗口，NemoNotch §5.3）

```swift
final class PassThroughView: NSView {
    var isBlocking = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if view !== self { return view }
        return isBlocking ? self : nil
    }
}
```

**用于：** notch 面板等需要"展开时可点击、收起时全穿透"的动态交互窗口。

### 4. 屏幕内置判断（HUD / Toast 只出现在内置屏）

```swift
// ScreenExtensions.swift
var isBuiltInDisplay: Bool {
    CGDisplayIsBuiltin(displayID) == 1
}
```

`isBuiltInDisplay` 用于过滤：HUD overlay、completion toast 只挂在内置屏幕，避免多屏重复显示。

### 5. 多屏目标选择（Peekaboo 模式）

```swift
// Peekaboo 三级回退
NSScreen.mouseScreen      // 鼠标所在屏（P10 自定义扩展）
NSScreen.screen(containing: point)   // 包含特定 CGPoint 的屏
NSScreen.main             // ⚠️ 仅作最后兜底：这是 key-window 所在屏，非用户"活跃"屏
NSScreen.screens.first!   // 最终保底
```

**切勿直接用 `NSScreen.main`** 做定向操作——它是 key-window 所在屏，多显示器下会指向错误屏幕。

### 6. NSHostingController frame offset（多屏坐标换算）

```swift
// NotchCoordinator.swift:127-155  makeSlot(for:)
let sf = screen.frame
hosting.view.frame = NSRect(
    x: sf.minX - wf.minX,
    y: sf.minY - wf.minY,
    width: sf.width,
    height: sf.height
)
```

window frame 是 notch 上方的小矩形；hosting view 内部需要填充整个 `screen.frame`，坐标用**窗口本地坐标系**（`screen.frame.origin - window.frame.origin`）。

---

## Overlay Level 选择：两种场景并列

> **裁决：不强裁。两种 level 针对不同场景，按需选择。**

### `.screenSaver`（Peekaboo P10，通用屏上 overlay）

```swift
window.level = .screenSaver    // 高于所有普通应用窗口，包括系统 overlay
```

**适用场景：**
- 纯视觉动画 overlay（音频可视化、屏幕效果）
- 需要出现在**一切**应用窗口之上，包括全屏 App（配合 `.fullScreenAuxiliary`）
- 不需要与 notch 面板同层对齐

**注意（macOS 26）：** `.screenSaver` 级窗口在 Liquid Glass 渲染流水线下有更高 GPU 合成开销；若 GPU 负载高，可降至 `.popUpMenu`。

---

### `.statusBar + 8`（NemoNotch §5.1 §5.10，与 notch 面板同层）

```swift
window.level = .statusBar + 8  // 经验值，清出 menu-extras 遮挡
```

**适用场景：**
- 与 notch 主面板**同层对齐**（completion flash 需要在 notch 上方可见）
- 多个 overlay 需要相对层级一致
- 专门服务于 notch 区域 UI 的 overlay

**注意：** `+8` 是经验值；若仍被遮挡，递增测试。需要配合 `.fullScreenAuxiliary` 才能在全屏 App 内可见（level 本身不够）。

---

### 对比速查

| 场景 | 推荐 level | 必须配合 |
|------|------------|----------|
| 通用全屏 overlay（visualizer / flash） | `.screenSaver` | `.fullScreenAuxiliary` |
| 跟随 notch 面板同层显示 | `.statusBar + 8` | `.fullScreenAuxiliary` |
| 跟随外部窗口浮动（inspector） | `.floating` | `isFloatingPanel = true`（NSPanel） |

---

## 锚点（file:line）

| 符号 | 位置 |
|------|------|
| `NotchCoordinator.makeSlot(for:)` | `NemoNotch/Notch/NotchCoordinator.swift:127` |
| `NotchCoordinator.screenParametersChanged()` | `NemoNotch/Notch/NotchCoordinator.swift:244` |
| `CompletionFlashWindowController.rebuild()` | `NemoNotch/Notch/CompletionFlashWindow.swift` |
| `ScreenExtensions.displayID` | `NemoNotch/Helpers/ScreenExtensions.swift:~30` |
| `ScreenExtensions.isBuiltInDisplay` | `NemoNotch/Helpers/ScreenExtensions.swift` |
| `PassThroughView.hitTest(_:)` | `NemoNotch/Notch/NotchWindow.swift:28` |

---

## Pitfalls

1. **`NSScreen.main` 定向目标**：多显示器下指向 key-window 所在屏，不是用户活跃屏 → 用 `NSScreen.mouseScreen` 或 `screen(containing:)`。
2. **`isReleasedWhenClosed` 默认 `true`**：pool 里 `close()` 后再次使用 → 野指针；创建 overlay 窗口时显式 `isReleasedWhenClosed = false`。
3. **Notification 在睡眠/唤醒时密集触发**：handler 必须幂等，diff 而非重建全部。
4. **活跃屏消失（合盖）后悬空 `activeScreen`**：必须在 `screenParametersChanged` 里主动 nil + 强制 `status = .closed`。
5. **`collectionBehavior` 需在 `orderFront` 前设置**：后设置无效，需 `orderOut` + 重设 + `orderFront`。
6. **`MainActor` 隔离**：`NSApplication.didChangeScreenParametersNotification` 的回调上下文不一定是 `@MainActor`，需显式 `MainActor.assumeIsolated { }` 包裹。

---

## 落地 checklist

- [ ] 每屏 `makeWindow(for:)`，以 `screen.displayID` 为 key 存字典
- [ ] 监听 `NSApplication.didChangeScreenParametersNotification`，handler 做差集（不全重建）
- [ ] 纯视觉：`ignoresMouseEvents = true` + `canBecomeKey/Main → false`
- [ ] 交互：`PassThroughView` + `isBlocking` 状态切换
- [ ] 根据场景选 level：与 notch 同层 → `.statusBar+8`；通用 overlay → `.screenSaver`
- [ ] 配 `.fullScreenAuxiliary` 确保全屏 App 内可见
- [ ] HUD/Toast 只挂内置屏：`screen.isBuiltInDisplay`

---

## 延伸阅读

- [nspanel-and-notch.md](nspanel-and-notch.md) — notch 主面板配置、glow ring
- [window-conventions.md](window-conventions.md) — 激活策略、焦点还原
- [../events-hotkeys/](../events-hotkeys/) — 全局鼠标监听、`EventMonitor`
