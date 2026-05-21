---
summary: 'Combine SwiftUI scene management with AppKit window control and adopt Liquid Glass effects with a macOS 26 availability guard.'
read_when:
  - 'bridging SwiftUI and AppKit for precise NSWindow level, style, or collection-behavior control'
  - 'adding Liquid Glass or vibrancy effects with backward-compatible fallbacks'
---

# 09 · SwiftUI + AppKit 互操作 + Liquid Glass

## TL;DR

Peekaboo 以 `@main App` 协议作为入口,用 `@NSApplicationDelegateAdaptor` 注入 `AppDelegate`,在 SwiftUI 场景树管理多窗口的同时保留完整的 AppKit 生命周期控制。绝大多数 UI 用 SwiftUI 编写,当需要精确控制 `NSWindow`(level / styleMask / collectionBehavior)或使用 `NSGlassEffectView` 等纯 AppKit API 时,才通过 `NSViewRepresentable` / `NSHostingView` 下沉到 AppKit 层。Liquid Glass 效果通过统一的 `ModernEffectView` 适配器包装:`#available(macOS 26, *)` 分支使用 `NSGlassEffectView`(via `NSViewRepresentable`),低版本回退到 `.regularMaterial`。

## Peekaboo 在哪里实现

- 模块:`Apps/Mac/Peekaboo/`
- 关键文件:`Apps/Mac/Peekaboo/PeekabooApp.swift:11` — `@main PeekabooApp: App`,用 `@NSApplicationDelegateAdaptor` 桥接 `AppDelegate`,在同一文件声明四个 `WindowGroup` / `Settings` 场景
- 关键文件:`Apps/Mac/Peekaboo/PeekabooApp.swift:184` — `AppDelegate: NSObject, NSApplicationDelegate`,管理 `StatusBarController`、`VisualizerCoordinator` 及窗口查找逻辑
- 关键文件:`Apps/Mac/Peekaboo/Features/Inspector/InspectorWindow.swift:45` — `WindowAccessor: NSViewRepresentable`,在 `updateNSView` 中拿到 `nsView.window` 后配置 `styleMask` / `level` / `collectionBehavior`
- 关键文件:`Apps/Mac/Peekaboo/Core/GlassEffectView.swift:16` — `GlassEffectView: NSViewRepresentable`,将 `NSGlassEffectView` 包装成 SwiftUI 视图,内嵌 `NSHostingView` 以保持 SwiftUI 内容树
- 关键文件:`Apps/Mac/Peekaboo/Core/HostingViewHelpers.swift:9` — `makeHostedContentView` / `pinHostedContentView` / `hostedContentView`,封装 `NSHostingView` 创建、Auto Layout 固定和跨更新复用三件套
- 关键文件:`Apps/Mac/Peekaboo/Core/ModernEffects.swift:15` — `ModernEffectView`,运行时分支:macOS 26+ 走 `NativeGlassWrapper`(NSViewRepresentable),低版本走 `.regularMaterial` + `RoundedRectangle`
- 关键文件:`Apps/Mac/Peekaboo/Features/StatusBar/StatusBarController.swift:116` — `NSHostingController` 承载菜单栏弹出层的 SwiftUI 视图树
- 关键文件:`Apps/Mac/Peekaboo/Features/Main/SessionHelpers.swift:90` — `VisualEffectView: NSViewRepresentable`,将 `NSVisualEffectView` 直接暴露给 SwiftUI(macOS 14-25 的 blur 背景)
- 相关 docs:`docs/SwiftUI-Implementing-Liquid-Glass-Design.md`、`docs/AppKit-Implementing-Liquid-Glass-Design.md`、`docs/SwiftUI-New-Toolbar-Features.md`

## 设计动机(Why)

**为什么以 SwiftUI 为主入口?** SwiftUI 的 `App` 协议统一管理窗口恢复、Scene 生命周期和多窗口路由,减少手写 `NSWindow` 初始化的样板代码。`@Environment(\.openWindow)` 让跨组件唤起新窗口变成一行调用。

**为什么保留 AppDelegate?** SwiftUI 场景无法直接拿到底层 `NSWindow` 引用(见 Pitfall 1)。Peekaboo 需要在 `applicationDidFinishLaunching` 时初始化 `StatusBarController`、启动 `VisualizerCoordinator`、注册全局快捷键,这些是 AppKit 专属的时序需求。`@NSApplicationDelegateAdaptor` 是两套生命周期并存的正规接口。

**为什么 `@Observable` 而非 `ObservableObject`?** `PeekabooSettings`、`SessionStore`、`Permissions` 等核心状态类全部标注 `@Observable`,编译器自动追踪属性粒度依赖,避免整对象变动触发全树重绘。

**Liquid Glass 的落地取舍:** `NSGlassEffectView` 是纯 AppKit 类,SwiftUI 侧没有对等的原生 modifier。Peekaboo 通过 `NSViewRepresentable` 将其引入 SwiftUI 视图树,并在 `ModernEffectView` 里用 `if #available(macOS 26, *)` 做运行时切换,低版本不引入任何 macOS 26 符号。

## 核心模式(Pattern)

### 1. 入口:双层架构

```swift
// PeekabooApp.swift:11
@main
struct PeekabooApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = PeekabooSettings()   // @Observable,下传给 Scene
    var body: some Scene {
        WindowGroup("Peekaboo Sessions", id: "main") { … }
        Settings { … }
    }
}
```

SwiftUI 负责场景路由,AppDelegate 负责 AppKit 生命周期。两者通过 `connectToState(_:)` 方法在 `.task {}` 中完成状态握手。

### 2. 拿到 NSWindow:WindowAccessor 桥

SwiftUI 场景无法通过环境值直接拿到 `NSWindow`,需借助零尺寸的 `NSViewRepresentable` 的 `updateNSView`:

```swift
// InspectorWindow.swift:45
struct WindowAccessor: NSViewRepresentable {
    let windowAction: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { windowAction(window) }
    }
}
```

在 `makeNSView` 阶段 view 还未入窗口层级,`updateNSView` 阶段才有 `.window`。配置 `styleMask` / `level` / `collectionBehavior` 均在此处完成:

```swift
// InspectorWindow.swift:17
window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
window.level = .normal
window.collectionBehavior = [.managed, .participatesInCycle]
```

### 3. AppKit 视图嵌入 SwiftUI:VisualEffectView

```swift
// SessionHelpers.swift:90
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material
        v.blendingMode = blendingMode; v.state = .active; return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material; nsView.blendingMode = blendingMode
    }
}
```

`NSVisualEffectView` 的 `state` 必须显式设为 `.active`,否则非 key window 时材质失活变白。

### 4. SwiftUI 视图嵌入 AppKit:NSHostingView 三件套

```swift
// HostingViewHelpers.swift:9
func makeHostedContentView<Content: View>(
    _ content: Content,
    identifier: NSUserInterfaceItemIdentifier) -> NSHostingView<Content>
{
    let hv = NSHostingView(rootView: content)
    hv.identifier = identifier
    hv.translatesAutoresizingMaskIntoConstraints = false
    return hv
}
```

`makeHostedContentView` 创建并标记 identifier,`pinHostedContentView` 用四条 Auto Layout 约束固定边距,`hostedContentView(identifiedBy:in:fallbackView:)` 在 `updateNSView` 中按 identifier 复用而非重建。**复用而非重建**是保持 SwiftUI 状态不丢失的关键:如果每次 `updateNSView` 都 `addSubview` 新 `NSHostingView`,内嵌的 SwiftUI 状态(如动画进度、`@State` 值)会被清零。

### 5. Liquid Glass:运行时分支

```swift
// ModernEffects.swift:31
if #available(macOS 26.0, *) {
    NativeGlassWrapper(style: style, cornerRadius: cornerRadius, content: content)
} else {
    content.background {
        RoundedRectangle(cornerRadius: cornerRadius).fill(style.nativeMaterial)
    }
}
```

`NativeGlassWrapper`(macOS 26+ only)是 `NSViewRepresentable`,内部创建 `NSGlassEffectView` 并用 `makeHostedContentView` 注入 SwiftUI 内容。低版本则用 SwiftUI 原生 `Material`(`.regularMaterial`、`.bar`、`.ultraThinMaterial` 等)。

对外统一暴露 `.glassSurface()` 修饰符:

```swift
// ModernEffects.swift:243
func glassSurface(style: ModernEffectStyle = .content, cornerRadius: CGFloat = 16) -> some View {
    modifier(GlassSurfaceModifier(style: style, cornerRadius: cornerRadius))
}
```

实际调用者(`SessionComponents.swift:48`)只需一行:

```swift
.glassSurface(style: .content, cornerRadius: 14)
```

### 6. @Observable 状态管理

```swift
// Settings.swift:12
@Observable
@MainActor
final class PeekabooSettings { … }
```

所有核心状态类(`PeekabooSettings`、`SessionStore`、`Permissions`)同时标注 `@Observable` 和 `@MainActor`。前者让 SwiftUI 精确追踪属性依赖,后者满足 Swift 6 严格并发检查对 MainActor-bound 可变状态的要求,避免跨模块 `Sendable` 错误(见 Pitfall 2)。状态通过 `PeekabooApp.body` 中的 `.environment(settings)` 注入场景树。

## 新项目落地步骤(How to apply)

1. **建立双层入口**:用 `@main struct MyApp: App` 声明入口,同时用 `@NSApplicationDelegateAdaptor(AppDelegate.self)` 保留 AppKit 生命周期;在 `App.body` 用 `WindowGroup(id:)` 声明所有窗口,不要在 `AppDelegate` 里手动 `makeKeyAndOrderFront`。
2. **状态类型用 `@Observable` + `@MainActor`**:替换 `ObservableObject` + `@Published`;用 `@State private var settings = MySettings()` 在 `App` 层初始化,通过 `.environment(settings)` 下传;跨模块时确保类型带 `@MainActor` 以满足 Swift 6 `Sendable` 约束。
3. **需要 NSWindow 配置时插入 WindowAccessor**:在目标 SwiftUI 视图的 `.background {}` 中嵌入 `WindowAccessor`,在回调里设置 `window.level` / `styleMask` / `collectionBehavior`；`makeNSView` 返回空 `NSView()`，所有配置放 `updateNSView`。
4. **包装 NSVisualEffectView / NSGlassEffectView**:新建一个 `NSViewRepresentable`(参考 `GlassEffectView.swift`),用 `makeHostedContentView` 创建内容视图、`pinHostedContentView` 固定约束、`hostedContentView(identifiedBy:)` 在 `updateNSView` 中复用而非重建;对外用 `View` 扩展或 `ViewModifier` 屏蔽实现细节。
5. **运行时分支**:在适配器内用 `if #available(macOS 26, *)` 分支隔离新 API,低版本路径只使用 `Material`(`SwiftUI.Material`)及 `NSVisualEffectView`;不要在低版本路径中引用任何 macOS 26 符号,否则会在 macOS 14 上链接报错。

## 常见陷阱(Pitfalls)

**Pitfall 1:SwiftUI WindowGroup 里拿不到 NSWindow 引用**

症状:试图在 SwiftUI 视图中通过 `@Environment(\.window)` 或直接访问 `NSApp.keyWindow` 来配置 `level` / `styleMask`,结果要么编译失败(`\.window` 不存在于标准环境值),要么时机早于窗口创建导致 `keyWindow` 为 nil。

根因:`makeNSView` 阶段视图尚未插入 NSWindow 层级,`nsView.window` 为 nil。

处理:`WindowAccessor` 模式(见 `InspectorWindow.swift:45`):在 `updateNSView` 中读取 `nsView.window`,此时保证非 nil。若需在 `AppDelegate` 侧查找窗口,用 `NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })`(见 `PeekabooApp.swift:331`),不要假设 `NSApp.keyWindow` 是目标窗口。

**Pitfall 2:`@Observable` 跨模块编译报 Sendable 错误**

症状:Swift 6 严格并发模式下,`@Observable` 类型从一个模块传入另一个模块的 `async` 函数或 Task 闭包时,编译器报 "Type X does not conform to 'Sendable'"。

根因:`@Observable` 宏默认不添加 `@MainActor` 约束;跨越并发域引用非 Sendable 可变引用类型违反 Swift 6 规则。

处理:给状态类加上 `@MainActor`(`Settings.swift:12`、`ConversationSession.swift:13`);所有跨模块传递均限制在 `@MainActor` 任务中执行,例如 `Task { @MainActor in self.openWindow(id: windowId) }`(见 `PeekabooApp.swift:82`)。

**Pitfall 3:`NSViewRepresentable` 中 `updateNSView` 重复 addSubview 导致 SwiftUI 状态重置**

症状:内嵌在 `NSGlassEffectView` 或其他 AppKit 容器中的 SwiftUI 视图每次父状态更新时动画闪烁、`@State` 值归零、输入焦点丢失。

根因:`updateNSView` 被 SwiftUI 频繁调用;若每次都新建 `NSHostingView` 并 `addSubview`,则旧的 SwiftUI 树被销毁,状态随之丢失。

处理:用 `NSUserInterfaceItemIdentifier` 标记 `NSHostingView`,在 `updateNSView` 中先 `hostedContentView(identifiedBy:in:fallbackView:)` 查找已有实例并更新 `rootView`,找不到才新建(`HostingViewHelpers.swift:28`)。

## 延伸阅读

- Peekaboo:`docs/SwiftUI-Implementing-Liquid-Glass-Design.md`、`docs/AppKit-Implementing-Liquid-Glass-Design.md`、`docs/SwiftUI-New-Toolbar-Features.md`、`docs/modern-api.md`
- Apple:[Adopting Liquid Glass](https://developer.apple.com/design/)、[NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- 其它 playbook:[02 · Swift 6 并发](./02-swift6-concurrency.md)、[10 · Visualizer 屏上 overlay](./10-visualizer-overlay.md)、[11 · 工程混合](./11-swiftpm-xcode-poltergeist.md)

---
*Last verified against Peekaboo @ `5647718f`*
