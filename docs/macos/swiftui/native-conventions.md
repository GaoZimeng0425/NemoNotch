---
summary: '可复用原生交互约定与设计 token：来自 native-feel 参考和 Warm Noir Utility 的融合，并列呈现三处场景差异。'
read_when:
  - '判断一个新 UI 是否符合 macOS 原生交互约定'
  - '选择 accent 颜色策略（跟系统 vs 固定品牌色）'
  - '决定动画节奏（何时用 spring，何时不用）'
  - '决定是否使用 toast（OS 通知 vs 应用内 HUD）'
sources: ['D', 'R']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# Native Conventions

## TL;DR

两个角度互补：**native-feel**（`06-native-conventions.md`）给出跨平台 web-wrapper 场景下"让 app 看起来原生"的 checklist；**Warm Noir Utility**（`design-system/warm-noir-utility.md`）给出 NemoNotch 这类固定风格单 OS 工具的具体 token 和组件规范。三处明显的分歧（accent / 动画 / toast）各有适用场景，不是非此即彼——分别标注。

---

## 可复用模式

### 输入与光标

- List row、sidebar item、toolbar item：**保留** subtle hover background；**不要**改 cursor（`cursor: pointer` 是 web 告，native list row 不改光标）。
- 普通 push button（`NSButton.bezelStyle = .rounded`）：native 不加 hover 背景，不要加。
- Borderless / icon button in toolbar：native 加 subtle background tint on hover，匹配它。
- 仅内容区（editable text、message body）允许文字选择；标签、按钮文字、标题不可选。
- Caret cursor 仅出现在 input 上；non-editable 区不显示 I-beam。

---

### 窗口与焦点

- ⌘W 关窗口；⌘M 最小化（mac）；⌘, 打开 Settings。
- Settings 开独立 native 窗口，不做主窗口内的模态层。
- Dock/Taskbar 图标点击：re-focus 已有窗口，不重开新窗口（macOS `LSMultipleInstancesProhibited` 自动处理）。
- 窗口跨启动记住尺寸和位置（多屏各自记）。
- Mac 绿色按钮 = zoom（窗口级别缩放），不是全屏，除非用户按住 Option。

---

### 材质与视觉

- 窗口背景用平台材质：macOS 14-25 用 `NSVisualEffectView`；macOS 26+ 用 `NSGlassEffectView`（Liquid Glass）。
- 深色模式跟系统设置，切换时无逐帧闪烁。
- 系统字体：macOS 用 `-apple-system / SF Pro`；SwiftUI 里默认 `.system(…)` 即对。
- 不用 `box-shadow` 模拟窗口阴影（OS 绘制）；不用 `border-radius` 模拟窗口圆角（OS 控制）。

---

### 滚动

- Mac 上 overlay scrollbar（淡出式，WebKit 默认正确）。
- 不用 JS smooth-scroll polyfill（`behavior: 'auto'`）。
- 不 override rubber-band 弹性回弹。
- 导航内切换不重置 scroll position。

---

### 键盘

- 所有可操作元素可 Tab/方向键到达。
- Focus ring 匹配系统样式（Mac：蓝色 glow ring）。
- Escape 有意义：关 popover、取消操作、关闭窗口。
- List 支持 type-ahead（按字母跳转）。

---

### 系统集成

- 真实 `Info.plist` / bundle identifier / version / icon / document types。
- URL schemes 正确注册（`appname://` 全系统可用）。
- Crash reporter 接入（Sentry / Bugsnag 等）；不只是"请下载新版本"链接。
- Auto-update 用真实流程（Sparkle on macOS）。

---

### 无障碍

- VoiceOver 可读全部内容（native 控件自动支持；WebView 需 ARIA roles）。
- 焦点移动时宣告（announce）。
- 颜色对比度至少满足 WCAG AA。
- 不用固定像素尺寸（系统字体大小调大后不应 overflow）。
- 所有操作鼠标外可达。

---

## Warm Noir Utility 样式 Token

### 色彩 Token（`NotchTheme`）

```swift
// NemoNotch/Helpers/ViewModifiers.swift
enum NotchTheme {
    static let accent        = Color(red: 1.0, green: 0.55, blue: 0.08)   // ~#FF8C14
    static let accentHot     = Color(red: 1.0, green: 0.38, blue: 0.18)   // ~#FF612E
    static let accentText    = Color(red: 1.0, green: 0.58, blue: 0.28)   // ~#FF9447
    static let accentSoft    = accent.opacity(0.18)
    static let textPrimary   = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.42)
    static let textMuted     = Color.white.opacity(0.30)
    static let panelBase     = Color(red: 0.005, green: 0.005, blue: 0.004)
    static let panelRaised   = Color(red: 0.025, green: 0.023, blue: 0.020)
    static let surfaceSubtle = Color.white.opacity(0.045)
    static let surface       = Color.white.opacity(0.07)
    static let surfaceEmphasis = Color.white.opacity(0.12)
    static let surfaceWarm   = Color(red: 0.23, green: 0.11, blue: 0.035).opacity(0.64)
    static let rail          = Color.white.opacity(0.075)
    static let stroke        = Color.white.opacity(0.10)
    static let strokeStrong  = Color.white.opacity(0.15)
    static let accentStroke  = accent.opacity(0.42)
}
```

### 状态语义映射

| 语义 | Token |
|------|-------|
| 主要文字（标题、重要值） | `textPrimary` |
| 次要文字（摘要、元数据） | `textSecondary` |
| 三级文字（闲置图标、时间戳） | `textTertiary` |
| 静音文字（路径、旧值） | `textMuted` |
| 活跃状态（working / waiting / approval） | `accent`、`accentText`、`surfaceWarm`、`accentStroke` |
| 进度条 | `accentText` on `rail` |
| 普通行 | `surfaceSubtle` + `strokeStrong` |
| 嵌入工具面板 | `surface` + `stroke` |
| 选中 tab / chip | `surfaceEmphasis` |

### 允许的例外色

- Gemini / Hermes / 外部 source identity：小蓝 tint icon / badge / row border / active dot
- 错误：红色，仅用于 failure/error/denied/high CPU
- 警告：黄/橙，仅用于 caution/pending/中优先级
- 成功：绿色，仅用于 completed/online/success

规则：例外色只能做 icon、dot、label、badge tint、细线条、低透明度 row tint；**不能**主导 shell、主背景或全局 accent。

---

### 字型比例

| 角色 | SwiftUI | 用途 |
|------|---------|------|
| 标题 | `.system(18, .bold)` | Tab 级产品/source 标题 |
| 副标题 | `.system(13, .medium)` | session 数量、摘要 |
| 行标题 | `.system(13, .bold)` | session/agent/进程名 |
| 行正文 | `.system(10)` | 最新消息、辅助细节 |
| 行元数据 | `.system(9)` | workspace、token 数 |
| 时间戳 | `.system(11, .medium)` | `now`、`1m`、`3h` |
| Badge | `.system(10, .bold, design: .rounded)` | 状态/source/工具标签 |
| 按钮 | `.system(11, .semibold)` | pill button |
| 数值（等宽） | `.system(13, .semibold, design: .monospaced)` | CPU、速度、紧凑数字 |
| 进度标签 | `.system(8, .medium, design: .monospaced)` | context token 标签 |

---

### 间距词汇表

| 值 | 用途 |
|----|------|
| 4 | 内部元数据间隙、紧凑 HStack |
| 6 | 小行/图标间隙、badge horizontal gap |
| 8 | 标准紧凑间距、row 内部分组、card radius |
| 11 | 当前 list row vertical padding |
| 12 | row horizontal padding |
| 14 | header icon/title 间隙、pill horizontal padding |
| 16 | tab content padding、scroll fade 厚度 |

---

### 圆角与形状

| 元素 | 圆角 |
|------|------|
| Opened notch shell | `24`（底角），`cornerRadiusOpened` |
| Closed notch | `8`，`cornerRadiusClosed` |
| Source hero tile（header） | `12`，continuous |
| Source mark（row） | `9`，continuous |
| Standard row card | `8`，continuous |
| Badge / pill / progress | capsule |

---

### 动效词汇表

| 动作 | 常量 / 值 | 用途 |
|------|---------|------|
| Open spring | `openSpringDuration = 0.314`, bounce `0.1` | Shell 展开 |
| Close spring | `closeSpringDuration = 0.24` | Shell 收起 |
| Tab switch | `tabSwitchSpringDuration = 0.28`, bounce `0.06` | Tab 切换 |
| Badge spring | `badgeSpringDuration = 0.32`, bounce `0.08` | Badge 更换 |
| Fast fade | `fadeFastDuration = 0.16` | 快速透明度变化 |
| Normal fade | `fadeNormalDuration = 0.24` | 标准 fade |
| Pulse | `pulseDuration = 1.05` | Active 状态脉冲 |
| HUD appear | `hudAppearDuration = 0.3`, bounce `0.08` | HUD 出现 |
| HUD dismiss | `hudDismissDuration = 0.2` | HUD 消隐 |

---

## 三处场景差异（并列呈现，适用场景不同，非错误）

### ① Accent 颜色：跟系统 vs 固定品牌色

**native-feel 基准**（`06-native-conventions.md`，Materials & visual）：

> "Accent color follows system accent color（Mac: `NSColor.controlAccentColor`）. Don't hardcode brand blue."

适用场景：跨平台 web-wrapper app、工具类 utility app、希望融入不同用户系统主题的 app——跟随系统强调色，让 app 在任何主题下都原生感。

**Warm Noir Utility（NemoNotch）**：

> `NotchTheme.accent = Color(red: 1.0, green: 0.55, blue: 0.08)` 固定暖橙，不跟系统。

适用场景：单 OS 纯原生品牌 HUD app——notch 作为设备内一体化的系统级面板，暖橙是视觉身份的核心，跟随系统可能破坏精心调校的黑橙对比。

**结论：** 两个建议都对。判断标准是：app 是否有强品牌视觉身份 + 是否只在 macOS 上运行。品牌 HUD → 固定色；通用工具 / 跨平台 → 跟系统。

---

### ② 动画节奏：简单状态变化不用 spring vs 开合 / tab 用短促 spring

**native-feel 基准**（`06-native-conventions.md`，Motion）：

> "No spring/bounce animations on simple state changes. Native uses tightly-controlled ease curves. Reserve spring for grab-and-drag."

适用场景：针对 web app 不加区分地对所有状态变化（文字变色、opacity 切换、微小 layout）加 spring 的反模式——告诫"不要在简单状态变化上堆 spring"。

**Warm Noir Utility（NemoNotch）**：

> notch 开合用 `interactiveSpring(0.314)` / `spring(0.24)`；tab 切换用 `tabSwitchSpringDuration = 0.28, bounce 0.06`。

适用场景：notch 开合是一个大幅几何形变（宽从 200 变 560，高从 32 变 328），与 grab-and-drag 在物理感受上等同；interactiveSpring 的具体作用是融合用户快速悬停时在途动画。这与 native-feel 说的"简单状态变化"不同类。

**结论：** 两个建议都对，区别在于"状态变化有多大"。大幅空间变形（notch 展开、sheet 弹出、side panel 滑入）→ spring 合理；小幅状态变化（文字颜色、opacity、小 icon 旋转）→ ease curve 更原生。

---

### ③ Toast 通知：不用 web 式 toast vs Notch 内 HUD toast

**native-feel 基准**（`06-native-conventions.md`，Windowing & focus）：

> "No web-style 'toast' notifications. Use the OS notification center."

适用场景：替代系统通知（文件保存成功、操作完成、错误提示）时，web app 常用页面内 toast；macOS 原生做法是用 `UNUserNotificationCenter`，让 OS 统一管理展示时机和 Do Not Disturb 规则。

**Warm Noir Utility / NemoNotch 的 `CompletionToastView`**：

AI / agent session 完成时在 notch 内紧贴显示 HUD 胶囊 toast（列出完成的 project / agent 名）。这不是通知替代——它是 **notch 自身 UI 的一部分**，与 notch 物理上一体，功能更接近音量/亮度 HUD overlay，而非系统通知。它不出现在通知中心，不受 Do Not Disturb 影响，也不需要通知权限。

**结论：** 两个都对，区别在于"告知的是谁的事"。系统级事件（文件、应用操作）→ OS 通知中心；notch 自身状态的直接反馈（AI 完成、HUD volume）→ notch 内 overlay 合理，且更紧凑、延迟更低。

---

## Anti-Pattern 速查

| 反模式 | 类别 |
|--------|------|
| `cursor: pointer` on list row | Input |
| 标签文字可选中 | Input |
| 模态层 + backdrop blur 替代 `NSAlert` | Windowing |
| 用 web toast 替代系统通知（应用事件） | Windowing |
| 静态颜色替代 `NSVisualEffectView` 背景 | Material |
| JS smooth-scroll polyfill | Scrolling |
| 简单状态变化加 spring / bounce | Motion |
| 加载时展示骨架屏（< 500ms 操作） | Loading |
| 多步 onboarding tour | Onboarding |
| 紫/蓝 AI 渐变作主题 | Design system |
| 大面积橙色矩形背景 | Design system |
| emoji 作为核心导航/操作图标 | Design system |
| nested rounded card × 3+ | Design system |

---

## 落地 Checklist

- [ ] List row hover：保留 subtle background tint，不改 cursor
- [ ] Settings 用独立 native 窗口 + `Form(.grouped)`
- [ ] 窗口大小/位置跨启动保存（多屏各自记）
- [ ] VoiceOver 可读，icon-only button 有 `.accessibilityLabel`
- [ ] 新 UI 使用 `NotchTheme` token，不内联 hex 颜色
- [ ] 大幅空间变形用 spring；小幅状态变化用 ease-out；参见 `../swiftui/swiftui-patterns.md P3`
- [ ] 应用事件通知走 `UNUserNotificationCenter`；notch 自身状态反馈可用 HUD overlay

---

## 延伸阅读

- `../native-feel/` — 完整 native-feel 原则与 checklist 原文
- `../design-system/` — Warm Noir Utility 完整设计规范（组件级规格、Motion System、Review Checklist）
- `swiftui-patterns.md` — `@Observable` 注入、spring 动画对实现
- `state-driven-compact-ui.md` — NemoNotch glow / flash / toast 完整驱动模型
