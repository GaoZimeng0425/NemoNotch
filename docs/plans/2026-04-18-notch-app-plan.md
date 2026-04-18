# NotchApp 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 构建一个 macOS notch 应用，集中展示媒体播放、日历事件、Claude Code 状态，并提供快速应用启动。

**Architecture:** 自建 NSPanel 窗口管理（参考 Peninsula 模式），不依赖 DynamicNotchKit 做主 UI——它只适合弹出式通知，不适合持久交互面板。仅提取 DynamicNotchKit 的刘海检测工具代码。四个独立 Service（ObservableObject）驱动四个 Tab 视图。Claude Code 监控通过 hooks + NWListener 实现，需与 masko-code 等工具共存。

**Tech Stack:** SwiftUI, AppKit (NSPanel), MediaPlayer, EventKit, Network (NWListener)

---

## 关键架构决策

| 决策 | 选择 | 原因 |
|------|------|------|
| 主 notch UI | 自建 NSPanel（参考 Peninsula） | DynamicNotchKit 设计为弹出通知（show→timeout→hide），不支持持久交互面板 |
| DynamicNotchKit 用途 | 仅提取刘海检测代码（NSScreen extension） | 避免框架限制，复用 notch 检测逻辑 |
| 窗口层级 | `.mainMenu + 3` | 与 Peninsula 一致，在普通窗口之上，屏幕保护之下 |
| 窗口策略 | 始终存在、始终覆盖屏幕顶部，closed 时全透明 | Peninsula 同策略，确保徽章等内容可渲染 |
| 状态机 | 3 态：closed → popping → opened | 参考 Peninsula，悬停预览降低误触 |
| CC hooks 共存 | 仅追加不覆盖已有 hooks | masko-code 等工具可能已注册 hooks，必须幂等追加 |
| CC PermissionRequest | 不注册此 hook | 避免与 masko-code 冲突，NotchApp 只读状态不需要阻塞 hooks |
| CC 多会话 | 按 session_id 分组显示 | hook 事件含 session_id，支持同时显示多个活跃 session |
| 无刘海设备 | fallback 到顶部居中浮动胶囊 | 参考 DynamicNotchKit 的 NotchlessView，用 VisualEffectView 实现 |
| 数据持久化 | AppSettings 为唯一数据源，Service 从它读取 | 避免多对象读写同一 UserDefaults key 产生冲突 |
| 全局快捷键 | Carbon `RegisterEventHotKey` API | `NSEvent.addGlobalMonitor` 只读不拦截且前台失效，Carbon API 才是真正的全局热键 |
| Tab 动态数量 | TabBarView/导航按钮/快捷键均根据 enabledTabs 动态生成 | 避免用户隐藏 Tab 后硬编码不一致 |
| 偏好设置 | 独立 NSWindow 设置窗口，不作为 notch Tab | notch 空间太小不适合设置 UI，标准 macOS 设置窗口更合理 |
| Service 注入 | EnvironmentObject | SwiftUI 原生依赖注入，Tab 视图通过环境访问 Service |
| hook-sender.sh 版本管理 | 内嵌版本号，app 更新后自动重生成 | 参考 masko-code 版本戳机制，确保脚本与 app 同步 |

---

## 参考代码

| 参考 | 路径 | 复用什么 |
|------|------|----------|
| Peninsula NotchWindow | `Peninsula/Peninsula/Notch/NotchWindow.swift` | NSPanel 配置、窗口定位 |
| Peninsula NotchViewModel | `Peninsula/Peninsula/Notch/NotchViewModel.swift` | 状态机（closed/popping/opened）、尺寸计算 |
| Peninsula NotchBackgroundView | `Peninsula/Peninsula/Notch/Notch/NotchBackgroundView.swift` | 黑色刘海形状（clipShape + blendMode 切角） |
| Peninsula NotchView | `Peninsula/Peninsula/Notch/NotchView.swift` | 悬停检测、状态切换 |
| Peninsula NotchNavView | `Peninsula/Peninsula/Notch/Notch/NotchNavView.swift` | popping 状态导航按钮 |
| Peninsula HotKeyObserver | `Peninsula/Peninsula/` — 搜索 HotKey 相关文件 | Carbon RegisterEventHotKey 全局快捷键 |
| NotchDrop EventMonitors | `NotchDrop/NotchDrop/EventMonitors.swift` | NSEvent 全局鼠标事件监听 |
| DynamicNotchKit NSScreen+Ext | `DynamicNotchKit/Sources/DynamicNotchKit/NSScreen+Extensions.swift` | `hasNotch`/`notchSize`/`notchFrame` 检测 |
| masko-code HookInstaller | `masko-code/Sources/Services/HookInstaller.swift` | hooks 幂等注册 |
| masko-code LocalServer | `masko-code/Sources/Services/LocalServer.swift` | NWListener HTTP 服务 |
| masko-code AgentEvent | `masko-code/Sources/Models/AgentEvent.swift` | hook 事件 JSON 格式 |

---

## 实现顺序与依赖

```
Task 1 (脚手架 + 刘海检测)
  └── Task 2 (窗口 + 状态机)
        ├── Task 3 (鼠标事件监听)
        └── Task 4 (背景形状 + Tab 栏)
              └── Task 5 (Models)
                    ├── Task 6  (Media)    ─┐
                    ├── Task 7  (Calendar) ─┤ 可并行
                    ├── Task 8  (Claude)   ─┤
                    └── Task 9  (Launcher) ─┘
                          │
                    Task 10 (紧凑徽章)  ← 需要 Service 已存在
                          │
                    Task 11 (集成：启动流程 + 快捷键)  ← 串联所有组件
                          │
                    Task 12 (偏好设置窗口)
                          │
                    Task 13 (打磨)
```

Task 6-9 互相无依赖，可并行实现。Task 10 需要至少一个 Service 完成。Task 11 是最终集成。

---

## Task 1: 项目脚手架 + 刘海检测

**Files:**
- Create: `NotchApp/NotchApp.xcodeproj`（Xcode 项目，macOS App, SwiftUI, macOS 14+）
- Create: `NotchApp/NotchApp.swift`（App 入口）
- Create: `NotchApp/Helpers/ScreenExtensions.swift`（刘海检测）

**Steps:**

1. 在 `/Users/gaozimeng/Learn/macOS/NotchApp/` 创建 Xcode 项目
2. 配置 `Info.plist`：`LSUIElement = true`（不显示 Dock 图标）
3. App 入口用 `MenuBarExtra` 占位，显示一个图标 + "退出" 菜单项
4. 从 DynamicNotchKit `NSScreen+Extensions.swift` 提取刘海检测代码到 `ScreenExtensions.swift`：
   - `NSScreen.hasNotch: Bool`
   - `NSScreen.notchSize: NSSize?`
   - `NSScreen.notchFrame: NSRect?`
   - `NSScreen.screenWithMouse: NSScreen?`
   - 依赖的 `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 属性
5. 构建确认编译通过
6. Commit: `feat: scaffold NotchApp with screen notch detection`

---

## Task 2: Notch 窗口 + 状态机

**Files:**
- Create: `NotchApp/Notch/NotchWindow.swift`
- Create: `NotchApp/Notch/NotchCoordinator.swift`

**Steps:**

1. `NotchWindow`（NSPanel 子类，参考 Peninsula）：
   - `styleMask = [.borderless, .nonactivatingPanel]`
   - `level = .mainMenu + 3`，`isFloatingPanel = true`
   - 透明背景、无阴影、`canBecomeKey = true`、`canBecomeMain = true`
   - `collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]`
   - `isMovable = false`，`isReleasedWhenClosed = false`
2. `NotchCoordinator`（ObservableObject）：
   - 状态枚举：`closed` / `popping` / `opened`
   - 持有 `NotchWindow` 实例 + `NSHostingController`
   - **窗口策略**：窗口始终存在、始终覆盖屏幕顶部区域（宽 = 屏幕宽，高 = 屏幕 menubar 高度 + opened 时内容高度），closed 时窗口内容为透明/不可见
   - 刘海尺寸检测：从 `ScreenExtensions` 获取，监听 `didChangeScreenParametersNotification` 刷新
   - 尺寸计算（参考 Peninsula `notchSize`）：
     - closed：硬件刘海尺寸（无刘海时 200x6）
     - popping：刘海宽 + padding，高度 2x 刘海高
     - opened：500x260
   - 方法：`notchPop()`、`notchOpen(tab:)`、`notchClose()`
   - 窗口定位：居中屏幕顶部
   - `@Published var status: Status`、`@Published var selectedTab: Tab`
3. 构建确认编译通过
4. Commit: `feat: add notch window and coordinator state machine`

---

## Task 3: 鼠标事件监听 + 悬停检测

**Files:**
- Create: `NotchApp/Notch/EventMonitor.swift`
- Modify: `NotchApp/Notch/NotchCoordinator.swift`

**Steps:**

1. `EventMonitor`（参考 NotchDrop `EventMonitors.swift`）：
   - 单例，`NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents`
   - 监听：`.mouseMoved`、`.leftMouseDown`、`.leftMouseUp`
   - Combine 发布：`mouseLocation`、`mouseDown`
2. `NotchCoordinator` 订阅事件：
   - mouseMoved：
     - closed + 鼠标进入刘海 hitbox → `notchPop()`
     - popping/opened + 鼠标离开 → `notchClose()`
   - mouseDown：closed + 点击 hitbox → `notchPop()`（popping 状态的点击由导航按钮处理）
   - hitbox 比实际刘海大 10pt padding
3. 触觉反馈：pop 时 `NSHapticFeedbackManager.defaultPerformer.perform(.levelChange)`
4. 构建并运行，确认悬停弹出、离开收起
5. Commit: `feat: add mouse event monitoring and hover detection`

---

## Task 4: Notch 背景形状 + Tab 栏

**Files:**
- Create: `NotchApp/Notch/NotchView.swift`
- Create: `NotchApp/Notch/NotchBackgroundView.swift`
- Create: `NotchApp/Notch/TabBarView.swift`
- Create: `NotchApp/Models/Tab.swift`

**Steps:**

1. `Tab` 枚举：media/calendar/claude/launcher，含 SF Symbol 和标题；实现 `CaseIterable`
2. `NotchBackgroundView`（参考 Peninsula）：
   - 黑色矩形，仅底部圆角（closed 8pt，opened 32pt）
   - 顶部 `clipShape` + `blendMode(.destinationOut)` 切出凹弧匹配硬件刘海
   - opened/popping 加阴影（radius 16）
   - 无刘海时用 `VisualEffectView(.popover)` 圆角胶囊替代
3. `TabBarView`：
   - 根据 `enabledTabs`（`Set<Tab>`，默认全部）**动态生成**图标按钮
   - 绑定 `selectedTab`，选中白色高亮，未选灰色
   - 按钮数量 = enabledTabs.count，不是写死 4 个
4. `NotchView` 主视图：
   - `ZStack(alignment: .top)`：背景层 + 内容层
   - closed：仅背景（不可见或最小）+ CompactBadge 占位
   - popping：背景 + 导航按钮（数量和内容根据 enabledTabs 动态生成，如 Peninsula NotchNavView）
   - opened：背景 + TabBar + 内容区域（占位 Spacer）
   - Service 通过 `.environmentObject()` 注入，Tab 视图用 `@EnvironmentObject` 访问
   - 动画：outer `interactiveSpring(duration: 0.314)`，inner 延迟 0.157s
5. 构建并运行，确认 Tab 切换正常
6. Commit: `feat: add notch background shape and tab bar`

---

## Task 5: 数据模型 + AppSettings

**Files:**
- Create: `NotchApp/Models/PlaybackState.swift`
- Create: `NotchApp/Models/CalendarEvent.swift`
- Create: `NotchApp/Models/ClaudeState.swift`
- Create: `NotchApp/Models/AppItem.swift`
- Create: `NotchApp/Models/AppSettings.swift`

**Steps:**

1. `PlaybackState`：title、artist、album、duration、position、isPlaying、artworkData（Data?）
2. `CalendarEvent`：title、startDate、endDate、calendarColor（CGColor）、isAllDay；Identifiable
3. `ClaudeState`：status 枚举（idle/working/waiting）、currentTool、sessionId、sessionStart、lastEventTime；Identifiable（用 sessionId）
4. `AppItem`：name、bundleIdentifier、iconData（Data?）；Identifiable、Codable
5. `AppSettings`（ObservableObject + UserDefaults `@AppStorage`）：
   - `defaultTab: Tab`（默认 .media）
   - `enabledTabs: Set<Tab>`（默认全部，`Tab.allCases`）
   - **唯一数据源**：所有 Tab 相关配置和 launcher 应用列表都由 AppSettings 管理
   - Service 通过 AppSettings 读取配置，不自行持久化
6. Commit: `feat: add data models and app settings`

---

## Task 6: MediaService + MediaTab

**Files:**
- Create: `NotchApp/Services/MediaService.swift`
- Create: `NotchApp/Tabs/MediaTab.swift`

**Steps:**

1. `MediaService`（ObservableObject）：
   - `MPNowPlayingInfoCenter.default().nowPlayingInfo` 获取播放信息
   - 监听通知：`MPMusicPlayerControllerNowPlayingItemDidChange`、`playbackStateDidChange`
   - `MPRemoteCommandCenter` 控制命令：play/pause、nextTrack、previousTrack
   - `@Published var playbackState: PlaybackState`（默认空/未播放）
2. `MediaTab`：
   - 上：专辑封面（50x50 圆角 8pt）+ 歌名（粗体）+ 艺术家（灰色）+ 进度条
   - 下：控制按钮行（上一首 | 播放/暂停 | 下一首）
   - 无播放："未在播放" + 音乐图标占位
3. 构建并运行，播放 Spotify/Apple Music 确认显示
4. Commit: `feat: add media service and tab`

---

## Task 7: CalendarService + CalendarTab

**Files:**
- Create: `NotchApp/Services/CalendarService.swift`
- Create: `NotchApp/Tabs/CalendarTab.swift`

**Steps:**

1. `CalendarService`（ObservableObject）：
   - `EKEventStore`，请求 `EKEntityType.event` 权限
   - 查询今日事件：start = 今日 0:00，end = 23:59
   - 监听 `EKEventStoreChangedNotification` 自动刷新
   - `@Published var todayEvents: [CalendarEvent]`
   - `@Published var nextEvent: CalendarEvent?`
   - `@Published var authorizationStatus: EKAuthorizationStatus`
2. `CalendarTab`：
   - 顶部：nextEvent 倒计时（如 "15 分钟后"），粗体大字
   - 列表：日历颜色圆点 + 标题 + 时间范围（已结束灰显）
   - 无事件："今日无日程"
   - 无权限："需要日历权限" + 打开系统设置按钮
3. 构建并运行，确认显示日历事件
4. Commit: `feat: add calendar service and tab`

---

## Task 8: ClaudeCodeService + ClaudeTab

**Files:**
- Create: `NotchApp/Services/HookInstaller.swift`
- Create: `NotchApp/Services/HookServer.swift`
- Create: `NotchApp/Services/ClaudeCodeService.swift`
- Create: `NotchApp/Tabs/ClaudeTab.swift`

**Steps:**

1. `HookInstaller`（参考 masko-code）：
   - **共存安全**：读现有 hooks，仅追加 NotchApp 条目，不删其他工具 hooks
   - 注册事件：`PreToolUse`、`PostToolUse`、`Stop`、`SessionStart`、`SessionEnd`、`Notification`
   - **不注册 PermissionRequest**（避免与 masko-code 冲突）
   - 生成 `~/.notchapp/hooks/hook-sender.sh`：health check（超时 0.3s 无响应直接 exit 0）→ 读 stdin JSON → 注入 pid → POST
   - **版本管理**：脚本内嵌版本号注释（`# version: 1`），app 启动时检查版本，不一致则重新生成并重装
   - 方法：`install()`、`uninstall()`、`isInstalled() -> Bool`
   - 端口变化时重新生成脚本并重装
2. `HookServer`（NWListener HTTP）：
   - 默认端口 49200，冲突递增（最多 10 个）
   - 最终端口存 UserDefaults，重装 hooks 同步
   - 路由：`GET /health`（ok）、`POST /hook`（解析事件，200 OK，fire-and-forget）
   - **容错**：JSON 解析失败返回 400 但不 crash，记录日志；连接异常断开不影响后续请求
3. `ClaudeCodeService`（ObservableObject）：
   - 事件→状态：SessionStart→新 session(idle)，PreToolUse→working，Stop/SessionEnd→idle
   - 多会话：`@Published var sessions: [String: ClaudeState]`
   - 便捷：`@Published var activeSession: ClaudeState?`
   - `@Published var isHookInstalled: Bool`、`@Published var serverRunning: Bool`
   - 超时清理：30 分钟无事件 → idle
4. `ClaudeTab`：
   - 未安装：引导安装按钮 + 说明
   - 已安装：活跃 session 列表（状态圆点 + 工具名 + 耗时）
   - 圆点：idle 灰、working 绿脉冲、waiting 黄
   - 底部：卸载按钮（小字灰色）
5. 构建并运行，安装 hooks 后启动 Claude Code 确认同步
6. Commit: `feat: add Claude Code monitoring service and tab`

---

## Task 9: LauncherService + LauncherTab

**Files:**
- Create: `NotchApp/Services/LauncherService.swift`
- Create: `NotchApp/Tabs/LauncherTab.swift`

**Steps:**

1. `LauncherService`（ObservableObject）：
   - 默认列表：Safari、Xcode、Terminal、Finder、VS Code、音乐、日历、系统设置
   - `NSWorkspace` 获取图标 + 启动应用
   - `@Published var apps: [AppItem]`（完整列表，**从 AppSettings 读取**）
   - `@Published var filteredApps: [AppItem]`（过滤后）
   - `@Published var searchText: String`
   - 应用列表变更写入 AppSettings，不直接写 UserDefaults
   - 方法：`addApp(bundleIdentifier:)`、`removeApp(at:)`（都通过 AppSettings）
2. `LauncherTab`：
   - 顶部：搜索框（TextField + magnifyingglass 图标）
   - 4 列网格：图标（36x36）+ 名称（截断 8 字符）
   - 点击启动 → notch 自动收起
   - 搜索实时过滤
3. 构建并运行，确认搜索和启动
4. Commit: `feat: add app launcher service and tab`

---

## Task 10: 收起状态紧凑徽章

**Files:**
- Create: `NotchApp/Notch/CompactBadge.swift`
- Modify: `NotchApp/Notch/NotchView.swift`

**Steps:**

1. `CompactBadge` 视图：
   - 三种徽章：CC working（绿色脉冲点）、播放中（音符+歌名截断15字）、即将日程（日历+倒计时）
   - 同时最多显示 2 个（按优先级截断）
   - 半透明黑底胶囊，白色文字，圆角 10pt
   - **可点击**：点击徽章直接展开到对应 Tab（CC→ClaudeTab、音乐→MediaTab、日程→CalendarTab）
2. `NotchView` closed 状态渲染徽章：
   - 窗口始终存在（Task 2 的策略），徽章在透明窗口内、notch 右侧渲染
   - 淡入淡出动画
3. 绑定各 Service `@Published` 驱动徽章更新
4. 构建并运行，确认各状态徽章正确显示
5. Commit: `feat: add compact badge for collapsed notch state`

---

## Task 11: 集成 — 启动流程 + 快捷键 + MenuBar

**Files:**
- Modify: `NotchApp/NotchApp.swift`
- Create: `NotchApp/Services/HotkeyService.swift`

**Steps:**

1. 启动流程（`@main` App）：
   - 初始化 `AppSettings`
   - 初始化所有 Service（MediaService、CalendarService、ClaudeCodeService、LauncherService），注入 AppSettings
   - 启动 HookServer
   - 创建 NotchCoordinator，注入 Service 通过 `.environmentObject()`
   - 监听 `didChangeScreenParametersNotification` 重新定位窗口
2. `HotkeyService`（参考 Peninsula `HotKeyObserver`）：
   - 使用 **Carbon `RegisterEventHotKey` API**（不是 `NSEvent.addGlobalMonitor`）
   - `RegisterEventHotKey` 可以真正拦截按键、全局生效（含前台应用）
   - 快捷键根据 `enabledTabs` 动态绑定：
     - `⌥⌘N` — 展开/收起 notch
     - `⌥⌘1` 到 `⌥⌘N`（N = enabledTabs.count）— 展开并切换到对应 Tab
   - 快捷键配置持久化到 AppSettings
3. `MenuBarExtra` 菜单：
   - 动态图标（无事件 `menubar.rectangle`，有 CC 事件 `menubar.rectangle.fill`）
   - "展开 Notch"
   - "Claude Code Hooks: 已安装 ✓" / "安装 Claude Code Hooks..."
   - "偏好设置..." → 打开设置窗口（Task 12）
   - "关于 NotchApp"
   - "退出"
4. Commit: `feat: integrate startup flow, hotkeys, and menu bar`

---

## Task 12: 偏好设置窗口

**Files:**
- Create: `NotchApp/Settings/SettingsWindow.swift`
- Create: `NotchApp/Settings/SettingsView.swift`
- Modify: `NotchApp/Models/AppSettings.swift`（补充快捷键存储）

**Steps:**

1. `SettingsWindow`（NSWindow）：
   - 标准 macOS 设置窗口风格，固定大小（约 450x400）
   - 从 MenuBarExtra "偏好设置..." 菜单项打开
   - 不作为 notch 内 Tab
2. `SettingsView`（SwiftUI，托管在 SettingsWindow 中）：
   - **Tab 管理**：每个 Tab 的显示/隐藏开关（根据 enabledTabs）
   - **默认 Tab**：选择展开 notch 时默认显示哪个 Tab
   - **快捷键**：显示当前绑定，点击重新录制
   - **应用列表**：添加/删除/排序（修改后通过 AppSettings 同步到 LauncherService）
   - **Claude Code**：hooks 安装/卸载按钮 + 当前状态
3. 所有修改写入 AppSettings，Service 通过绑定自动更新
4. Commit: `feat: add preferences settings window`

---

## Task 13: 打磨动画 + 边缘情况

**Steps:**

1. 动画调优（参考 Peninsula）：
   - outer: `interactiveSpring(duration: 0.314)`
   - inner: `interactiveSpring(duration: 0.314).delay(0.157)`
   - 收起: `spring(duration: 0.236)`
2. 触觉反馈：pop/open 时 `NSHapticFeedbackManager`
3. 窗口失焦收起：`resignFirstResponder` → `notchClose()`
4. 外接显示器切换：重建窗口
5. 全屏应用：检测全屏空间，隐藏 notch 窗口
6. Commit: `feat: polish animations and edge cases`
