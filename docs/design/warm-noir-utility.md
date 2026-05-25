---
summary: 'Warm Noir Utility design system reference for NemoNotch UI and future component development.'
read_when:
  - 'designing any new NemoNotch UI'
  - 'refactoring SwiftUI styles for the notch, tabs, overlays, settings, or agent/session surfaces'
  - 'prompting an AI assistant to match the current NemoNotch interface'
  - 'reviewing whether a UI change still belongs to the NemoNotch visual system'
source_of_truth:
  - '../../NemoNotch/Helpers/ViewModifiers.swift'
  - '../../NemoNotch/Helpers/Constants.swift'
reference_images:
  - '../images/nemo-notch.png'
  - '../images/nemo-notch-2.png'
---

# Warm Noir Utility

Warm Noir Utility 是 NemoNotch 的核心 UI 风格。它定义了 NemoNotch 未来所有 Notch、HUD、tab、agent/session、系统状态、轻量设置与辅助面板应该共享的视觉语言。

它的气质是一个从 macOS Notch 自然展开的系统级 HUD:黑色悬浮面板、温暖橙色状态反馈、紧凑的信息密度、原生系统字体、极少装饰。它应该像 macOS 的一部分,而不是像网页 dashboard、营销页、聊天产品官网或通用 AI SaaS 模板。

## Is This Enough?

旧版文档足够传达“感觉”,但不足以稳定约束未来所有 UI。它缺少这些会影响一致性的内容:

- 代码中的真实 token 映射: `NotchTheme`, `NotchConstants`, `notchCard`, `NotchPillButtonStyle`。
- 组件级规格:header、row、badge、progress、empty state、detail view、HUD、settings 的具体做法。
- 状态语义:哪些状态可以用橙色,哪些只能用灰色,什么时候允许蓝/红/黄/绿。
- SwiftUI 落地规则:新 UI 应复用哪些 helper,什么情况下才新增 token。
- AI 使用流程:后续 AI 开始写 UI 前应该读什么、检查什么、避免什么。
- Review checklist:判断一个新组件是否偏离风格的标准。

本文件扩展后可以作为“设计参考源”使用。若要进一步强制一致性,下一步应把本规范沉淀为更多代码级组件和 modifier,让实现天然走同一条路。

## One-Line Prompt

> Follow the Warm Noir Utility style from `docs/design/warm-noir-utility.md`: black floating macOS HUD surfaces, large notch-like rounded panels, restrained warm orange state accents, SF Pro-like system typography, compact utility layout, subtle borders, soft glow only for active state, and no marketing-style decorative UI.

## Design Pillars

### 1. System HUD, Not App Page

NemoNotch 的 UI 是屏幕顶部伸出的系统级控制面板。它不应该像一个完整网页、传统 dashboard 或卡片式管理后台。

Do:

- 让主面板感觉是一个连续的悬浮物体。
- 让信息从 Notch 锚点向下展开。
- 使用系统字体、SF Symbols、macOS 原生动画节奏。
- 保持内容操作化:状态、进度、会话、动作、同步、系统指标。

Avoid:

- Hero section、营销标语、大幅插图、宣传型文案。
- 一屏多个大 card 拼成 dashboard。
- 用装饰性背景来制造“高级感”。

### 2. Warm Status, Cold Discipline

整体是黑灰克制系统,橙色只负责让状态“活起来”。橙色不是品牌背景色,而是状态能量。

Do:

- 用暖橙表示 active、waiting、working、progress、approval、primary action。
- 在黑色表面上用低透明橙色做 active fill / glow。
- 让灰色负责绝大多数结构和说明信息。

Avoid:

- 大面积橙色背景。
- 每个模块都用不同高饱和颜色。
- 紫蓝 AI 渐变、玻璃彩虹、霓虹科技风。

### 3. Dense But Breathable

NemoNotch 的可用空间有限,所以信息要紧凑。但紧凑不等于拥挤:靠明确的行高、间距、字体层级和对齐保证可扫读。

Do:

- 行内信息按固定顺序排列:source/status -> title -> badges -> spacer -> time/value。
- 使用 `lineLimit`, `truncationMode`, `minimumScaleFactor` 管理极端内容。
- 让数字、百分比、token、时间右对齐或单独定宽。

Avoid:

- 长句说明挤在 row 里。
- 因 hover、badge、loading、动态文本导致布局跳动。
- 在小区域使用过大的标题字。

### 4. Native Motion, Not Performance

动画是为了表达状态转换和空间关系,不是为了表演。NemoNotch 应该有系统弹性,但不能有网页式炫技。

Do:

- 打开、关闭、tab 切换使用短促 spring。
- 状态点可以轻微 pulse。
- Hover / press 只做细微亮度、边框、scale、opacity 变化。

Avoid:

- 大幅滑动、旋转、粒子、背景漂浮物。
- 持续循环的装饰动画。
- 影响阅读的闪烁。

## Source Files To Respect

Future UI work should treat these files as the implementation source of truth:

| File | Purpose |
|---|---|
| `NemoNotch/Helpers/ViewModifiers.swift` | `NotchTheme`, `notchCard`, `NotchPillButtonStyle`, pulse/glow modifiers |
| `NemoNotch/Helpers/Constants.swift` | Notch geometry, spacing, animation durations, HUD dimensions |
| `NemoNotch/Notch/NotchBackgroundView.swift` | Main notch material, mask, shadow, opened shell |
| `NemoNotch/Notch/NotchView.swift` | Open/closed geometry, tab content padding, transition behavior |
| `NemoNotch/Tabs/AIChatTab.swift` | Best reference for header, session rows, badges, progress bars, approval actions |
| `NemoNotch/Tabs/AgentMonitorTab.swift` | Best reference for source identity, agent rows, active/idle hierarchy |
| `NemoNotch/Tabs/SystemTab.swift` | Best reference for compact metrics, monospaced numbers, utility rows |

Rule: if a new UI needs a visual primitive already represented in these files, reuse the existing token, modifier, or component pattern. Do not invent a parallel style in a single view.

## Color System

Use `NotchTheme` first. Do not hard-code colors inside new components unless it is a one-off external identity color, and even then keep it small and local.

### Core Tokens

Current SwiftUI source:

```swift
enum NotchTheme {
    static let accent = Color(red: 1.0, green: 0.55, blue: 0.08)
    static let accentHot = Color(red: 1.0, green: 0.38, blue: 0.18)
    static let accentText = Color(red: 1.0, green: 0.58, blue: 0.28)
    static let accentSoft = accent.opacity(0.18)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.42)
    static let textMuted = Color.white.opacity(0.30)
    static let panelBase = Color(red: 0.005, green: 0.005, blue: 0.004)
    static let panelRaised = Color(red: 0.025, green: 0.023, blue: 0.020)
    static let scrollFade = Color(red: 0.070, green: 0.038, blue: 0.018)
    static let surfaceWarm = Color(red: 0.23, green: 0.11, blue: 0.035).opacity(0.64)
    static let surfaceSubtle = Color.white.opacity(0.045)
    static let surface = Color.white.opacity(0.07)
    static let surfaceEmphasis = Color.white.opacity(0.12)
    static let rail = Color.white.opacity(0.075)
    static let stroke = Color.white.opacity(0.10)
    static let strokeStrong = Color.white.opacity(0.15)
    static let accentStroke = accent.opacity(0.42)
}
```

Approximate perceptual palette:

| Token | Approx | Role |
|---|---:|---|
| `panelBase` | near `#010101` | Main black shell |
| `panelRaised` | near `#060605` | Slightly lifted top gradient |
| `accent` | near `#FF8C14` | Main warm orange action/state |
| `accentHot` | near `#FF612E` | Hotter orange gradient stop |
| `accentText` | near `#FF9447` | Orange text/progress that reads softer |
| `scrollFade` | near `#120A05` | Warm scroll edge fade |
| `textPrimary` | rgba white 94% | Primary readable text |
| `textSecondary` | rgba white 62% | Metadata and secondary labels |
| `textTertiary` | rgba white 42% | Quiet labels, icons, idle state |
| `textMuted` | rgba white 30% | De-emphasized helper content |
| `surfaceSubtle` | white 4.5% | Quiet row/card fill |
| `surface` | white 7% | Standard embedded surface |
| `surfaceEmphasis` | white 12% | Selected tab, chip, stronger surface |
| `surfaceWarm` | warm brown 64% opacity | Attention/approval/active surface |
| `rail` | white 7.5% | Progress track |
| `stroke` | white 10% | Default border |
| `strokeStrong` | white 15% | Stronger row border |
| `accentStroke` | orange 42% | Active/attention border |

### Color Semantics

| Semantic | Use | Token |
|---|---|---|
| Primary text | Titles, row labels, important values | `textPrimary` |
| Secondary text | Summaries, subtitles, metadata | `textSecondary` |
| Tertiary text | Inactive icons, quiet timestamps | `textTertiary` |
| Muted text | File paths, old values, helper fragments | `textMuted` |
| Active state | Working, waiting, approval, selected active row | `accent`, `accentText`, `surfaceWarm`, `accentStroke` |
| Progress | Context bars, usage bars, completion | `accentText` on `rail` |
| Neutral row | Regular list item | `surfaceSubtle` + `strokeStrong` |
| Embedded utility panel | Footer, metric group, message card | `surface` + `stroke` |
| Selected tab/chip | Current tab, selected filter, subtle selected control | `surfaceEmphasis` |

### Secondary Colors And Exceptions

Warm orange is the default accent. Other colors are allowed only when they carry external identity or established system semantics.

Allowed exceptions:

- Gemini / Hermes / external source identity: small blue-tinted icon, badge, row border, or active dot.
- Error: red, only for failure/error/denied/high CPU.
- Warning: yellow/orange, only for caution, pending, medium priority, or temporary warning.
- Success: green, only for completed/online/success states.
- Calendar/event colors: small strips or icons can inherit calendar/app colors.

Rules for exceptions:

- Keep non-orange colors small: icon, dot, label text, badge tint, thin strip, or low-opacity row tint.
- Never let exception colors take over the shell, main background, or global accent.
- Pair color with text/icon. Do not communicate state by color alone.

### Color Anti-Patterns

- Purple-blue AI gradient as a primary theme.
- Beige/cream dashboard look.
- Full glassmorphism surface with bright blur highlights.
- Large orange rectangles behind full sections.
- Random colors per component without semantic need.
- Pure white strokes or text at 100% opacity except tiny icons on colored tiles.

## Surface Hierarchy

Warm Noir Utility has a strict surface hierarchy. Most inconsistency comes from adding too many independent card layers.

### Level 0: Desktop / Screen

Outside NemoNotch. The UI must separate itself through black material and shadow, not by adding a fake page background.

### Level 1: Notch Shell

The main object. It is one continuous black shape that expands from the hardware notch.

Existing constants:

| Constant | Value |
|---|---:|
| `defaultNotchWidth` | `200` |
| `defaultNotchHeight` | `32` |
| `openedWidth` | `560` |
| `overviewOpenedWidth` | `700` |
| `openedHeight` | `328` |
| `cornerRadiusClosed` | `8` |
| `cornerRadiusOpened` | `24` |
| `notchBackgroundSpacing` | `16` |

Style:

- Fill: vertical gradient from `panelRaised` to `panelBase` to black.
- Optional highlight: low-opacity warm radial/linear glow when opened.
- Shadow: black, radius `14`, opacity `0.34`.
- Bottom corners: `24` in opened state.

Use this level only for the Notch container itself. Do not put another full-width fake panel inside it unless the UI is an auxiliary window.

### Level 2: Tab Content Area

The content inside the opened shell.

Existing constant:

| Constant | Value |
|---|---:|
| `tabContentPadding` | `16` |

Rules:

- Default content padding is `16`.
- Many tabs add `2-4` px internal horizontal nudge to align row edges.
- The content area should feel integrated into the shell; avoid large section cards that fight the shell.

### Level 3: Rows And Embedded Cards

Use for session rows, process rows, message cards, metric footers, and compact forms.

Default recipe:

```swift
.background(
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(NotchTheme.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NotchTheme.strokeStrong, lineWidth: 0.7)
        )
)
```

Active/attention recipe:

```swift
.background(
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(NotchTheme.surfaceWarm)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(NotchTheme.accentStroke, lineWidth: 1)
        )
)
.shadow(color: NotchTheme.accent.opacity(0.12), radius: 14, y: 6)
```

### Level 4: Pills, Badges, Dots, Progress

Small elements that express metadata and state. They sit inside rows and should never become dominant containers.

## Typography

Use macOS system typography. In SwiftUI, use `.system(...)` with deliberate size, weight, and rounded/monospaced design only when useful.

### Type Scale

| Role | SwiftUI Example | Use |
|---|---|---|
| Header title | `.system(size: 18, weight: .bold)` | Tab-level product/source title |
| Header subtitle | `.system(size: 13, weight: .medium)` | Session count, summary |
| Row title | `.system(size: 13, weight: .bold)` | Session/agent/process name |
| Row body | `.system(size: 10)` | Last message, helper detail |
| Row metadata | `.system(size: 9)` | Workspace, token count, small path |
| Timestamp | `.system(size: 11, weight: .medium)` | `now`, `1m`, `3h` |
| Badge | `.system(size: 10, weight: .bold, design: .rounded)` | Status/source/tool/model tags |
| Button | `.system(size: 11, weight: .semibold)` | Pill buttons |
| Metric value | `.system(size: 13, weight: .semibold, design: .monospaced)` | CPU, speed, compact numeric values |
| Progress label | `.system(size: 8, weight: .medium, design: .monospaced)` | Context token labels |
| Empty state icon | `.system(size: 20-28, weight: .semibold)` | Empty/install/offline states |

### Typography Rules

- Use `textPrimary` for titles and values that must scan first.
- Use `textSecondary` for summary and supporting content.
- Use `textTertiary` or `textMuted` for idle, older, or less important metadata.
- Use monospaced design for numbers that compare across rows: CPU, memory, tokens, percentages, speed.
- Use rounded design for badges and compact state labels.
- Keep UI copy short and operational.
- Prefer `lineLimit(1)` for labels and titles, `lineLimit(2)` for message previews.
- Use `minimumScaleFactor(0.8)` for narrow numeric values that must stay in place.
- Avoid display fonts, serif fonts, playful fonts, and oversized page-style headings.

## Spacing System

Use the existing compact spacing vocabulary. Values are usually small, even when the UI feels spacious, because the Notch surface is short.

### Common Values

| Value | Use |
|---:|---|
| `2` | Tiny alignment nudges, compact tab adjustment |
| `3` | Mini badge vertical padding, tiny meter spacing |
| `4` | Inner metadata gaps, compact HStack spacing |
| `6` | Small row/icon gaps, button vertical padding, badge horizontal gap |
| `8` | Standard compact spacing, row inner groups, card radius |
| `10` | Medium gaps, compact panel padding |
| `11` | Current list row vertical padding |
| `12` | Row horizontal padding, tab bar spacing |
| `14` | Header icon/title gap, pill horizontal padding |
| `16` | Tab content padding, scroll fade thickness |

### Layout Recipes

Header:

```swift
HStack(alignment: .top, spacing: 14) { ... }
    .padding(.horizontal, 4)
    .padding(.bottom, 4)
```

Session/agent row:

```swift
HStack(alignment: .top, spacing: 11) { ... }
    .padding(.horizontal, 12)
    .padding(.vertical, 11)
```

Scrollable list:

```swift
ScrollView {
    LazyVStack(spacing: 8) { ... }
        .padding(.bottom, 10)
}
.notchScrollEdgeShadow(.vertical, thickness: 16, intensity: 0.30)
```

Sectioned scroll:

```swift
ScrollView {
    LazyVStack(spacing: 14) { ... }
}
.padding(.horizontal, 2)
.padding(.bottom, 14)
```

## Radius And Shape System

| Element | Radius / Shape | Existing Pattern |
|---|---:|---|
| Opened Notch shell | `24` bottom corners | `cornerRadiusOpened` |
| Closed notch | `8` | `cornerRadiusClosed` |
| App/source hero tile | `12`, continuous | `44x44` header icon |
| Source mark in row | `9`, continuous | `34x34`, framed in `40x40` |
| Standard row | `8`, continuous | session/agent row |
| Compact process row | `6` | system tab row |
| Tab icon background | `8` or `iconSize / 3` | selected tab |
| App/process icon | `4-5` | process/media app icon |
| Keyboard key / input chip | `6-8` | quick start |
| Badge / pill / progress | capsule | `Capsule(style: .continuous)` |

Rules:

- Prefer continuous rounded rectangles in SwiftUI.
- Use capsules for badges, segmented state, progress bars, pill buttons.
- Avoid very large card radii inside the Notch; the shell already owns the big shape.
- Avoid nested rounded card stacks. If a section needs grouping, use spacing and a divider before adding another card.

## Shadows And Glow

### Shell Shadow

Use only at the Notch shell / HUD level:

```swift
.shadow(
    color: .black.opacity(NotchConstants.openedShadowOpacity),
    radius: NotchConstants.openedShadowRadius
)
```

Current values:

| Constant | Value |
|---|---:|
| `openedShadowRadius` | `14` |
| `openedShadowOpacity` | `0.34` |

### Active Glow

Small active elements may glow:

- Header icon tile: `accent.opacity(0.30-0.32)`, radius `16`, y `8`.
- Status dot: state color opacity `0.55-0.76`, radius `5-8`.
- Active row: tint opacity `0.10-0.12`, radius `14`, y `6`.

Rules:

- Glow should make active state legible, not create decoration.
- Do not add glow to every card.
- Do not use glow on inactive rows.

## Component Specifications

### Notch Shell

Use for the main top-anchored container only.

Required:

- Anchored to screen top / hardware notch.
- Closed and opened states share the same physical origin.
- Opened content uses `tabContentPadding`.
- Shell background uses `NotchBackgroundView` material.
- Opened height remains compact; default is `328`.

Avoid:

- Additional page-level backgrounds inside shell.
- Centered app-page layouts.
- Scroll views with large top padding that make the shell feel empty.

### Tab Bar / Icon Navigation

Reference: `TabBarView`, `NotchView.notchTabBar`.

Spec:

- SF Symbol icon only.
- Icon font: `10-12`, rounded.
- Button visual frame: `28x28` for tab bar; smaller for notch-side tabs.
- Selected state: `textPrimary` icon + `surfaceEmphasis` rounded rect.
- Unselected state: `textTertiary` icon + clear background.
- No text labels in the compact tab bar.

Avoid:

- Filled colored icons per tab.
- Large tab pills with text.
- Moving layout when tab count changes.

### Header / Source Hero

Reference: `AIChatTab.aiConsoleHeader`, `AgentMonitorSection.monitorHeader`.

Spec:

- HStack top-aligned, spacing `14`.
- Left: `44x44` rounded source tile with gradient or external app icon.
- Middle: title `18 bold`, summary `13 medium`.
- Right: compact metrics, active count, server status, or action.
- Header bottom padding `4`.

Source tile:

- Radius `12`.
- Gradient: `[accent, accentHot]` for NemoNotch/Claude/OpenClaw-like warm sources.
- External identity can use its own gradient if small and justified, e.g. Hermes blue.
- Shadow: tint opacity about `0.30`, radius `16`, y `8`.

Avoid:

- Oversized titles.
- Long explanatory subtitles.
- Multiple colorful icons competing in the header.

### Status Dot

Reference: `AIChatTab.statusDot`, `AgentRowView.statusDot`.

Spec:

- Outer frame: `14x14`.
- Inner dot: `8x8`.
- Active halo: `14x14`, color opacity `0.18`.
- Stroke against shell: `panelBase.opacity(0.92)`, line width `1.5`.
- Shadow: color opacity `0.55`, radius `5`.

State colors:

- Idle: `textTertiary`.
- Working/tool calling: source tint or `accentText`.
- Waiting/approval: `accent`.
- Error: red.

### Badge / Pill

Use for source, status, tool, model, mode, compact count.

Spec:

- Shape: capsule continuous.
- Font: `10 bold rounded` for state/source/tool; `10 semibold rounded` for model.
- Padding: horizontal `7-8`, vertical `3`.
- Background: tint opacity `0.14-0.16` or `surfaceEmphasis`.
- Foreground: tint, `accentText`, or `textSecondary`.

Semantic examples:

| Badge | Foreground | Background |
|---|---|---|
| `Working` | `accentText` | `accentText.opacity(0.16)` |
| `Waiting for input` | `accent` | `accent.opacity(0.16)` |
| `Idle` | `textTertiary` | `textTertiary.opacity(0.16)` |
| Source badge | source tint | tint opacity `0.14` |
| Model badge | `textSecondary` | `surfaceEmphasis` |
| Tool badge | `ToolStyle.color(tool)` | tool color opacity `0.14` |

Avoid:

- Badge text longer than roughly 18 characters unless unavoidable.
- Multiple high-emphasis badges in a row.
- Border on every pill; most pills are fill-only.

### Session / Agent Row

Reference: `AIChatTab.sessionRow`, `AgentRowView`.

Default structure:

1. Source mark, fixed `40x40` visual slot.
2. Text column.
3. First line: title, state badge, optional event/tool/model badges, spacer, timestamp.
4. Second line: latest message, max 2 lines.
5. Third line: workspace/tokens/subagent summary, muted.
6. Optional progress/context bar.
7. Optional trailing approval buttons.

Default metrics:

| Property | Value |
|---|---:|
| HStack spacing | `11` |
| Horizontal padding | `12` |
| Vertical padding | `11` |
| Corner radius | `8` |
| Default fill | `surfaceSubtle` |
| Default stroke | `strokeStrong`, `0.7` |
| Active fill | source surface or `surfaceWarm` |
| Active stroke | source stroke or `accentStroke`, `1` |
| Active shadow | tint/accent opacity `0.10-0.12`, radius `14`, y `6` |

Rules:

- Keep the timestamp pinned at trailing edge.
- Source mark should not resize because of content.
- Put volatile details in muted text or badges, not in the title.
- If the row is clickable, use `.buttonStyle(.plain)` and `.contentShape(Rectangle())`.

### Source Mark

Small source icon used in rows.

Spec:

- Visual tile: `34x34`, radius `9`.
- Outer layout slot: `40x40`, aligned top leading.
- Fill: source tint opacity `0.16`.
- Stroke: source tint opacity `0.34`, line width `0.8`.
- Icon size: `17-18`.
- Status dot attached bottom trailing, offset `x: 3, y: 3`.

### Progress / Meter

Reference: `compactContextMeter`, `contextBar`, `SystemTab`.

Compact header meter:

- Label: `11 semibold rounded`, width `54`, trailing.
- Bar: width `68`, height `7`.
- Percentage: `11 bold rounded`, width `34`, trailing.
- Track: `rail`.
- Fill: `accentText`.

Inline context bar:

- Label row font: `8 medium monospaced`.
- Bar height: `5`.
- Track: `rail`.
- Fill: `accentText.opacity(0.88)`.
- Minimum visible fill width: `3-4`.
- High danger threshold may use red when value exceeds `0.8`.

Rules:

- Use capsule bars.
- Always keep percentage or value aligned.
- Do not animate progress in a way that distracts from row reading.

### Pill Button

Reference: `NotchPillButtonStyle`.

Spec:

```swift
Button("Allow") { ... }
    .buttonStyle(NotchPillButtonStyle(prominent: true))
```

Default:

- Font: `11 semibold`.
- Padding: horizontal `14`, vertical `6`.
- Shape: capsule.
- Fill: `surfaceEmphasis`.
- Stroke: `stroke`, line width `0.6`.
- Text: `textPrimary`.

Prominent:

- Fill: `accent`.
- Text: black opacity `0.86`.
- No stroke.

Pressed:

- Opacity `0.85`.
- Scale `0.98`.
- Animation `easeOut 0.12`.

Rules:

- Use prominent only for primary confirmation or install action.
- Secondary action stays neutral.
- Destructive action should be text/icon red only when truly destructive.

### Text Action

Use for low-friction actions in header/footer, e.g. `+ New chat`, `Refresh`.

Spec:

- Text/icon in `accentText` or `accent`.
- No filled background unless hover/pressed or toolbar pattern requires it.
- Keep label short: verb or verb+noun.
- Use SF Symbol when it improves scan speed.

### Approval / Attention Bar

Reference: `quickApprovalBar`.

Spec:

- Fill: `accentSoft` or `surfaceWarm`.
- Stroke can be omitted if nested in active row, or use `accentStroke`.
- Title: `10 medium`, `accent`.
- Detail: `9`, `textTertiary`, one line.
- Actions on right: neutral deny + prominent allow.
- Padding: horizontal `8`, vertical `6`.
- Radius: `8`.

Rules:

- Use this only for user decision points.
- Keep tool/input details truncated.
- Do not make approval UIs look like generic notifications.

### Empty / Install / Offline State

Reference: `AIChatTab.installPrompt`, `AIChatTab.idleState`, `AgentMonitorTab.offlineState`.

Spec:

- Centered `VStack`, spacing `8-10`.
- Icon: `20-28`, `textSecondary` or `textTertiary`.
- Main text: `11`, `textSecondary`.
- Optional command/help text: `10 monospaced`, `textTertiary`.
- Optional status line: `6x6` dot + `9` tertiary label.
- Optional primary action: prominent pill.

Rules:

- Keep copy short.
- Empty states should not become onboarding pages.
- Use one action at most unless the flow truly requires more.

### Detail View

Reference: `AIChatTab.chatDetail`.

Spec:

- Top toolbar compact, height determined by content.
- Back button: chevron, `11 medium`, `textSecondary`, plain.
- Header labels: source badge + title + trailing status dot.
- Metadata row: `9`, muted/accent.
- Divider: `stroke`.
- Scroll content uses `LazyVStack(spacing: 6)` with horizontal padding `8`, vertical padding `4`.
- Auto-scroll transitions use tab switch spring constants.

Rules:

- Detail view should feel like drilling into the same surface, not a new page.
- Keep the top toolbar visually smaller than list headers.
- Use dividers sparingly to separate toolbars from scroll content.

### Chat / Message Cards

Reference: `ChatMessageView`.

Rules:

- User/assistant/tool/system roles should differ through icon, mutedness, and compact card treatment.
- Tool messages may use tool-specific color at low opacity.
- Keep message cards radius small, usually `6`.
- Do not add full chat-app bubbles that fight the HUD style.
- Text should prioritize readability but stay compact.

### System Metrics Row

Reference: `SystemTab`.

Spec:

- Process row radius: `6`.
- Row padding: horizontal `8`, vertical `6`.
- App icon: `20x20`, radius `4`.
- Process title: `12`.
- Memory: `10 monospaced`, secondary.
- CPU: `11 semibold monospaced`, fixed width `42`, trailing.
- Fill: `surface`; stroke: `stroke`, `0.6`.

Footer metric panel:

- Use `.notchCard()`.
- Internal dividers use `stroke`, `0.6`.
- Numeric values use monospaced and accent where important.

### HUD Overlay

Reference: `HUDOverlayView`.

Existing constants:

| Constant | Value |
|---|---:|
| `hudHeight` | `32` |
| `hudCornerRadius` | `16` |
| `hudIconSize` | `18` |
| `hudHorizontalPadding` | `14` |
| `hudTopPadding` | `6` |
| `hudSegmentWidth` | `5` |
| `hudSegmentHeight` | `14` |
| `hudSegmentSpacing` | `2.5` |
| `hudSegmentCornerRadius` | `2` |

Rules:

- HUD overlay is capsule-shaped black.
- It should be even quieter and more compact than the opened panel.
- It may use accent for icon/value, but not full colored backgrounds.

### Settings And Auxiliary Windows

Settings can be more native macOS than the Notch surface, but should still share the same accent and restraint.

Rules:

- Use system settings structure when appropriate.
- Prefer `.bar` / native materials for settings chrome.
- Use `NotchTheme.accent` for selected/important settings controls only when it reads well.
- Keep settings windows practical; do not import Notch visual drama into every preferences pane.
- If a settings control directly configures Notch UI, show compact previews using the Notch style.

### Quick Start / Command Window

Quick start can use `ultraThinMaterial` because it is an auxiliary command palette, not the main Notch surface.

Rules:

- Keep radius around `14` for the window.
- Use `NotchTheme.stroke` border.
- Inputs and chips should use `surface`, `surfaceEmphasis`, capsule/rounded rects.
- Warning banners can use yellow at low opacity.

## Icons And Imagery

### Icon Sources

Preferred:

- SF Symbols for system actions, state, and navigation.
- App/source assets for real providers or installed apps.
- Existing helper icons such as `ClaudeCrabIcon`.

Allowed with care:

- External monitor emoji only when the monitor itself provides it as source identity. Do not invent emoji UI for core controls.

Avoid:

- Emoji as primary app/navigation icons.
- Decorative illustrations.
- SVG mascot/character art inside utility surfaces.
- Generic stock images.

### Icon Sizes

| Use | Size |
|---|---:|
| Header source tile icon | `22-26` |
| Row source mark icon | `17-18` |
| Tab icon | `10-12` |
| Empty state icon | `20-28` |
| HUD icon | `18` |
| Small role/tool icon | `8-12` |

## Motion System

Use existing constants from `NotchConstants`.

| Motion | Constant / Value | Use |
|---|---:|---|
| Open spring | `openSpringDuration = 0.314`, bounce `0.1` | Shell open |
| Close spring | `closeSpringDuration = 0.24` | Shell close |
| Tab switch | `tabSwitchSpringDuration = 0.28`, bounce `0.06` | Tab/content transitions |
| Badge spring | `badgeSpringDuration = 0.32`, bounce `0.08` | Badge movement |
| Fast fade | `fadeFastDuration = 0.16` | Quick opacity changes |
| Normal fade | `fadeNormalDuration = 0.24` | Standard fades |
| Pulse | `pulseDuration = 1.05` | Active state pulse |
| HUD appear | `hudAppearDuration = 0.3`, bounce `0.08` | HUD show |
| HUD dismiss | `hudDismissDuration = 0.2` | HUD hide |

Rules:

- Use springs for spatial state changes.
- Use ease-out for press/opacity feedback.
- Only repeat animation for active status indicators.
- Respect reduced motion when adding new global or continuous animation.

## Content And Copy

NemoNotch copy should sound like an instrument panel, not a product tour.

Good:

- `Working`
- `Waiting for input`
- `Approval`
- `Claude 2 · Gemini 1`
- `3 working · 1 idle`
- `Synced just now`
- `Refresh`
- `Install hooks`

Avoid:

- Long explanatory paragraphs in the panel.
- Marketing value props.
- Cute or overly casual labels for core states.
- Ambiguous action labels like `Go`, `Do it`, `Magic`.

Rules:

- Prefer nouns and direct verbs.
- Keep status labels stable across surfaces.
- Localize all user-facing strings in app code.
- Use middot separators (`·`) for compact metadata groups.
- Avoid punctuation-heavy labels in rows.

## Layout Patterns

### Common Header Layout

```swift
HStack(alignment: .top, spacing: 14) {
    sourceTile

    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(NotchTheme.textPrimary)
            .lineLimit(1)

        Text(summary)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(NotchTheme.textSecondary)
            .lineLimit(1)
    }

    Spacer(minLength: 12)

    trailingMetricsOrAction
}
.padding(.horizontal, 4)
.padding(.bottom, 4)
```

### Common Row Layout

```swift
Button {
    selectItem()
} label: {
    HStack(alignment: .top, spacing: 11) {
        sourceMark

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)

                statusPill
                optionalBadges

                Spacer(minLength: 0)

                Text(time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
            }

            Text(preview)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(2)

            metadata
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textMuted)
        }
    }
    .contentShape(Rectangle())
}
.buttonStyle(.plain)
.padding(.horizontal, 12)
.padding(.vertical, 11)
```

### Common Card Modifier

Use the existing helper when a simple embedded surface is enough:

```swift
content
    .notchCard(radius: 8, fill: NotchTheme.surface)
```

If you need custom active/warning state, write it explicitly or add a reusable helper if it appears more than twice.

## State Mapping

| State | Visual Treatment |
|---|---|
| Idle | `textTertiary`, `surfaceSubtle`, no glow |
| Working | `accentText` or source tint, active dot pulse, optional warm/source row surface |
| Waiting for input | `accent`, warm pill, active row if user attention needed |
| Approval required | `surfaceWarm`, `accentStroke`, primary allow action |
| Offline | centered empty/offline state, tertiary icon, orange waiting dot only if actively listening |
| Installed/ready | quiet green or tertiary status; do not celebrate loudly |
| Error | red text/dot/badge plus explicit label |
| Disabled | lower opacity, `textMuted`, no accent |
| Hover | slightly stronger fill/stroke, no layout shift |
| Pressed | opacity `0.85`, scale `0.98` for pill buttons |
| Selected | `surfaceEmphasis` or active row surface, not broad color fill |

## Accessibility And Robustness

- Text should never overlap or overflow its container.
- Use fixed-width slots for dynamic numeric values, trailing timestamps, progress percentages, and source marks.
- Use `lineLimit` and truncation for workspace paths, model names, tool names, and messages.
- Do not rely on color alone for status.
- Keep clickable controls at least visually clear; for non-Notch app surfaces, prefer macOS-standard hit targets.
- Avoid text smaller than `8` inside the Notch, and avoid smaller than `12` in normal windows unless it is metadata.
- Use accessibility labels for icon-only buttons when adding new controls.
- Respect localization expansion; avoid layouts that assume English strings are short.
- Respect reduced motion for any new continuous animation.

## AI Development Workflow

When an AI assistant is asked to build or modify NemoNotch UI:

1. Read this file.
2. Read `NemoNotch/Helpers/ViewModifiers.swift` and `NemoNotch/Helpers/Constants.swift`.
3. Read one nearby existing component that has the same shape:
   - Session/AI UI: `AIChatTab.swift`
   - Agent UI: `AgentMonitorTab.swift`
   - Metrics/system UI: `SystemTab.swift`
   - Shell/navigation/HUD: `NotchView.swift`, `HUDOverlayView.swift`
4. Reuse `NotchTheme`, `NotchConstants`, `notchCard`, `NotchPillButtonStyle`, `PulseModifier`, and `notchScrollEdgeShadow` where appropriate.
5. If a new visual pattern is needed more than once, promote it into a helper instead of copy/pasting one-off styling.
6. Before finalizing, compare against the checklist below.

## Review Checklist

### Style Fit

- Does it feel like a macOS Notch HUD instead of a web page?
- Is the UI mostly black/gray with orange used only for meaningful state/action?
- Does the main shell remain the dominant surface?
- Are there too many nested cards?
- Are non-orange colors limited to external identity or system semantics?

### Layout

- Does the component fit comfortably inside `560x328` or the relevant Notch size?
- Are row edges aligned with existing tabs?
- Are dynamic values in stable slots?
- Do labels truncate instead of pushing controls offscreen?
- Is there enough breathing room without wasting vertical space?

### Components

- Do rows follow the source mark -> title/badges -> spacer -> time/value structure?
- Are badges capsule-shaped with the correct font and padding?
- Are progress bars capsule-shaped with dark rail and orange/source fill?
- Are primary actions using `NotchPillButtonStyle(prominent: true)` or orange text action?
- Are empty states short and centered?

### Implementation

- Does it use `NotchTheme` instead of hard-coded colors?
- Does it use `NotchConstants` for existing geometry/animation concepts?
- Does it reuse `notchCard` or existing modifiers where possible?
- Are new helper abstractions justified by repeated use?
- Are user-facing strings localized?

### Motion And Interaction

- Are animations within the existing duration vocabulary?
- Does hover/press feedback avoid layout shift?
- Is continuous animation limited to active state?
- Is the UI still usable with reduced motion?

### Anti-Slop Gate

Reject or revise if the UI contains:

- Purple/blue AI gradients as the main theme.
- Decorative orbs, bokeh, particle backgrounds, or fake glass cards.
- Hero-page typography inside utility panels.
- Large marketing copy.
- Multiple unrelated accent colors competing at once.
- Rounded card inside rounded card inside rounded card.
- Emoji used as core navigation/action icon.

## Prompt Template For Future AI Work

Use this when asking an AI assistant to build UI in this repo:

```text
You are working in NemoNotch. Before changing UI, read:
- docs/design/warm-noir-utility.md
- NemoNotch/Helpers/ViewModifiers.swift
- NemoNotch/Helpers/Constants.swift
- the nearest existing component for the target surface

Implement the requested UI in the Warm Noir Utility style:
- black floating macOS HUD surfaces
- restrained warm orange state/action accents
- SF Pro-like system typography
- compact utility layout
- subtle 0.6-1px borders
- source/status badges as compact capsules
- active state dot/glow only where meaningful
- no marketing-page composition, no decorative gradients, no glass-card dashboard look

Reuse NotchTheme, NotchConstants, notchCard, NotchPillButtonStyle, and existing row/header/badge/progress patterns. Keep dynamic text stable with lineLimit/truncation/fixed slots. Localize user-facing strings.
```

