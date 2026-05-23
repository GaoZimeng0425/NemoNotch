# Pomodoro Timer + TODO — Design

**Date:** 2026-05-23
**Status:** Approved (pending user review)

## Problem

NemoNotch 目前是一个被动信息呈现器（媒体、日历、AI、agents），缺少"主动专注辅助"的能力。用户希望：

1. 一个**经典番茄钟** —— 工作/休息自动交替、可暂停可放弃、能记录历史。
2. 一份**持久 TODO 列表** —— 独立于番茄钟存在，每个 task 可累计若干个完成的番茄钟。
3. 一个**全局快捷键呼出的居中浮窗** —— 极速新建一个任务并启动番茄钟，不打断当前 app。
4. **Notch 折叠态**能直观看到番茄钟剩余时间（饼状图 + 番茄 emoji），跟现有 badge 系统共存。
5. **完整统计** —— 今日/本周/全部维度的完成数、partial 和 abandoned 分开记录，可视化图表。

## Goals

- TODO 和 Pomodoro 在数据/服务两层都解耦：一个任务可以有 0、1 或多个番茄钟；一个番茄钟也可以不挂任何任务。
- 状态机覆盖：idle / running / paused / justFinished(completed|partial|abandoned)，支持手动暂停、提前完成、放弃、自然结束。
- 经典周期支持：work → shortBreak(或 longBreak) → work，每 N 个 work 后 longBreak（N 可设置）。模式（单次 / 持续）在每次启动时决定。
- 折叠态 notch：左侧 🍅 emoji，右侧饼状图（剩余时间），优先级仅低于通知与 AI 审批。
- 快捷启动浮窗：居中、可拖、Esc 关、Enter 确认；含标题/优先级/时长/模式/备注。
- Settings 页可调时长、长休息间隔、声音/通知开关、两个 hotkey 自定义。
- 通知权限按现有 `PermissionCard` 模式做按钮触发，不在启动时自动请求。
- 永久保留历史记录，统计含 7/30/全部三档维度，柱状图可视化。
- 任务支持搜索 / 标签 / 截止日 / 拖拽重排。

## Non-Goals

- 跨设备同步（无 iCloud / 无云端）
- 跨进程持久化 running 状态（app 重启即丢，已 running 的写一条 `abandoned` 记录）
- 多任务并行（一次只能跑一个番茄钟）
- 自定义声音文件（仅系统声音 `Glass` / `Hero`）
- 全 Apple 平台支持（仅 macOS）
- Tag 管理 UI（重命名/合并/全局删除 tag）—— 用户改单条任务的 tag 即可
- 子任务 / 任务依赖
- 任务循环规则（每周一自动新建）
- 系统休眠期间继续计时 —— 休眠 → `abandon()`，不 resume

## Phasing

实施分两个 PR，spec 一次写完。

- **PR 1 — MVP**：状态机、TODO 核心、QuickStart、notch badge、设置/权限/提醒、基础统计（纯数字）。
- **PR 2 — 增强**：搜索 / 标签 / 截止日 / 拖拽重排 / 柱状图统计。

数据模型在 PR 1 就把 `tags` / `dueDate` 字段建好，避免后续迁移；UI 后置。

---

## Architecture

### 三个独立 `@Observable` 服务

```
PomodoroTimerService     ← 状态机：当前 phase / 剩余秒 / pause 状态 / 接受 task 引用（可空）
TaskStore                ← 持久化 TODO 列表（含 tag/dueDate）
PomodoroHistoryStore     ← 持久化历史记录：每个 work/break 各一条
```

**依赖方向（单向回调）**：

```
QuickStartWindow ──► PomodoroTimerService
                       │   (optional taskID)
                       ▼
                    TaskStore  ◄── PomodoroTab
                       │
PomodoroTab ◄──────────┘
                       │ on .completed / .partial / .abandoned
                       ▼
                PomodoroHistoryStore
```

- `TaskStore` 不知道 `PomodoroTimerService`。Tasks 是一等公民。
- `PomodoroTimerService` 持有可选 `currentTaskID: UUID?`；没挂任务也能跑（"裸 focus"）。
- 一个 pomodoro 写库时，timer service 通过闭包回调让 `TaskStore` 给目标任务 `completedPomodoros += 1`（仅 work 阶段且 outcome ≠ abandoned），并让 `PomodoroHistoryStore` append 一条 record。
- AppDelegate 三者都 own，统一注入 environment。

### 文件清单

新建：

```
Models/
  TodoTask.swift
  PomodoroPhase.swift
  PomodoroRecord.swift
Services/
  PomodoroTimerService.swift
  TaskStore.swift
  PomodoroHistoryStore.swift
  NotificationPermissionMonitor.swift
Tabs/
  PomodoroTab.swift
  PomodoroTab+ActiveBlock.swift
  PomodoroTab+TodoList.swift
  PomodoroTab+StatsPopover.swift
  PomodoroTab+StatsChart.swift              # PR 2
  PomodoroTab+EditSheet.swift
Notch/
  QuickStartWindow.swift
  QuickStartWindowController.swift
  Badge/PomodoroBadgeView.swift
Settings/
  PomodoroSettingsView.swift
NemoNotchTests/
  PomodoroTimerServiceTests.swift
  TaskStoreTests.swift
  PomodoroHistoryStoreTests.swift
  PomodoroStatsTests.swift
```

修改：

```
Models/Tab.swift                       # 加 .pomodoro case
Models/AppSettings.swift               # 加 6 个 pomodoro.* 字段
Notch/Badge/BadgeItem.swift            # 加 .pomodoro case，priority 重编号
Notch/Badge/BadgeViewModel.swift       # 注入 PomodoroTimerService，activeBadgeItems 加入 pomodoro
Notch/Badge/BadgeIconView.swift        # 加 pomodoro 渲染分支（compactLeft/right/row）
Notch/NotchView.swift                  # @Environment 注入 PomodoroTimerService
NemoNotchApp.swift / AppDelegate       # 创建三个 service，注入 environment，注册 hotkey 回调
Services/Hotkeys.swift                 # 加 openPomodoro / openQuickStart（无默认值）
Settings/SettingsView.swift            # sidebar 加 Pomodoro 项
Settings/HotkeysSettingsView.swift     # 不动（两个新 hotkey 集中在 Pomodoro 设置页里）
Localizable.xcstrings                  # 见 Localization 节
README.md / README_CN.md / CLAUDE.md   # 文档更新
docs/macos-cookbook.md                 # 加 "NSPanel 居中可拖拽" / "SwiftUI Path arc 饼图" 两条
```

---

## Data Models

### `Models/TodoTask.swift`

```swift
struct TodoTask: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var priority: Priority           // 视觉标签 + 配色，不参与排序
    var notes: String                // 默认 ""
    var tags: [String]               // 默认 []，PR 2 起暴露 UI
    var dueDate: Date?               // 默认 nil，PR 2 起暴露 UI
    var completedPomodoros: Int      // 仅 outcome ∈ {completed, partial} 的 work 阶段累加
    var isDone: Bool                 // 用户手动勾选 "任务整体完成"
    var createdAt: Date
    var sortIndex: Double            // 唯一排序 key（升序）

    enum Priority: String, Codable, CaseIterable { case low, medium, high }
}
```

### `Models/PomodoroPhase.swift`

```swift
enum PomodoroPhase: String, Codable {
    case idle
    case work
    case shortBreak
    case longBreak
}
```

### `Models/PomodoroRecord.swift`

```swift
struct PomodoroRecord: Identifiable, Codable {
    let id: UUID
    let taskID: UUID?                // 可空：未挂任务的纯 focus
    let phase: PomodoroPhase         // 永远不为 .idle
    let plannedDuration: TimeInterval
    let actualDuration: TimeInterval // partial 时 < planned
    let startedAt: Date
    let endedAt: Date
    let outcome: Outcome

    enum Outcome: String, Codable { case completed, partial, abandoned }
}
```

### Persistence

| 数据 | 位置 | 备注 |
|---|---|---|
| TODO 列表 | `~/.NemoNotch/tasks.json` | atomic write，整体保存 |
| 历史记录 | `~/.NemoNotch/pomodoro-history.json` | 永久保留，append-on-write，启动时全量 load |
| 配置项 | `AppSettings` (UserDefaults) | 沿用现有模式，键前缀 `pomodoro.` |

`TaskStore.init` 加载 `tasks.json`；缺字段（旧版本无 `tags` / `dueDate`）走 `Codable` 默认值（`[]` / `nil`），无显式 migration。**`TaskStoreTests` 必须覆盖 "loads v1 JSON without tags/dueDate" 测例**。

---

## State Machine

### 状态

```swift
enum PomodoroState {
    case idle
    case running(RunningContext)
    case paused(RunningContext)
    case justFinished(FinishedContext)
}

struct RunningContext {
    let phase: PomodoroPhase
    let taskID: UUID?
    let plannedDuration: TimeInterval
    let startedAt: Date              // 进入当前 running 段的时刻
    var accumulatedElapsed: TimeInterval  // 跨多次 pause 累加
    let autoFlow: Bool               // 单次=false / 持续=true，启动时定，跑完不能改
}

struct FinishedContext {
    let phase: PomodoroPhase
    let taskID: UUID?
    let outcome: PomodoroRecord.Outcome
}
```

`PomodoroTimerService` 顶层暴露：

- `var state: PomodoroState`
- `var remainingSeconds: Int`（computed from running 段）
- `var workCounterSinceLongBreak: Int`
- `var pulseToken: UUID`（进入 `.justFinished` 时刷新一次，驱动 notch 闪烁）

### 转移表

| 触发 | from → to | 副作用 |
|---|---|---|
| `start(task?, dur, autoFlow)` | idle → running(.work) | 重置 `accumulatedElapsed=0`；若已 running/paused，先内部 `completeEarly()`（覆盖语义，partial 入库） |
| `pause()` | running → paused | tick timer 暂停；`accumulatedElapsed += now - startedAt` |
| `resume()` | paused → running | `startedAt = now`（不动 accumulated） |
| `completeEarly()` | running / paused → justFinished(.partial) | 写 history（actual < planned）；task.completedPomodoros++（仅 work 阶段） |
| `abandon()` | running / paused → justFinished(.abandoned) | 写 history；**task 不增计数**；**不触发结束提醒** |
| naturalEnd（tick 检测 elapsed ≥ planned） | running → justFinished(.completed) | 写 history（actual = planned）；task.completedPomodoros++（仅 work 阶段） |
| 0.6s 过渡结束后 `advance()` | justFinished → running(nextPhase) 或 idle | 根据 `autoFlow` 与 outcome 决定 |
| 系统休眠 (`NSWorkspace.willSleepNotification`) | running / paused → justFinished(.abandoned) | 同 abandon |
| App 退出 (`applicationWillTerminate`) | running / paused → justFinished(.abandoned) | 同 abandon，写库 |

### `advance()` 规则

```
当前 outcome=.abandoned 或 .partial → idle（无论 autoFlow）
当前 outcome=.completed 且 autoFlow=false → idle
当前 outcome=.completed 且 autoFlow=true：
  if 当前 phase==.work:
    workCounterSinceLongBreak += 1
    if counter % longBreakInterval == 0:
      → running(.longBreak)         // counter 此时不重置
    else:
      → running(.shortBreak)
  if 当前 phase==.shortBreak:
    → running(.work)
  if 当前 phase==.longBreak:
    workCounterSinceLongBreak = 0
    → running(.work)
```

### `justFinished` 过渡态

显式建模成 0.6s 状态而非瞬间副作用，目的是让 UI（notch badge / Pomodoro Tab）能稳定 observe 状态做闪烁动画，不依赖 Timer hacks。0.6s 后由 service 自行 `advance()`。

期间执行：

1. `NotificationService` 推 `UNNotificationRequest`（受权限和开关 gate）
2. `NSSound(named: phase == .work ? "Glass" : "Hero").play()`（受开关 gate）
3. `pulseToken = UUID()` → BadgeViewModel `.onChange` → `PomodoroBadgeView` 做一次性 opacity 脉冲

`abandon()` **不执行** 1-3（用户主动放弃就别再吓人）。

---

## Notch Badge Integration

### `BadgeItem` 新 case

```swift
case pomodoro(phase: PomodoroPhase)
```

**不携带剩余时间**。每秒变化的 fraction 进 case 会触发 BadgeViewModel 每秒走 `updateDisplayedBadges` 的 spring animation，视觉抖动。正确做法：case 只携带 phase，view 内部通过 `@Environment(PomodoroTimerService.self)` 直接读 `remainingSeconds`。

### 优先级重编号

| 旧 priority | 新 priority | item |
|---|---|---|
| 0 | 0 | ai approval |
| 1 | 1 | notification |
| – | **2** | **pomodoro (新)** |
| 2 | 3 | agents |
| 3 | 4 | ai working |
| 4 | 5 | media |
| 5 | 6 | calendar |

`BadgeItem.tab`：`.pomodoro → Tab.pomodoro`。

`BadgeViewModel.activeBadgeItems` 在 notification block 之后、agents 之前插入：

```swift
if pomodoroService.state.isActive {        // running 或 paused 或 justFinished
    items.append(.pomodoro(phase: pomodoroService.currentPhase))
}
```

### 视觉

| Slot | 内容 | 尺寸 |
|---|---|---|
| `compactLeft` | 🍅 emoji（始终是番茄，phase 信息靠右侧颜色） | 14pt rounded |
| `compactRight` | 饼状图：扇形填充 = 剩余时间，背景细圈 | 14pt 直径 |
| `row`（非主 badge） | 仅饼状图 | 12pt 直径 |

**饼图绘制**：

```swift
struct PomodoroPieView: View {
    let remainingFraction: Double  // 0...1
    let phaseColor: Color
    var body: some View {
        ZStack {
            Circle().stroke(phaseColor.opacity(0.25), lineWidth: 1)
            Path { p in
                let c = CGPoint(x: 7, y: 7)
                p.move(to: c)
                p.addArc(
                    center: c, radius: 7,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * remainingFraction),
                    clockwise: false
                )
                p.closeSubpath()
            }
            .fill(phaseColor)
        }
        .frame(width: 14, height: 14)
    }
}
```

从 12 点钟方向出发顺时针扫，扇形随时间收缩。

### Phase 配色

| Phase | 色 |
|---|---|
| `work` | `Color(red: 0.93, green: 0.36, blue: 0.36)` 柔红 |
| `shortBreak` | `Color(red: 0.34, green: 0.78, blue: 0.51)` 薄荷绿 |
| `longBreak` | `Color(red: 0.40, green: 0.66, blue: 0.92)` 天蓝 |

### 状态反馈

| 状态 | 🍅 emoji | 饼图 |
|---|---|---|
| `running` | 正常 | 扇形按秒缩小 |
| `paused` | opacity 0.55 | 扇形保持当前角度 + opacity 缓动脉冲（1s 周期 0.6↔1.0） |
| `justFinished` | 一次性 scale 1.0→1.25→1.0 弹跳（0.6s） | 整圈 opacity 1→0.3→1 闪烁 ×2 |

闪烁通过 `pulseToken: UUID` 变更 + view 本地 `@State` `.onChange` 触发，避免 service tick 每秒触发 view 动画。

### 不做

- **不做"圆环绕在整个 notch 边缘"** —— 需要重画 `NotchBackgroundView` 胶囊路径并沿路径 stroke，跟 notch 自身 spring 动画冲突。Badge 饼图已能达到一眼可见的目标。

---

## Quick Start Window

### `Notch/QuickStartWindow.swift`

```swift
final class QuickStartWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 124),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .transient]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }
    override var canBecomeKey: Bool { true }
}
```

参考：`DSFQuickActionBar`（无边框居中浮层 + 键盘导航）。

### `QuickStartWindowController`

```swift
@MainActor
final class QuickStartWindowController {
    private var window: QuickStartWindow?
    private let timerService: PomodoroTimerService
    private let taskStore: TaskStore
    private let appSettings: AppSettings
    private var clickOutsideMonitor: Any?
    private var previousApp: NSRunningApplication?

    func toggle() { /* present or dismiss */ }
    func present() { /* center, focus textfield, install clickOutside monitor, capture prevApp */ }
    func dismiss() { /* uninstall monitor, restore prevApp */ }
}
```

`AppDelegate` 在 `applicationDidFinishLaunching` 中**预创建一个隐藏实例**（避免首次按 hotkey 的 NSPanel 初始化延迟）。

### 居中定位

```swift
let screen = NSScreen.main ?? NSScreen.screens.first
let sf = screen.frame
let wf = NSRect(
    x: sf.midX - 190,
    y: sf.midY - 62 + 80,    // 略偏上做光学居中
    width: 380, height: 124
)
window.setFrame(wf, display: false)
```

**位置不持久化**。每次重新呼出回到中心略偏上。

### Hotkey

`Hotkeys.swift` 加：

```swift
static let openPomodoro    = Self("openPomodoro")     // 无默认值
static let openQuickStart  = Self("openQuickStart")   // 无默认值
```

两者**不预设默认 binding**，首次启动时 Settings 页显示"未设置"，用户主动绑定（用户在 §4 明确要求"自定义"）。Pomodoro Tab 顶端的 "+ 新建" 按钮是 QuickStart 的备用入口；TabBar 点击是 Pomodoro Tab 的备用入口。`Tab.pomodoro.hotkeyName` 加进 `Tab` extension（指向 `openPomodoro`）。

### 窗口内容

默认折叠版（380 × 124）：

```
┌────────────────────────────────────────────────┐
│ 🍅  ┌──────────────────────────────────────┐   │
│     │ 在做什么？                            │   │  ← Title TextField, 自动 focus, 可留空
│     └──────────────────────────────────────┘   │
│                                                │
│     [优先级 ▽]  [时长 ▽]  [○单次 ●持续]   ↵  │
│                                                │
│     + 添加备注                                 │
└────────────────────────────────────────────────┘
```

点击 "+ 添加备注" → 展开备注区，窗口高度动画到 184pt，加 3 行可滚动 TextEditor。

### 控件规格

| 控件 | 规格 |
|---|---|
| Title TextField | 14pt rounded，自动 focus，可留空（任务不入库） |
| 优先级下拉 | 低/中/高，**默认 = 中** |
| 时长下拉 | 15/25/45/60/自定义...（1-180 分钟），**默认未选，placeholder "时长"** |
| 模式 toggle | `○单次 ●持续`，**默认 = 持续** |
| 备注 TextEditor | 默认折叠；展开后 3 行高，可滚 |

### 验证 & 提交

Enter 触发：

1. 若**时长未选** → 时长下拉外缘加红色 stroke + 0.5s 抖动，不提交
2. Title 非空 → `TaskStore.add(title:priority:notes:tags:dueDate:)` 创建 TodoTask（tags=[], dueDate=nil 在 PR 1）
3. Title 空 → 不创建 task，taskID=nil
4. `timerService.start(taskID:duration:autoFlow:)`，`autoFlow = (mode == .continuous)`
5. `dismiss()`；`previousApp?.activate()`

### 已有 pomodoro 在跑

窗口顶部增加一条黄底警告：

```
⚠️ 当前番茄钟将被覆盖（计为部分完成）
```

Enter 按钮文案变 "覆盖并开始"。按下后 `timerService.start(...)` 内部先 `completeEarly()`（覆盖语义）再 start 新的。

### 行为细节

| 触发 | 行为 |
|---|---|
| Esc | dismiss，不提交 |
| 点击窗口外部 | 通过 `NSEvent.addGlobalMonitorForEvents(.leftMouseDown)`，落点不在 frame 内 → dismiss |
| 再次按 hotkey | toggle：可见 → 关闭；不可见 → 打开 |
| ↑ / ↓ | 切换时长下拉选项（键盘党友好） |
| 退出时 | `previousApp.activate()` 把前台还给被打断的进程 |

### 不做

- 不持久化窗口位置
- 不在快捷窗口选已有 task（这功能在 Tab 内做）
- 不显示标签 / 截止日字段（也留给 Tab）

---

## Pomodoro Tab

Tab 区域 560 × 328（沿用 `NotchConstants.openedWidth` / `openedHeight`）。两个主要状态：**idle** 和 **active**（running / paused / justFinished 通用）。

### Idle 状态

```
┌──────────────────────────────────────────────────────────────┐
│   今日 ✓4 ~1   ·  本周 ✓28        📊  + 新建番茄钟           │
│ ─────────────────────────────────────────────────────────    │
│  🔍 [搜索任务/标签...]  [标签 ▽]  [截止 ▽]  显示已完成 ▽    │  ← PR 2 起出现
│ ─────────────────────────────────────────────────────────    │
│   待办 (6)                                                   │
│   ☐ 高 ▲ 写设计文档        #notch #spec  今天   ●●● 3   ▶   │
│   ☐ 高 ▲ 修复登录回调      #bug          5月26  ●● 2    ▶   │
│   ☐ 中 ─ 整理周报模板                  已逾期2天 ○ 0    ▶   │
│   ☐ 中 ─ 给团队回邮件                                ○ 0  ▶ │
│   ☐ 低 ▽ 周报排版          #routine               ○ 0    ▶ │
│   ☐ 低 ▽ 给 PM 拉会议                              ○ 0    ▶ │
└──────────────────────────────────────────────────────────────┘
```

- 顶端 stats 条（24pt）：今日 / 本周快速摘要
- PR 1：toolbar 不出现，列表直接渲染
- PR 2：加上搜索 / 标签 / 截止日 / 显示已完成 toggle

### Active 状态

```
┌──────────────────────────────────────────────────────────────┐
│   ╱─────╲   写设计文档                       📊  + 新建      │
│  │  ╲  ╱│   工作 · 第 2/4 个 · 接下来：短休息                  │
│  │  17  │   优先级 中  ·  累计 ●●○○○ 2                       │
│   ╲─────╱   17:35 剩余                                       │
│                                                              │
│   [ ⏸ 暂停 ]  [ ✓ 提前完成 ]  [ ✗ 放弃 ]                      │
│ ─────────────────────────────────────────────────────────    │
│   待办 (5)                                                   │
│   ☐ 高 ▲ 修复登录回调 bug                  ●● 2       ▶      │
│   ☐ 中 ─ 整理周报模板                       ○ 0        ▶      │
│   ...                                                        │
└──────────────────────────────────────────────────────────────┘
```

**Active block（~140pt 高）**：

- 大饼图（直径 88pt）：同 badge 视觉但加上中心 mm:ss 文字（14pt monospaced rounded）
- 右侧文字栏：task title（16pt semibold） / phase + counter / priority + 累计点数 / "剩余 17:35"
- 控制按钮一行：⏸ / ▶︎（互斥）、✓ 提前完成、✗ 放弃
- 放弃 / 提前完成都弹**行内 inline confirmation**（避开 NSAlert 打断 notch 焦点）

### TODO 行规格

24pt 高，从左到右：

```
[☐ checkbox] [优先级色块] [title] [tag chips] [dueDate label] [completedPomodoros dots] [▶ start]
```

- 优先级色块：3pt 宽竖条，高=●● 优先 / 中 / 低（红 / 黄 / 灰）
- Tag chips（PR 2）：最多 2 个可见，超出显示 `+N`
- DueDate label（PR 2）：
  - 今天 → "今天"，橙色
  - 明天 → "明天"，黄色
  - 7 天内 → "5月26日"
  - 已过 → "已逾期 N 天"，红色 + 行底浅红描边
  - 无 → 不显示
- 累计点数：最多 5 实心点，超过显示 "5+"
- 行尾 ▶ 始终可见（小图标按钮）

### 行交互

| 操作 | 行为 |
|---|---|
| 点 ▶ | fast-path 启动：复用该 task 的 priority 与 "上次启动用过的 duration 或 25 分钟默认"，autoFlow 从 AppSettings 上次值。**不弹 QuickStart 窗口**。若已 running → 弹 inline 确认条 "覆盖当前番茄钟？" |
| 点 checkbox | 切换 isDone |
| 点 title 区 | 行内编辑 title |
| Hover 行末出 `⋯` 按钮 | 菜单：编辑（sheet）/ 删除（带确认）/ 置顶 |
| **拖拽（PR 2）** | onDrag/onDrop，更新 sortIndex；详见 Sorting Model |

### 编辑 Sheet

点 `⋯ → 编辑` 弹 380 × 280 sheet（attach 到 notch，不离开）：

```
┌──────────────────────────────────────┐
│ 编辑任务                           ✕ │
│                                      │
│ 标题  [..............................] │
│ 优先级 [低 ▽] [中 ▽] [高 ▽]            │
│ 标签   [#tag1 ✕] [#tag2 ✕] [+]        │  ← PR 2
│ 截止   [DatePicker.graphical]   清除  │  ← PR 2
│ 备注  ┌────────────────────────────┐ │
│       │                            │ │
│       └────────────────────────────┘ │
│                                      │
│ 完成情况：●●● 3 个番茄钟              │
│ 创建于：5月23日                       │
│                                      │
│         [取消]    [保存]              │
└──────────────────────────────────────┘
```

### Stats Popover

📊 按钮 → popover，PR 1 纯数字版（320pt 宽），PR 2 加图（440pt 宽）：

**PR 1**：

```
┌──────────────────────────────┐
│ 今日                          │
│ ✓ 4 完成                      │
│ ~ 1 部分完成                  │
│ ✗ 0 放弃                      │
│ ─────────────────             │
│ 本周                          │
│ ✓ 28 · ~ 4 · ✗ 2              │
│ ─────────────────             │
│ 全部                          │
│ ✓ 142 · ~ 18 · ✗ 9            │
│ 最常做：写设计文档 14         │
│                              │
│ 最近 5 次                     │
│ 10:30 写设计文档    25✓       │
│ 09:55 修复登录回调  partial18 │
│ ...                          │
└──────────────────────────────┘
```

**PR 2**：

- 顶端 segmented：`7 天 / 30 天 / 全部` 切换 X 轴
- 柱状图：每天一根柱，按 outcome 分段堆叠（completed / partial / abandoned 用三档透明度）
- 全部维度下按周聚合
- 鼠标 hover 柱：tooltip 显示该日详细数字 + 最常做 task

数据全从 `PomodoroHistoryStore` 实时计算（filter + reduce），不预聚合。

### Phase Counter 文案规则

active block 中 "工作 · 第 2/4 个 · 接下来：短休息"：

- 第 N/M 个：N = `workCounterSinceLongBreak + 1`，M = `longBreakInterval`（默认 4）
- "接下来"：
  - work → `(N % M == 0) ? "长休息" : "短休息"`
  - shortBreak/longBreak → `"工作"`
- 单次模式（autoFlow=false）：文案改为 "单次工作"，不显示 "接下来"

---

## Sorting Model

### sortIndex-only

**从 §5 之前"priority-排序 + sortIndex-兜底"切换到"sortIndex 单一升序 key"**。

- `priority` 退化为视觉标签 + 配色，不参与排序
- 新任务 `sortIndex = currentMax + 1.0`（append 到尾）
- "置顶" 设 `sortIndex = currentMin - 1.0`
- 拖拽落到行 A 和 B 之间 → 新 sortIndex = (A.sortIndex + B.sortIndex) / 2

### 拖拽实现（PR 2）

- `ForEach` 行 `.onDrag { NSItemProvider(object: task.id.uuidString as NSString) }`
- 行间隙 `.onDrop(of: [UTType.text]) { providers, _ in ... }` 解析 UUID，计算新 sortIndex
- 视觉：拖拽时原行 opacity 0.4，落点处渲染 2pt 蓝色横线指示器
- **跨"未完成 / 已完成"段拖拽 blocked** —— 避免语义混乱（用户应该用 checkbox 切换 isDone，而不是拖到另一段）

### 浮点精度

(a + b) / 2 反复折半，1000 次后会触 1e-15 边界。

- MVP **不解决**
- 在 `TaskStore.moveTask(_:to:)` 加：检测到相邻 sortIndex 差 < 1e-9 时 `LogService.warn`
- 留一个 TODO：当 warn 触发时 trigger "rebalance"（按当前顺序重分 1.0 / 2.0 / 3.0 ...）

`TaskStoreTests.swift` 加 "1000 次相邻拖拽不触发 underflow" 测例（具体阈值通过测试探出）。

---

## Settings, Permissions, End Alerts

### `AppSettings` 新增字段

```swift
var pomodoroWorkDuration: TimeInterval        // 默认 25*60
var pomodoroShortBreakDuration: TimeInterval  // 默认 5*60
var pomodoroLongBreakDuration: TimeInterval   // 默认 15*60
var pomodoroLongBreakInterval: Int            // 默认 4
var pomodoroSoundEnabled: Bool                // 默认 true
var pomodoroNotificationEnabled: Bool         // 默认 true
```

全部 UserDefaults 持久化，键前缀 `pomodoro.`。

**没有** `autoFlow` 全局开关 —— 模式在每次启动时通过 QuickStart 窗口决定，存于 `RunningContext.autoFlow`。

### `PomodoroSettingsView`

挂到现有 `SettingsView` sidebar，紧跟 Notifications 之后：

```
┌────────────────────────────────────────────────────┐
│  番茄钟                                            │
│  ─────────────────────────────────────────         │
│  工作时长             [ 25 分钟 ▽ ]                 │
│  短休息时长           [  5 分钟 ▽ ]                 │
│  长休息时长           [ 15 分钟 ▽ ]                 │
│  长休息间隔           [  4 个工作后 ▽ ]              │
│                                                    │
│  ☑ 结束时播放声音                                  │
│  ☑ 结束时发送系统通知                              │
│                                                    │
│  ─────────────────────────────────────────         │
│  快捷键                                            │
│  打开番茄钟 Tab       [ 录制快捷键 ]                │
│  打开快速启动窗口     [ 录制快捷键 ]                │
│                                                    │
│  ─────────────────────────────────────────         │
│  通知权限                                          │
│  [PermissionCard, 仅当 permission != authorized]   │
└────────────────────────────────────────────────────┘
```

- 时长下拉：5/10/15/20/25/30/45/60 + 自定义（行内 stepper 1-180）
- 长休息间隔：3/4/5/6
- Hotkey 录制：`KeyboardShortcuts.Recorder`（已在 `HotkeysSettingsView` 用过）
- 两 hotkey **不在** `HotkeysSettingsView`，集中收在 Pomodoro 设置页（feature-grouped）

### 通知权限 —— PermissionCard 模式

沿用 `2026-05-23-permissions-and-hotkey-dismiss-design.md` 的 `PermissionCard` 模式 —— 不在 app 启动时自动请求 `UNUserNotificationCenter` 授权。

新文件 `Services/NotificationPermissionMonitor.swift`：

```swift
@MainActor
@Observable
final class NotificationPermissionMonitor {
    var status: UNAuthorizationStatus = .notDetermined

    func refresh() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        status = s.authorizationStatus
    }

    func request() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            await refresh()
        } catch {
            LogService.warn("UN auth request failed: \(error)", category: "Pomodoro")
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

`PomodoroSettingsView` 仅在 `status != .authorized` 时渲染 `PermissionCard`：

```swift
PermissionCard(
    icon: "bell.badge",
    titleKey: "permission.notification.title",
    detailKey: "permission.notification.detail",
    status: monitor.status == .denied ? .denied : .notDetermined,
    primary: .programmatic { Task { await monitor.request() } },
    openSettings: { monitor.openSystemSettings() }
)
```

发通知时双 gate：

```swift
if appSettings.pomodoroNotificationEnabled
    && monitor.status == .authorized { /* post */ }
```

未授予则**静默 skip**，用户靠声音 + notch 闪烁感知。

### Info.plist

`UNUserNotificationCenter` **不需要** Info.plist 描述键。和 Automation/Calendar/Location 的 NSXxxUsageDescription 不同 —— 通知权限走 `UNAuthorizationOptions` 申请就行，不会因为缺 key 静默失败。**无需修改 `project.pbxproj`**。

### 结束提醒三件套

`PomodoroTimerService` 在 `naturalEnd()` / `completeEarly()` 写完 history 后调：

```swift
private func triggerEndAlerts(phase: PomodoroPhase, taskTitle: String?) {
    // 1. 声音
    if appSettings.pomodoroSoundEnabled {
        NSSound(named: phase == .work ? "Glass" : "Hero")?.play()
    }

    // 2. 系统通知（双重 gate）
    if appSettings.pomodoroNotificationEnabled,
       notificationMonitor.status == .authorized {
        let content = UNMutableNotificationContent()
        content.title = phase.endTitleKey.localized()
        content.body = endBody(phase, taskTitle)
        content.sound = nil   // 避免和 NSSound 双响
        let req = UNNotificationRequest(
            identifier: "pomodoro.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    // 3. notch ring 闪烁
    pulseToken = UUID()
}
```

`abandon()` 路径**不调** `triggerEndAlerts`。

点通知触发：通过 `UNUserNotificationCenterDelegate` 接收 → `NotchCoordinator.notchOpen(tab: .pomodoro, viaHotkey: true)`（走 §165 3 秒宽限期）。

### 系统休眠 / app 退出

`PomodoroTimerService.init` 注册：

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willSleepNotification,
    object: nil, queue: nil
) { [weak self] _ in
    Task { @MainActor in self?.abandonDueToSystemSleep() }
}
```

- `willSleepNotification` → `abandon()` 走 abandoned 路径
- `didWakeNotification` → 无特殊处理

`AppDelegate.applicationWillTerminate`：

```swift
switch timerService.state {
case .running, .paused: timerService.abandon()
default: break
}
```

---

## Localization

新增键（`Localizable.xcstrings`）：

| 键 | 中 | 英 |
|---|---|---|
| `models.tab.pomodoro` | 番茄钟 | Pomodoro |
| `pomodoro.quick.placeholder` | 在做什么？ | What are you working on? |
| `pomodoro.quick.priority` | 优先级 | Priority |
| `pomodoro.quick.duration` | 时长 | Duration |
| `pomodoro.quick.duration.placeholder` | 时长 | Duration |
| `pomodoro.quick.duration.required` | 请选择时长 | Pick a duration |
| `pomodoro.quick.mode.single` | 单次 | Single |
| `pomodoro.quick.mode.continuous` | 持续 | Continuous |
| `pomodoro.quick.notes` | 备注（可选） | Notes (optional) |
| `pomodoro.quick.addNotes` | + 添加备注 | + Add notes |
| `pomodoro.quick.overrideWarning` | 当前番茄钟将被覆盖（计为部分完成） | Current pomodoro will be overridden (counted as partial) |
| `pomodoro.quick.confirm` | 开始 | Start |
| `pomodoro.quick.confirmOverride` | 覆盖并开始 | Override & start |
| `pomodoro.priority.low` | 低 | Low |
| `pomodoro.priority.medium` | 中 | Medium |
| `pomodoro.priority.high` | 高 | High |
| `pomodoro.phase.work` | 工作 | Work |
| `pomodoro.phase.shortBreak` | 短休息 | Short Break |
| `pomodoro.phase.longBreak` | 长休息 | Long Break |
| `pomodoro.phase.next` | 接下来：%@ | Next: %@ |
| `pomodoro.phase.counter` | 第 %d/%d 个 | %d/%d |
| `pomodoro.phase.singleWork` | 单次工作 | Single work |
| `pomodoro.action.pause` | 暂停 | Pause |
| `pomodoro.action.resume` | 继续 | Resume |
| `pomodoro.action.completeEarly` | 提前完成 | Complete Early |
| `pomodoro.action.abandon` | 放弃 | Abandon |
| `pomodoro.action.start` | 开始 | Start |
| `pomodoro.action.newTask` | + 新建 | + New |
| `pomodoro.action.newPomodoro` | + 新建番茄钟 | + New Pomodoro |
| `pomodoro.confirm.completeEarly` | 还有 %@ 剩余，确定提前完成？ | %@ remaining, complete early? |
| `pomodoro.confirm.abandon` | 放弃当前番茄钟？ | Abandon current pomodoro? |
| `pomodoro.confirm.override` | 覆盖当前番茄钟？ | Override current pomodoro? |
| `pomodoro.todo.empty` | 暂无任务，按快捷键或点击 + 新建 | No tasks. Use the hotkey or + New |
| `pomodoro.todo.showCompleted` | 显示已完成 | Show completed |
| `pomodoro.todo.completed` | 已完成 | Completed |
| `pomodoro.todo.search` | 搜索任务/标签... | Search tasks/tags... |
| `pomodoro.todo.tagFilter` | 标签 | Tags |
| `pomodoro.todo.dueFilter` | 截止 | Due |
| `pomodoro.todo.dueFilter.today` | 今天 | Today |
| `pomodoro.todo.dueFilter.week` | 本周 | This week |
| `pomodoro.todo.dueFilter.overdue` | 已逾期 | Overdue |
| `pomodoro.todo.dueFilter.none` | 无截止 | No due date |
| `pomodoro.todo.dueFilter.all` | 全部 | All |
| `pomodoro.todo.delete.confirm` | 删除任务"%@"？ | Delete "%@"? |
| `pomodoro.todo.pin` | 置顶 | Pin to top |
| `pomodoro.todo.edit` | 编辑 | Edit |
| `pomodoro.todo.delete` | 删除 | Delete |
| `pomodoro.todo.relativeDue.today` | 今天 | Today |
| `pomodoro.todo.relativeDue.tomorrow` | 明天 | Tomorrow |
| `pomodoro.todo.relativeDue.overdue` | 已逾期 %d 天 | Overdue %d day(s) |
| `pomodoro.edit.title` | 编辑任务 | Edit Task |
| `pomodoro.edit.titleField` | 标题 | Title |
| `pomodoro.edit.tags` | 标签 | Tags |
| `pomodoro.edit.dueDate` | 截止 | Due |
| `pomodoro.edit.dueDate.clear` | 清除 | Clear |
| `pomodoro.edit.notes` | 备注 | Notes |
| `pomodoro.edit.createdAt` | 创建于：%@ | Created: %@ |
| `pomodoro.edit.completedCount` | 完成情况：●●● %d 个番茄钟 | Completed: %d pomodoros |
| `pomodoro.stats.today` | 今日 | Today |
| `pomodoro.stats.week` | 本周 | Week |
| `pomodoro.stats.all` | 全部 | All |
| `pomodoro.stats.completed` | 完成 | Completed |
| `pomodoro.stats.partial` | 部分完成 | Partial |
| `pomodoro.stats.abandoned` | 放弃 | Abandoned |
| `pomodoro.stats.mostFrequent` | 最常做：%@ %d | Most frequent: %@ %d |
| `pomodoro.stats.recent` | 最近 5 次 | Recent 5 |
| `pomodoro.stats.range.7d` | 7 天 | 7 days |
| `pomodoro.stats.range.30d` | 30 天 | 30 days |
| `pomodoro.stats.range.all` | 全部 | All |
| `pomodoro.notification.workEnd.title` | 番茄钟结束 🍅 | Pomodoro complete 🍅 |
| `pomodoro.notification.breakEnd.title` | 休息结束 | Break over |
| `pomodoro.notification.body.withTask` | %@ · %d 分钟完成 | %@ · %d min done |
| `pomodoro.notification.body.noTask` | %d 分钟完成 | %d min done |
| `permission.notification.title` | 通知 | Notifications |
| `permission.notification.detail` | 番茄钟结束时发送系统通知 | Send a system notification when a pomodoro ends |
| `settings.pomodoro.title` | 番茄钟 | Pomodoro |
| `settings.pomodoro.workDuration` | 工作时长 | Work duration |
| `settings.pomodoro.shortBreakDuration` | 短休息时长 | Short break duration |
| `settings.pomodoro.longBreakDuration` | 长休息时长 | Long break duration |
| `settings.pomodoro.longBreakInterval` | 长休息间隔 | Long break interval |
| `settings.pomodoro.longBreakInterval.unit` | %d 个工作后 | After %d work |
| `settings.pomodoro.soundEnabled` | 结束时播放声音 | Play sound at end |
| `settings.pomodoro.notificationEnabled` | 结束时发送系统通知 | Send notification at end |
| `settings.pomodoro.hotkey.openTab` | 打开番茄钟 Tab | Open Pomodoro tab |
| `settings.pomodoro.hotkey.quickStart` | 打开快速启动窗口 | Open quick start |

---

## Testing

新建 `NemoNotchTests/`（Swift Testing 风格）：

| 测试文件 | 覆盖 |
|---|---|
| `PomodoroTimerServiceTests.swift` | 状态转移全 12 条边；workCounterSinceLongBreak 累加与 longBreak 触发；autoFlow=true/false 在 justFinished 后的下一状态；覆盖式 start；abandon 不调 triggerEndAlerts |
| `TaskStoreTests.swift` | add/update/delete/markDone；JSON 序列化往返；缺 tags/dueDate 的 v1 JSON 兼容；sortIndex 计算（拖拽 N 次的 underflow 检测）；按 tag/dueDate filter；search filter |
| `PomodoroHistoryStoreTests.swift` | append/load；1000 条 load 性能 < 100ms；按 taskID 聚合；按日期 filter |
| `PomodoroStatsTests.swift` | 今日/本周/全部 聚合；7/30 天桶聚合（PR 2）；最常做任务计算；空数据兜底 |

**跳过**：`QuickStartWindow`（NSPanel 集成）、`PomodoroBadgeView`（SwiftUI 渲染）、`NotificationPermissionMonitor`（系统 API）—— 走人工 QA。

---

## Implementation Order

### PR 1 — MVP

1. 数据层：`TodoTask`（含 tags/dueDate 字段从一开始就在）/ `PomodoroPhase` / `PomodoroRecord` + 三个 Store/Service 骨架 + 单测
2. `AppSettings` 扩展 + `PomodoroSettingsView`
3. `PomodoroTab` idle 状态 + `Tab` enum 注册
4. `QuickStartWindow` + `QuickStartWindowController` + 两 hotkey + AppDelegate 接线（hotkey 默认无 binding）
5. 状态机驱动 active 状态 UI（active block + 控制按钮 + inline confirm）
6. Notch badge 集成（`BadgeItem` / `BadgeIconView` / `BadgeViewModel` / 优先级重编号）
7. 通知 + 声音 + `NotificationPermissionMonitor` + `PermissionCard`
8. 休眠 / quit 处理 + edge case
9. 基础 Stats popover（纯数字）+ 编辑 sheet（不含 tags/dueDate UI）
10. 本地化补齐 + 文档（README / README_CN / CLAUDE.md / macOS cookbook）

### PR 2 — 增强

11. 拖拽重排 + 排序模型从 priority-sorted 切换到 sortIndex-only（含 Pomodoro Tab 文案与列表渲染的修订）
12. 搜索 TextField + 防抖
13. 标签 chip UI + 编辑器 + toolbar 过滤
14. 截止日 DatePicker + 行内显示 + toolbar 过滤 + 逾期高亮
15. Charts popover 升级（柱状图 + segmented period 切换）

---

## Risks & Compromises

| 风险 | 影响 | 决策 |
|---|---|---|
| `PomodoroHistoryStore` 永久保留可能膨胀 | N 年后 JSON 几 MB | 启动时 lazy 加载；N>10000 触发分卷（未实现，留 TODO） |
| `BadgeItem` priority 重编号影响 BadgeViewModel 排序测试 | 现有逻辑被微调 | 一并改测试；priority 从硬编码 int 改成 enum 计算属性，未来加 case 不再手动重编号 |
| `QuickStartWindow` 首次 hotkey 触发延迟 | 首次按 hotkey 略慢 | AppDelegate `applicationDidFinishLaunching` 预创建（不显示） |
| Hotkey-aware dismiss（参考 `2026-05-23-permissions-and-hotkey-dismiss-design.md`）和通知点击打开 notch 的交互 | 用户从通知点开 notch 后，3 秒未鼠标进入会自动收 | 沿用现有机制，用户可鼠标进入或 ESC 接管 |
| 拖拽 sortIndex 浮点 underflow | 1000 次拖拽后相邻差 1e-15 | LogService.warn + 留 rebalance TODO |
| 时长下拉默认未选 | 用户必须主动选才能 Enter | 显式验证 + 红圈+抖动反馈，避免静默失败 |

---

## References

代码上下文（设计中提到的现有文件）：

- `NemoNotch/Notch/Badge/BadgeItem.swift` — 现有 BadgeItem 枚举与 priority
- `NemoNotch/Notch/Badge/BadgeIconView.swift` — `compactLeft` / `compactRight` / `row` 三槽渲染范式
- `NemoNotch/Notch/Badge/BadgeViewModel.swift` — `activeBadgeItems` 组装逻辑
- `NemoNotch/Notch/NotchCoordinator.swift` — `notchOpen(viaHotkey:)` + hotkey-aware dismiss 3 秒宽限期
- `NemoNotch/Helpers/PermissionCard.swift` — 通知权限沿用此组件
- `NemoNotch/Services/Hotkeys.swift` — `KeyboardShortcuts.Name` 注册模式
- `NemoNotch/Settings/HotkeysSettingsView.swift` — `KeyboardShortcuts.Recorder` 使用范式
- `NemoNotch/Models/AppSettings.swift` — UserDefaults 字段添加模式
- `NemoNotch/Tabs/LauncherTab.swift` — 简单 Tab 范式（搜索框 + LazyVGrid）
- `docs/superpowers/specs/2026-05-23-permissions-and-hotkey-dismiss-design.md` — PermissionCard 模式起源

参考项目（详见 CLAUDE.md "Reference Projects"）：

- `DSFQuickActionBar` — Spotlight 风格的居中浮窗 + 键盘导航（QuickStart 窗口参考）
- `KeyboardShortcuts` — 用户自定义快捷键（已在用）
