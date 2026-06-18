---
summary: 'NemoNotch + Ironsmith 两个项目提炼的可复用 SwiftUI 模式：@Observable 注入、多屏闪烁抑制、弹簧动画对、HUD 自动消隐、Path 饼图。'
read_when:
  - '在 macOS 原生 app 中用 @Observable 服务注入 SwiftUI 视图树'
  - '调试多屏动画闪烁'
  - '实现可取消的定时器驱动 HUD 淡出'
  - '构建紧凑的环形/饼图徽章'
sources: ['N §16', 'I-20']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# SwiftUI Patterns

## TL;DR

两个项目共同验证的模式：`@Observable @MainActor` 服务 + `@Environment` 注入；`effectiveStatus` 门控抑制副屏闪烁；interactiveSpring 开 / spring 关动画对；`Task { @MainActor in }` 可取消定时器；`Path.addArc` 饼图。Ironsmith 补充了 `@AppStorage`、`@Bindable`、Settings `Form` 等菜单栏 app 惯例。

---

## 可复用模式

### P1 · `@Observable @MainActor` 服务 + `@Environment` 注入

```swift
// NemoNotch/Notch/NotchView.swift:3-15
struct NotchView: View {
    let screen: NSScreen

    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self)      var appSettings
    @Environment(MediaService.self)     var mediaService
    @Environment(AICLIMonitorService.self) var aiService
    // …
}
```

在父级通过 `.environment(serviceInstance)` 播种，通常在 `AppDelegate.applicationDidFinishLaunching` 的 content-builder 闭包里。

**Gotcha：** 运行时缺少服务会在首次访问时 **crash**，没有可选形式。对功能开关型服务，在父级用条件渲染阻止 consumer view 渲染，而不是寄望于 SwiftUI 降级处理。

**Gotcha：** Swift 5.9+ 的 `@Observable` 注入与旧 `@EnvironmentObject` API **不互通**。同一视图树里不要混用两套机制。

---

### P2 · `effectiveStatus` 多屏闪烁抑制

```swift
// NemoNotch/Notch/NotchView.swift:36-38
private var effectiveStatus: NotchCoordinator.Status {
    coordinator.isActiveScreen(screen) ? coordinator.status : .closed
}
```

所有 `notchSize`、`cornerRadius` 以及 `.animation(…, value: effectiveStatus)` 都读这个计算属性，而不是直接读 `coordinator.status`。

**Gotcha：** 缺少此门控，副屏会跟随主屏同步展开——插拔显示器时出现闪烁，并在鼠标悬停主屏 notch 时让副屏永远停在展开态。参见 NemoNotch 关键陷阱 #8。

**Gotcha：** `.animation(_:value:)` 监视的是 `effectiveStatus`，新增动画属性时也必须从 `effectiveStatus` 驱动，否则会回退触发副屏 bug。

---

### P3 · 弹簧动画对：interactiveSpring 开 / spring 关

```swift
// NemoNotch/Notch/NotchCoordinator.swift:187 + 198

// 开：interactive 弹簧，动画叠加时融合而非堆积
withAnimation(.interactiveSpring(duration: NotchConstants.openSpringDuration)) { … }
// 0.314 s

// 关：普通弹簧，确保完成即使鼠标短暂回移
withAnimation(.spring(duration: NotchConstants.closeSpringDuration)) { … }
// 0.24 s
```

**Gotcha：** 两者对调会带来问题——interactive 关给出抖动、永不完全关闭的 notch；普通 open 在快速悬停时产生叠加动画伪影。

**Gotcha：** 时长常量集中在 `NotchConstants`（`openSpringDuration = 0.314`，`closeSpringDuration = 0.24`）。在调用处硬编码字面量会导致 `NotchView` 中多处 `.animation(…)` 修饰符不同步。

> **场景差异（适用场景不同，非错误）**
>
> - **NemoNotch / Notch HUD**：notch 开合和 tab 切换都用短促 spring，理由是用户快速悬停时 interactiveSpring 能融合在途动画。
> - **native-feel 参考**（`06-native-conventions.md`）："简单状态变化不用 spring / bounce 动画；spring 保留给拖拽"——这是针对 web-app 不加区分地在所有状态变化上堆 spring 给出的建议。NemoNotch 的 notch 开合本质上是空间展开（类似 grab-and-drag 的大幅几何变化），属于 native-feel 所说的合理 spring 场景。

---

### P4 · 可取消自动消隐 `Task`（HUD 模式）

```swift
// NemoNotch/Services/HUDService.swift:20 + 283-292  restartDismissTimer()
private var dismissTask: Task<Void, Never>?

private func restartDismissTimer() {
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(NotchConstants.hudDismissDelay))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: NotchConstants.hudDismissDuration)) {
            activeHUD = nil
        }
    }
}
```

每次音量/亮度/电池变化都调用一次 `restartDismissTimer()`；快速连续触发时取消上一个 Task，仅在用户停止操作后才淡出。

**Gotcha：** 需要两层取消保护。`dismissTask?.cancel()` 在赋值前终止在途 Task；sleep 之后的 `guard !Task.isCancelled` 捕捉极小概率的竞态：Task.sleep 返回与 `withAnimation` 执行之间的取消信号。缺少 post-sleep guard 时，快速连续操作偶尔会出现 HUD 中途闪到 nil。

**Gotcha：** `Task { @MainActor in }` 标注是强制的——缺少时 `withAnimation` 在非主线程执行，动画静默失效（UI 直接 snap 而非淡出）。优先用此惯用语代替 `DispatchQueue.main.asyncAfter(deadline:)`，后者不可取消，需要额外的布尔标志。

---

### P5 · `Path.addArc` 饼图（多尺寸复用）

```swift
// NemoNotch/Notch/Badge/PomodoroPieView.swift
GeometryReader { geo in
    let radius = min(geo.size.width, geo.size.height) / 2
    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
    Path { p in
        p.move(to: center)
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),                            // 12 点方向起
            endAngle: .degrees(-90 + 360 * remainingFraction),
            clockwise: false
        )
        p.closeSubpath()
    }
    .fill(color)
}
```

背景用 `Circle().stroke(color.opacity(0.25))` 渲染空扇区。同一组件用于 14pt notch 徽章和 88pt 活动面板——尺寸预设不同，组件相同。

**Gotcha：** 不要把 `remainingFraction` 传进 `BadgeItem` 的 `Equatable` case——每秒变化会触发 `BadgeViewModel.updateDisplayedBadges` 的徽章弹簧动画。用 case 传身份（如 `.pomodoro(phase:)`），在视图内通过 `@Environment(PomodoroTimerService.self)` 读实时比例。

---

### P6 · Ironsmith 补充：菜单栏 app SwiftUI 惯例

来源：Ironsmith principles §20(I-20)

- **菜单栏优先**，不引入模板式主窗口流。
- Settings 用原生 `Form { Section { … } }` + `.formStyle(.grouped)`；控件选 `LabeledContent / Picker / Toggle / Stepper / Slider / List`。
- 共享状态：`@Environment(InferenceStore.self)`；需要 binding 时在 `body` 内建局部 `@Bindable var x = x`。
- UserDefaults 绑定：`@AppStorage(IronsmithPreferenceKeys.xxx)`——键用常量，不硬编码字符串。
- 条件渲染用 `@ViewBuilder` 私有计算属性，而非深层 if-else 嵌套。
- 展示辅助（logo / 名称清洗）集中管理，**优先扩展而非重复实现**。
- 预览和测试必须容忍空数组；预览 frame 应贴近真实 surface 尺寸。

---

### P7 · 共享 modifier 即设计系统

```swift
// NemoNotch/Helpers/ViewModifiers.swift
// NotchTheme (色彩 token)
// NotchCardModifier / .notchCard()
// NotchPillButtonStyle
// PulseModifier, GlowPulseModifier
// ScrollEdgeShadowMaskModifier / .notchScrollEdgeShadow()

// NemoNotch/Helpers/ToolStyles.swift
// ToolStyle.icon(_:) / ToolStyle.color(_:) — AI 工具名 → SF Symbol + tint
```

**Gotcha：** 在 tab 视图里内联 `.background(Color…)` 或 `.font(.system(size: …))` 是代码异味——应扩展共享 modifier 或 token。Review 时应拒绝与现有 modifier 重复的内联样式。

---

## 锚点

| 锚点 | 文件:行 |
|------|--------|
| `NotchView` `@Environment` 注入 | `NemoNotch/Notch/NotchView.swift:3-15` |
| `effectiveStatus` 门控 | `NemoNotch/Notch/NotchView.swift:36-38` |
| 弹簧动画对 | `NemoNotch/Notch/NotchCoordinator.swift:187+198` |
| `restartDismissTimer` HUD 模式 | `NemoNotch/Services/HUDService.swift:20+283-292` |
| `PomodoroPieView` 饼图 | `NemoNotch/Notch/Badge/PomodoroPieView.swift` |
| 共享 modifier | `NemoNotch/Helpers/ViewModifiers.swift` |
| ToolStyles | `NemoNotch/Helpers/ToolStyles.swift` |

---

## Pitfalls

1. **Missing `@Environment` seed → crash**：运行时无降级，必须在父级保证已播种。
2. **直接读 `coordinator.status` 而不经 `effectiveStatus`**：副屏闪烁，难复现。
3. **互换 interactiveSpring/spring**：rapid hover 时动画堆叠或永不关闭。
4. **`withAnimation` 在非 `@MainActor` context 执行**：动画静默失效，UI snap。
5. **每秒变化量传进 `BadgeItem` case**：触发不必要的弹簧动画，性能劣化。

---

## 落地 Checklist

- [ ] 每个 `@Environment` property 均有祖先 `.environment(instance)` 保障
- [ ] 多屏 app 的 animated property 经 `effectiveStatus`（或等价门控）驱动
- [ ] 开合弹簧使用 interactiveSpring/spring 对，时长常量化
- [ ] 可取消 HUD 定时器使用 `Task { @MainActor in }` + 双层取消保护
- [ ] 饼图 `BadgeItem` case 只携带身份，不携带实时比例
- [ ] 新 UI 复用 `NotchTheme` / `NotchConstants` / 共享 modifier，不内联

---

## 延伸阅读

- `../architecture/` — 服务所有权、闭包注入 vs `AppDelegate.shared`
- `appkit-bridging-liquid-glass.md` — `@Observable @MainActor` 跨模块 Sendable 边界
- `state-driven-compact-ui.md` — badge 优先级状态机与 glow 决策
- `native-conventions.md` — spring 使用场景的 native-feel 基准
