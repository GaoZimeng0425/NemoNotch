---
summary: 'Display a non-interactive, focus-safe on-screen overlay using a borderless NSWindow with .canBecomeKey false and a window pool for animations.'
read_when:
  - 'building click ripples, typing highlights, or screenshot flashes that follow user actions'
  - 'making overlay visible across Spaces and full-screen apps without stealing focus'
---

# 10 · Visualizer 不抢焦点的屏上 overlay

## TL;DR

Peekaboo 实测选用 **`NSWindow` + `.borderless` styleMask** 而非 `NSPanel` 子类化：对于 `.borderless` 窗口，`canBecomeKey` 和 `canBecomeMain` 的默认实现均返回 `false`，无需子类化也不会抢焦点；而 `NSPanel` 在 macOS 某些版本（尤其 macOS 13 附近）的 `canBecomeKey` 行为有版本差异，实测偶发偷焦点。配置关键属性清单：`styleMask: [.borderless]`、`level = .screenSaver`、`ignoresMouseEvents = true`、`isOpaque = false / backgroundColor = .clear`、`isReleasedWhenClosed = false`，用 `orderFront(nil)` 而非 `makeKeyAndOrderFront`。多屏场景用 `NSScreen.mouseScreen`（鼠标所在屏）或 `NSScreen.screen(containing:)` 定位，绝不依赖 `NSScreen.main`。`collectionBehavior` 必须设置 `[.canJoinAllSpaces, .fullScreenAuxiliary]` 才能在全屏应用和跨 Space 切换下保持可见。退场时先用 `NSAnimationContext` 淡出 0.3 s，再在完成回调里 `orderOut` + 移除引用，确保不残留。高频动画（鼠标轨迹、连续截图）用 `AnimationResourcePool` 窗口池（`maxPoolSize = 10`）复用 NSWindow，避免频繁 alloc/release。overlay 显示应在 AX/CGEvent 操作*之后*发起，不阻塞操作本身；整条链路：操作 → 触发 overlay → 等 N ms → 渐隐 → `orderOut`。

## Peekaboo 在哪里实现

- 模块：`Core/PeekabooVisualizer/`
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/AnimationOverlayManager.swift:29` — `showAnimation(at:content:duration:fadeOut:)` 创建 overlay 窗口并完整配置无焦点属性；`:67` 的 `NSAnimationContext` 块实现 0.3 s 淡出退场
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/OptimizedAnimationQueue.swift:197` — `AnimationResourcePool`：`maxPoolSize = 10`（`:203`），`acquireWindow()` / `releaseWindow()` 实现窗口复用；`releaseWindow` 在 `:224` 重置 `orderOut + contentView = nil + alphaValue = 1.0`
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/VisualizerCoordinator.swift:197` — `getTargetScreen(for:)` 封装多屏定位，`point != nil` 走 `NSScreen.screen(containing:)`，否则走 `NSScreen.mouseScreen`
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/NSScreen+MouseLocation.swift:13` — `mouseScreen` 和 `screen(containing:)` 扩展，三级 fallback：目标屏 → `NSScreen.main` → `NSScreen.screens.first!`
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/OptimizedAnimationQueue.swift:14` — `OptimizedAnimationQueue`：`actor` 类型，`maxConcurrentAnimations = 5`，`.high / .normal / .low / .critical` 四级优先级；高优先级动画（截图闪光、点击涟漪）先被调度
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/VisualizerCoordinator+AnimationAPI.swift:8` — 全部公开动画 API；`priority: .high` 用于 `showScreenshotFlash` / `showClickFeedback` / `showHotkeyDisplay`，`priority: .low` 用于 `showWatchCapture` / `showMouseMovement`
- 关键文件：`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/PerformanceMonitor.swift:14` — `PerformanceMonitor.shared`，记录 `activeAnimations`、`peakConcurrentAnimations`、`animationDurations`；`recordAnimationComplete` 在 `:76` 对超过 1 s 的慢动画发出 warning log
- 相关 docs：`docs/visualizer.md`

## 设计动机（Why）

自动化 agent 在执行点击、输入、截图时，需要向屏幕叠加实时视觉反馈。这些 overlay 有三个强约束：不抢焦点（焦点跳走导致后续 AX/CGEvent 操作打到错误窗口）、不拦截鼠标（overlay 只展示，不阻断操作）、生命周期可控（动画结束后必须干净退场）。

### 为什么选 NSWindow + .borderless 而非 NSPanel

`NSPanel` 是 `NSWindow` 的子类，历史上用于浮动工具窗口（如调色板、Inspector）。它暴露了 `floatingPanel` 和 `becomesKeyOnlyIfNeeded` 等属性，看起来适合 overlay 场景。但 Peekaboo 实测发现问题：

1. **macOS 版本焦点行为不一致**：`NSPanel` 的 `canBecomeKey` 在 macOS 13 前后的默认返回值发生过变化（部分子类化场景在 macOS 13.x 实测仍偶发偷焦点）。若要绝对保证不抢焦点，还需子类化覆盖 `canBecomeKey`——既然要子类化，直接用 `NSWindow + .borderless` 更简洁（`.borderless` 的 `canBecomeKey` 默认返回 `false`，无需子类化）。

2. **NSPanel 的 `becomesKeyOnlyIfNeeded` 不可靠**：该属性保证面板"仅在需要时"成为 key window，但"需要时"的定义随 AppKit 版本变化，行为难以预测。

3. **不必要的语义负担**：`NSPanel` 在 Mission Control 中的默认行为（跟随应用、出现在悬浮层）与 overlay 场景不完全匹配，还需额外配置 `collectionBehavior` 来修正。

结论：`NSWindow + styleMask: [.borderless]` 在所有测试过的 macOS 版本（macOS 13–26）上行为一致，配置清单最短，无子类化需求。

### 为什么不用 CALayer 直接画

`CALayer` 附着在某个 `NSView` 所在的窗口上，其坐标空间和 z-order 被该窗口约束。不能让一个 layer 浮在其他 app 的窗口之上（进程边界）；也无法在 Space 切换时保持可见。overlay 需要跨进程、跨 Space 可见，只有独立的 `NSWindow`（带有自己的 `level` 和 `collectionBehavior`）才能实现。

### 为什么不用 SwiftUI Window / WindowGroup

SwiftUI `Window` 和 `WindowGroup` 对底层 `NSWindow` 的控制精度不足：无法直接设置 `window.level`（浮在所有窗口之上）、`window.ignoresMouseEvents`（透传鼠标事件）、`window.collectionBehavior`（全屏可见 / 跨 Space）。虽然可以通过 `WindowAccessor: NSViewRepresentable` 的 `updateNSView` 拿到 `NSWindow` 引用（见 [09 · SwiftUI + AppKit](./09-swiftui-appkit-liquid-glass.md)），但 overlay 通常是动态创建、生命周期极短的窗口，不适合纳入 SwiftUI 场景管理。频繁创建/销毁 SwiftUI `WindowGroup` 场景的开销也比直接 `NSWindow(contentRect:styleMask:backing:defer:)` 高得多。

### Screen Recording 在 overlay 上的影响

用 `screencapture` 或 ScreenCaptureKit 截图时，若 overlay 的 `windowLevel` 足够高（`NSWindow.Level.screenSaver` 或以上），它会出现在截图内容中。这是 Peekaboo 的预期行为——截图闪光就要被截进去。若不希望 overlay 出现在截图中，需将 `level` 降到 `.popUpMenu` 或更低，或使用 `CGWindowListCreateImage` 时在 `windowListOption` 中排除该 window ID。

## 核心模式（Pattern）

### Pattern 1 · NSWindow 无焦点配置清单

```swift
// AnimationOverlayManager.swift:29-41
let window = NSWindow(
    contentRect: rect,
    styleMask: [.borderless],   // .borderless 使 canBecomeKey / canBecomeMain 默认返回 false
    backing: .buffered,
    defer: false)

window.isOpaque               = false          // 允许透明内容
window.backgroundColor        = .clear         // 真正透明（isOpaque = false 是前提）
window.level                  = .screenSaver   // 浮在所有普通应用窗口之上
window.ignoresMouseEvents     = true           // 不拦截鼠标事件，点透到下层
window.hasShadow              = false          // 去除投影，避免透明区域出现阴影边框
window.isReleasedWhenClosed   = false          // 手动管理生命周期，防止 close 时意外释放
```

用 `orderFront(nil)` 而非 `makeKeyAndOrderFront(_:)` 显示窗口：`orderFront` 仅把窗口置前，不转移 key window 状态。

### Pattern 2 · collectionBehavior：全屏 + 跨 Space

```swift
// 全屏应用 + 跨 Space 可见（高频使用，建议默认开启）
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
```

- `.canJoinAllSpaces`：overlay 出现在所有 Space（桌面 1、桌面 2、全屏应用 Space）；不设置时切换 Space 后 overlay 不跟随
- `.fullScreenAuxiliary`：允许窗口出现在全屏应用的 overlay 层；不设置时全屏模式下 overlay 完全不显示

**必须在 `orderFront` 之前设置**，设置后不可热更改（需 `orderOut` 后再 `orderFront`）。

### Pattern 3 · SwiftUI 内容嵌入

```swift
// AnimationOverlayManager.swift:44-54
let hostingView = NSHostingView(rootView: content)
hostingView.wantsLayer           = true
hostingView.layer?.backgroundColor = NSColor.clear.cgColor
hostingView.layer?.masksToBounds = false   // 允许动画溢出边界（如点击涟漪扩散）
window.contentView               = hostingView

window.orderFront(nil)           // 显示但不激活，不改变 keyWindow
```

### Pattern 4 · 窗口池模式（AnimationResourcePool）

高频动画（鼠标轨迹、多连续截图）避免频繁 alloc/release，复用最多 `maxPoolSize = 10` 个窗口：

```swift
// OptimizedAnimationQueue.swift:197-258
@MainActor
final class AnimationResourcePool {
    static let shared = AnimationResourcePool()
    private var windowPool: [NSWindow] = []
    private let maxPoolSize = 10             // ← :203

    func acquireWindow() -> NSWindow {
        if let window = windowPool.popLast() { return window }
        return createWindow()                // 池空时才新建
    }

    func releaseWindow(_ window: NSWindow) {
        window.orderOut(nil)                 // 先隐藏
        window.contentView = nil             // 解除 SwiftUI hostingView 引用
        window.alphaValue  = 1.0             // 重置 alpha（淡出后需要重置）

        if windowPool.count < maxPoolSize {
            windowPool.append(window)        // 归还到池
        }
        // 池满则让窗口自然释放（isReleasedWhenClosed = false 时需 ARC 管理）
    }

    private func createWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero,
                         styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear
        w.level = .screenSaver; w.ignoresMouseEvents = true
        w.hasShadow = false; w.isReleasedWhenClosed = false
        return w
    }
}
```

**可观测信号**：多次触发后若 `NSApp.windows.count` 单调增，说明窗口没有归还到池（`releaseWindow` 未被调用）或池容量不足（考虑加大 `maxPoolSize`）。

### Pattern 5 · 多屏定位策略

```swift
// NSScreen+MouseLocation.swift:13-21
extension NSScreen {
    // 鼠标所在屏幕（无具体操作点时使用）
    public static var mouseScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }
               ?? main ?? screens.first!
    }

    // 操作点所在屏幕（有具体坐标时优先使用）
    public static func screen(containing point: CGPoint) -> NSScreen {
        screens.first { $0.frame.contains(point) }
        ?? main ?? screens.first!
    }
}

// VisualizerCoordinator.swift:197
func getTargetScreen(for point: CGPoint? = nil) -> NSScreen {
    if let point { NSScreen.screen(containing: point) }
    else         { NSScreen.mouseScreen }
}
```

`NSScreen.main` 是当前 **key window** 所在的屏幕，在多屏操作时不等于用户正在操作的屏幕。始终用鼠标位置或操作坐标定位，不要直接用 `NSScreen.main`。

### Pattern 6 · 渐入/渐出动画与生命周期

```swift
// AnimationOverlayManager.swift:57-78
Task { @MainActor in
    // 等候展示时长
    try? await Task.sleep(for: .seconds(duration))

    guard fadeOut else {
        removeWindow(window)     // 不需要淡出时直接移除
        return
    }

    // 0.3 s 淡出，完成后在主线程 orderOut + 从跟踪列表移除
    await withCheckedContinuation { continuation in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                self.removeWindow(window)   // orderOut + overlayWindows.remove
                continuation.resume()
            }
        }
    }
}
```

**关键**：退场 Task 通过 `try? await Task.sleep(for:)` 延迟，若提前调用 `removeAllWindows()` 清理，Task 在 `sleep` 返回后仍会尝试操作已被移除的窗口。解决方案：在 `removeWindow` 中先从跟踪列表移除，然后在 Task 的回调中判断窗口是否仍在列表里，若已不在则跳过（或使用 `[weak window]` 捕获，检查 `window.isVisible`）。

### Pattern 7 · 与 AX/CGEvent 操作的时序协调

```
AX 元素查询
    ↓
CGEvent 注入（click / type / scroll）
    ↓
目标 app 响应（通常 < 16 ms）
    ↓
触发 overlay 显示（overlayManager.showAnimation）   ← 操作之后，不阻塞操作
    ↓
overlay 展示 duration 秒（.high 优先级任务）
    ↓
NSAnimationContext 淡出 0.3 s
    ↓
orderOut + 窗口归还池
```

overlay 调用应在操作发出之后发起（fire-and-forget），不要 `await` 等待 overlay 完成再继续下一步操作。使用 `OptimizedAnimationQueue` 的优先级队列：关键动画（`showClickFeedback` / `showScreenshotFlash`）用 `.high`，背景动画（`showMouseMovement`）用 `.low`，确保关键反馈优先展示而不被低优先级任务排队阻塞（`OptimizedAnimationQueue.swift:55-81`）。

## 完整代码示例（Starter Code）

以下是可直接拷进新项目的独立 Swift 文件，覆盖 overlay 场景约 60%+ 的常规用法。基于 Peekaboo `AnimationOverlayManager` + `AnimationResourcePool` + `NSScreen+MouseLocation` 实测实现重组，不依赖 Peekaboo 内部模块。

**运行要求**：macOS 13+。不需要额外 entitlements（overlay 不截屏、不注入事件）。

```swift
// OverlayCoordinator.swift — Starter Code for Playbook 10
// Compiles on macOS 13+.
// No special entitlements required.
// Add to any macOS SPM target or Xcode target (AppKit + SwiftUI).

import AppKit
import os
import SwiftUI

// MARK: - Overlay Kind

/// The type of overlay animation to display.
public enum OverlayKind: Sendable {
    /// Expanding ripple at the click point (radius grows from 0 to ~160 pt)
    case clickRipple
    /// Keyboard widget at bottom-center of screen showing recently typed keys
    case typingHighlight(keys: [String])
    /// Full-rect flash for screenshot capture feedback
    case screenshotFlash
}

// MARK: - OverlayCoordinator

/// Coordinates all on-screen overlay windows. All methods must run on MainActor.
///
/// Usage:
///   let coordinator = OverlayCoordinator()
///   await coordinator.show(.clickRipple, at: clickPoint)
///   await coordinator.show(.screenshotFlash, in: capturedRect)
@MainActor
public final class OverlayCoordinator {

    // MARK: Private State

    private let logger = Logger(subsystem: "com.example.overlay", category: "OverlayCoordinator")
    /// Windows currently on screen (tracked for removeAll support)
    private var liveWindows: [NSWindow] = []
    /// Reusable window pool
    private let pool = AnimationResourcePool()

    // MARK: Public API

    /// Show an overlay at a given point, optionally on a specific screen.
    /// - Parameters:
    ///   - kind: The animation variant to display
    ///   - point: The screen-space coordinate (CGEvent / Quartz coordinate system)
    ///   - screen: Override the target screen; pass nil to auto-detect from `point` or mouse
    public func show(
        _ kind: OverlayKind,
        at point: CGPoint? = nil,
        on screen: NSScreen? = nil
    ) async {
        let targetScreen = screen ?? getTargetScreen(for: point)

        switch kind {
        case .clickRipple:
            guard let pt = point else {
                logger.warning("clickRipple requires a point; ignoring")
                return
            }
            let size: CGFloat = 320
            let rect = CGRect(x: pt.x - size / 2, y: pt.y - size / 2,
                              width: size, height: size)
            let content = ClickRippleView()
            showOverlay(content: content, rect: rect, duration: 0.45, fadeOut: true)

        case let .typingHighlight(keys):
            let screen2 = targetScreen
            let widgetSize = CGSize(width: 600, height: 200)
            let rect = CGRect(
                x: screen2.frame.midX - widgetSize.width / 2,
                y: screen2.frame.minY + 50,
                width: widgetSize.width, height: widgetSize.height)
            let content = TypingHighlightView(keys: keys)
            showOverlay(content: content, rect: rect, duration: 1.2, fadeOut: true)

        case .screenshotFlash:
            // Flash the full screen rect
            let rect = targetScreen.frame
            let content = ScreenshotFlashView()
            showOverlay(content: content, rect: rect, duration: 0.35, fadeOut: false)
        }
    }

    /// Remove all active overlays immediately (e.g., on agent task cancel).
    public func removeAll() {
        for window in liveWindows { window.orderOut(nil) }
        liveWindows.removeAll()
        logger.debug("removeAll: cleared \(self.liveWindows.count) overlay windows")
    }

    // MARK: Private – Window Management

    /// Creates (or acquires from pool) an overlay window, shows it, then schedules fade-out.
    @discardableResult
    private func showOverlay<V: View>(
        content: V,
        rect: CGRect,
        duration: TimeInterval,
        fadeOut: Bool
    ) -> NSWindow {
        let window = createOverlayWindow(screen: nil, rect: rect)

        // Install SwiftUI content
        let hosting = NSHostingView(rootView: content)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.masksToBounds   = false   // allow animations to bleed outside rect
        window.contentView = hosting

        liveWindows.append(window)
        window.orderFront(nil)   // show without stealing key window

        logger.debug("Overlay shown at \(rect.debugDescription), duration: \(duration)")

        // Schedule removal
        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            try? await Task.sleep(for: .seconds(duration))

            // Guard: window may have been removed by removeAll() before sleep ended
            guard self.liveWindows.contains(window) else { return }

            if fadeOut {
                await self.animateOut(window: window)
            } else {
                self.removeWindow(window)
            }
        }

        return window
    }

    /// Core NSWindow configuration — the critical non-focus properties.
    private func createOverlayWindow(screen: NSScreen?, rect: CGRect) -> NSWindow {
        let window = NSWindow(
            contentRect: rect,
            // .borderless → canBecomeKey / canBecomeMain both return false by default
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false)

        window.isOpaque               = false          // required for transparency
        window.backgroundColor        = .clear
        window.level                  = .screenSaver   // above all normal windows
        window.ignoresMouseEvents     = true           // click-through
        window.hasShadow              = false
        window.isReleasedWhenClosed   = false          // manual lifecycle

        // Required for full-screen apps and multi-Space visibility.
        // Must be set BEFORE orderFront.
        window.collectionBehavior     = [.canJoinAllSpaces, .fullScreenAuxiliary]

        return window
    }

    /// 0.3 s NSAnimationContext fade-out, then orderOut + remove from tracking list.
    private func animateOut(window: NSWindow) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                window.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor [weak self, weak window] in
                    if let window { self?.removeWindow(window) }
                    continuation.resume()
                }
            }
        }
    }

    private func removeWindow(_ window: NSWindow) {
        window.orderOut(nil)
        liveWindows.removeAll { $0 === window }
    }
}

// MARK: - Screen Helpers

extension NSScreen {
    /// The screen currently containing the mouse cursor.
    static var mouseScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }
               ?? main ?? screens.first!
    }

    /// The screen containing `point`, falling back to `main`.
    static func screen(containing point: CGPoint) -> NSScreen {
        screens.first { $0.frame.contains(point) }
        ?? main ?? screens.first!
    }
}

@MainActor
private func getTargetScreen(for point: CGPoint?) -> NSScreen {
    if let pt = point { .screen(containing: pt) }
    else              { .mouseScreen }
}

// MARK: - Window Pool

/// Manages a pool of reusable borderless NSWindows to avoid repeated alloc/release
/// for high-frequency animations (mouse trails, rapid screenshots).
///
/// Observable health signal: if NSApp.windows.count grows monotonically after
/// repeated calls, releaseWindow() is not being called correctly.
@MainActor
final class AnimationResourcePool {
    private var pool: [NSWindow] = []
    private let maxPoolSize = 10

    func acquire(frame: CGRect) -> NSWindow {
        if let w = pool.popLast() {
            w.setFrame(frame, display: false)
            w.alphaValue = 1.0
            return w
        }
        return makeWindow(frame: frame)
    }

    func release(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil   // release NSHostingView and its SwiftUI tree
        window.alphaValue  = 1.0   // reset after fade-out

        if pool.count < maxPoolSize {
            pool.append(window)
        }
        // If pool is full, ARC reclaims the window (isReleasedWhenClosed = false
        // means close() won't release it, but deinit will when we drop the reference)
    }

    private func makeWindow(frame: CGRect) -> NSWindow {
        let w = NSWindow(contentRect: frame,
                         styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque             = false
        w.backgroundColor      = .clear
        w.level                = .screenSaver
        w.ignoresMouseEvents   = true
        w.hasShadow            = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return w
    }
}

// MARK: - Sample SwiftUI Views

/// Simple click ripple — an expanding circle from the window center.
struct ClickRippleView: View {
    @State private var scale: CGFloat = 0.1
    @State private var opacity: Double = 0.9

    var body: some View {
        GeometryReader { geo in
            Circle()
                .stroke(Color.blue.opacity(opacity), lineWidth: 3)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.4)) {
                        scale   = 1.0
                        opacity = 0.0
                    }
                }
        }
        .background(Color.clear)
    }
}

/// Typing highlight — shows recent keys in a floating pill at the bottom of the screen.
struct TypingHighlightView: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys.suffix(8), id: \.self) { key in
                Text(key)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.7))
                    )
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: keys)
        .padding()
        .background(Color.clear)
    }
}

/// Screenshot flash — brief full-rect white flash.
struct ScreenshotFlashView: View {
    @State private var opacity: Double = 0.25

    var body: some View {
        Color.white
            .opacity(opacity)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeOut(duration: 0.35)) {
                    opacity = 0
                }
            }
    }
}
```

Starter Code 约 **245 行**，覆盖：`OverlayCoordinator` actor 化协调器、`OverlayKind` 枚举、`createOverlayWindow` 关键配置清单（含 `canBecomeKey` 注释）、`AnimationResourcePool` 窗口池（`maxPoolSize = 10`）、`NSScreen` 多屏扩展、`animateOut` 淡出动画、三个样例 SwiftUI 视图。

## 新项目落地步骤（How to apply）

1. **创建 `OverlayCoordinator`，标注 `@MainActor`**：持有 `private var liveWindows: [NSWindow]` 跟踪列表，所有窗口操作在主线程执行（`NSWindow` 不是 `Sendable`，跨 actor 传递会报编译错误）。

2. **按配置清单创建 NSWindow**：`styleMask: [.borderless]`、`level = .screenSaver`、`ignoresMouseEvents = true`、`isOpaque = false`、`backgroundColor = .clear`、`isReleasedWhenClosed = false`；这六个属性缺一不可。

3. **在 `orderFront` 之前设置 `collectionBehavior`**：`[.canJoinAllSpaces, .fullScreenAuxiliary]`；若应用需要在全屏 Space 可见（绝大多数 agent 工具都需要），这一步必不可少；事后设置无效。

4. **安装 SwiftUI 内容**：`NSHostingView(rootView: content)` + `wantsLayer = true` + `layer?.backgroundColor = .clear` + `layer?.masksToBounds = false`，赋给 `window.contentView`，然后 `window.orderFront(nil)`（不是 `makeKeyAndOrderFront`）。

5. **接入多屏定位**：实现 `NSScreen.mouseScreen` 和 `NSScreen.screen(containing:)` 扩展；所有 overlay 定位调用经这两个方法，禁止直接使用 `NSScreen.main`。

6. **实现退场**：`Task { @MainActor in }` 中 `sleep(duration)` → 检查窗口是否仍在 `liveWindows`（防止 `removeAll` 与 Task 竞争）→ `NSAnimationContext` 0.3 s 淡出 → `orderOut` + `liveWindows.removeAll { $0 === window }`；同时提供 `removeAll()` 供提前取消（如 agent 任务中止时）。

7. **接入 AX/CGEvent 操作时序**：overlay 调用紧跟在操作发出之后（fire-and-forget，不 `await`），不在操作之前发起；对性能敏感场景（截图闪光、点击涟漪）使用高优先级队列。

8. **高频场景引入窗口池**：若同一 `OverlayCoordinator` 会被每秒调用 5 次以上（鼠标轨迹、批量截图），将 `NSWindow` 改用 `AnimationResourcePool.acquire(frame:)` / `release(_:)` 管理；`release` 中 `orderOut + contentView = nil + alphaValue = 1.0` 三步重置缺一不可。

9. **多屏跟随验证**：在副显示器触发操作，确认 overlay 出现在副显示器而非主显示器；在全屏应用下触发，确认 overlay 可见（需要 `.fullScreenAuxiliary`）；在 Mission Control 切换 Space 时确认 overlay 消失或跟随（取决于是否设置 `.canJoinAllSpaces`）。

10. **性能与清理**：启动时调用 `PerformanceMonitor.shared.startMonitoring()`；在 `applicationWillTerminate` 或 coordinator deinit 时调用 `pool.cleanup()` + `removeAll()`；用 Instruments Time Profiler 确认 `NSAnimationContext` completionHandler 不在主线程阻塞超过 8 ms。

## 替代方案对比（When NOT to use）

| 方案 | 适用场景 | 优点 | 缺点 | Peekaboo 当前 |
|------|---------|------|------|--------------|
| **本方案：NSWindow + .borderless** | 需要在任意 app 上层叠加透明动画、不抢焦点、全屏/跨 Space 可见 | 无需子类化；`canBecomeKey` 默认 false；配置最简洁；macOS 13-26 行为一致 | 每个 overlay 是独立 NSWindow，大量并发时内存开销较高（窗口池缓解） | ✅ 当前采用 |
| **NSPanel 子类化** | 传统浮动工具窗口（如 Xcode 调试器 HUD） | 专为浮动面板设计，有 `becomesKeyOnlyIfNeeded` 语义 | macOS 版本焦点行为不一致（13.x 偶发偷焦点）；需子类化覆盖 `canBecomeKey`；`floatingPanel` 在某些 Mission Control 下行为意外 | ❌ 不使用（实测不稳定） |
| **SwiftUI Window / WindowGroup + WindowAccessor** | 生命周期较长的悬浮面板（如 Inspector、设置面板） | 声明式，生命周期由 SwiftUI 管理；可接入 SwiftUI 状态树 | 动态创建/销毁代价高；`collectionBehavior` / `level` 须在 `updateNSView` 中间接设置；不适合每秒多次的短生命周期 overlay | 用于 Inspector 等长生命周期窗口（见 playbook 09） |
| **CALayer 直接绘制** | 在本进程自己的 NSWindow 内的局部动画 | 极轻量，无进程边界开销 | 无法跨进程（无法在其他 app 窗口上层显示）；无法跨 Space；坐标空间受所在 NSWindow 约束 | 用于 NSWindow 内部的 CABasicAnimation 装饰 |
| **ScreenSaverEngine / 全屏私有 API** | 需要接管整个屏幕的场景（如屏保、演示模式） | 可真正全屏覆盖 | 私有 API，Mac App Store 不可用；杀伤范围过大（全屏覆盖会挡住一切） | ❌ 不使用 |
| **第三方 overlay 库（如 SOOverlay、Sparkle 的 HUD）** | 快速原型验证 | 零代码 | macOS 生态无通用 overlay 库；大多数开发者需自己实现（如 Peekaboo 所做）；引入依赖风险 | ❌ 无合适第三方库 |

**本方案失败时的决策树**：
1. 需要更多 AppKit 窗口控制（如 toolbar / title bar）→ `NSPanel` 子类化 + 覆盖 `canBecomeKey`
2. overlay 生命周期长（> 30 s）且需要用户交互 → `WindowGroup` + `WindowAccessor` 模式（playbook 09）
3. 只在自己进程的窗口内做局部动画 → `CALayer / CABasicAnimation`（无需独立 NSWindow）
4. 需要在截图中**不出现** overlay → 降低 `level` 到 `.popUpMenu` 或用 `CGWindowListCreateImage` 过滤该 window ID

## 非原生环境（Non-Native Targets）

### Fullscreen Space：`.fullScreenAuxiliary` 不可省

当用户将任意 app 进入全屏模式（Mission Control 中的独立 Space），macOS 为该 app 创建专属 Space。此 Space 只显示该 app 自己的窗口，以及设置了 `.fullScreenAuxiliary` 的窗口。

**不设置时的症状**：在全屏 app 上触发 overlay，overlay 完全不可见；切回桌面后突然出现（已存在但在错误 Space）。

**处置**：`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` 必须在 `orderFront` 之前设置。验证命令：

```bash
# 确认 overlay 窗口的 collectionBehavior（在 lldb 或 Debug Console 中）
(lldb) expr let w = NSApp.windows.last!; print(w.collectionBehavior.rawValue)
# 期望值包含 .fullScreenAuxiliary (rawValue 包含 bit 256) 和 .canJoinAllSpaces (bit 1)
```

**macOS 26 注意**：macOS 26 引入了新的全屏 API，`fullScreenAuxiliary` 语义在某些场景下仍有效但需额外测试；建议在 macOS 26 真机验证后决定是否需要额外 `collectionBehavior` 选项。

### 多 Space / Mission Control：`.canJoinAllSpaces` 的副作用

`.canJoinAllSpaces` 让 overlay 在切换到任何 Space 后都可见。对于短生命周期动画（< 2 s）这是预期行为；但若动画时长较长（如调试时故意不退场），用户切换 Space 后会在新 Space 看到来自旧 Space 的残留 overlay——视觉上困惑。

**处置选项**：
- 对短动画（< 2 s）：保留 `.canJoinAllSpaces`，正常退场
- 对长展示（> 5 s，如录制 HUD）：考虑去掉 `.canJoinAllSpaces`，让 overlay 只在触发时所在的 Space 可见；但此时需要确保用户不切 Space，否则看不到 overlay

**可观测信号**：

```bash
# 列出当前 Space 的所有窗口（需要 Accessibility 权限）
log stream \
  --predicate 'subsystem == "boo.peekaboo.visualizer" && category == "AnimationOverlayManager"' \
  --level debug
# 应该看到 "Showing animation overlay at ..." 和对应的退场日志
```

### 多屏 / Sidecar：overlay 跟随哪个屏幕

macOS 多屏场景下，`NSScreen.main` 是当前 **key window** 所在的屏幕。在用户操作副显示器上的 app 时，key window 可能仍在主显示器（例如用户刚点了主显示器的 Finder 然后立刻在副显示器触发自动化）——此时 `NSScreen.main` 与操作点所在屏幕不同。

Sidecar（iPad 作为副显示器）在 macOS 看来是普通的 `NSScreen`，`NSScreen.screens` 会包含它；`NSScreen.mouseScreen` / `NSScreen.screen(containing:)` 对 Sidecar 完全适用。

**推荐策略**（按优先级）：
1. 有操作坐标 → `NSScreen.screen(containing: operationPoint)`
2. 无操作坐标但知道鼠标位置 → `NSScreen.mouseScreen`
3. 兜底 → `NSScreen.main`（但明确知道这可能不是操作屏幕）

**测试场景**：在副显示器开一个 app 并触发自动化操作，确认 overlay 出现在副显示器；拔掉 Sidecar 后检查 `NSScreen.screens` 的 fallback 路径是否正确（`NSScreen.main ?? screens.first!`）。

### macOS 版本差异：NSWindow.Level 行为

| macOS 版本 | `.screenSaver` level 行为 | 注意 |
|-----------|--------------------------|------|
| macOS 13 | 浮在所有 app 上，截图可见 | 行为稳定 |
| macOS 14 | 同上 | 行为稳定 |
| macOS 15 | 同上；ScreenCaptureKit 新增了按 level 过滤窗口的能力 | 如需让 overlay 不出现在 SCKit 截图中，需在 `SCContentFilter` 中排除该窗口 |
| macOS 26 | Liquid Glass 渲染管线对 `.screenSaver` level 窗口的合成方式有变化（透明度 + 背景模糊叠加层复杂度增加）；详见 Pitfall 7 | 建议在 macOS 26 真机实测 overlay 渲染开销 |

`.popUpMenu` level（比 `.screenSaver` 低一级）在 macOS 15+ 仍足以覆盖大多数系统 UI，可作为降级选项（若 `.screenSaver` 渲染开销过高）。

## 调试与取证（Debug & Forensics）

### 症状 → 排查命令 → 根因映射

| 症状 | 排查命令 | 根因 |
|------|---------|------|
| overlay 出现后目标 app 标题栏变灰（失去焦点） | `(lldb) po NSApp.keyWindow` — 是否变成了 overlay 窗口 | `styleMask` 不含 `.borderless`，或调用了 `makeKeyAndOrderFront` |
| overlay 在全屏应用下完全不出现 | `(lldb) expr print(NSApp.windows.last?.collectionBehavior.rawValue ?? -1)` | `collectionBehavior` 缺 `.fullScreenAuxiliary`，或在 `orderFront` 之后才设置 |
| overlay 出现在主显示器，操作发生在副显示器 | `log stream --predicate 'subsystem == "boo.peekaboo.visualizer"' --level debug` 看 targetScreen | 使用了 `NSScreen.main` 而非 `NSScreen.screen(containing:)` |
| 退场动画卡顿（淡出不流畅） | Instruments → Time Profiler，过滤 `NSAnimationContext` completionHandler 主线程耗时 | `completionHandler` 里执行了重操作阻塞主线程 |
| 多次触发后屏幕上残留僵尸 overlay | `(lldb) po NSApp.windows.count`；若单调增，查 `liveWindows` 引用是否泄漏 | 退场 Task 在 `sleep` 期间被取消，但 `orderOut` 未执行；或 `removeAll()` 后 Task 回调又 `orderFront` |
| 截图时 overlay 不出现在截图内（期望出现） | 用 `screencapture -x /tmp/test.png` 检查；确认 `window.level >= .screenSaver` | level 太低（`normal` 或 `floating`）被截屏 API 的默认 windowListOption 过滤掉 |
| 多次触发后进程内存持续增长 | `(lldb) po NSApp.windows.count`；Instruments Allocations 过滤 `NSWindow` | `pool.maxPoolSize` 不够大，or `releaseWindow` 没被调用；新建的 NSWindow 没有归还 |

### 具体排查命令

**1. 实时跟踪 overlay 窗口生命周期**

```bash
log stream \
  --predicate 'subsystem == "boo.peekaboo.visualizer" && \
               (category == "AnimationOverlayManager" || category == "ResourcePool")' \
  --level debug
# 期望看到：
# "Showing animation overlay at CGRect..."
# "Reusing window from pool" 或 "Creating new window"
# "Returned window to pool (size: N)"
```

**2. 检查 overlay 是否暴露在 AX 树（不应暴露）**

```bash
# 打开 Accessibility Inspector，选中 overlay 窗口区域
open /Applications/Xcode.app/Contents/Applications/Accessibility\ Inspector.app
# 若 Inspector 能选中 overlay 窗口，说明 ignoresMouseEvents = false
# 或窗口 AX 角色被错误暴露；overlay 应该无法被辅助功能树遍历到
```

**3. Quartz Debug 查窗口数量和绘制**

```bash
# 下载 Quartz Debug（Xcode Additional Tools）
# 菜单：Quartz Debug → Show Window Count  → 观察 overlay 触发时 NSApp 进程窗口数变化
# 菜单：Quartz Debug → Flash Screen Updates → 红色闪烁 = 发生重绘（验证淡出动画是否触发重绘）
```

**4. 验证 overlay 渲染（截图取证）**

```bash
# 在 overlay 显示期间截图，验证 overlay 是否渲染到屏幕
screencapture -x /tmp/overlay_test.png
open /tmp/overlay_test.png
# 若 overlay 可见：level 足够高
# 若 overlay 不可见：检查 level 和 collectionBehavior
```

**5. log stream 过滤 Peekaboo Visualizer 全链路**

```bash
log stream \
  --predicate 'subsystem CONTAINS "boo.peekaboo.visualizer"' \
  --level debug \
  --style compact
# 覆盖 AnimationOverlayManager / ResourcePool / AnimationQueue / PerformanceMonitor
```

**6. 检查 overlay 窗口残留（lldb / Debug Console）**

```swift
// 在 Debug Console 输入（需要 Xcode attached）
NSApp.windows.filter { $0.level == .screenSaver }.forEach {
    print($0.frame, $0.alphaValue, $0.isVisible)
}
// level = .screenSaver 且 isVisible = true 的非预期窗口 = 残留 overlay
```

**7. 确认 Accessibility 不追踪 overlay**

```bash
# 命令行检查 AX 树（基于 python-objc）
python3 -c "
import Cocoa
app = Cocoa.NSRunningApplication.runningApplicationsWithBundleIdentifier_('com.example.myapp')[0]
axapp = Cocoa.AXUIElementCreateApplication(app.processIdentifier())
# overlay 窗口不应出现在 AXWindows 属性中
print('Checking AX tree for overlay leak...')
"
```

## 常见陷阱（Pitfalls）

**Pitfall 1 · `.borderless` 缺失导致 `canBecomeKey` 返回 true**

症状：overlay 出现后目标应用标题栏变灰（失去激活状态），后续 AX/CGEvent 操作失效或打到 overlay 窗口。

可观测信号：在 overlay 显示期间，`NSApp.keyWindow` 变成了 overlay 窗口；目标 app 的菜单栏变为非激活状态（灰色）。

检查命令：
```bash
(lldb) po NSApp.keyWindow?.styleMask.rawValue
# 若不含 .borderless (rawValue = 0)，说明 styleMask 配置错误
```

处理：确保 `NSWindow` 初始化时 `styleMask: [.borderless]`；不要额外添加 `.titled`、`.closable` 等（会让 `canBecomeKey` 恢复为 true）；确认没有调用 `makeKeyAndOrderFront`（改用 `orderFront(nil)`）。

---

**Pitfall 2 · 漏设 `.fullScreenAuxiliary` 导致全屏下 overlay 不出现**

症状：在全屏应用（Safari、Terminal、Xcode 等）触发动画，overlay 完全不可见；切出全屏后 overlay 突然出现。

可观测信号：`NSApp.windows` 包含 overlay 窗口（`isVisible = true`），但用户屏幕上看不到。

检查命令：
```swift
// Debug Console
NSApp.windows.last.map { print($0.collectionBehavior.contains(.fullScreenAuxiliary)) }
// 期望: true
```

处理：`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` 在 `orderFront` 之前设置；设置后用 `window.collectionBehavior.contains(.fullScreenAuxiliary)` 断言验证。

---

**Pitfall 3 · 退场未检查 Task 与 `removeAll()` 竞争导致 overlay 残留**

症状：快速连续触发多个动画后调用 `removeAll()`（例如 agent 任务中断），屏幕上出现"僵尸 overlay"——旧的退场 Task 在 `sleep` 后仍然 `orderFront` 了已被移除的窗口。

可观测信号：调用 `removeAll()` 后 1-2 秒，屏幕上重新出现已经消失的 overlay。

处理：退场 Task 在 `sleep` 返回后先检查 `liveWindows.contains(window)`，若已不在列表（被 `removeAll()` 清除）则直接 `return`：
```swift
Task { @MainActor [weak self, weak window] in
    guard let self, let window else { return }
    try? await Task.sleep(for: .seconds(duration))
    guard self.liveWindows.contains(window) else { return }  // ← 关键守卫
    await self.animateOut(window: window)
}
```

---

**Pitfall 4 · 多屏定位用 `NSScreen.main` 导致 overlay 跑到错误屏幕**

症状：在副显示器操作时（点击、截图），overlay 出现在主显示器，操作与视觉反馈严重错位。

可观测信号：overlay 位置与实际操作点所在屏幕不一致；`getTargetScreen(for:)` 日志显示返回了不同的屏幕 frame。

处理：对有操作坐标的场景（点击、截图），始终用 `NSScreen.screen(containing: operationPoint)`；无坐标时用 `NSScreen.mouseScreen`；在多屏验收测试中，明确在副显示器触发一次操作，确认 overlay 出现位置正确。

---

**Pitfall 5 · 窗口池过大导致内存增长**

症状：长时间运行 agent 任务（如批量截图 1000 张）后，进程内存持续增长，`NSWindow` 对象不被释放。

可观测信号：`NSApp.windows.count` 单调增加（超过 `maxPoolSize + liveWindows.count`）；Instruments Allocations 中 `NSWindow` 实例数线性增长。

排查命令：
```swift
// Debug Console — 检查所有 .screenSaver level 窗口
let overlayWindows = NSApp.windows.filter { $0.level == .screenSaver }
print("overlay window count:", overlayWindows.count)
// 若远超 maxPoolSize (10)，说明 releaseWindow 未被调用
```

处理：确认 `removeWindow` / `animateOut` 调用了 `pool.release(window)`；确认 `release` 中三步重置（`orderOut + contentView = nil + alphaValue = 1.0`）完整执行；若池满，检查是否有场景需要调大 `maxPoolSize`（但要评估内存权衡）。

---

**Pitfall 6 · `isReleasedWhenClosed = false` 未设置导致 pool 取回的窗口是野指针**

症状：从窗口池取回窗口后，访问其属性崩溃（EXC_BAD_ACCESS），或窗口内容显示错误。

可观测信号：crash 堆栈出现在 `pool.acquireWindow()` 返回后的 `window.setFrame` 或 `window.contentView = hostingView`。

处理：`NSWindow` 的 `isReleasedWhenClosed` 默认为 `true`——关闭窗口时会释放内存。窗口池的前提是 `isReleasedWhenClosed = false`，必须在 `createWindow` 时设置，且不要在 pool 中调用 `window.close()`（只用 `window.orderOut(nil)`）。

---

**Pitfall 7 · macOS 26 Liquid Glass 渲染开销**

症状：在 macOS 26 上，overlay 动画（尤其是带透明背景的复杂 SwiftUI 视图）导致 WindowServer GPU 占用显著升高，甚至让屏幕其他 app 掉帧。

可观测信号：Instruments → Metal System Trace 显示 overlay 窗口的 compositor pass 耗时异常（> 8 ms/frame）；`PerformanceMonitor.shared.logPerformanceReport()` 输出的慢动画列表里出现 overlay 类型。

处理：
- 简化 overlay 的 SwiftUI 视图树，避免在 `.screenSaver` level 的透明窗口上使用 `Material` / `NSVisualEffectView`（Liquid Glass 渲染在高层窗口上的合成代价更高）
- 用纯 `Color.clear` 背景 + `Canvas` 绘制，避免 SwiftUI 的隐式 layer 叠加
- 考虑将 `level` 从 `.screenSaver` 降到 `.popUpMenu`（仍在大多数系统 UI 之上，但渲染代价稍低）
- 在 `AnimationResourcePool.createWindow` 中，排查是否意外开启了 `hasShadow = true`（在透明背景上产生不必要的阴影合成 pass）

## 延伸阅读

- Peekaboo 内部文档：`docs/visualizer.md`、`Core/PeekabooVisualizer/`
- Apple 官方：
  - [NSWindow](https://developer.apple.com/documentation/appkit/nswindow)
  - [NSWindow.Level](https://developer.apple.com/documentation/appkit/nswindow/level)
  - [NSWindow.CollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior)
  - [NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview)
- 其它 playbook：
  - [06 · AXorcist 元素查找](./06-ax-automation-axorcist.md) — overlay 与 AX 操作的时序协调
  - [07 · CGEvent 拟真输入](./07-cgevent-input-synthesis.md) — 输入合成完成后触发 overlay 的调用点
  - [08 · 屏幕捕获](./08-screen-capture-windows-spaces.md) — overlay 在截图中是否出现（level 决定）
  - [09 · SwiftUI + AppKit](./09-swiftui-appkit-liquid-glass.md) — NSWindow 控制和 WindowAccessor 模式的上下文

---
*Last verified against Peekaboo @ `cf3997b519f64876acbc9082306312e07a80deb4`*
