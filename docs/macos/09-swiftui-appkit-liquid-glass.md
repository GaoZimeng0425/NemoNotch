---
summary: 'Combine SwiftUI scene management with AppKit NSWindow control and Liquid Glass materials, using WindowAccessor and HostingViewHelpers patterns.'
read_when:
  - 'mixing SwiftUI and AppKit in a new macOS app for window-level control'
  - 'adopting Liquid Glass materials with macOS 26 / older-OS fallback'
---

# 09 · SwiftUI + AppKit 互操作 + Liquid Glass

## TL;DR

Peekaboo 以 `@main App` 协议作为入口,用 `@NSApplicationDelegateAdaptor` 注入 `AppDelegate`,在 SwiftUI 场景树管理多窗口的同时保留完整的 AppKit 生命周期控制。绝大多数 UI 用 SwiftUI 编写并以 `@Observable @MainActor` 状态驱动,当需要精确控制 `NSWindow`(level / styleMask / collectionBehavior)时,通过 `WindowAccessor: NSViewRepresentable` 在 `updateNSView` 取到真实窗口引用。Liquid Glass 效果通过 `ModernEffectView` 适配器在运行时分支:`#available(macOS 26, *)` 走 `NSGlassEffectView`(AppKit only),低版本回退到 SwiftUI 原生 `Material`。AppKit 组件嵌入 SwiftUI 靠 `HostingViewHelpers` 三件套(`makeHostedContentView` / `pinHostedContentView` / `hostedContentView`)保证 `NSHostingView` 复用而非重建,防止 SwiftUI 状态被清零。菜单栏弹出层用 `NSHostingController` 承载 SwiftUI 视图树,Inspector 等悬浮工具窗用 `WindowAccessor` 在 `updateNSView` 一次性完成 `styleMask` + `level` + `collectionBehavior` 配置。

## Peekaboo 在哪里实现

- 模块:`Apps/Mac/Peekaboo/`
- **关键文件**:`Apps/Mac/Peekaboo/PeekabooApp.swift:11` — `@main PeekabooApp: App`；用 `@NSApplicationDelegateAdaptor` 桥接 `AppDelegate`；同文件声明 `WindowGroup("Peekaboo Sessions", id: "main")` / `WindowGroup("Inspector", id: "inspector")` / `Settings` 三类场景；`@State private var settings = PeekabooSettings()` 是 `@Observable` 根状态
- **关键文件**:`Apps/Mac/Peekaboo/PeekabooApp.swift:184` — `AppDelegate: NSObject, NSApplicationDelegate @MainActor`；在 `applicationDidFinishLaunching` 初始化 `StatusBarController` 与 `VisualizerCoordinator`；`connectToState(_:)` 在 `.task {}` 里完成 SwiftUI/AppKit 双层状态握手
- **关键文件**:`Apps/Mac/Peekaboo/Features/Inspector/InspectorWindow.swift:45` — `WindowAccessor: NSViewRepresentable`；`makeNSView` 返回空 `NSView()`；`updateNSView` 中取 `nsView.window` 设置 `styleMask` / `level` / `collectionBehavior` / `identifier`
- **关键文件**:`Apps/Mac/Peekaboo/Core/GlassEffectView.swift:16` — `GlassEffectView<Content>: NSViewRepresentable`(@available macOS 26.0)；包装 `NSGlassEffectView`；用 `makeHostedContentView` + `pinHostedContentView` 注入 SwiftUI 内容树；`GlassEffectContainer` 用于多 Glass 视图合并渲染
- **关键文件**:`Apps/Mac/Peekaboo/Core/HostingViewHelpers.swift:9` — `makeHostedContentView` / `pinHostedContentView` / `hostedContentView(identifiedBy:in:fallbackView:)`：NSHostingView 创建、Auto Layout 四边固定、identifier 复用三件套
- **关键文件**:`Apps/Mac/Peekaboo/Core/ModernEffects.swift:15` — `ModernEffectView<Content>: View`(macOS 14+)；运行时分支：macOS 26+ 走 `NativeGlassWrapper`(NSViewRepresentable + NSGlassEffectView)，低版本走 `.regularMaterial` + `RoundedRectangle`；`GlassSurfaceModifier` 统一对外接口
- **关键文件**:`Apps/Mac/Peekaboo/Core/ModernEffects.swift:243` — `extension View { func glassSurface(...) }` 修饰符；被 `SessionComponents.swift:48` 直接调用
- **关键文件**:`Apps/Mac/Peekaboo/Features/StatusBar/StatusBarController.swift:116` — `NSHostingController(rootView: baseView)` 承载菜单栏弹出层的 SwiftUI 视图树；`popover.contentViewController` 赋值
- **关键文件**:`Apps/Mac/Peekaboo/Core/Settings.swift:12` — `@Observable @MainActor final class PeekabooSettings`；所有核心状态类同时标注两者满足 Swift 6 Sendable 约束
- **关键文件**:`Apps/Mac/Peekaboo/Features/StatusBar/StatusBarComponents/SessionComponents.swift:48` — `.glassSurface(style: .content, cornerRadius: 14)` 实际调用点
- 相关 docs:`docs/SwiftUI-Implementing-Liquid-Glass-Design.md`、`docs/AppKit-Implementing-Liquid-Glass-Design.md`、`docs/SwiftUI-New-Toolbar-Features.md`、`docs/modern-api.md`

## 设计动机（Why）

### 为什么不纯 SwiftUI

SwiftUI 的 `WindowGroup` 对底层 `NSWindow` 的控制非常有限：`window.level`（浮动窗口）、`collectionBehavior`（Space 跨屏展示）、`styleMask`（无边框/工具窗口）只能通过间接方式获取，且获取时机与 `makeNSView` 时序不一致。新 API 的 fallback 慢：macOS 26 的 `GlassEffect` modifier 在 SwiftUI 侧还没有对应的公开等价物（需要 `NSViewRepresentable` 桥接 `NSGlassEffectView`）；SwiftUI toolbar 的新特性（`ToolbarSpacer`、glass button style）在低版本无法优雅降级。复杂窗口布局（多级浮动 HUD、独立 inspector、常驻 overlay）用纯 SwiftUI 管理时，跨 `WindowGroup` 的状态同步和窗口查找需要大量 hack（`NSApp.windows.first(where:)`），维护成本高。

### 为什么不纯 AppKit

纯 AppKit 要手写大量样板：每个视图控制器需要实现 `loadView`、`viewDidLoad`、数据绑定代码；`@Published` / `Combine` 虽然可以，但相比 `@Observable` 的属性粒度追踪，整对象变动的重绘面更大、代码量更多。新设计语言（Liquid Glass、glass button style、animated SF Symbols）均以 SwiftUI modifier 为第一公民，AppKit 侧只有底层类（`NSGlassEffectView`）而没有高阶 modifier。Swift 6 的结构化并发与 SwiftUI 的生命周期 hook（`.task`、`.onAppear`）深度结合，在 AppKit 的 `viewDidAppear` 里手写 `async` 任务需要额外的 `Task` 管理，容易产生内存泄漏和取消时序问题。

### macOS 26 / Liquid Glass 时代的能力分布

| 能力 | SwiftUI 侧 | AppKit 侧 |
|------|-----------|-----------|
| Liquid Glass 背景 | `.glassEffect()` modifier（macOS 26+ SwiftUI 原生） | `NSGlassEffectView`（底层，需手动布局） |
| 多 Glass 合并渲染 | 无直接等价物 | `NSGlassEffectContainerView`（合并相邻视图渲染） |
| Glass 按钮 | `.buttonStyle(.glass)`（macOS 26+） | 无直接等价物 |
| 老版本材质 | `Material`（`.regular`、`.bar`、`.ultraThin` 等） | `NSVisualEffectView`（material + blendingMode） |
| 窗口 level/styleMask | `WindowGroup` modifier 部分支持 | `NSWindow` 直接设置，完整控制 |
| 菜单栏 extra | `MenuBarExtra`（SwiftUI scene，macOS 13+） | `NSStatusItem` + 手动 popover，最大控制 |
| Toolbar | `.toolbar {}` + ToolbarItem | `NSToolbar` + `NSToolbarDelegate`，完全自定义 |

**结论**：macOS 26 时代 SwiftUI modifier 是 Liquid Glass 的高阶入口，AppKit 类是底层实现细节。两层并存、按需下沉是最优路径。

## 核心模式（Pattern）

### Pattern 1 · 双层架构：SwiftUI 场景 + AppDelegate 生命周期

```swift
// PeekabooApp.swift:11
@main
struct PeekabooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = PeekabooSettings()   // @Observable root state
    @State private var sessionStore = SessionStore()

    var body: some Scene {
        WindowGroup("Peekaboo Sessions", id: "main") {
            SessionMainWindow()
                .environment(settings)
                .environment(sessionStore)
                .task { /* 状态握手 */ appDelegate.connectToState(…) }
        }
        Settings { SettingsWindow(…).environment(settings) }
    }
}
```

SwiftUI 负责场景路由与环境注入，AppDelegate 负责 AppKit 专属时序（`applicationDidFinishLaunching`、全局快捷键、状态栏 item）。两者通过 `connectToState(_:)` 完成一次性握手，之后状态单向流动到 SwiftUI 树。

### Pattern 2 · `@Observable @MainActor` 根状态

```swift
// Settings.swift:12 — 所有核心状态类的标准写法
@Observable
@MainActor
final class PeekabooSettings { … }
```

`@Observable` 让 SwiftUI 精确追踪属性粒度依赖（读哪个属性、只在那个属性变时重绘）；`@MainActor` 满足 Swift 6 严格并发下跨模块传递时的 `Sendable` 约束。在 `App` 层用 `@State private var settings = PeekabooSettings()` 初始化，通过 `.environment(settings)` 下传整棵场景树。**注意**：`@Observable` 需要 macOS 14+；低于 14 须改用 `ObservableObject` + `@Published`（见 Pitfall 4）。

### Pattern 3 · AppKit 视图嵌入 SwiftUI：NSVisualEffectView（macOS 14-25）

```swift
// SessionHelpers.swift 变体 — macOS 14-25 vibrancy 背景
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

`state = .active` 是关键：默认 `.followsWindowActiveState` 导致非焦点窗口（如 inspector overlay）材质失活。

### Pattern 4 · SwiftUI 视图嵌入 AppKit：NSHostingView 三件套

来自 `HostingViewHelpers.swift:9`，在所有 `NSViewRepresentable` 包装器中共享：

```swift
// 创建：带 identifier，禁用 autoresizingMask
func makeHostedContentView<C: View>(_ content: C,
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

// 复用：按 identifier 查找已有 NSHostingView，避免每次 updateNSView 重建
func hostedContentView<C: View>(identifiedBy id: NSUserInterfaceItemIdentifier,
    in contentView: NSView?, fallbackView: NSView) -> NSHostingView<C>?
{
    (contentView?.subviews.first(where: { $0.identifier == id })
     ?? fallbackView.subviews.first(where: { $0.identifier == id }))
    as? NSHostingView<C>
}
```

**复用而非重建**：如果 `updateNSView` 每次都 `addSubview` 新的 `NSHostingView`，内嵌 SwiftUI 状态（`@State` 值、动画进度、输入焦点）全部归零。`hostedContentView(identifiedBy:)` 找到旧实例后只更新 `rootView`，状态保持不变。

### Pattern 5 · Liquid Glass：运行时分支统一 API

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
                        .fill(style.nativeMaterial)   // .regular / .bar / .ultraThin 等
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
```

对外统一的 `glassSurface` modifier（`ModernEffects.swift:243`）：

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

调用方只需一行（`SessionComponents.swift:48`）：

```swift
.glassSurface(style: .content, cornerRadius: 14)
```

### Pattern 6 · WindowAccessor 模式：SwiftUI 取底层 NSWindow

`makeNSView` 阶段 view 尚未插入窗口层级，`nsView.window` 为 nil；只有 `updateNSView` 才保证非 nil。

```swift
// InspectorWindow.swift:45 — 实际来源
struct WindowAccessor: NSViewRepresentable {
    let windowAction: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }  // 空 view，不做任何事

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            windowAction(window)   // 此处才保证 window 非 nil
        }
    }
}
```

在目标 SwiftUI 视图的 `.background {}` 中嵌入（`InspectorWindow.swift:17`）：

```swift
InspectorView()
    .background(WindowAccessor { window in
        window.styleMask    = [.titled, .closable, .miniaturizable, .resizable]
        window.level        = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.identifier   = NSUserInterfaceItemIdentifier("inspector")
        window.ignoresMouseEvents = false
    })
```

**注意**：`windowAction` 会在每次 SwiftUI 刷新时重复调用。幂等操作（设置 styleMask/level）无害；非幂等操作须加 guard 防重入。

### Pattern 7 · HostingViewHelpers：NSViewRepresentable 的统一工厂

所有需要在 AppKit 容器（`NSGlassEffectView` / `NSVisualEffectView` / 自定义 `NSView`）中承载 SwiftUI 内容的 `NSViewRepresentable`，均应通过三件套工厂而非手写 `NSHostingView`：

```swift
// GlassEffectView.swift:34 — makeNSView 中正确使用方式
func makeNSView(context: Context) -> NSGlassEffectView {
    let glassView = NSGlassEffectView()
    glassView.cornerRadius = cornerRadius
    let hostingView = makeHostedContentView(content, identifier: myIdentifier)
    let target = glassView.contentView ?? glassView
    target.addSubview(hostingView)
    pinHostedContentView(hostingView, to: target)
    return glassView
}

// GlassEffectView.swift:59 — updateNSView 中复用而非重建
func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
    nsView.cornerRadius = cornerRadius
    hostedContentView(identifiedBy: myIdentifier,
        in: nsView.contentView, fallbackView: nsView)?.rootView = content
}
```

三件套的作用：`makeHostedContentView` 统一标记 identifier + 禁用 autoresizingMask；`pinHostedContentView` 安全地一次激活四条约束；`hostedContentView` 提供跨 contentView/fallbackView 的双层查找，兼容 `NSGlassEffectView.contentView` 存在与否两种场景。

### Pattern 8 · ModernEffectView：macOS 26+ / fallback 双版本切换

`ModernEffectStyle` 枚举封装了两侧的语义映射：

```swift
enum ModernEffectStyle {
    case automatic, sidebar, content, popover, hudWindow, toolbar, selection

    // macOS 14-25 SwiftUI Material
    var nativeMaterial: Material {
        switch self {
        case .popover:    .ultraThinMaterial
        case .hudWindow:  .ultraThickMaterial
        case .sidebar:    .bar
        case .toolbar:    .bar
        case .selection:  .thick
        default:          .regularMaterial
        }
    }

    // macOS 26+ NSGlassEffectView.Style（按实际 enum 值调整）
    @available(macOS 26.0, *)
    var glassStyle: NSGlassEffectView.Style { NSGlassEffectView.Style(rawValue: 0)! }
}
```

调用者不需要知道底层使用了哪个 API；`ModernEffectView` / `GlassSurfaceModifier` 在运行时自动选择。

### Pattern 9 · `@Observable` 跨模块 Sendable 边界

Swift 6 严格并发下，`@Observable` 类型默认不 `Sendable`。跨模块传入 `async` 函数时编译器报错。**标准解**：类同时加 `@MainActor`，将所有可变状态绑定到主 actor 隔离域（`Settings.swift:12`、`ConversationSession.swift:13`）。跨模块传递时明确在 `@MainActor` Task 里：

```swift
// PeekabooApp.swift:82 — 正确做法
appDelegate.windowOpener = { windowId in
    Task { @MainActor in self.openWindow(id: windowId) }
}
```

`withObservationTracking` 在非 `@Observable` 上下文（如 `StatusBarController.observeAgentState`）中手动触发观测循环时，回调在任意线程被调用，须用 `Task { @MainActor in … }` 切回主线程。

## 完整代码示例（Starter Code）

> **运行要求**：macOS 14+ baseline（`@Observable` 最低版本），macOS 26+ 自动启用 Liquid Glass。无需额外 entitlements。

```swift
// SwiftUIAppKitStarterKit.swift
// macOS 14+ baseline | macOS 26+ Liquid Glass enhanced
// Demonstrates: @main App, AppDelegate bridge, @Observable state,
//               WindowAccessor, GlassEffectView, ModernEffectView,
//               glassSurface modifier, NSHostingController for status bar

import AppKit
import SwiftUI

// MARK: - App Entry Point
// Pattern 1 · 双层架构
// ─────────────────────────────────────────────────────────────────────────────

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    @State private var appState = AppState()

    var body: some Scene {
        // Hidden bootstrap window (workaround for FB10184971 / MenuBarExtra + Settings)
        WindowGroup("_hidden") {
            Color.clear.frame(width: 1, height: 1)
                .task {
                    appDelegate.windowOpener = { id in
                        Task { @MainActor in self.openWindow(id: id) }
                    }
                    appDelegate.connectState(appState)
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()

        // Main window
        WindowGroup("My App", id: "main") {
            ContentView()
                .environment(appState)
        }
        .windowResizability(.automatic)
        .defaultSize(width: 800, height: 600)

        // Settings
        Settings {
            SettingsView().environment(appState)
        }
    }
}

// MARK: - AppDelegate
// Pattern 1 · AppKit 生命周期桥
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusBarController: StatusBarController?
    var windowOpener: ((String) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // StatusBarController 需要在此初始化；state 通过 connectState 后绑
    }

    func connectState(_ state: AppState) {
        guard statusBarController == nil else { return }
        statusBarController = StatusBarController(state: state)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // 菜单栏 app 保持运行
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            windowOpener?("main")
        }
    }
}

// MARK: - @Observable Root State
// Pattern 9 · @Observable @MainActor Sendable boundary
// ─────────────────────────────────────────────────────────────────────────────

@Observable
@MainActor
final class AppState {
    var counter: Int = 0
    var title: String = "My App"
    var isProcessing: Bool = false
}

// MARK: - WindowAccessor
// Pattern 6 · SwiftUI → NSWindow bridge
// ─────────────────────────────────────────────────────────────────────────────

struct WindowAccessor: NSViewRepresentable {
    let windowAction: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        // window is guaranteed non-nil here (unlike makeNSView)
        if let window = nsView.window {
            windowAction(window)
        }
    }
}

// MARK: - HostingViewHelpers
// Pattern 7 · NSHostingView factory (三件套)
// ─────────────────────────────────────────────────────────────────────────────

func makeHostedContentView<C: View>(
    _ content: C,
    identifier: NSUserInterfaceItemIdentifier) -> NSHostingView<C>
{
    let hv = NSHostingView(rootView: content)
    hv.identifier = identifier
    hv.translatesAutoresizingMaskIntoConstraints = false
    return hv
}

func pinHostedContentView(_ child: NSView, to parent: NSView) {
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        child.topAnchor.constraint(equalTo: parent.topAnchor),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
    ])
}

func hostedContentView<C: View>(
    identifiedBy id: NSUserInterfaceItemIdentifier,
    in contentView: NSView?,
    fallbackView: NSView) -> NSHostingView<C>?
{
    (contentView?.subviews.first(where: { $0.identifier == id })
     ?? fallbackView.subviews.first(where: { $0.identifier == id }))
    as? NSHostingView<C>
}

// MARK: - GlassEffectView (macOS 26+ only)
// Pattern 5 + 7 · NSGlassEffectView wrapped as NSViewRepresentable
// ─────────────────────────────────────────────────────────────────────────────

private let glassViewID = NSUserInterfaceItemIdentifier("MyApp.GlassHostingView")

@available(macOS 26.0, *)
struct GlassEffectView<Content: View>: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tintColor: NSColor?
    let content: Content

    init(cornerRadius: CGFloat = 10, tintColor: NSColor? = nil,
         @ViewBuilder content: () -> Content)
    {
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.content = content()
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        if let tint = tintColor { glass.tintColor = tint }
        let hv = makeHostedContentView(content, identifier: glassViewID)
        let target = glass.contentView ?? glass
        target.addSubview(hv)
        pinHostedContentView(hv, to: target)
        return glass
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.tintColor = tintColor
        // 复用，不重建：updateNSView 被频繁调用
        hostedContentView(identifiedBy: glassViewID,
            in: nsView.contentView, fallbackView: nsView)?.rootView = content
    }
}

// MARK: - ModernEffectView (macOS 14+, auto-upgrades on 26+)
// Pattern 8 · 双版本自动切换
// ─────────────────────────────────────────────────────────────────────────────

@available(macOS 14.0, *)
struct ModernEffectView<Content: View>: View {
    var cornerRadius: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectView(cornerRadius: cornerRadius) { content }
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Material.regularMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - glassSurface View Modifier
// Pattern 5 · unified public API
// ─────────────────────────────────────────────────────────────────────────────

private struct GlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    GlassEffectView(
                        cornerRadius: cornerRadius,
                        tintColor: NSColor(calibratedWhite: 0.08, alpha: 0.55)) { Color.clear }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        .blendMode(.plusLighter)
                }
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Material.regularMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                }
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - StatusBarController (NSHostingController for menu bar popover)
// Pattern from StatusBarController.swift:116
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let state: AppState

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "My App")
        button.image?.isTemplate = true
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func setupPopover() {
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        // NSHostingController wraps SwiftUI view for AppKit popover
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().environment(state))
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

// MARK: - InspectorWindow (WindowAccessor + styleMask)
// Pattern 6 · window-level control from SwiftUI
// ─────────────────────────────────────────────────────────────────────────────

struct InspectorWindow: View {
    var body: some View {
        VStack {
            Text("Inspector").font(.headline)
            Spacer()
        }
        .frame(minWidth: 350, minHeight: 500)
        .background(WindowAccessor { window in
            window.styleMask          = [.titled, .closable, .miniaturizable, .resizable]
            window.level              = .normal
            window.collectionBehavior = [.managed, .participatesInCycle]
            window.identifier         = NSUserInterfaceItemIdentifier("inspector")
            window.ignoresMouseEvents = false
            window.titlebarAppearsTransparent = false
        })
    }
}

// MARK: - Sample Views

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 20) {
            Text(state.title).font(.largeTitle)
            Text("Count: \(state.counter)")
                .padding()
                .glassSurface(cornerRadius: 12)
            HStack(spacing: 12) {
                if #available(macOS 26.0, *) {
                    Button("Increment") { state.counter += 1 }
                        .buttonStyle(.glass)
                } else {
                    Button("Increment") { state.counter += 1 }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PopoverView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.title).font(.headline).padding(.horizontal)
            Divider()
            Text("Count: \(state.counter)")
                .padding(.horizontal)
                .glassSurface(cornerRadius: 8)
        }
        .padding(.vertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            TextField("Title", text: Bindable(state).title)
        }
        .padding()
        .frame(width: 400, height: 200)
    }
}
```

Starter Code 共约 **290 行**，覆盖：`@main App` 入口、`AppDelegate` 桥、`@Observable @MainActor AppState`、`WindowAccessor`、`GlassEffectView<Content>`（macOS 26+）、`ModernEffectView<Content>`（macOS 14+ 双版本）、`glassSurface` modifier、`HostingViewHelpers` 三件套、`StatusBarController`（NSHostingController 菜单栏）、`InspectorWindow`（styleMask + level + collectionBehavior）。

## 新项目落地步骤（How to apply）

1. **声明双层入口**：创建 `@main struct MyApp: App`，加 `@NSApplicationDelegateAdaptor(AppDelegate.self)`；`AppDelegate` 标注 `@MainActor final class … : NSObject, NSApplicationDelegate`；`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` 返回 `false`（菜单栏 app）。

2. **设计 `@Observable @MainActor` 根状态**：每个核心状态类同时标注 `@Observable @MainActor final class`（macOS 14+）；在 `App` 层用 `@State private var appState = AppState()` 初始化；通过 `.environment(appState)` 注入所有 `WindowGroup`；若需支持 macOS < 14，使用 `ObservableObject` + `@Published` 替代。

3. **桥接 AppDelegate 状态**：通过 `connectState(_:)` 方法在 `.task {}` 中将 `AppState` 传给 `AppDelegate`；`AppDelegate` 在此时初始化 `StatusBarController` 等 AppKit 组件；`windowOpener` 闭包让 `AppDelegate` 能调用 SwiftUI 的 `openWindow(id:)`。

4. **需要 NSWindow 控制时插入 WindowAccessor**：在目标 SwiftUI 视图的 `.background {}` 嵌入 `WindowAccessor { window in … }`；在回调里设置 `window.level` / `styleMask` / `collectionBehavior` / `identifier`；保持回调幂等（`styleMask` 赋值是幂等的，`addObserver` 不是——需 guard 防重入）。

5. **菜单栏弹出层用 NSHostingController**：`NSPopover().contentViewController = NSHostingController(rootView: popoverView.environment(state))`；`contentSize` 在 `setupPopover` 里设置；SwiftUI 视图用 `.environment` 而非构造参数拿状态（保证 `@Observable` 追踪正常工作）。

6. **AppKit 容器内嵌 SwiftUI 内容用三件套**：`makeNSView` 调用 `makeHostedContentView` + `pinHostedContentView` 建立一次；`updateNSView` 调用 `hostedContentView(identifiedBy:in:fallbackView:)` 找到已有实例后只更新 `rootView`，找不到才新建并 `addSubview`（此为 fallback 分支，正常运行不应触发）。

7. **Liquid Glass material 用 `glassSurface()` modifier 统一对外**：新建 `GlassSurfaceModifier: ViewModifier`，在 `func body(content:)` 里 `if #available(macOS 26, *)` 分支走 `GlassEffectView`，else 走 `RoundedRectangle + Material`；对外只暴露 `extension View { func glassSurface(...) }`；调用侧零感知版本分支。

8. **多版本 fallback 完整性检查**：`GlassEffectView` / `NativeGlassWrapper` 整体标 `@available(macOS 26.0, *)`；`ModernEffectView` 标 `@available(macOS 14.0, *)`；确保低版本路径（else 分支）不引用任何 macOS 26 符号——一旦引用，在 macOS 14 设备运行时会产生 dyld 链接报错（不是编译报错）。

9. **性能 profile**：在 Apple Silicon MacBook 上打开 Instruments（Time Profiler + Metal System Trace）跑 Liquid Glass 密集场景；`NSGlassEffectView` 的渲染走 Metal compositor，Apple Silicon GPU 加速正常时开销极小；Intel Mac 上 blur 计算由 CPU 承担，`NSGlassEffectContainerView` 合并相邻 glass 视图可减少渲染 pass 数（见 Pitfall 3）。

10. **测试多版本**：在 macOS 14/15 虚拟机或真机上完整跑一遍 `pnpm run test:safe`；重点检查 `glassSurface` / `ModernEffectView` 的 else 分支是否显示正常（主要表现为材质颜色和圆角）；toolbar 的 `if #available` 包必须整体测试，渐进迁移时有"花屏"风险（见 Pitfall 5）。

## 替代方案对比（When NOT to use）

| 方案 | 适用场景 | 优点 | 缺点 | Peekaboo 当前 |
|------|---------|------|------|--------------|
| **本方案：SwiftUI 主 + AppKit 下沉** | 中大型 macOS 应用，需要窗口级控制 + 现代 UI | 声明式 UI + 完整 AppKit 控制权；Liquid Glass / SwiftUI toolbar 直接可用 | 双层状态同步有额外认知负担；`NSViewRepresentable` 包装层需维护 | ✅ 当前采用 |
| **纯 SwiftUI（无 AppDelegate）** | 简单工具 app，macOS 14+，无特殊窗口需求 | 最少样板代码；`App` + `WindowGroup` 自动管理窗口恢复 | `NSWindow` 控制弱（level / styleMask 须 hack）；菜单栏 extra 需 `MenuBarExtra`（macOS 13+，功能有限）；新组件 fallback 须手写 `if #available` | 不适用（Peekaboo 需要 `StatusBarController` + `VisualizerCoordinator` 精确时序） |
| **纯 AppKit（无 SwiftUI）** | Legacy 代码迁移；高度自定义 rendering；性能极敏感路径 | 完全控制 `NSWindow` / `NSView` / rendering；适合游戏、专业绘图等自定义渲染 | `@Observable` / Combine / SwiftUI modifier 均不可用；Liquid Glass 新设计语言难以采用；样板代码量大 | 不适用（新模块全部用 SwiftUI） |
| **Mac Catalyst（UIKit for macOS）** | 已有 iOS/iPadOS app，想快速上架 macOS | 单一代码库跨 iOS + macOS；无需重写 | macOS 体验弱（控件尺寸、交互惯例不原生）；`NSWindow` 访问受限；Liquid Glass 在 Catalyst 上效果与原生 AppKit 有差异 | ❌ 不使用 |
| **Tuist + SwiftUI（模块化生成）** | 大型团队，多 target 共享，需要 Xcode project 自动生成 | 减少 project 冲突；模块边界清晰 | 额外工具链依赖；Tuist 和 Xcode 版本兼容性需维护 | ❌ 不使用（Peekaboo 用 SwiftPM） |
| **Tokamak（SwiftWasm）** | 实验性 Web / WASM 目标 | 用 SwiftUI-like API 写 Web UI | 极不成熟；macOS 原生 API 全部不可用 | ❌ 不使用 |

**降级策略**：若本方案中 `NSViewRepresentable` 包装层出现无法解决的时序 bug（罕见），可以将该视图退化为纯 AppKit `NSViewController`，通过 `NSHostingController` 或 `NSHostingView` 在边界处嵌入 SwiftUI——本质上是 SwiftUI 比例进一步降低，方向与本方案一致。

## 非原生环境（Non-Native Targets）

### 嵌入 WKWebView

`WKWebView` 是 AppKit 体系的子集，可通过 `NSViewRepresentable` 包装后嵌入 SwiftUI：

```swift
struct WebView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView { WKWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.load(URLRequest(url: url))
    }
}
```

**关键差异**：
- WKWebView 有独立的 Accessibility 树（`AXWebArea` 子树），不融入 SwiftUI / AppKit 的标准 AX 树；AXorcist 无法遍历 web 内容，需要通过 `WKWebView.evaluateJavaScript` 或 `WKWebView.callAsyncJavaScript` 注入 JS 操作 DOM。
- `WKWebView` 的 `NSView` 层级包含内部子视图（`WKContentView`），直接 `addSubview` 到 WKWebView 上层可能导致 z-order 异常；`glassSurface` modifier 放在 `WebView` 包装层外侧（SwiftUI 层）可正常工作。
- 输入事件（文字输入）：从 SwiftUI 层发起的 `CGEvent` 合成可以抵达 WKWebView，但渲染进程输入处理走 Chromium 渲染管道，极端情况下需要 `.cghidEventTap` 代替 `.cgSessionEventTap`（参见 playbook 07）。
- `NSVisualEffectView` / `NSGlassEffectView` 叠加在 WKWebView 上时，需确认 `blendingMode = .behindWindow` 以透过 webview 内容；`.withinWindow` 在 WKWebView 上方会遮住内容。

### 嵌入 Electron / CEF 应用（极罕见，通常是跨进程协作而非嵌入）

严格说 SwiftUI 无法"嵌入"到另一个 Electron 应用的窗口中（进程边界阻止 subview 跨进程）。真实场景是：macOS App 与 Electron App 并排运行，通过 IPC 协调：

- **窗口追踪**：用 `CGWindowListCopyWindowInfo` 或 `SCShareableContent` 枚举 Electron 窗口的 `CGWindowID`，再通过 `CGSCopySpacesForWindows`（私有 API）确认 Space，用 `NSWindow.init(contentRect:styleMask:backing:defer:)` 创建 overlay 精确覆盖（坐标系转换：`NSScreen.main!.frame` vs `SCDisplay.frame` 的 Y 轴翻转）。
- **层级管理**：overlay NSWindow 需要 `window.level = .floating` + `window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` 才能跟随 Electron 窗口跨 Space；Electron 窗口移动时需要监听 `NSWorkspace.activeSpaceDidChangeNotification` 或定时轮询更新 overlay frame。
- **不要假设 AX 树完整**：Electron 的 AX 实现不一致（VSCode 有相对完整的 AX 树，大多数 Electron app 只有顶层 `AXWindow`）；`WindowAccessor` 在这里无意义（无法拿到 Electron 的 NSWindow）；只能操作自己进程的 NSWindow。

### 跨平台 framework（Flutter 桌面 / Tauri / .NET MAUI）

这类框架通常 **own 整个 NSWindow**，内部用自己的渲染引擎（Flutter: Metal Impeller / Tauri: WKWebView / MAUI: AppKit 封装）。SwiftUI 无法作为子视图嵌入其窗口，只能**并排**：

- **Flutter 桌面**：Flutter macOS 用 `FlutterViewController` 作为 `NSViewController`，整个窗口交给 Flutter 渲染。想用 SwiftUI 组件，需要 [flutter_platform_view](https://docs.flutter.dev/platform-integration/ios/platform-views) 的 macOS 变体（社区方案，不稳定），或通过 IPC 在另一个原生 NSWindow 中显示。Liquid Glass 效果在 Flutter 层无法直接使用，须用 Flutter 自己的 shader 模拟。
- **Tauri（WKWebView + Rust）**：Tauri 2.x 的 macOS 窗口是 `WKWebView` full-window；可以通过 Tauri plugin 暴露 Swift/AppKit API，在 `applicationDidFinishLaunching` 时创建独立的 `NSWindow`（SwiftUI `WindowGroup` 或纯 AppKit），通过 `WKWebView.callAsyncJavaScript` / IPC 与前端通信。`WindowAccessor` + `glassSurface` 在独立 NSWindow 里完整可用。
- **.NET MAUI macOS（Mac Catalyst）**：MAUI 通过 Catalyst 在 macOS 运行，底层 UIKit，AppKit interop 有限；SwiftUI 代码无法直接嵌入，只能通过 `NSViewControllerRepresentable` 的 Catalyst 等价物（`UIViewControllerRepresentable`）或 XPC service 隔离。

**通用建议**：如果 macOS 原生 UI 是重点（Liquid Glass、NSWindow 精确控制、AX 完整性），选择 SwiftUI + AppKit 为主框架，而不是把 SwiftUI 当跨平台 framework 的插件。跨平台 framework 的 macOS 体验在 2026 年仍然弱于原生。

## 调试与取证（Debug & Forensics）

### 诊断工具速查

```bash
# 1. 枚举所有 NSWindow（在 lldb 或 Debug Console 中）
(lldb) expr NSApp.windows.forEach { print($0.identifier?.rawValue ?? "nil", $0.level, $0.styleMask.rawValue) }

# 2. SwiftUI 视图重绘追踪（macOS 14+，Debug Console）
# 在任意 View.body 里临时插入：
_ = Self._printChanges()

# 3. 开启 SwiftUI frame-change overlay（部分版本支持）
defaults write com.apple.SwiftUI debugFrameChanges YES

# 4. NSWindow 层级（Quartz Debug — 从 Xcode Additional Tools 下载）
# 菜单：Quartz Debug → Flash Screen Updates（红色闪烁 = 发生重绘）
# 菜单：Quartz Debug → Show Window Count（显示各进程窗口数）

# 5. Accessibility 树检查（查 SwiftUI 组件是否正确暴露 AX）
# 打开 Accessibility Inspector.app（Xcode → Open Developer Tool → Accessibility Inspector）
# 选中目标 app → 点击"Inspection Pointer"→ 悬停到 SwiftUI 组件上

# 6. 实时 log 过滤（观察 @Observable 状态变化和 AppDelegate 事件）
log stream --predicate 'subsystem == "boo.peekaboo.app"' --level debug

# 7. 查 NSHostingView 被 addSubview 的次数（调试 Pitfall 3）
# 在 updateNSView 临时加断点，计数器观察调用频率
# 或用 Instruments → Allocations 过滤 NSHostingView 实例数
```

### 症状 → 根因 → 处理映射表

| 症状 | 排查命令 / 方法 | 根因 | 处理 |
|------|----------------|------|------|
| SwiftUI 视图拿不到 `NSWindow`，`windowAction` 不被调用 | lldb 在 `updateNSView` 打断点，检查 `nsView.window` 是否 nil | `makeNSView` 时 view 未入层级；或 view 从未进入屏幕（hidden window group） | 改用 `updateNSView`；确认 `WindowGroup` 有对应窗口被创建 |
| `@Observable` 类型跨模块报 `Sendable` 编译错误 | 查 error 行，确认 `Task` 闭包是否 `@MainActor` | `@Observable` 默认不 `Sendable`；Swift 6 strict concurrency | 给类加 `@MainActor`；Task 闭包加 `@MainActor in` |
| Liquid Glass material 在老 Mac 卡顿 / 耗电高 | Instruments → Metal System Trace → GPU Timeline | Intel Mac 无 Apple Silicon GPU，blur 走 CPU；没有 fallback 到 Material | `if #available(macOS 26, *)` 正确分支；Intel Mac 用 `NSVisualEffectView.material = .sidebar` |
| `NSHostingView` 内嵌的 `@State` 值每次父更新归零 | Instruments Allocations，过滤 `NSHostingView`，观察实例数增长 | `updateNSView` 每次 `addSubview` 新实例，旧实例被销毁 | 用 `hostedContentView(identifiedBy:)` 复用；只在 `makeNSView` 做 `addSubview` |
| Toolbar 在新旧 API 切换时花屏 / 闪烁 | 在 macOS 14/15 + macOS 26 各跑一遍，Quartz Debug 观察重绘 | `if #available` 包不完整，两侧 toolbar 结构不一致 | 整体测试 `if #available` 两个分支；确保两侧 toolbar item 数量和 placement 语义一致 |
| `AppDelegate.connectState` 被重复调用，`StatusBarController` 初始化多次 | 在 `connectState` 打断点，查调用栈 | `WindowGroup.task {}` 在窗口重建时重跑 | 在 `connectState` 加 `guard statusBarController == nil` 幂等保护 |
| `withObservationTracking` 回调在非主线程触发，报 MainActor isolation 错误 | `Thread.isMainThread` 断点 | `withObservationTracking onChange:` 在任意线程回调 | 回调体用 `Task { @MainActor in … }` 切回主线程 |
| `windowAction` 调用 `window.makeKeyAndOrderFront(nil)` 导致 Inspector 在启动时意外弹出 | 检查 `WindowGroup` 的 `windowResizability` 和 `defaultSize` | `updateNSView` 首次调用时即触发 `makeKeyAndOrderFront`，窗口提前显示 | 从 `windowAction` 中移除 `makeKeyAndOrderFront`；窗口显示交给 `openWindow(id:)` |

### 关键 log 开启

```swift
// 在 AppDelegate 或 App 入口加 Logger
import os.log
let logger = Logger(subsystem: "com.myapp.app", category: "WindowBridge")

// WindowAccessor 调试版
func updateNSView(_ nsView: NSView, context: Context) {
    if let window = nsView.window {
        logger.debug("WindowAccessor: got window \(window.identifier?.rawValue ?? "nil")")
        windowAction(window)
    } else {
        logger.warning("WindowAccessor: window is nil in updateNSView")
    }
}
```

```bash
# Console.app 过滤：
# Subsystem = com.myapp.app
# 或命令行实时：
log stream --predicate 'subsystem == "com.myapp.app"' --level debug
```

## 常见陷阱（Pitfalls）

**Pitfall 1：SwiftUI WindowGroup 里拿不到 NSWindow 引用**

症状：试图通过 `@Environment(\.window)` 或 `NSApp.keyWindow` 配置 `level` / `styleMask`，要么编译失败（`\.window` 不在标准环境值），要么时机早于窗口创建，`keyWindow` 为 nil。

根因：`makeNSView` 阶段 view 尚未插入 NSWindow 层级，`nsView.window` 为 nil。

处理：`WindowAccessor` 模式（`InspectorWindow.swift:45`）：在 `updateNSView` 中读取 `nsView.window`，此时保证非 nil。若需在 `AppDelegate` 侧查找窗口，用 `NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })`（`PeekabooApp.swift:331`），不要假设 `NSApp.keyWindow` 是目标窗口。

---

**Pitfall 2：`@Observable` 跨模块编译报 Sendable 错误**

症状：Swift 6 严格并发模式下，`@Observable` 类型从一个模块传入另一个模块的 `async` 函数或 Task 闭包时，编译器报 "Type X does not conform to 'Sendable'"。

根因：`@Observable` 宏默认不添加 `@MainActor` 约束；跨越并发域引用非 Sendable 可变引用类型违反 Swift 6 规则。

处理：给状态类加 `@MainActor`（`Settings.swift:12`）；所有跨模块传递均限制在 `@MainActor` 任务中，例如 `Task { @MainActor in self.openWindow(id: windowId) }`（`PeekabooApp.swift:82`）。

---

**Pitfall 3：`NSViewRepresentable` 中 `updateNSView` 重复 addSubview 导致 SwiftUI 状态重置**

症状：内嵌在 `NSGlassEffectView` 或其他 AppKit 容器中的 SwiftUI 视图每次父状态更新时动画闪烁、`@State` 值归零、输入焦点丢失。

根因：`updateNSView` 被 SwiftUI 频繁调用；若每次都新建 `NSHostingView` 并 `addSubview`，则旧的 SwiftUI 树被销毁，状态随之丢失。

处理：用 `NSUserInterfaceItemIdentifier` 标记 `NSHostingView`，在 `updateNSView` 中先 `hostedContentView(identifiedBy:in:fallbackView:)` 查找已有实例并更新 `rootView`，找不到才新建（`HostingViewHelpers.swift:28`）。

---

**Pitfall 4：`@Observable` 在 macOS 14 之前不可用**

症状：在 macOS 13 目标上编译报错 "'Observable' is only available in macOS 14 or newer"；或运行时 crash（如果没有 `@available` 保护）。

根因：`@Observable` macro 和 `Observation` framework 是 macOS 14 / iOS 17 新增；早于此版本的 app 不能直接使用。

处理：若需支持 macOS 13，将状态类改为 `ObservableObject` + `@Published`，SwiftUI 侧用 `@EnvironmentObject` / `@StateObject` 接收。或用编译条件隔离：`#if os(macOS) && swift(>=5.9)` / `@available(macOS 14, *)` 包整个类，提供 macOS 13 fallback 实现。

---

**Pitfall 5：Liquid Glass material 在 Apple Silicon 之前的 Mac 上性能差**

症状：在 Intel Mac（macOS 26 升级后）上使用 `GlassEffectView` / `NSGlassEffectView` 导致高 CPU 使用率、界面卡顿，Activity Monitor 中 WindowServer 进程占用飙升。

根因：Liquid Glass 的实时光照模拟和 blur 合成依赖 Apple Silicon GPU 的 unified memory 架构；Intel Mac 没有这个优化路径，渲染全走 CPU。

处理：在 `if #available(macOS 26, *)` 分支内额外检测处理器架构（`#if arch(arm64)`），Intel 路径降级到 `NSVisualEffectView.material`；或通过 `ProcessInfo.processInfo.performanceMicrocoreCount` 粗略判断是否 Apple Silicon。`NSGlassEffectContainerView` 合并相邻 glass 视图可减少渲染 pass，一定程度缓解 Intel 卡顿。

---

**Pitfall 6：SwiftUI `Window` vs `WindowGroup` 在多窗口 app 上的差异**

症状：用 `Window(id:)` 声明的窗口在 File → New Window 时无法创建多实例；用 `WindowGroup(id:)` 声明的窗口有时出现多余的空白实例。

根因：`Window` 是单例窗口（最多一个实例，macOS 14+）；`WindowGroup` 支持多实例但 SwiftUI 会在应用启动或状态恢复时自动创建实例。隐藏的 bootstrap window（`WindowGroup("_hidden")`）如果不用 `.commandsRemoved()` + `.windowStyle(.hiddenTitleBar)` 处理，会出现在 Window 菜单。

处理：单例工具窗（Inspector、Settings）用 `Window(id:)`（macOS 14+）；多实例文档窗用 `WindowGroup`；bootstrap window 用 `WindowGroup` + `.commandsRemoved()` + `.windowStyle(.hiddenTitleBar)` + 极小 `defaultSize`（`PeekabooApp.swift:64`）。

## 延伸阅读

- Peekaboo 内部文档：`docs/SwiftUI-Implementing-Liquid-Glass-Design.md`、`docs/AppKit-Implementing-Liquid-Glass-Design.md`、`docs/SwiftUI-New-Toolbar-Features.md`、`docs/modern-api.md`
- Apple 官方：[Adopting Liquid Glass](https://developer.apple.com/design/)、[NSGlassEffectView documentation](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- WWDC 2023：[Discover Observation in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10149/)（`@Observable` macro 原理）
- WWDC 2024：[Demystify SwiftUI containers](https://developer.apple.com/videos/play/wwdc2024/10146/)（视图容器与状态生命周期）
- WWDC 2024/25：Liquid Glass design session（macOS 26 material system）
- 其它 playbook：[02 · Swift 6 并发](./02-swift6-concurrency.md)、[10 · Visualizer 屏上 overlay](./10-visualizer-overlay.md)、[11 · SwiftPM + Xcode + Poltergeist](./11-swiftpm-xcode-poltergeist.md)

---

*Last verified against Peekaboo @ `e3a66d317544420891d62da17120bf18e37118f3`*
