---
summary: '@main App + @NSApplicationDelegateAdaptor 双层架构、WindowAccessor、NSHostingView 三件套、Liquid Glass 统一适配器封装（macOS 14 / 26 双版本）。'
read_when:
  - '新建 macOS app 需要同时控制 NSWindow level/styleMask 和 SwiftUI 声明式 UI'
  - '采用 Liquid Glass 材质并需要 macOS 14 fallback'
  - '在 AppKit 容器（NSGlassEffectView / NSVisualEffectView）中嵌入 SwiftUI 内容'
  - '调试 NSHostingView 状态重置或 updateNSView 重复 addSubview'
sources: ['P09']
last_verified:
  peekaboo: 'e3a66d317544420891d62da17120bf18e37118f3'
  nemonotch: 'fe4e9e5'
---

# AppKit Bridging + Liquid Glass

## TL;DR

Peekaboo 以 `@main App` 协议入口 + `@NSApplicationDelegateAdaptor` 桥接 `AppDelegate`，在 SwiftUI 场景树管理多窗口的同时保留完整 AppKit 生命周期控制。需要精确控制 `NSWindow` 时，通过 `WindowAccessor: NSViewRepresentable` 在 `updateNSView` 取到真实窗口。Liquid Glass 效果由 `ModernEffectView` 在运行时分支：`#available(macOS 26, *)` 走 `NSGlassEffectView`，低版本走 SwiftUI 原生 `Material`。AppKit 容器内嵌 SwiftUI 内容靠 `HostingViewHelpers` 三件套，防止 `NSHostingView` 在每次 `updateNSView` 被重建导致 SwiftUI 状态清零。

---

## 可复用模式

### Pattern 1 · 双层架构：SwiftUI 场景 + AppDelegate 生命周期

```swift
// PeekabooApp.swift:11
@main
struct PeekabooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = PeekabooSettings()   // @Observable 根状态

    var body: some Scene {
        WindowGroup("Peekaboo Sessions", id: "main") {
            SessionMainWindow()
                .environment(settings)
                .task { appDelegate.connectToState(…) }
        }
        Settings { SettingsWindow(…).environment(settings) }
    }
}
```

SwiftUI 负责场景路由与 environment 注入；`AppDelegate` 负责 AppKit 专属时序（`applicationDidFinishLaunching`、全局快捷键、状态栏 item）。两层通过 `connectToState(_:)` 完成一次性握手，之后状态单向流动到 SwiftUI 树。

> **与 NemoNotch 的差异**（架构取向不同，各有适用场景）：NemoNotch 完全使用 `AppDelegate`（不用 `@main App`），所有服务在 `applicationDidFinishLaunching` 里手动实例化，再通过 `.environment(instance)` 注入 `NotchView`。Peekaboo 的双层方案适合需要 `WindowGroup` 多窗口管理 + 精确 `AppKit` 控制权的中大型 app；NemoNotch 的纯 AppDelegate 方案适合 notch 这类无主窗口、单一 UI 树的工具型 app。

---

### Pattern 2 · `@Observable @MainActor` 根状态

```swift
// Settings.swift:12
@Observable
@MainActor
final class PeekabooSettings { … }
```

`@Observable` 精确追踪属性粒度依赖（仅读到的属性变化才重绘）；`@MainActor` 满足 Swift 6 严格并发下跨模块传递的 `Sendable` 约束。在 `App` 层用 `@State private var settings = PeekabooSettings()` 初始化，`.environment(settings)` 下传整棵场景树。

**注意：** `@Observable` 需要 macOS 14+；低于 14 须用 `ObservableObject` + `@Published`。

**Gotcha（Swift 6 Sendable）**：`@Observable` 类默认不 `Sendable`。跨模块传入 `async` 函数或 Task 闭包时报编译错误 → 给类加 `@MainActor`；跨模块传递时限制在 `@MainActor` Task 里：

```swift
// PeekabooApp.swift:82
appDelegate.windowOpener = { windowId in
    Task { @MainActor in self.openWindow(id: windowId) }
}
```

`withObservationTracking` 回调在任意线程调用，须用 `Task { @MainActor in … }` 切回主线程。

---

### Pattern 3 · WindowAccessor：SwiftUI 取底层 NSWindow

`makeNSView` 阶段 view 尚未插入窗口层级，`nsView.window` 为 nil；只有 `updateNSView` 才保证非 nil。

```swift
// InspectorWindow.swift:45
struct WindowAccessor: NSViewRepresentable {
    let windowAction: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }  // 空 view

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            windowAction(window)   // 此处保证非 nil
        }
    }
}
```

在目标 SwiftUI 视图的 `.background {}` 中嵌入：

```swift
// InspectorWindow.swift:17
InspectorView()
    .background(WindowAccessor { window in
        window.styleMask          = [.titled, .closable, .miniaturizable, .resizable]
        window.level              = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.identifier         = NSUserInterfaceItemIdentifier("inspector")
    })
```

**Gotcha：** `windowAction` 在每次 SwiftUI 刷新时重复调用。幂等操作（设置 styleMask/level）无害；非幂等操作（如 `addObserver`）须加 guard 防重入。

---

### Pattern 4 · NSHostingView 三件套（HostingViewHelpers）

所有需要在 AppKit 容器内承载 SwiftUI 内容的 `NSViewRepresentable` 均应通过三件套：

```swift
// HostingViewHelpers.swift:9

// 创建：带 identifier，禁用 autoresizingMask
func makeHostedContentView<C: View>(
    _ content: C,
    identifier: NSUserInterfaceItemIdentifier) -> NSHostingView<C>
{
    let hv = NSHostingView(rootView: content)
    hv.identifier = identifier
    hv.translatesAutoresizingMaskIntoConstraints = false
    return hv
}

// 固定：四边 Auto Layout 约束
func pinHostedContentView(_ child: NSView, to parent: NSView) {
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        child.topAnchor.constraint(equalTo: parent.topAnchor),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
}

// 复用：按 identifier 查找已有实例，避免重建
func hostedContentView<C: View>(
    identifiedBy id: NSUserInterfaceItemIdentifier,
    in contentView: NSView?, fallbackView: NSView) -> NSHostingView<C>?
{
    (contentView?.subviews.first(where: { $0.identifier == id })
     ?? fallbackView.subviews.first(where: { $0.identifier == id }))
    as? NSHostingView<C>
}
```

正确用法：

```swift
// makeNSView：建立一次
func makeNSView(context: Context) -> NSGlassEffectView {
    let glass = NSGlassEffectView()
    let hv = makeHostedContentView(content, identifier: myID)
    let target = glass.contentView ?? glass
    target.addSubview(hv)
    pinHostedContentView(hv, to: target)
    return glass
}

// updateNSView：复用，只更新 rootView
func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
    hostedContentView(identifiedBy: myID,
        in: nsView.contentView, fallbackView: nsView)?.rootView = content
}
```

**Gotcha（Pitfall 3）：** `updateNSView` 被 SwiftUI 频繁调用。每次都新建 `NSHostingView` + `addSubview` 会销毁旧 SwiftUI 树，`@State` 值、动画进度、输入焦点全部归零，并出现闪烁。

---

### Pattern 5 · Liquid Glass 统一适配器封装

```swift
// ModernEffects.swift:15
@available(macOS 14.0, *)
struct ModernEffectView<Content: View>: View {
    let style: ModernEffectStyle
    let cornerRadius: CGFloat
    let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            // macOS 26+：NSGlassEffectView via NSViewRepresentable
            NativeGlassWrapper(style: style, cornerRadius: cornerRadius, content: content)
        } else {
            // macOS 14-25：SwiftUI Material
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(style.nativeMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
```

对外统一 `glassSurface` modifier（`ModernEffects.swift:243`）：

```swift
extension View {
    func glassSurface(
        style: ModernEffectStyle = .content,
        cornerRadius: CGFloat = 16) -> some View
    {
        modifier(GlassSurfaceModifier(style: style, cornerRadius: cornerRadius))
    }
}
```

调用侧零感知版本分支（`SessionComponents.swift:48`）：

```swift
.glassSurface(style: .content, cornerRadius: 14)
```

**Gotcha（Pitfall 5）：** Intel Mac 上 `NSGlassEffectView` blur 由 CPU 承担，WindowServer 占用飙升。在 `if #available(macOS 26, *)` 分支内额外检测 `#if arch(arm64)`，Intel 路径降级到 `NSVisualEffectView.material`。

**Gotcha（Pitfall 8）：** `GlassEffectView` / `NativeGlassWrapper` 整体标 `@available(macOS 26.0, *)`；else 分支不得引用任何 macOS 26 符号——引用后在 macOS 14 设备运行时产生 dyld 链接报错（非编译错误）。

---

### Pattern 6 · AppKit 嵌入 SwiftUI（NSHostingController 菜单栏弹出层）

```swift
// StatusBarController.swift:116
popover.contentViewController = NSHostingController(
    rootView: popoverView.environment(state))
```

SwiftUI 视图用 `.environment` 而非构造参数接收状态，保证 `@Observable` 追踪正常工作。

---

### Pattern 7 · NSVisualEffectView（macOS 14-25 vibrancy 背景）

```swift
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active   // ← 必须，否则非 key window 时失活变白
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
```

`state = .active` 是关键：默认 `.followsWindowActiveState` 导致非焦点 inspector overlay 材质失活。

---

## 锚点

| 锚点 | 文件:行 |
|------|--------|
| `@main PeekabooApp` 双层入口 | `Apps/Mac/Peekaboo/PeekabooApp.swift:11` |
| `AppDelegate` 生命周期桥 | `Apps/Mac/Peekaboo/PeekabooApp.swift:184` |
| `WindowAccessor` | `Apps/Mac/Peekaboo/Features/Inspector/InspectorWindow.swift:45` |
| `GlassEffectView` (macOS 26+) | `Apps/Mac/Peekaboo/Core/GlassEffectView.swift:16` |
| `HostingViewHelpers` 三件套 | `Apps/Mac/Peekaboo/Core/HostingViewHelpers.swift:9` |
| `ModernEffectView` 双版本切换 | `Apps/Mac/Peekaboo/Core/ModernEffects.swift:15` |
| `glassSurface` modifier | `Apps/Mac/Peekaboo/Core/ModernEffects.swift:243` |
| `NSHostingController` 菜单栏 | `Apps/Mac/Peekaboo/Features/StatusBar/StatusBarController.swift:116` |
| `PeekabooSettings` 根状态 | `Apps/Mac/Peekaboo/Core/Settings.swift:12` |

---

## Pitfalls

1. **`makeNSView` 里 `nsView.window` 为 nil**：window 在 `updateNSView` 才可用；用 `WindowAccessor` 模式。
2. **`@Observable` 跨模块 Sendable 错误**：给类加 `@MainActor`；Task 闭包加 `@MainActor in`。
3. **`updateNSView` 重复 `addSubview` → SwiftUI 状态重置**：用 `hostedContentView(identifiedBy:)` 复用实例。
4. **`@Observable` 在 macOS 13 不可用**：支持 macOS < 14 须改用 `ObservableObject` + `@Published`。
5. **Intel Mac Liquid Glass 卡顿**：`#if arch(arm64)` 区分 Apple Silicon / Intel，Intel 降级到 `NSVisualEffectView`。
6. **`windowAction` 非幂等操作重入**：`addObserver` 等非幂等操作须加 guard 防每次刷新重复执行。
7. **`connectToState` 被 `WindowGroup.task` 重复调用**：在方法内加 `guard statusBarController == nil` 幂等保护。

---

## 落地 Checklist

- [ ] `@main App` + `@NSApplicationDelegateAdaptor` 入口已配置；`AppDelegate` 标注 `@MainActor final class`
- [ ] 根状态类同时标注 `@Observable @MainActor final class`
- [ ] 状态通过 `connectToState` / `.task {}` 握手一次，后续单向流动
- [ ] 需要 NSWindow 控制：插入 `WindowAccessor` 到 `.background {}`，回调保持幂等
- [ ] AppKit 容器内嵌 SwiftUI：`makeNSView` 用三件套建立，`updateNSView` 用 `hostedContentView` 复用
- [ ] Liquid Glass 统一走 `glassSurface()`，内部 `#available` 分支隔离 macOS 26 符号
- [ ] 低版本路径（else 分支）在 macOS 14/15 实机或虚拟机全量测试

---

## 延伸阅读

- Peekaboo 内部文档：`docs/SwiftUI-Implementing-Liquid-Glass-Design.md`、`docs/AppKit-Implementing-Liquid-Glass-Design.md`
- `../concurrency/` — Swift 6 `@MainActor` 与 Sendable 约束
- `../window/` — NSWindow level / styleMask / collectionBehavior 完整参考
- `swiftui-patterns.md` — `@Observable @Environment` 注入、弹簧动画对
