---
summary: 'Display a non-interactive, focus-safe on-screen overlay using a borderless NSWindow at screen-saver level with SwiftUI content.'
read_when:
  - 'showing visual feedback overlays that must not steal focus from the automated target app'
  - 'positioning overlays correctly across multiple monitors without relying on NSScreen.main'
---

# 10 · Visualizer 不抢焦点的屏上 overlay

## TL;DR

在 macOS 上显示"看得见、点不到、不抢焦点"的屏上 overlay，核心是用无边框 `NSWindow` 配合 `level = .screenSaver`、`ignoresMouseEvents = true`、`isOpaque = false`，内容用 `NSHostingView` 承载 SwiftUI 视图。退场时先淡出再调 `orderOut` 释放资源，避免 overlay 残留。多屏场景下要根据鼠标或操作点所在的屏幕来定位，而不是依赖 `NSScreen.main`。整套模式与 AX 自动化、CGEvent 输入注入无缝串联，不干扰被操作应用的焦点状态。

## Peekaboo 在哪里实现

- 模块：`Core/PeekabooVisualizer/`
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/AnimationOverlayManager.swift:29` — 创建 overlay 窗口并设置所有无焦点属性，负责显示、淡出和移除
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/OptimizedAnimationQueue.swift:197` — 窗口池 `AnimationResourcePool`（`maxPoolSize = 10` 在 :203），复用最多 10 个 overlay 窗口减少分配开销
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/VisualizerCoordinator.swift:197` — `getTargetScreen(for:)` 封装多屏定位逻辑
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/NSScreen+MouseLocation.swift:13` — `mouseScreen` 和 `screen(containing:)` 扩展
- 相关 docs：`docs/visualizer.md`

## 设计动机（Why）

自动化 agent 执行点击、输入、截图时，需要向屏幕叠加实时视觉反馈。这些 overlay 有三个强约束：

1. **不抢焦点**：焦点跳走会导致后续 AX/CGEvent 操作打到错误窗口。
2. **不拦截鼠标**：overlay 只展示，不阻断操作。
3. **生命周期可控**：动画结束后必须干净退场，避免窗口列表污染或内存泄漏。

标准 `NSWindow` 默认会成为 key window 并接受鼠标事件，需用特定属性组合让它"隐形于交互层"。

## 核心模式（Pattern）

### NSWindow 无焦点配置清单

```swift
let window = NSWindow(
    contentRect: rect,
    styleMask: [.borderless],   // 无标题栏、无边框
    backing: .buffered,
    defer: false)

window.isOpaque         = false              // 允许透明内容
window.backgroundColor  = .clear
window.level            = .screenSaver       // 浮在所有普通窗口之上
window.ignoresMouseEvents = true             // 不拦截鼠标事件
window.hasShadow        = false              // 无投影，避免视觉干扰
window.isReleasedWhenClosed = false          // 手动管理生命周期
```

**关键**：`NSWindow` 的 `canBecomeKey` 和 `canBecomeMain` 默认实现对 `.borderless` 窗口返回 `false`，因此无需子类化即可保证不抢焦点。若要在全屏应用上显示，需额外设置：

```swift
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
```

- `.canJoinAllSpaces`：overlay 跟随所有 Space，切换桌面后继续可见。
- `.fullScreenAuxiliary`：允许窗口出现在全屏应用的 overlay 层，否则全屏模式下 overlay 不显示。

### SwiftUI 内容嵌入

```swift
let hostingView = NSHostingView(rootView: mySwiftUIView)
hostingView.wantsLayer = true
hostingView.layer?.backgroundColor = NSColor.clear.cgColor
hostingView.layer?.masksToBounds = false   // 允许动画溢出边界
window.contentView = hostingView
window.orderFront(nil)                     // 显示但不激活
```

用 `orderFront(nil)` 而非 `makeKeyAndOrderFront(_:)`，前者仅把窗口置前但不转移 key window 状态。

### 多屏定位

```swift
// 根据操作点定位到对应屏幕
func getTargetScreen(for point: CGPoint? = nil) -> NSScreen {
    if let point {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main!
    } else {
        // 无具体点时，跟随鼠标所在屏幕
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
    }
}
```

始终用操作点或鼠标坐标定位屏幕，不要直接用 `NSScreen.main`——在多屏、Sidecar、镜像等场景下 `main` 不等于用户正在操作的屏幕。

### 退场动画与生命周期

```swift
// 显示 duration 秒后淡出 0.3 秒，再移除
Task { @MainActor in
    try? await Task.sleep(for: .seconds(duration))
    await withCheckedContinuation { continuation in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)        // 隐藏
                windows.removeAll { $0 === window }  // 从跟踪列表移除
                continuation.resume()
            }
        }
    }
}
```

淡出完成回调里执行 `orderOut` + 从引用列表移除，确保窗口不残留。若提前取消，调 `removeAllWindows()` 一次性清理所有 overlay。

### 窗口池（可选优化）

高频动画场景（如鼠标轨迹）可复用窗口对象，避免反复分配。核心操作：归还时 `orderOut` + `contentView = nil` + `alphaValue = 1.0` 重置状态，限制池大小（≤10）防止内存占用膨胀。

### 与 AX/CGEvent 操作的时序

```
AX 查询 → CGEvent 注入 → [目标 app 响应] → 触发 overlay 显示
```

overlay 显示调用应在操作*之后*发起，不阻塞操作本身。使用 `async/await` + 优先级队列（high / normal / low）保证关键动画（点击、截图）优先展示，后台动画（鼠标轨迹）不阻塞主流程。

## 新项目落地步骤（How to apply）

1. 创建 `OverlayManager` 类，标注 `@MainActor`，持有 `[NSWindow]` 跟踪列表，确保所有窗口操作在主线程执行。
2. 在 `showOverlay(at:content:duration:)` 方法中按配置清单创建 `NSWindow`：`.borderless`、`level = .screenSaver`、`ignoresMouseEvents = true`、`isOpaque = false`、`backgroundColor = .clear`。
3. 若需要在全屏应用上显示，追加 `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`。
4. 用 `NSHostingView` 包裹 SwiftUI 内容视图，设置 `wantsLayer = true` 和透明背景，赋给 `window.contentView`，然后调 `window.orderFront(nil)`。
5. 用 `NSScreen` 扩展实现 `mouseScreen` 和 `screen(containing:)` 辅助方法，所有定位调用经此两个方法，禁止直接使用 `NSScreen.main`。
6. 在 `Task { @MainActor in }` 中 `sleep(duration)` → `NSAnimationContext` 淡出 → `orderOut` + 移除引用，三步串联实现干净退场；同时提供 `removeAll()` 供提前取消。
7. 验证：打开任意目标应用并保持其为 key window，触发 overlay，确认目标应用焦点不变；在全屏应用中重复验证。

## 常见陷阱（Pitfalls）

- **不用 `.borderless` 导致 `canBecomeKey` 返回 true**：`NSWindow` 对非 borderless 窗口默认允许成为 key window。看到 overlay 出现后目标应用标题栏变灰（失去焦点），检查 `styleMask` 是否包含 `.borderless`，并确认没有调用 `makeKeyAndOrderFront`。

- **漏设 `.fullScreenAuxiliary` 导致全屏下 overlay 不出现**：在全屏应用中触发动画，overlay 完全不可见。检查 `collectionBehavior` 是否包含 `.fullScreenAuxiliary`；注意必须在 `orderFront` *之前*设置，设置后可用 `window.collectionBehavior.contains(.fullScreenAuxiliary)` 断言确认。

- **退场未取消 Task 导致 overlay 残留**：用户快速连续触发多个动画，旧 overlay 的 sleep Task 还在等待，`removeAll()` 调用后又被 Task 完成回调重新 `orderFront`。看到屏幕上有僵尸 overlay 残留，检查 Task 是否持有对已移除窗口的强引用；退场 Task 开始前先检查窗口是否还在跟踪列表，或在 Task 中使用 `[weak window]` 捕获，若已 `orderOut` 则跳过后续操作。

- **多屏定位用 `NSScreen.main` 而非操作点所在屏幕**：在副显示器操作时 overlay 出现在主显示器，操作与视觉反馈错位。看到 overlay 位置与点击/输入位置不一致，检查定位逻辑是否使用了 `NSScreen.main`，替换为 `NSScreen.screens.first { $0.frame.contains(point) }`。

## 延伸阅读

- Peekaboo：`docs/visualizer.md`、`Core/PeekabooVisualizer/`
- Apple：[NSWindow](https://developer.apple.com/documentation/appkit/nswindow)、[NSWindow.Level](https://developer.apple.com/documentation/appkit/nswindow/level)、[NSWindow.CollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior)
- 其它 playbook：[06 · AXorcist](./06-ax-automation-axorcist.md)、[07 · CGEvent](./07-cgevent-input-synthesis.md)、[08 · 屏幕捕获](./08-screen-capture-windows-spaces.md)、[09 · SwiftUI + AppKit](./09-swiftui-appkit-liquid-glass.md)

---
*Last verified against Peekaboo @ `71976886`*
