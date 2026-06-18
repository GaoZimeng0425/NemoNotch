---
summary: 'SwiftUI 知识库索引：四篇覆盖框架模式、AppKit 互操作、状态驱动紧凑 UI 和原生交互约定。'
last_verified:
  peekaboo: 'e3a66d317544420891d62da17120bf18e37118f3'
  nemonotch: 'fe4e9e5'
---

# SwiftUI 知识库

来自 NemoNotch 和 Peekaboo 两个项目的 SwiftUI 可复用模式，融合 native-feel 参考和 Warm Noir Utility 设计系统提炼。

| 文件 | 一句话 | 何时读 |
|------|--------|--------|
| [swiftui-patterns.md](swiftui-patterns.md) | `@Observable` 注入、多屏闪烁抑制、spring 动画对、HUD 可取消定时器、Path 饼图 | 构建 SwiftUI 视图树或调试多屏动画 |
| [appkit-bridging-liquid-glass.md](appkit-bridging-liquid-glass.md) | `@main App` + `@NSApplicationDelegateAdaptor` 双层架构、WindowAccessor、NSHostingView 三件套、Liquid Glass 适配器 | 混用 SwiftUI 与 AppKit，或需要 NSWindow level/styleMask 控制 |
| [state-driven-compact-ui.md](state-driven-compact-ui.md) | Badge 优先级纯函数状态机、`glow(for:)` 决策、CompletionFlashService 观测链路 | 向 notch collapsed/expanded 状态添加新的视觉反馈 |
| [native-conventions.md](native-conventions.md) | 原生交互约定 + Warm Noir Utility token，并列三处场景差异（accent / spring / toast） | 判断新 UI 是否原生，或选择 accent / 动画 / toast 策略 |
