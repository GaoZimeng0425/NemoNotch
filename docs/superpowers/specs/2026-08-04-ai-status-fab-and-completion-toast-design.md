# 设计:可拖拽悬浮状态按钮 + 完成提示增强

- **日期**:2026-08-04
- **分支**:`feature/mainthread-probe`(继续在此分支或切新分支)
- **状态**:已通过设计评审,待实现计划

## 目标

两个相互独立的增强,都围绕"让用户更清楚 AI 在干什么":

1. **可拖拽悬浮按钮**(`AIStatusFAB`):当有 AI CLI 会话正在运行时,屏幕上出现一个可拖拽的小胶囊,显示运行中的会话数量;点击展开成宽面板,看到每个会话的 title、当前 tool、模型、context 进度等详情。
2. **完成提示增强**:现有的完成提示(全屏边缘发光 + 居中黑胶囊)目前只显示路径末尾(`projectFolder`),把它增强为显示任务标题、最后 tool、来源徽标、模型、token/用时。

两者相互独立,不联动。

## 背景

### 现有数据流
- `AISessionStore`(`Services/AISessionStore.swift`)是单一数据源,`sortedSessions` 暴露所有 AI 会话。
- `AISessionState`(`Models/AIProvider.swift:20`)已携带丰富的可推导字段:`displayTitle`(优先 `firstUserMessage` 回退 `projectFolder`)、`currentTool`、`displayModel`、`tokenDisplay`、`contextPercent`、`projectFolder`、`status`(`idle`/`working`/`waiting`)、`sessionStart`、`lastEventTime`。**两个功能所需的全部数据都已存在**,无需新增数据采集。

### 现有悬浮窗范式
- `QuickStartWindow`(`Notch/QuickStartWindow.swift`)+ `QuickStartWindowController`(`Notch/QuickStartWindowController.swift`)是项目里唯一被验证的"可任意拖拽 + 不抢焦点 + 常驻悬浮"范式:`NSPanel` + `.borderless, .nonactivatingPanel` + `isFloatingPanel = true` + `level = .statusBar + 9` + `isMovableByWindowBackground = true` + `collectionBehavior` + `animationBehavior = .none`(后者避开 QuickStart 注释里记录的 `_NSWindowTransformAnimation` 崩溃)。

### 完成提示的根因
- `CompletionFlashService.currentCandidates()`(`Services/CompletionFlashService.swift:50`)把丰富的 `AISessionState` 塌缩成单个 `name` 字符串(往往是 `projectFolder`,即路径末尾),再传给 `CompletionItem`(`Services/CompletionDetector.swift:12`,仅 `{ name, source }`)。
- `CompletionToastView`(`Notch/CompletionToastView.swift`)只拿到这一个名字 → 用户看到的"只有路径"。
- **底层数据齐全,瓶颈在中间模型。**

## 非目标(YAGNI)

- 不跟踪 OpenClaw / Hermes 多 agent(悬浮按钮仅 AI CLI 会话)。
- 不跟踪 Pomodoro(语义不符)。
- 不新增数据采集或新 hook。
- 两个功能不联动(悬浮按钮不作为完成提示通道)。
- 不改全屏发光流水线本身,只改它喂给视图的数据与视图布局。

## 决策回顾

| 项 | 决策 |
|---|---|
| 悬浮按钮显示时机 | 仅运行时(`status == .working` 会话 > 0 时淡入,全空闲延迟 3s 淡出) |
| 跟踪范围 | 仅 `AISessionStore` |
| 展开布局 | 宽面板 B:左列表(168px)+ 右详情;展开固定宽 420px,收起胶囊宽度自适应 |
| 交互 | 整胶囊可拖(`isMovableByWindowBackground`);点击展开/收起;展开态改由 header 拖拽(`performDrag`) |
| 位置记忆 | 存 `frame.origin` 到 UserDefaults,恢复时 clamp 到 `screen.visibleFrame` |
| 收起显示 | 脉冲圆点 + "N running" |
| 完成 alert 形态 | 增强现有提示胶囊(全屏发光 + 居中胶囊不变,内容变丰富) |
| 完成 alert 内容 | 任务标题 + 最后 tool + 来源徽标 + 模型 + token/用时 |

---

## 第一部分:悬浮按钮

### 1.1 窗口承载 — `AIStatusWindow: NSPanel`

完全复刻 `QuickStartWindow` 的范式。新文件 `Notch/AIStatusWindow.swift`。

关键配置:
- `styleMask: [.borderless, .nonactivatingPanel]`,`contentRect: .zero`(尺寸由 hostingController `fittingSize` 动态决定)
- `isFloatingPanel = true`;`level = .statusBar + 9`(与 QuickStart 同层,盖在 notch 之上)
- `isOpaque = false`;`backgroundColor = .clear`;`hasShadow = false`(阴影在 SwiftUI 画,避免黑方框)
- `collectionBehavior = [.canJoinAllSpaces, .stationary]`(`.stationary` 让它不随 Space 切换漂移)
- `animationBehavior = .none`(避开 `_NSWindowTransformAnimation` 崩溃,见 QuickStart 注释)
- `canBecomeKey = false`(不抢焦点,不打断正在用的终端)

### 1.2 控制器 — `AIStatusWindowController`

新文件 `Notch/AIStatusWindowController.swift`。`@MainActor`,持有 `AISessionStore` 与 `AppSettings`。

#### 三态状态机
```
hidden ──(workingCount > 0)──→ collapsed ──(点击胶囊)──→ expanded
  ↑                                ↑──(点击 ✕ / 点击胶囊)──┘
  └──(workingCount == 0 延迟 3s)──┘
```
- `hidden`:窗口 `orderOut`,不占屏
- `collapsed`:`isMovableByWindowBackground = true`(整胶囊可拖);点击胶囊 → expanded
- `expanded`:`isMovableByWindowBackground = false`(避免点击列表项触发拖拽);拖拽改由 header 的拖拽手势 `window.performDrag(with:)` 承担;点击胶囊/header 的展开切换按钮 → collapsed;点击 ✕ → collapsed

#### 观察 + 显隐
用项目通行的 `withObservationTracking` 模式(参考 `CompletionFlashService.observe()`):
- 观察 `store.sortedSessions` 的 `status`
- `workingCount > 0` → 出现:`orderFront` + alpha 淡入(`withAnimation(.easeOut)`)
- `workingCount == 0` → 启动 3s 延迟 Task;期间若再次出现 working 则取消 Task;超时则 alpha 淡出 + `orderOut`(注意 expanded 态下不自动收,保持用户展开意图)
- `appSettings.aiStatusFabEnabled == false` 时强制 hidden

#### 尺寸/位置
- 出现/展开/收起时 `setContentSize(hostingController.view.fittingSize)`(参考 QuickStartWindowController.present)
- 位置记忆见 1.5

#### 环境注入
按 QuickStartWindowController `makeHost` 的范式,把 `aiMonitorService.store`、`appSettings` 注入 SwiftUI 环境,供 `AIStatusFABView` 直接 `@Environment` 读取。

### 1.3 SwiftUI 视图 — `AIStatusFABView`

新文件 `Notch/AIStatusFABView.swift`。一个 View,内部按 `isExpanded` 切胶囊/面板两种 body。

#### 收起态 — 胶囊
- 布局:`HStack`:脉冲圆点 + `Text("\(workingCount)")` + `Text("running")`
- 脉冲圆点:accent 径向渐变 + 呼吸光环,复用现有 `PulseModifier`(`Helpers/ViewModifiers.swift:72`)思路
- `.fixedSize(horizontal: true, vertical: false)` → 宽度随文字/数字自适应(短的 "1 running" 就窄)
- 整体 `.background(.black).clipShape(Capsule())` + `stroke(NotchTheme.stroke, lineWidth: 0.6)`,黑胶囊风格与 `CompletionToastView` 一致
- `.onTapGesture { controller.toggleExpanded() }`

#### 展开态 — 面板 B(420px 固定宽)
结构:
```
┌ header(可拖区): ●  N running · AI sessions           ✕
├─────────────┬──────────────────────────────────────┤
│ 左列(168px)│ 右列:详情                              │
│ ●  fix-auth │ fix authentication bug in login flow  │
│ ●  refactor │ ⚡ Edit                               │
│ ●  optimize │ ███░░░░░ 30%                          │
│             │ Model    Sonnet 4.5                   │
│             │ Context  30% · 48K / 200K             │
│             │ Tokens   12.4k                        │
│             │ Folder   NemoNotch                    │
└─────────────┴──────────────────────────────────────┘
```
- **header**:`HStack` 脉冲圆点 + "N running · AI sessions" + 右侧 ✕ 按钮;`.onDrag` / drag gesture 调 `window.performDrag`(展开态拖拽入口);✕ `onTapGesture { controller.collapse() }`
- **左列**(168px):`ScrollView` + `LazyVStack`,每个会话一行 = 状态点(`.working` 才点亮)+ 截断 title(`lineLimit(1).truncationMode(.tail)`);`selectedSessionId` 高亮(默认首个 working 会话);`onTapGesture` 切选
- **右列**:从 `store.get(selectedSessionId)` 取详情,字段映射:
  - 标题 = `session.displayTitle`
  - tool = `session.currentTool`(胶囊样式,复用 `AgentMonitorTab` 的 tool badge 配色)
  - 进度条 = `contextPercent`(`LinearProgressView`)
  - Model / Context / Tokens / Folder = `displayModel` / `contextPercent`+`contextTokenDisplay`+`contextLimitDisplay` / `tokenDisplay` / `projectFolder`,用键值对(key 灰 + value 等宽)布局
- 风格复用 `AgentMonitorTab`(`Tabs/AgentMonitorTab.swift`)的 `AgentRowView` 配色与 `notchCard`;圆角 14、`NotchTheme.panelRaised→panelBase` 渐变、`stroke` 0.6、外加 `openedShadowRadius` 阴影 + 透明 padding(参考 QuickStartFormView 的 shadow 处理)
- `selectedSessionId` 在会话被移除时回退到首个 working 会话(防 nil)

### 1.4 来源徽标

胶囊态不显示来源(保持窄);面板左列每行不显示徽标(窄);**右列详情头部**显示来源徽标(与 `CompletionToastView.sourceIcon` / `AIChatTab.sourceIcon` 同款:Claude 螃蟹 / Gemini sparkles / opencode / zcode)。复用现有 icon 组件。

### 1.5 位置记忆

- UserDefaults 键 `aiStatusFabPosition`,存 `frame.origin`(`Codable` CGPoint)
- 恢复时 **clamp 到 `screen.visibleFrame`**:确定策略——把 origin 平移进可见矩形内(若 X 越界贴到对应边,Y 越界贴到顶/底),不回退到默认位,保留用户的横向偏好
- 默认首次位置(无记忆时):`NSScreen.main` 右上角 `visibleFrame.maxX - panelWidth - margin, visibleFrame.maxY - margin`(margin ≈ 24)
- 找不到原屏(多屏变化)→ 落到 `NSScreen.main` 默认右上角
- 拖拽结束(`windowDidMove` 通知,或拖手势结束时)写回 UserDefaults

### 1.6 多屏

单实例(不像 NotchWindow 每屏一个)。挂在 `NSScreen.main`(含 menu bar 的屏)。拖到别的屏上时跟随该屏 `visibleFrame` clamp。简单优先,不做 per-screen。

---

## 第二部分:完成提示增强

### 2.1 拓宽模型 — `Services/CompletionDetector.swift`

```swift
struct CompletionItem {
    let name: String                    // 保留(多 item 与 Pomodoro 仍只用它)
    let source: CompletionSource
    // 新增(全可选;nil 时视图降级为单行)
    var subtitle: String?               // = session.displayTitle(优先 firstUserMessage)
    var tool: String?                   // = session.currentTool
    var model: String?                  // = session.displayModel
    var tokenDisplay: String?           // = session.tokenDisplay
    var duration: TimeInterval?         // = now - sessionStart(秒)
}

struct CompletionCandidate {
    let key: String
    let name: String
    let isActive: Bool
    let source: CompletionSource
    // 新增快照字段(同上五项)——在检测 active→idle 边缘时,会话上仍有这些值
    var subtitle: String?
    var tool: String?
    var model: String?
    var tokenDisplay: String?
    var duration: TimeInterval?
}
```

`CompletionDetector.step()` 在 active→idle 转换时,把 candidate 的快照字段原样搬进 `CompletionItem`。首调仍只建基线(已活跃的不误触发)——这个语义不变。

`CompletionFlashNames.merge(existing:new:)` 的去重逻辑扩展:按 `name` 去重(保持现状);若同 name 的两个 item 字段不同,后者覆盖前者字段(新 item 信息更新)。

### 2.2 填充 — `Services/CompletionFlashService.currentCandidates()`

`ai:` 分支从 `AISessionState` 填充新字段:
```swift
result.append(CompletionCandidate(
    key: "ai:\(session.id)",
    name: session.projectFolder ?? session.displayTitle,
    isActive: session.status == .working,
    source: .ai(session.source),
    subtitle: session.displayTitle,
    tool: session.currentTool,
    model: session.displayModel,
    tokenDisplay: session.tokenDisplay,
    duration: Date().timeIntervalSince(session.sessionStart)
))
```
`agent:` 分支:字段保持 nil(降级单行,行为不变)。Pomodoro 路径 `showCompletionToast(names:)`:字段 nil,降级单行,行为不变。

### 2.3 视图 — `Notch/CompletionToastView.swift`

**单 item(`items.count == 1`)**:双行布局
- 主行:来源徽标 + `subtitle`(回退 `name`),`semibold`
- 次行(灰字小号):`tool · model · tokens · 用时`,用 `·` 分隔,逐字段跳过 nil;用时格式化:< 60s 显秒(`42s`)、< 1h 显 `2m 14s`、≥ 1h 显 `1h 5m`
- 对所有新字段 nil 安全降级(若全是 nil → 退回现有单行)

**多 item(`items.count > 1`)**:保持现状(来源徽标 + names `·` 连接 + count chip)。多 item 时详情太挤,只显 name。

### 2.4 沿用现有流水线

不引入新窗口、不改 flash 双脉冲动画、不改节流/合并/cooldown 逻辑。增强是**原位改动**:模型拓宽 → 填充 → 视图读新字段。

---

## 第三部分:设置与常量

### 3.1 AppSettings(`Models/AppSettings.swift`)
- 新增 `aiStatusFabEnabled: Bool = true`,UserDefaults 键 `aiStatusFabEnabledKey = "aiStatusFabEnabled"`,init 默认 `true`(参考现有 `completionFlashEnabled` 的 `:117-118, :185-186` 写法)
- 新增 `aiStatusFabPositionKey = "aiStatusFabPosition"`(位置持久化用,虽也可放 controller;统一在 AppSettings 便于测试)

### 3.2 SettingsView(`Settings/SettingsView.swift`)
- 在现有完成提示 Section 旁或新 Section 加 `Toggle("settings.ai_fab.enabled", ...)`,绑定 `appSettings.aiStatusFabEnabled`
- 本地化 key 进 `Resources/Localizable.xcstrings`(中英文)

### 3.3 常量(`Helpers/Constants.swift`)
- `aiStatusFabPanelWidth = 420`、`aiStatusFabListColumnWidth = 168`
- `aiStatusFabHideDelay: TimeInterval = 3`
- `aiStatusFabEdgeMargin: CGFloat = 24`
- 胶囊/面板的字号、内边距等沿用现有 `completionToast*` / `openedShadow*` 常量,不重复定义

---

## 第四部分:接线(`NemoNotchApp.swift`)

在 `AppDelegate.applicationDidFinishLaunching`:
- 构造 `aiStatusFabController = AIStatusWindowController(store: aiMonitorService.store, appSettings: appSettings)`(位置参考现有 `quickStartController` 构造 `:191-196`)
- 它在 init 里自行 `observe`,无需手动 `start`
- 注入到 SwiftUI 环境(若视图用 `@Environment` 取 controller):在 coordinator content closure `:200-222` 加 `.environment(\.aiStatusController, aiStatusFabController)`(参考 QuickStart 的 `EnvironmentValues.quickStartController`)

不注册热键(悬浮按钮是被动出现,不需要唤起)。

---

## 文件清单

| 动作 | 文件 | 说明 |
|---|---|---|
| 新增 | `Notch/AIStatusWindow.swift` | `NSPanel` 子类,复刻 QuickStartWindow |
| 新增 | `Notch/AIStatusWindowController.swift` | 生命周期/三态/观察显隐/位置持久化 |
| 新增 | `Notch/AIStatusFABView.swift` | SwiftUI 胶囊 + 面板 B |
| 改 | `Services/CompletionDetector.swift` | 拓宽 `CompletionItem`/`CompletionCandidate`;`step`/`merge` 透传新字段 |
| 改 | `Services/CompletionFlashService.swift` | `currentCandidates` 填充新字段 |
| 改 | `Notch/CompletionToastView.swift` | 单 item 双行布局,多字段降级 |
| 改 | `Models/AppSettings.swift` | `aiStatusFabEnabled` + 位置键 |
| 改 | `Settings/SettingsView.swift` | +开关 |
| 改 | `NemoNotchApp.swift` | 构造 controller + 环境注入 |
| 改 | `Helpers/Constants.swift` | +常量 |
| 改 | `Resources/Localizable.xcstrings` | +本地化 key |

`MainThreadProbe.swift` 不在本次范围(属另一分支工作)。

---

## 测试

### 自动化(单测)
- `CompletionDetector`:拓宽后 `step()` 仍正确检测 active→idle;首调只建基线(不误触发启动时已活跃的会话);新字段正确透传到 `CompletionItem`;会话消失(从 candidates 移除)不报完成。
- `CompletionFlashNames.merge`:同 name 去重 + 字段覆盖语义正确。
- (纯值类型,无需 actor/UI,易写)

### 手动(悬浮按钮)
- 拖拽:整胶囊可拖,松手位置记忆,重启 App 后恢复且 clamp 进 `visibleFrame`
- 展开/收起:点击胶囊展开;✕ / 再点胶囊收起;展开态拖 header 不误触列表项点击
- 显隐:启动 Claude Code 会话 → 胶囊淡入;会话 idle → 3s 后淡出;期间再次 working → 取消淡出
- 多屏:拖到副屏不丢、不漂移(`.stationary`)
- `nonactivating`:出现时不抢当前 App(终端)焦点
- 开关:`aiStatusFabEnabled = false` → 强制隐藏
- 详情正确:右列字段与 `AISessionState` 计算属性一致

### 回归
- 完成 alert:Pomodoro 结束仍显示(降级单行);多 AI 同时完成仍合并 + count chip;全屏发光双脉冲不变
- QuickStartWindow:不受影响(独立窗口)
- 多 AI 会话来源(Claude/Gemini/opencode/zcode)徽标与详情字段正确

---

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 展开态拖拽与列表项点击冲突 | 展开态 `isMovableByWindowBackground = false`,仅 header `performDrag`;列表项用 `onTapGesture` |
| 位置记忆后多屏变化导致按钮丢失 | 恢复时 clamp 到 `visibleFrame`,找不到原屏回退 main |
| `selectedSessionId` 指向已移除会话 | getter 回退首个 working 会话 |
| 拓宽模型破坏现有 Pomodoro/多 item 路径 | 新字段全可选,nil 时视图降级单行;`merge` 保持 name 去重 |
| `_NSWindowTransformAnimation` 崩溃(QuickStart 记录) | `animationBehavior = .none` + 复用同一 panel swap content(不重复 order-in/out) |
| 短暂 idle 抖动导致按钮闪烁 | 消失延迟 3s + 期间可取消 |
