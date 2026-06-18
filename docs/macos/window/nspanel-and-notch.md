---
summary: 'NSPanel/NSWindow 用于 macOS notch 区域：level、collectionBehavior、tri-state 状态机、hotkey-aware dismiss、glow ring 渲染技法'
read_when:
  - '需要在 notch 区域创建悬浮面板'
  - '调试 collectionBehavior 导致的 Mission Control / fullscreen 可见性问题'
  - '实现 tri-state open/popping/closed 动画状态机'
  - '实现基于 .mask + .screen blendMode 的 glow ring 效果'
  - '实现 completion flash 全屏 overlay'
sources: ['NemoNotch §5.1–§5.10', 'Peninsula', 'DynamicNotchKit', 'NotchDrop']
last_verified: { nemonotch: 'fe4e9e5' }
---
# NSPanel & Notch 窗口

## TL;DR

NemoNotch 的 notch 面板是一个 `.borderless` `NSWindow`（或 `NSPanel` 子类），`level = .statusBar + 8`，同时持有 `[.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]` 四个 `collectionBehavior` 标志。整个面板覆盖全屏，通过 `PassThroughView` 按需暴露/屏蔽点击事件。Completion flash 则是独立的 `ignoresMouseEvents = true` 全屏透明窗口，用 `.screen` blendMode + `.mask` clip 实现内边缘 glow ring。

---

## 可复用模式

### 1. 无边框窗口配置（`.statusBar + 8`）

```swift
// NotchWindow.swift:3-22  init(rect:)
class NotchWindow: NSWindow {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        alphaValue = 1
        level = .statusBar + 8       // 经验值：+0 在某些版本会被 menubar UI 遮挡
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        acceptsMouseMovedEvents = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }
    override var canBecomeKey: Bool { true }   // 搜索框需要键盘焦点
    override var canBecomeMain: Bool { true }
}
```

**为什么用 `.statusBar + 8`：** `.statusBar + 0` 在部分 macOS 版本下会被 menu-extras 遮挡；`+8` 是 NemoNotch 测试出的稳定清除值。若窗口仍在菜单栏 UI 后面，尝试再往上加。

### 2. `collectionBehavior` 四标志

```swift
// NotchWindow.swift:21
collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
```

| 标志 | 作用 |
|------|------|
| `.fullScreenAuxiliary` | 其他 App 进全屏时本窗口保持可见 |
| `.stationary` | Mission Control / Spaces 切换时不随桌面滑动 |
| `.canJoinAllSpaces` | 跨所有 Space 可见 |
| `.ignoresCycle` | 排除在 Cmd-Tab / Cmd-\` 之外 |

缺少 `.stationary` → Mission Control 时窗口会漂移；缺少 `.ignoresCycle` → notch 出现在 Cmd-Tab 列表。

### 3. `PassThroughView` 按需穿透

```swift
// NotchWindow.swift:28-36  PassThroughView.hitTest(_:)
final class PassThroughView: NSView {
    var isBlocking = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if view !== self { return view }
        return isBlocking ? self : nil
    }
}
```

- `isBlocking = true`：notch 展开时阻止点击穿透（`NotchCoordinator.swift:191`）
- `isBlocking = false`：notch 收起时放行（`NotchCoordinator.swift:202`）
- `super.hitTest` 先调用，确保 SwiftUI 子视图仍能收到点击

**陷阱：** 若 notch 收起后忘记 `isBlocking = false`，菜单栏附近区域会吞掉所有点击。

### 4. Tri-state 状态机（closed / popping / opened）

参考 Peninsula 的三态实现：

```
closed  →(mouse enter / hotkey)→  popping  →(animation done)→  opened
opened  →(mouse leave / ESC)→     closing  →(animation done)→  closed
```

- `closed`：`PassThroughView.isBlocking = false`，窗口仍在屏幕上但内容隐藏
- `popping`：开始弹出动画，`.bouncy(duration: 0.4)`（DynamicNotchKit 参数）
- `opened`：内容完全可见，`isBlocking = true`

### 5. Hotkey-aware dismiss

全局热键打开 notch 后，**不**立即在鼠标离开时关闭，直到：
- (a) 鼠标进入内容区域至少一次
- (b) 3 秒内无鼠标进入（`NotchConstants.hotkeyAutoCloseDelay`）
- (c) 用户按 ESC / 热键 / 在外侧点击

状态机在 `HotkeyDismissState` 中，与 `NotchCoordinator` 协作。

### 6. Activity Glow Ring（展开时内边缘光晕）

```swift
// NotchBackgroundView（伪码示意）
NotchShape()
    .stroke(NotchTheme.accent, lineWidth: glowRingWidth)
    .blur(radius: glowRingBlur)
    .blendMode(.screen)                       // 仅叠加不遮挡
    .mask(
        LinearGradient(                        // 只让下半边缘发光
            gradient: Gradient(colors: [.black, .clear]),
            startPoint: .bottom,
            endPoint: .center
        )
    )
    .mask(notchShape)                          // clip 向外扩散，只留内边缘
    .allowsHitTesting(false)
    .opacity(glowRingOpacity)
```

决策逻辑（纯函数）：
- `.attention`：有 session 等待审批
- `.running`：AI 工作中 / agent 活跃
- `.none`：否则

可调常量：`NotchConstants.glowRingOpacity` / `glowRingWidth` / `glowRingBlur` / `glowRingCoverage`

### 7. Completion Flash（全屏 overlay 窗口）

```swift
// CompletionFlashWindow.swift:6-25
final class CompletionFlashWindow: NSWindow {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 8
        ignoresMouseEvents = true         // 纯视觉：永不捕获点击
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

与 `NotchWindow` 的关键差异：
- `ignoresMouseEvents = true`（不需要 `PassThroughView`）
- `canBecomeKey/Main` 均返回 `false`
- 窗口大小 = 全屏 `NSScreen.frame`（而非 notch 区域小矩形）

Flash 动画曲线：`0 → 1 → completionFlashDipLevel → 1 → 0`（双脉冲），由 `CompletionFlashService` 驱动，`flashLevel` 经 `completionFlashRise / completionFlashDip / completionFlashFall` 三段控制。Toast 独立于 HUD 的 `hudDismissDelay`，使用 `completionToastDuration`（5 s）。

### 8. 热键触发快速工具窗（`NSPanel`）

```swift
// QuickStartWindow.swift
NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], ...)
window.isFloatingPanel = true
window.level = .floating
window.collectionBehavior = [.canJoinAllSpaces, .transient]
window.isMovableByWindowBackground = true   // 整窗口可拖动
override var canBecomeKey: Bool { true }    // TextField 需要键盘焦点
```

点击外侧关闭：`NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)`，dismiss 时 uninstall。

---

## 锚点（file:line）

| 符号 | 位置 |
|------|------|
| `NotchWindow.init(rect:)` | `NemoNotch/Notch/NotchWindow.swift:3` |
| `PassThroughView.hitTest(_:)` | `NemoNotch/Notch/NotchWindow.swift:28` |
| `NotchCoordinator.makeSlot(for:)` | `NemoNotch/Notch/NotchCoordinator.swift:127` |
| `NotchCoordinator.captureFrontmostApp()` | `NemoNotch/Notch/NotchCoordinator.swift:220` |
| `CompletionFlashWindow.init(rect:)` | `NemoNotch/Notch/CompletionFlashWindow.swift:6` |
| `CompletionFlashWindowController.rebuild()` | `NemoNotch/Notch/CompletionFlashWindow.swift` |
| `QuickStartWindow` | `NemoNotch/Notch/QuickStartWindow.swift` |
| `ScreenExtensions.hasNotch` | `NemoNotch/Helpers/ScreenExtensions.swift:9` |

---

## Pitfalls

1. **`.statusBar + 0` 被遮挡**：某些 macOS 版本下 menu-extras 会覆盖，用 `+8`。
2. **`isBlocking` 状态不同步**：notch 收起后未清 `isBlocking = true` → 点击穿透失效。
3. **`orderFrontRegardless()` vs `makeKeyAndOrderFront`**：slot 初始化用前者（不抢焦点），打开 notch 用后者（需要焦点）。
4. **热键打开后 3 秒逻辑**：若跳过 `HotkeyDismissState`，鼠标稍微移动就关闭，体验差。
5. **`canBecomeKey = false` 对 flash window 必须显式覆写**：`.borderless` NSWindow 默认有时仍会响应 key。

---

## 落地 checklist

- [ ] `styleMask: [.borderless]`，`isOpaque = false`，`backgroundColor = .clear`
- [ ] `level = .statusBar + 8`（若仍被遮挡，尝试 `+9`）
- [ ] `collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`
- [ ] 交互窗口：`PassThroughView` + `isBlocking` 按状态切换
- [ ] 纯视觉 overlay：`ignoresMouseEvents = true`，`canBecomeKey/Main → false`
- [ ] Glow ring：`.screen` blendMode + 双层 `.mask`（形状 clip + gradient 渐隐）
- [ ] 多屏：每屏一个 slot，见 [multi-screen-overlay.md](multi-screen-overlay.md)

---

## 延伸阅读

- [multi-screen-overlay.md](multi-screen-overlay.md) — per-screen WindowController、level 选择并列
- [window-conventions.md](window-conventions.md) — 激活策略、焦点还原、OS 原生约定
- [../events-hotkeys/](../events-hotkeys/) — 全局鼠标 / 键盘事件监听
- [../swiftui/](../swiftui/) — SwiftUI `WindowAccessor`、`NSHostingController` 三件套
