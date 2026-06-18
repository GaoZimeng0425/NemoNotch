---
summary: '通过 paired global+local NSEvent monitor 监听鼠标进出,以及配套的 hitbox 计算与右键 context menu 管理。'
read_when:
  - '为 macOS 浮动面板实现鼠标悬停自动展开/收起'
  - '需要在 notch 工具类应用中全局捕获鼠标移动或点击事件'
  - '调试鼠标离开后面板意外关闭、或进入 NSMenu 时面板抖动关闭'
sources: ['N §6']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# 全局 NSEvent 监听 + Hitbox 计算

## TL;DR

macOS 悬浮面板(如 notch 工具)需要响应 **来自其他 app 的鼠标事件**——但 `NSWindow` 默认只接收自身收到的事件。解决方案:同时挂载 **global monitor**(捕获非本 app 的事件)和 **local monitor**(捕获本 app 的事件),并通过两段式 hitbox(open 时 tight / close 时加 inset)实现带迟滞的开关判断。

## 可复用模式

### 1 · Paired global + local NSEvent monitor

同时安装 global 和 local 两个监听器,缺一不可:

```swift
// NemoNotch/Notch/EventMonitor.swift:17-52  start()
private func start() {
    let globalMove = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
        MainActor.assumeIsolated {
            self?.onMouseMove?(NSEvent.mouseLocation)
        }
    }
    // globalDown / globalRightDown 以相同方式安装,matching .leftMouseDown / .rightMouseDown
    let localMove = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
        MainActor.assumeIsolated {
            self?.onMouseMove?(NSEvent.mouseLocation)
        }
        return event  // 本地 monitor 必须返回 event,否则后续视图不会收到
    }
    // localDown / localRightDown 同理
    monitors = [globalMove as Any, globalDown as Any, globalRightDown as Any,
                localMove as Any, localDown as Any, localRightDown as Any]
}
```

**为什么需要两个:**
- `addGlobalMonitorForEvents` 在本 app **无 key 焦点**时触发(notch 工具的正常工况:用户聚焦的是别的 app)
- `addLocalMonitorForEvents` 在本 app **有 key 焦点**时触发

### 2 · 屏幕坐标 hit 检测

```swift
// NemoNotch/Notch/NotchCoordinator.swift:295
self?.onMouseMove?(NSEvent.mouseLocation)
```

`NSEvent.mouseLocation` 使用**主屏幕左下角为原点**的坐标系,与 `NSScreen.frame` 一致。

### 3 · Hitbox 两段式迟滞

```swift
// NemoNotch/Notch/NotchCoordinator.swift:275-291  handleMouseMove(_:)
private func handleMouseMove(_ location: NSPoint) {
    guard !isContextMenuVisible else { return }
    switch status {
    case .closed:
        guard let screen = screen(at: location) else { return }
        if NSMouseInRect(location, hitboxRect(for: screen), false) {
            notchOpen(on: screen)
        }
    case .opened:
        guard let active = activeScreen else { return }
        let contentHit = contentRect(for: active, hitInset: NotchConstants.closeHitboxInset)
        if !NSMouseInRect(location, contentHit, false) {
            notchClose()
        }
    }
}
```

- **open hitbox** = notch 设备矩形 + `hitboxPadding = 10pt` 膨胀 → 小,避免鼠标离开时误触发重新打开
- **close hitbox** = 已展开内容矩形 + `closeHitboxInset = 20pt` for hover / `10pt` for click → 大,避免用户在面板内交互时误关闭

常量来源:`Helpers/Constants.swift:10-12`

### 4 · Right-click context menu + isContextMenuVisible 保护

```swift
// NemoNotch/Notch/NotchCoordinator.swift:313-351  handleRightMouseDown(_:)
isContextMenuVisible = true
let menu = NSMenu()
let delegate = ContextMenuDelegate(
    onClose: { [weak self] in self?.isContextMenuVisible = false },
    onSettings: { @MainActor [weak self] in self?.onShowSettings?() },
    onQuit: { NSApp.terminate(nil) }
)
contextMenuDelegate = delegate
menu.delegate = delegate
// ... 添加菜单项 ...
menu.popUp(positioning: nil, at: point, in: nil)
```

`ContextMenuDelegate` 在 `menuDidClose` 中重置 `isContextMenuVisible`(`NotchCoordinator.swift:400-421`)。

### 5 · Haptic feedback

```swift
// NemoNotch/Notch/NotchCoordinator.swift:186  notchOpen(tab:on:)
NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
```

## 锚点

| 位置 | 功能 |
|------|------|
| `NemoNotch/Notch/EventMonitor.swift:17-52` | `start()` — 安装所有 monitor |
| `NemoNotch/Notch/NotchCoordinator.swift:275-291` | `handleMouseMove(_:)` — hitbox 判断 |
| `NemoNotch/Notch/NotchCoordinator.swift:293-311` | `handleMouseDown()` — click hitbox |
| `NemoNotch/Notch/NotchCoordinator.swift:313-351` | `handleRightMouseDown(_:)` + context menu |
| `NemoNotch/Notch/NotchCoordinator.swift:400-421` | `ContextMenuDelegate` |
| `NemoNotch/Notch/NotchCoordinator.swift:48-50` | `hitboxRect(for:)` — notch + 10pt 膨胀 |
| `NemoNotch/Notch/NotchCoordinator.swift:63-71` | `contentRect(for:hitInset:)` |
| `NemoNotch/Helpers/Constants.swift:10-12` | `hitboxPadding` / `closeHitboxInset` / `clickHitboxInset` 常量 |
| `NemoNotch/Notch/NotchCoordinator.swift:186` | haptic feedback 调用 |

## Pitfalls

**1. Global monitor 返回的对象必须强引用保存**
`addGlobalMonitorForEvents` 返回的 opaque object 是 monitor token。一旦该对象被 ARC 释放,monitor 立即被移除。必须存入 `monitors: [Any]` 等 property,不能是局部变量。

**2. Local monitor 必须 return event**
`addLocalMonitorForEvents` 的闭包如果不返回 event(或返回 nil 表示吞掉),下游视图、窗口都不会收到该事件。通常返回原始 `event`;只有明确需要拦截时才返回 nil。

**3. `MainActor.assumeIsolated` 是 Swift 6 的越界跳转**
NSEvent monitor 闭包文档保证在 main thread 执行,但 Swift 6 编译器无法静态验证这一点。`assumeIsolated { … }` 是正确的转义方式——仅在确实位于 main thread 时才使用,否则会 crash。

**4. `NSEvent.mouseLocation` Y 轴朝上**
返回屏幕坐标(主屏左下角为原点,Y 向上)。与 `NSScreen.frame` 一致,可直接用 `NSMouseInRect`。若要与 SwiftUI view-local 坐标比较,需先做 screen-frame 转换。

**5. `isContextMenuVisible` 保护不可缺少**
`menu.popUp(...)` 是**同步的**——它内部会 spin 一个 nested run loop 直到用户关闭菜单。在此期间鼠标会移到菜单上方,此时 `contentRect` 不包含菜单位置,若无 `isContextMenuVisible` 保护,`handleMouseMove` 会立即调用 `notchClose()`。

**6. ContextMenuDelegate 必须强引用至 popUp 返回后**
若只声明为局部变量,delegate 会在 `popUp` 进入 nested run loop 之前 dealloc,`@objc` 方法 target 悬空,选择器调用 crash 或被静默忽略。

**7. `NSHapticFeedbackManager` 在无 Force Touch 硬件上静默忽略**
Magic Mouse、外置键盘、2015 前 MacBook 上无效。不要用 haptic 状态做业务判断,只作为纯 polish 层。

## 落地 checklist

- [ ] `monitors` 是 `[Any]` property,非局部变量
- [ ] local monitor 闭包末尾 `return event`
- [ ] 闭包内访问 `@MainActor` 状态前调用 `MainActor.assumeIsolated { … }`
- [ ] `deinit` 或 `stop()` 中调用 `NSEvent.removeMonitor(m)` 清理所有 token
- [ ] open hitbox 设 tight padding(≤10pt),避免鼠标离开后立即重触发
- [ ] close hitbox 加 inset(≥20pt hover / ≥10pt click),避免面板内交互时误关闭
- [ ] 右键菜单前设 `isContextMenuVisible = true`,`menuDidClose` 中重置
- [ ] `ContextMenuDelegate` 存入 strong property

## 延伸阅读

- [热键注册](hotkeys.md) — KeyboardShortcuts 全局热键,与 event monitor 互补
- [../window/](../window/) — NotchWindow NSPanel 配置,Pass-through view 让 click-through 工作
- [../permissions/](../permissions/) — Accessibility 权限请求流程(EventMonitor 本身不需要,但 AX 自动化需要)
