---
summary: 'NemoNotch collapsed/expanded 视觉契约、badge 优先级纯函数状态机、glow(for:) 决策与 CompletionFlashService 驱动模型。'
read_when:
  - '实现 notch badge 多源优先级排序'
  - '向 notch 开合状态添加新的视觉反馈（glow / flash）'
  - '设计基于状态快照的纯函数 UI 决策'
  - '理解 CompletionFlashService 的观测→检测→触发链路'
sources: ['N §16', 'D']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# State-Driven Compact UI

## TL;DR

NemoNotch 的视觉决策统一走**纯函数**：badge 优先级是一个 enum-based 比较函数，glow 颜色是一个 `BadgeItem.glow(for:)` 静态决策，`CompletionFlashService` 把 AI/agent 状态快照送进 `CompletionDetector` 检测边沿（working→idle / active→idle），再驱动全屏 flash + toast。所有决策与 `View` 解耦，可以独立测试。

---

## 可复用模式

### P1 · Badge 优先级纯函数状态机

collapsed 状态下 notch 只能展示一个 badge，优先级由纯函数裁决：

```
ai approval > notification > pomodoro running > agents active > ai working > media playing > calendar upcoming
```

实现方式：`BadgeItem` 是 enum，比较器读取当前 active badge 集合，返回最高优先级 case。决策**不依赖任何 `@Observable` 服务**，而是从外层（`BadgeViewModel`）接收快照（`activeBadgeItems: [BadgeItem]`）并同步返回结果。

**关键设计：** 每次服务状态变化，`BadgeViewModel` 重新计算 `displayedBadge` → SwiftUI 响应式重绘。视图层不保存"上次选择的 badge"这类中间状态。

---

### P2 · Activity Glow 决策：`BadgeItem.glow(for:)`

expanded notch 的内边缘 glow 颜色由以下纯函数决定：

```swift
// 逻辑等价（实际在 BadgeItem + BadgeViewModel 里）
func glow(for activeBadgeItems: [BadgeItem]) -> NotchGlow {
    if activeBadgeItems.contains(where: { /* approval waiting */ }) {
        return .attention
    } else if activeBadgeItems.contains(where: { /* AI working or agent active */ }) {
        return .running
    } else {
        return .none
    }
}
```

`NotchGlow` enum 保持 `.attention` / `.running` / `.none` 分离，当前两态均渲染相同的橙色 accent，但拆分枚举是为了后续可以不改决策逻辑直接区分颜色。

渲染管线：`BadgeViewModel.glowState` → `NotchView` → `NotchBackgroundView`：
- `Rectangle().strokeBorder(…)` 包边，blur 模糊，被 notch mask clip 向内
- 额外 vertical `LinearGradient` mask 让 glow 只出现在下半边缘（向上渐隐）
- `.screen` blendMode，仅在 `status != .closed` 时渲染

可调旋钮（`NotchConstants`）：`glowRingOpacity`、`glowRingWidth`、`glowRingBlur`、`glowRingCoverage`。

---

### P3 · CompletionFlashService 观测链路

```
AISessionStore.sortedSessions      ─┐
AgentMonitorRegistry.installedMonitors ─┘
         │  withObservationTracking（每次状态变）
         ▼
   CompletionDetector（纯函数）
   检测 working→idle / active→idle 边沿
         │  检测到完成
         ▼
  ┌──────────────────────────────────────────┐
  │  上次 flash 在 completionFlashThrottle   │
  │  (~2s) 冷却内？                          │
  │  是 → CompletionFlashNames.merge(…)     │
  │        合并 toast，不重播 glow            │
  │  否 → 触发 flash + 新 toast              │
  └──────────────────────────────────────────┘
```

**Flash 动画曲线**（双脉冲）：

```
flashLevel:  0 → 1 → completionFlashDipLevel → 1 → 0
             ↑rise  ↑dip                    ↑fall
```

通过 `completionGlowOpacity` = `f(flashLevel)` 驱动每个 `CompletionFlashView`（`.blendMode(.screen)` accent 边框 + 模糊 halo，`allowsHitTesting(false)`）。

**Toast**：`CompletionToastView` 挂在 `NotchView` 的 HUD overlay 旁，仅在 `isHUDScreen`（内置屏）显示，避免多屏重复。停留 `completionToastDuration`（5s）后淡出（独立于 HUD 的 `hudDismissDelay`）。

**每屏窗口**：`CompletionFlashWindowController` 为每个 `NSScreen` 创建一个 `CompletionFlashWindow`（全屏 `NSPanel`，`.statusBar + 8` 级别，`allowsHitTesting(false)`），监听 `NSApplication.didChangeScreenParametersNotification` 重建。

可调旋钮（`NotchConstants`）：`completionFlashThrottle`、`completionFlashRise`、`completionFlashDip`、`completionFlashFall`、`completionFlashDipLevel`、`completionToastDuration`、`completionGlowWidth`、`completionGlowBlur`、`completionGlowEdgeWidth`、`completionGlowOpacity`。

开关：`AppSettings.completionFlashEnabled`（默认 `true`），关闭后 flash 和 toast 均不触发。

---

### P4 · Collapsed / Expanded 视觉契约

| 状态 | 几何 | 交互 | 视觉反馈 |
|------|-----|------|---------|
| **Closed** | 硬件 notch 尺寸（约 200×32） | 无 hit testing | CompactBadge（优先级最高的一个徽章） |
| **Opening / popping** | spring 动画过渡 | 无 | 动画中的 notch 形状 |
| **Opened** | 560×328（或 Overview 700pt） | 全 hit testing | TabBar + Tab 内容 + Activity Glow 边缘 |

规则：
- Closed 状态只显示**一个** badge（纯函数决策），不堆叠多个图标
- Opened 状态 glow 只出现在**内边缘下半段**，content 区域保持干净，不影响可读性
- CompletionFlash 在**全屏每个 display** 触发，与 notch 是否展开无关

---

## 锚点

| 锚点 | 文件:行 |
|------|--------|
| Badge 优先级逻辑 | `NemoNotch/Notch/Badge/BadgeViewModel.swift` |
| `CompactBadge` | `NemoNotch/Notch/Badge/CompactBadge.swift` |
| `glow(for:)` 决策 | `NemoNotch/Notch/Badge/BadgeItem.swift` |
| `NotchBackgroundView` glow 渲染 | `NemoNotch/Notch/NotchBackgroundView.swift` |
| `CompletionFlashService` | `NemoNotch/Services/CompletionFlashService.swift` |
| `CompletionFlashWindow` / `WindowController` | `NemoNotch/Notch/CompletionFlashWindow.swift` |
| `CompletionToastView` | `NemoNotch/Notch/CompletionToastView.swift` |
| `NotchConstants` tunables | `NemoNotch/Helpers/Constants.swift` |

---

## Pitfalls

1. **把实时比例（`remainingFraction`）传进 `BadgeItem` case**：每秒触发弹簧动画，参见 `swiftui-patterns.md P5`。
2. **直接在视图里做优先级决策**：逻辑混进 `@Observable` 属性跟踪，难以单独测试。应在 `BadgeViewModel` 里纯函数计算。
3. **glow 渲染忘记 `effectiveStatus` 门控**：副屏在 notch 关闭时仍然持续 glow。
4. **CompletionFlash 在多屏下只在 primary display 创建窗口**：`CompletionFlashWindowController` 需要监听 `didChangeScreenParametersNotification` 并为每个 `NSScreen` 建立窗口。
5. **Toast 在多屏下重复出现**：用 `isHUDScreen` 门控限制只在内置屏显示。
6. **`withObservationTracking` 回调在非主线程触发**：回调体必须用 `Task { @MainActor in … }` 切回主线程，否则 `@MainActor` 隔离 crash。

---

## 落地 Checklist

- [ ] Badge 优先级是纯函数，输入是快照数组，无副作用
- [ ] `glow(for:)` 枚举分离 `.attention` / `.running`，即使当前同色
- [ ] Glow 渲染受 `effectiveStatus != .closed` 门控（防副屏常亮）
- [ ] CompletionFlash 触发前检查 `completionFlashThrottle` 冷却
- [ ] Toast 仅在 `isHUDScreen` 的 NotchView 里挂载
- [ ] CompletionFlashWindowController 监听屏幕参数变通知并重建窗口集合

---

## 延伸阅读

- `swiftui-patterns.md` — `@Observable` 注入、多屏 `effectiveStatus` 门控
- `../window/` — NSPanel `.statusBar+8` 全屏覆盖窗口
- `../architecture/` — `AISessionStore` 状态机与 `AgentMonitorRegistry` 模式
- `native-conventions.md` — HUD toast 场景差异说明
