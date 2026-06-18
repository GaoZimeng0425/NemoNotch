---
summary: 'macOS 原生窗口约定：OS 画阴影/圆角、激活策略切换、焦点还原；标注无边框 notch 面板须自绘形状，两者适用场景并列'
read_when:
  - '实现 Settings 窗口或标准 titled 窗口时确认原生约定'
  - '调试 .accessory 应用的 ⌘Q / 文字焦点问题'
  - '实现打开 notch 后焦点还原到前一个 App'
  - '核实 OS 是否自动处理阴影、圆角'
sources: ['NemoNotch §5.7', 'native-feel R06']
last_verified: { nemonotch: 'fe4e9e5' }
---
# 原生窗口约定

## TL;DR

macOS 对标准 titled 窗口自动处理阴影、圆角、Traffic Lights、Dark Mode 切换。无边框 notch 面板（`styleMask: [.borderless]`）脱离这套渲染，必须手动自绘形状和阴影。两类窗口**适用场景不同，约定不互斥**。激活策略（`.accessory` ↔ `.regular`）需要在显示 Settings 窗口时切换，关闭后切回；焦点还原需要在关闭 notch 时手动激活前一个 App。

---

## 可复用模式

### 1. 激活策略切换（Settings 窗口）

```swift
// NemoNotchApp.swift:97
NSApp.setActivationPolicy(.accessory)   // 启动时：无 Dock 图标，不出现在 Cmd-Tab

// NemoNotchApp.swift:182-194
func handleSettingsAppear() {
    suppressRestoreUntil = Date().addingTimeInterval(1.2)
    NSApp.setActivationPolicy(.regular)   // Settings 显示：恢复正常窗口行为
    NSApp.activate(ignoringOtherApps: true)
}

func handleSettingsDisappear() {
    suppressRestoreUntil = .distantPast
    NSApp.setActivationPolicy(.accessory)  // Settings 关闭：再次隐藏
}
```

**为什么必须切换：**
- `.accessory` 下文字框失去 key-event 路由，`⌘Q` 指向错误 App，Settings 窗口体验损坏
- 不切回 `.accessory` → Dock 遗留幽灵图标

### 2. 焦点还原（关闭 notch 时）

```swift
// NotchCoordinator.swift:29 & 220-239
private var previousApp: NSRunningApplication?

func captureFrontmostApp() {
    let frontmost = NSWorkspace.shared.frontmostApplication
    if frontmost?.bundleIdentifier != Self.ourBundleIdentifier {
        previousApp = frontmost
    }
}

func restorePreviousApp() {
    if restoreSuppressionCheck?() == true { previousApp = nil; return }
    guard let app = previousApp else { return }
    previousApp = nil
    let currentFront = NSWorkspace.shared.frontmostApplication
    if currentFront == nil || currentFront?.bundleIdentifier == Self.ourBundleIdentifier {
        app.activate()
    }
}
```

**suppression window（1.2 s）：** Settings 出现时设置，防止 notch 关闭路径把焦点还给前一个 App，立即让 Settings 消失。

### 3. OS 自动处理（标准 titled 窗口）

| 特性 | OS 行为 | 开发者需要做 |
|------|---------|-------------|
| 阴影 | 自动渲染（`hasShadow` 默认 `true`） | 无 |
| 圆角 | 系统统一圆角 | 无（勿用 `CALayer.cornerRadius` 覆盖） |
| Traffic Lights | 自动左侧放置 | 无 |
| Dark Mode | `NSVisualEffectView` / `NSGlassEffectView` 自动跟随 | 不要硬编码颜色 |
| 窗口阴影颜色 | 跟随系统 | 无 |
| Zoom 按钮 | Green = 窗口级别缩放（非全屏） | 无（Option 键才是全屏）|

### 4. 无边框 notch 面板 — 必须自绘

> **与标准 titled 窗口适用场景不同，两套约定并列。**

`styleMask: [.borderless]` 的窗口：

- `hasShadow = false`（notch 面板不需要阴影，或手动用 SwiftUI `.shadow()` 控制）
- 圆角：用 `RoundedRectangle` 或自定义 `NSBezierPath` clip（`ClipShape`）
- Traffic Lights：不存在
- Dark Mode：手动用 `NSColor.textColor` / `.controlBackgroundColor` 等语义色，或 `.colorScheme(.dark)` 强制锁定

```swift
// NotchBackgroundView 示意
RoundedRectangle(cornerRadius: notchCornerRadius)
    .fill(Color.black)
    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
```

### 5. 原生约定速查（native-feel 清单摘录）

**窗口行为：**
- `⌘W` 关闭，`⌘M` 最小化（Mac 惯例）
- 点 Dock 图标 → 恢复上次活跃窗口，不新建
- Settings 用独立窗口（`⌘,`），不内嵌为主窗口的模态层
- 不用全屏蒙层 + backdrop blur 做对话框，用 `NSAlert`
- 窗口记住上次尺寸/位置（多屏各自独立）

**视觉材质：**
- 背景用平台材质（`NSVisualEffectView`，macOS 26+ 用 `NSGlassEffectView`），不用静态色
- Accent color 跟随系统（`NSColor.controlAccentColor`），不硬编码
- 字体用系统字体（`.body`, `.title` 等 Dynamic Type 变体）

**动画约定：**
- 视图切换用 cut（无渐变过场）
- 动画遵守 `prefers-reduced-motion`
- 低于 200ms 操作不显示 loading；200ms–2s 转圈；>2s 显示进度

---

## 锚点（file:line）

| 符号 | 位置 |
|------|------|
| `NemoNotchApp.handleSettingsAppear()` | `NemoNotch/NemoNotchApp.swift:182` |
| `NemoNotchApp.handleSettingsDisappear()` | `NemoNotch/NemoNotchApp.swift:194` |
| `NotchCoordinator.captureFrontmostApp()` | `NemoNotch/Notch/NotchCoordinator.swift:220` |
| `NotchCoordinator.restorePreviousApp()` | `NemoNotch/Notch/NotchCoordinator.swift:229` |

---

## Pitfalls

1. **Settings 出现后忘切 `.regular`**：文字框失焦，`⌘Q` 错误，用户体验损坏。
2. **Settings 消失后忘切 `.accessory`**：Dock 留有幽灵图标（`NemoNotchApp` 变成正常 App）。
3. **无 suppression window**：Settings 出现时 notch-close path 把焦点还给前 App，Settings 瞬间消失。
4. **无边框窗口误用 `CALayer.cornerRadius`**：SwiftUI 的 `ClipShape` 更可靠，不依赖 layer 刷新时序。
5. **Dark Mode 硬编码颜色**：`NSColor.white` 在 Dark Mode 下仍是白色，用语义色（`.labelColor`, `.controlBackgroundColor`）。
6. **Zoom 按钮行为**：不要把 Green 按钮改成全屏入口（除非产品就是全屏 App），这违背用户预期。

---

## 落地 checklist

**标准 titled 窗口：**
- [ ] 勿自绘阴影/圆角，OS 自动处理
- [ ] 颜色全用语义色，支持 Dark Mode
- [ ] `⌘W` / `⌘M` 响应，通过 `NSWindow.close()` / `miniaturize(_:)`

**无边框 notch 面板：**
- [ ] `hasShadow = false`，自绘圆角（`RoundedRectangle` / `ClipShape`）
- [ ] 激活策略：启动 `.accessory`，Settings 出现切 `.regular`，消失切回
- [ ] 打开 notch 前 `captureFrontmostApp()`，关闭后 `restorePreviousApp()`
- [ ] suppression window（1.2 s）保护 Settings 出现时不被 restore 抢焦点

---

## 延伸阅读

- [nspanel-and-notch.md](nspanel-and-notch.md) — notch 面板完整配置
- [multi-screen-overlay.md](multi-screen-overlay.md) — 多屏 overlay
- [../native-feel/](../native-feel/) — 完整 native-feel 约定（含 Motion、Typography、Interaction）
- [../swiftui/](../swiftui/) — SwiftUI `WindowGroup` 限制 & `WindowAccessor`
