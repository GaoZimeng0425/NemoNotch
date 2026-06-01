# NemoNotch --uitest 自驱动截图 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 NemoNotch 加一个 `--uitest` 自驱动模式 —— 启动即用确定性 mock 数据填满 6 个 Tab、自动展开刘海面板并常驻,配套一个脚本逐 Tab `screencapture` 出营销级截图,然后用新图更新 README/README_CN 并修正过时内容。

**Architecture:** 单一服务装配路径 + 运行时 `UITestMode.isActive` 守卫。AppDelegate 在 uitest 下跳过所有实时副作用(HookServer/WebSocket/HTTP/perl 媒体守护/轮询/网络),调用 `UITestSeeder` 把各 `@Observable` service 的状态填成好看的活跃态,再程序化 `notchOpen` 并禁用 `EventMonitor` 让面板常驻;同时把面板的截取矩形写到 `/tmp/nemonotch-uitest.rect`。脚本退出用户的运行实例 → Debug 构建 → 逐 tab 启动并按矩形截图 → 恢复运行实例。

**Tech Stack:** Swift 6 / SwiftUI / AppKit、`ProcessInfo.arguments`、`screencapture`、Swift Testing(纯逻辑单测)、bash + osascript(脚本与等待)。

**前置:** 已在分支 `feature/uitest-screenshots`。spec 见 `docs/superpowers/specs/2026-06-01-uitest-screenshots-design.md`。

**关键事实(实现时直接用,无需再查):**
- `Tab` enum rawValue:`overview / claude / agents / launcher / pomodoro / system`(`NemoNotch/Models/Tab.swift`)。
- 服务装配在 `NemoNotch/NemoNotchApp.swift` `applicationDidFinishLaunching`(局部变量 `settings, media, permissionMonitor, calendar, aiMonitor, launcher, openClaw, hermes, registry, weather, hud, system, tasks, history, pomodoro, notificationPermission, notchCoordinator`)。
- `MediaService.init()`(`Services/MediaService.swift:44`)调用 `remote.registerForNotifications(); setupNotifications(); startPolling(); updateNowPlaying()`。`var playbackState = PlaybackState()`。
- `PlaybackState`(`Models/PlaybackState.swift`):`title/artist/album:String`、`duration/position:TimeInterval`、`isPlaying:Bool`、`artworkData:Data?`、`appName/appBundleIdentifier:String?`。
- `CalendarService`(`Services/CalendarService.swift`):`var todayEvents:[CalendarEvent]`、`var nextEvent:CalendarEvent?`、`var authorizationStatus:EKAuthorizationStatus`、`var selectedDate:Date`、`private(set) var multiDayEvents:[Date:[CalendarEvent]]`。`startOfDay` 用 `Calendar.current.startOfDay`。
- `CalendarEvent.init(title:startDate:endDate:calendarColor:isAllDay:url:location:notes:)`,`calendarColor:CGColor`。
- `WeatherService`(`Services/WeatherService.swift`):`var temperature/feelsLike/highTemp/lowTemp/windSpeed:Double`、`humidity:Int`、`condition/cityName:String`、`hourlyForecast:[(time:String,temp:Double,icon:String)]`、`isLoaded:Bool`。`setActive(_:)` 才起网络/定时器。
- `SystemService`(`Services/SystemService.swift`):`var topProcessesByCPU/topProcessesByMemory:[ProcessEntry]`、`cpuUsage:Double`、`memoryUsed/memoryTotal:UInt64`、`batteryLevel:Int`、`isCharging:Bool`。`init()` 调一次 `update()`;`setActive(true)` 才轮询。
- `ProcessEntry(id:Int32, displayName:String, icon:NSImage?, cpuUsage:Double, memoryUsed:UInt64)`。
- `AICLIMonitorService`(`Services/AICLIMonitorService.swift`):`let store:AISessionStore`,`startServer()` 才起 HookServer;`var activeSession {store.activeSession}`。
- `AISessionStore`(`Services/AISessionStore.swift`):`func upsert(_:)`、`func mutateOrCreate(_:source:_:)`、`func removeAll(source:)`、`var selectedSessionId`。
- `AISessionState(sessionId:source:)`,字段含 `phase/currentTool/cwd/lastMessage/firstUserMessage/lastUserMessage/messages/inputTokens/outputTokens/cacheReadTokens/cacheCreationTokens/lastContextTokens/model`;`mutating func upsertMessage(_:)`;`phase` 类型 `SessionPhase`(`.processing` 表示 working)。
- `ChatMessage(id:role:content:toolName:toolInput:timestamp:)`,`role:ChatMessageRole(.user/.assistant/.thought/.tool/.toolResult/.system)`。
- `AgentMonitorRegistry`(`Services/AgentMonitorRegistry.swift`):`func register(_ monitor: any MultiAgentMonitor)`、`var installedMonitors {monitors.filter(\.isInstalled)}`。
- `MultiAgentMonitor`(`Models/MultiAgentMonitor.swift`)需:`var agents:[String:MonitoredAgent]`、`var activeAgent:MonitoredAgent?`、`isOnline/isInstalled:Bool`、`displayName/iconEmoji:String`、`iconAssetName:String?`(默认 nil)、`sessionMessages:[String:[ChatMessage]]`(默认 [:])、`connect()/disconnect()`。
- `MonitoredAgent(id:name:emoji:iconAssetName:state:currentTool:lastMessage:workspace:lastEventTime:)`,`state:AgentMonitorState(.working/.toolCalling/.speaking/.idle/.error)`。
- `AgentMonitorRenderDecision.decide(hasOnlineMonitor:true,…)` → `.agentSections`(`Helpers/AgentMonitorRenderDecision.swift:47`),其余参数不影响。`agentSections` 渲染 `registry.installedMonitors.filter(\.isOnline)`,显示名含 "Hermes"/"OpenClaw" 会套对应配色(`Tabs/AgentMonitorTab.swift`)。
- `PomodoroTimerService`(`Services/PomodoroTimerService.swift`):`func start(taskID:UUID?, duration:TimeInterval, autoFlow:Bool)` → `.running`,起 1s tick;`private(set) var state`。
- `TaskStore(fileURL:)`(`Services/TaskStore.swift`)可注入路径;`func add(title:priority:notes:tags:dueDate:)->UUID`、`func update(_:_:)`(可改 `completedPomodoros`)。`TodoTask.Priority(.low/.medium/.high)`。
- `NotchCoordinator`(`Notch/NotchCoordinator.swift`):`init` 第 88 行 `setupEventMonitoring()`;`func notchOpen(tab:Tab?=nil, on:NSScreen?=nil, viaHotkey:Bool=false)`;`var status`、`var selectedTab`;`var openedWidth`(overview=700 否则 560);`NotchConstants.openedHeight=328`。
- 内建刘海屏判定:`NSScreen` 有 `isBuiltInDisplay` 与 `hasNotch`(见 `resolveUnifiedNotchSize`)。

---

## File Structure

- **新增** `NemoNotch/Helpers/UITestMode.swift` —— 解析 `--uitest` / `--tab=`,纯逻辑、可单测。
- **新增** `NemoNotch/Helpers/UITestMockAgentMonitor.swift` —— mock `MultiAgentMonitor`。
- **新增** `NemoNotch/Helpers/UITestSeeder.swift` —— 接住各 service 灌入 6 Tab mock;含示例封面图生成 + 截取矩形写盘。
- **改** `NemoNotch/Services/MediaService.swift` —— `init(disableLiveUpdates:)` 开关。
- **改** `NemoNotch/Services/CalendarService.swift` —— `seedForUITest(events:)`。
- **改** `NemoNotch/Notch/NotchCoordinator.swift` —— uitest 下跳过 `setupEventMonitoring()`。
- **改** `NemoNotch/NemoNotchApp.swift` —— uitest 分支:副作用门控 + 调 seeder + 程序化 `notchOpen`。
- **新增** `NemoNotchTests/UITestModeTests.swift` —— 参数解析单测。
- **新增** `scripts/uitest-screenshots.sh` —— 截图编排。
- **改** `README.md` / `README_CN.md` / `docs/macos-cookbook.md` / `CLAUDE.md` —— 文档。

> 注:`Helpers/`、`Services/` 等为 Xcode 16 自动同步根组,新增 `.swift` 文件**直接写盘即可**被编入,**不要**改 `project.pbxproj`(见项目记忆 Xcode-16-File-Sync)。

---

## Task 1: `UITestMode` 参数解析(纯逻辑 + 单测)

**Files:**
- Create: `NemoNotch/Helpers/UITestMode.swift`
- Test: `NemoNotchTests/UITestModeTests.swift`

- [ ] **Step 1: 写失败测试**

`NemoNotchTests/UITestModeTests.swift`:

```swift
import Testing
@testable import NemoNotch

@Suite("UITestMode")
struct UITestModeTests {
    @Test("无 --uitest 时 isActive 为 false")
    func inactive() {
        #expect(UITestMode.isActive(in: ["NemoNotch"]) == false)
    }

    @Test("有 --uitest 时 isActive 为 true")
    func active() {
        #expect(UITestMode.isActive(in: ["NemoNotch", "--uitest"]) == true)
    }

    @Test("缺省 tab 为 .overview")
    func defaultTab() {
        #expect(UITestMode.tab(in: ["--uitest"]) == .overview)
    }

    @Test("--tab=claude 解析为 .claude")
    func parsedTab() {
        #expect(UITestMode.tab(in: ["--uitest", "--tab=claude"]) == .claude)
    }

    @Test("非法 tab 回落 .overview")
    func invalidTab() {
        #expect(UITestMode.tab(in: ["--tab=nope"]) == .overview)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UITestModeTests 2>&1 | tail -20`
Expected: 编译失败(`UITestMode` 未定义)。

- [ ] **Step 3: 写实现**

`NemoNotch/Helpers/UITestMode.swift`:

```swift
import Foundation

/// 启动参数驱动的 UI 测试/截图模式。
/// `--uitest` 打开;`--tab=<rawValue>` 指定首屏 Tab(缺省 overview)。
enum UITestMode {
    static func isActive(in args: [String]) -> Bool {
        args.contains("--uitest")
    }

    static func tab(in args: [String]) -> Tab {
        guard let raw = args.first(where: { $0.hasPrefix("--tab=") })?
            .dropFirst("--tab=".count) else { return .overview }
        return Tab(rawValue: String(raw)) ?? .overview
    }

    /// 截图矩形落盘路径,供脚本读取后 screencapture。
    static let rectFilePath = "/tmp/nemonotch-uitest.rect"

    // 运行时便捷入口(读真实进程参数)。
    static var isActive: Bool { isActive(in: ProcessInfo.processInfo.arguments) }
    static var tab: Tab { tab(in: ProcessInfo.processInfo.arguments) }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UITestModeTests 2>&1 | tail -20`
Expected: `Test Suite 'UITestMode' passed`,5 个 `@Test` 全过。

- [ ] **Step 5: 提交**

```bash
git add NemoNotch/Helpers/UITestMode.swift NemoNotchTests/UITestModeTests.swift
git commit -m "feat(uitest): UITestMode arg parser (--uitest/--tab)"
```

---

## Task 2: `MediaService` 增加 `disableLiveUpdates` 开关

**Files:**
- Modify: `NemoNotch/Services/MediaService.swift:44`(init)

- [ ] **Step 1: 改 init 签名 + 门控副作用**

把 `MediaService.swift:44` 起的 `init()` 改为:

```swift
    init(disableLiveUpdates: Bool = false) {
        remote.registerForNotifications()
        remote.setCanBeNowPlayingApplication(false)
        MediaBridge.permissionDeniedCallback = { [weak self] bundleID in
            self?.permissionDeniedHandler?(bundleID)
        }
        guard !disableLiveUpdates else {
            LogService.info("MediaService init (uitest: live updates disabled)", category: "MediaService")
            return
        }
        setupNotifications()
        startPolling()
        updateNowPlaying()
    }
```

- [ ] **Step 2: 编译确认无破坏(默认参数,旧调用不变)**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: 提交**

```bash
git add NemoNotch/Services/MediaService.swift
git commit -m "feat(uitest): MediaService disableLiveUpdates flag to skip daemon/polling"
```

---

## Task 3: `CalendarService.seedForUITest`

**Files:**
- Modify: `NemoNotch/Services/CalendarService.swift`(末尾加方法)

- [ ] **Step 1: 加 seed 方法**

在 `CalendarService` 类内(`fetchEvents()` 之后、闭合 `}` 之前)加:

```swift
    /// UI 测试种子:直接写入授权态与多日事件,绕过 EventKit。
    func seedForUITest(events: [Date: [CalendarEvent]]) {
        authorizationStatus = .fullAccess
        multiDayEvents = events
        let todayKey = startOfDay(for: Date())
        todayEvents = (events[todayKey] ?? []).sorted { $0.startDate < $1.startDate }
        nextEvent = todayEvents.first { !$0.isPast }
        selectedDate = Date()
    }
```

- [ ] **Step 2: 编译确认**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: 提交**

```bash
git add NemoNotch/Services/CalendarService.swift
git commit -m "feat(uitest): CalendarService.seedForUITest"
```

---

## Task 4: mock `MultiAgentMonitor`

**Files:**
- Create: `NemoNotch/Helpers/UITestMockAgentMonitor.swift`

- [ ] **Step 1: 写实现**

```swift
import Foundation

/// UI 测试用的假 agent monitor:isInstalled+isOnline 恒为 true,
/// agents 由构造时注入。注册进 AgentMonitorRegistry 后即渲染 agentSections。
@MainActor
@Observable
final class UITestMockAgentMonitor: MultiAgentMonitor {
    let displayName: String
    let iconEmoji: String
    private(set) var agents: [String: MonitoredAgent]

    init(displayName: String, iconEmoji: String, agents: [MonitoredAgent]) {
        self.displayName = displayName
        self.iconEmoji = iconEmoji
        self.agents = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
    }

    var activeAgent: MonitoredAgent? {
        agents.values.first { $0.state != .idle }
    }

    var isOnline: Bool { true }
    var isInstalled: Bool { true }

    func connect() {}
    func disconnect() {}
}
```

- [ ] **Step 2: 编译确认(协议一致性)**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`(若报缺成员,核对 `MultiAgentMonitor` 协议默认实现 `iconAssetName`/`sessionMessages` 是否覆盖到 —— 默认 extension 已提供,无需在 mock 内实现)。

- [ ] **Step 3: 提交**

```bash
git add NemoNotch/Helpers/UITestMockAgentMonitor.swift
git commit -m "feat(uitest): mock MultiAgentMonitor for Agents tab"
```

---

## Task 5: `NotchCoordinator` 在 uitest 下跳过事件监听(面板常驻)

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift:88`

- [ ] **Step 1: 门控 setupEventMonitoring**

把 `init` 内第 88 行:

```swift
        setupEventMonitoring()
```

改为:

```swift
        // uitest 下不装鼠标事件监听:程序化 notchOpen 后面板需常驻供截图,
        // 否则鼠标在内容区外会触发 HotkeyDismissState.shouldClose 立刻收起。
        if !UITestMode.isActive {
            setupEventMonitoring()
        }
```

- [ ] **Step 2: 编译确认**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: 提交**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift
git commit -m "feat(uitest): keep notch panel open by skipping EventMonitor under --uitest"
```

---

## Task 6: `UITestSeeder` —— 6 Tab mock + 封面图 + 矩形落盘

**Files:**
- Create: `NemoNotch/Helpers/UITestSeeder.swift`

- [ ] **Step 1: 写实现**

```swift
import AppKit
import EventKit
import Foundation

/// UI 测试/截图模式下,把各 @Observable service 填成营销级活跃态。
/// 仅在 `UITestMode.isActive` 时由 AppDelegate 调用。
@MainActor
enum UITestSeeder {
    /// 临时 tasks 文件,避免污染 ~/.NemoNotch/tasks.json。
    static let tasksURL = URL(fileURLWithPath: "/tmp/nemonotch-uitest-tasks.json")

    static func seed(
        media: MediaService,
        calendar: CalendarService,
        weather: WeatherService,
        system: SystemService,
        aiStore: AISessionStore,
        registry: AgentMonitorRegistry,
        pomodoro: PomodoroTimerService,
        tasks: TaskStore
    ) {
        seedMedia(media)
        seedCalendar(calendar)
        seedWeather(weather)
        seedSystem(system)
        seedAI(aiStore)
        seedAgents(registry)
        seedPomodoro(pomodoro, tasks: tasks)
    }

    // MARK: - Overview: media + calendar + weather

    private static func seedMedia(_ media: MediaService) {
        var s = PlaybackState()
        s.title = "Midnight City"
        s.artist = "M83"
        s.album = "Hurry Up, We're Dreaming"
        s.duration = 244
        s.position = 96
        s.isPlaying = true
        s.appName = "Music"
        s.appBundleIdentifier = "com.apple.Music"
        s.artworkData = makeArtwork(top: NSColor(red: 0.42, green: 0.20, blue: 0.62, alpha: 1),
                                     bottom: NSColor(red: 0.95, green: 0.35, blue: 0.45, alpha: 1),
                                     glyph: "♪")
        media.playbackState = s
    }

    private static func seedCalendar(_ calendar: CalendarService) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        }
        let blue = NSColor.systemBlue.cgColor
        let green = NSColor.systemGreen.cgColor
        let orange = NSColor.systemOrange.cgColor
        let events: [CalendarEvent] = [
            CalendarEvent(title: "Standup", startDate: at(10, 0), endDate: at(10, 15),
                          calendarColor: blue, isAllDay: false,
                          url: URL(string: "https://meet.google.com/abc-defg-hij")),
            CalendarEvent(title: "Design Review", startDate: at(14, 0), endDate: at(15, 0),
                          calendarColor: green, isAllDay: false),
            CalendarEvent(title: "1:1 with Alex", startDate: at(16, 30), endDate: at(17, 0),
                          calendarColor: orange, isAllDay: false),
        ]
        var multi: [Date: [CalendarEvent]] = [today: events]
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: today) {
            multi[tomorrow] = [
                CalendarEvent(title: "Sprint Planning", startDate: tomorrow, endDate: tomorrow,
                              calendarColor: blue, isAllDay: true),
            ]
        }
        calendar.seedForUITest(events: multi)
    }

    private static func seedWeather(_ weather: WeatherService) {
        weather.cityName = "San Francisco"
        weather.condition = "Partly Cloudy"
        weather.temperature = 21
        weather.feelsLike = 20
        weather.highTemp = 24
        weather.lowTemp = 15
        weather.humidity = 62
        weather.windSpeed = 12
        weather.hourlyForecast = [
            ("15:00", 22, "Sunny"),
            ("16:00", 21, "Partly Cloudy"),
            ("17:00", 19, "Cloudy"),
        ]
        weather.isLoaded = true
    }

    // MARK: - System

    private static func seedSystem(_ system: SystemService) {
        func icon(_ bundleID: String) -> NSImage? {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let procs: [ProcessEntry] = [
            ProcessEntry(id: 101, displayName: "Xcode", icon: icon("com.apple.dt.Xcode"),
                         cpuUsage: 184.2, memoryUsed: 4_820_000_000),
            ProcessEntry(id: 102, displayName: "Google Chrome", icon: icon("com.google.Chrome"),
                         cpuUsage: 62.5, memoryUsed: 2_140_000_000),
            ProcessEntry(id: 103, displayName: "Figma", icon: icon("com.figma.Desktop"),
                         cpuUsage: 38.1, memoryUsed: 1_360_000_000),
            ProcessEntry(id: 104, displayName: "Slack", icon: icon("com.tinyspeck.slackmacgap"),
                         cpuUsage: 12.7, memoryUsed: 880_000_000),
            ProcessEntry(id: 105, displayName: "Terminal", icon: icon("com.apple.Terminal"),
                         cpuUsage: 6.3, memoryUsed: 210_000_000),
        ]
        system.topProcessesByCPU = procs
        system.topProcessesByMemory = procs.sorted { $0.memoryUsed > $1.memoryUsed }
        system.cpuUsage = 42
        system.memoryTotal = 16_000_000_000
        system.memoryUsed = 11_200_000_000
        system.batteryLevel = 76
        system.isCharging = true
    }

    // MARK: - AI Chat

    private static func seedAI(_ store: AISessionStore) {
        // 清掉真实扫描到的会话,确保种子会话成为 activeSession。
        store.removeAll(source: .claude)
        store.removeAll(source: .gemini)

        let sid = "uitest-claude-session"
        store.mutateOrCreate(sid, source: .claude) { s in
            s.cwd = "/Users/dev/Projects/NemoNotch"
            s.model = "claude-opus-4-8"
            s.phase = .processing
            s.firstUserMessage = "Add a pomodoro timer to the notch panel"
            s.lastUserMessage = "Add a pomodoro timer to the notch panel"
            s.inputTokens = 18_400
            s.outputTokens = 6_220
            s.cacheReadTokens = 142_000
            s.cacheCreationTokens = 9_800
            s.lastContextTokens = 96_500
            s.currentTool = "Edit"
            s.messages = [
                ChatMessage(id: "m1", role: .user,
                            content: "Add a pomodoro timer to the notch panel"),
                ChatMessage(id: "m2", role: .assistant,
                            content: "I'll add a PomodoroTimerService with a 25/5/15 cycle and wire it into a new tab."),
                ChatMessage(id: "m3", role: .assistant, content: "",
                            toolName: "Edit", toolInput: "NemoNotch/Services/PomodoroTimerService.swift"),
                ChatMessage(id: "m4", role: .toolResult, content: "Applied 1 edit to PomodoroTimerService.swift"),
                ChatMessage(id: "m5", role: .assistant,
                            content: "Done. The timer ticks every second and pulses the notch ring on phase end."),
            ]
        }
        store.selectedSessionId = sid
    }

    // MARK: - Agents

    private static func seedAgents(_ registry: AgentMonitorRegistry) {
        let hermes = UITestMockAgentMonitor(
            displayName: "Hermes",
            iconEmoji: "🪽",
            agents: [
                MonitoredAgent(id: "h1", name: "researcher", emoji: "🔎",
                               state: .working, currentTool: "WebSearch",
                               lastMessage: "Comparing 3 charting libraries…",
                               workspace: "/Users/dev/Projects/dashboard",
                               lastEventTime: Date().addingTimeInterval(-30)),
                MonitoredAgent(id: "h2", name: "writer", emoji: "✍️",
                               state: .speaking,
                               lastMessage: "Drafting the migration guide section 2.",
                               workspace: "/Users/dev/Projects/docs",
                               lastEventTime: Date().addingTimeInterval(-90)),
            ]
        )
        let openClaw = UITestMockAgentMonitor(
            displayName: "OpenClaw",
            iconEmoji: "🦞",
            agents: [
                MonitoredAgent(id: "o1", name: "builder", emoji: "🔨",
                               state: .toolCalling, currentTool: "Bash",
                               lastMessage: "Running the test suite…",
                               workspace: "/Users/dev/Projects/api",
                               lastEventTime: Date().addingTimeInterval(-12)),
            ]
        )
        registry.register(hermes)
        registry.register(openClaw)
    }

    // MARK: - Pomodoro

    private static func seedPomodoro(_ pomodoro: PomodoroTimerService, tasks: TaskStore) {
        let t1 = tasks.add(title: "Ship uitest screenshots", priority: .high,
                           notes: "", tags: ["nemonotch"], dueDate: nil)
        tasks.update(t1) { $0.completedPomodoros = 3 }
        let t2 = tasks.add(title: "Update README", priority: .medium,
                           notes: "", tags: ["docs"], dueDate: nil)
        tasks.update(t2) { $0.completedPomodoros = 1 }
        let t3 = tasks.add(title: "Review PR #42", priority: .low,
                           notes: "", tags: [], dueDate: nil)
        tasks.update(t3) { $0.completedPomodoros = 0 }
        // 进行中的工作番茄,active pie 立即可见。
        pomodoro.start(taskID: t1, duration: 25 * 60, autoFlow: false)
    }

    // MARK: - 截图矩形落盘(供脚本读取)

    /// 把指定屏上、给定 Tab 的面板内容矩形写到 rectFilePath,
    /// 坐标为 screencapture 习惯(原点=主屏左上,y 向下),单位点。
    static func writeCaptureRect(for tab: Tab, on screen: NSScreen) {
        let width: CGFloat = (tab == .overview) ? NotchConstants.overviewOpenedWidth : NotchConstants.openedWidth
        let height: CGFloat = NotchConstants.openedHeight + 8
        let x = screen.frame.midX - width / 2
        let y: CGFloat = 0 // 面板从刘海顶端下垂,内容顶 = 屏顶
        let line = "\(Int(x)) \(Int(y)) \(Int(width)) \(Int(height))\n"
        try? line.write(toFile: UITestMode.rectFilePath, atomically: true, encoding: .utf8)
    }

    // MARK: - 示例封面图(纯绘制,无版权素材)

    private static func makeArtwork(top: NSColor, bottom: NSColor, glyph: String) -> Data? {
        let size = NSSize(width: 300, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(starting: top, ending: bottom)
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -45)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 150, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: glyph, attributes: attrs)
        let textSize = str.size()
        str.draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                             y: (size.height - textSize.height) / 2))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
```

- [ ] **Step 2: 编译确认**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`。若报字段不匹配,以本文件顶部「关键事实」的真实签名为准修正。

- [ ] **Step 3: 提交**

```bash
git add NemoNotch/Helpers/UITestSeeder.swift
git commit -m "feat(uitest): UITestSeeder seeds all 6 tabs + capture rect + artwork"
```

---

## Task 7: AppDelegate uitest 分支(门控副作用 + seed + 程序化打开)

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`(`applicationDidFinishLaunching`)

- [ ] **Step 1: 门控会起副作用的构造/调用**

在 `applicationDidFinishLaunching` 内逐处改(行号以当前文件为准,按内容定位):

1. `let media = MediaService()` → `let media = MediaService(disableLiveUpdates: UITestMode.isActive)`
2. `permissionMonitor.startProbing()` → `if !UITestMode.isActive { permissionMonitor.startProbing() }`
3. `aiMonitor.startServer()` → `if !UITestMode.isActive { aiMonitor.startServer() }`
4. `openClaw.connect()` → `if !UITestMode.isActive { openClaw.connect() }`
5. `hermes.connect()` → `if !UITestMode.isActive { hermes.connect() }`
6. `let tasks = TaskStore()` → `let tasks = TaskStore(fileURL: UITestMode.isActive ? UITestSeeder.tasksURL : TaskStore.defaultURL)`
7. weather 那段:
   ```swift
   if !settings.weatherCity.isEmpty {
       weather.updateCity(settings.weatherCity)
   }
   ```
   → 改为
   ```swift
   if !UITestMode.isActive, !settings.weatherCity.isEmpty {
       weather.updateCity(settings.weatherCity)
   }
   ```

- [ ] **Step 2: 在 setupHotkeys 之后插入 uitest 启动块**

`setupHotkeys(coordinator: notchCoordinator)` 之后(`applicationDidFinishLaunching` 闭合前)插入:

```swift
        if UITestMode.isActive {
            UITestSeeder.seed(
                media: media,
                calendar: calendar,
                weather: weather,
                system: system,
                aiStore: aiMonitor.store,
                registry: registry,
                pomodoro: pomodoro,
                tasks: tasks
            )
            let target = NSScreen.screens.first(where: { $0.isBuiltInDisplay && $0.hasNotch })
                ?? NSScreen.main
            let tab = UITestMode.tab
            if let target {
                UITestSeeder.writeCaptureRect(for: tab, on: target)
            }
            NSApp.activate(ignoringOtherApps: true)
            notchCoordinator.notchOpen(tab: tab, on: target)
        }
```

- [ ] **Step 3: 编译确认**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: 手动冒烟(单 Tab,人眼确认)**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*/Build/Products/Debug/NemoNotch.app' -maxdepth 6 2>/dev/null | head -1)
# 退出已装实例避免叠影
osascript -e 'tell application "NemoNotch" to quit' 2>/dev/null; pkill -x NemoNotch 2>/dev/null
"$APP/Contents/MacOS/NemoNotch" --uitest --tab=claude &
PID=$!
osascript -e 'delay 1.5'
cat /tmp/nemonotch-uitest.rect
RECT=$(tr ' ' ',' < /tmp/nemonotch-uitest.rect)
screencapture -x -R"$RECT" /tmp/smoke-claude.png
kill $PID 2>/dev/null
echo "wrote /tmp/smoke-claude.png"
```

用 Read 工具查看 `/tmp/smoke-claude.png`:Expected — 面板展开在 AI Chat,显示种子的 Claude 会话(消息列表 + token 条 + 模型名),非空、非权限卡。若面板没展开或开错屏,核对 `target` 选屏逻辑与 Task 5 的 EventMonitor 门控。

- [ ] **Step 5: 提交**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "feat(uitest): AppDelegate --uitest branch — suppress side-effects, seed, auto-open"
```

---

## Task 8: 截图编排脚本

**Files:**
- Create: `scripts/uitest-screenshots.sh`

- [ ] **Step 1: 写脚本**

`scripts/uitest-screenshots.sh`:

```bash
#!/usr/bin/env bash
# 自驱动截取 NemoNotch 全部 6 个 Tab 的面板截图到 docs/images/。
# 用法: ./scripts/uitest-screenshots.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/docs/images"
RECT_FILE="/tmp/nemonotch-uitest.rect"
DERIVED="$ROOT/build/uitest"
APP="$DERIVED/Build/Products/Debug/NemoNotch.app"
TABS=(overview claude agents launcher pomodoro system)

mkdir -p "$OUT_DIR"

wait_for() { osascript -e "delay $1"; }  # 用 osascript 而非 shell sleep

echo "==> 退出当前运行实例(截完恢复)"
WAS_RUNNING=0
if pgrep -x NemoNotch >/dev/null; then WAS_RUNNING=1; fi
osascript -e 'tell application "NemoNotch" to quit' 2>/dev/null || true
pkill -x NemoNotch 2>/dev/null || true
wait_for 1

echo "==> Debug 构建"
xcodebuild build \
  -project "$ROOT/NemoNotch.xcodeproj" \
  -scheme NemoNotch \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" >/dev/null
test -d "$APP" || { echo "构建产物未找到: $APP"; exit 1; }

for tab in "${TABS[@]}"; do
  echo "==> 截图 $tab"
  rm -f "$RECT_FILE"
  "$APP/Contents/MacOS/NemoNotch" --uitest --tab="$tab" &
  PID=$!
  wait_for 1.6   # 等开屏 + 内容渲染
  test -f "$RECT_FILE" || { echo "未拿到矩形文件,$tab 跳过"; kill "$PID" 2>/dev/null || true; continue; }
  RECT=$(tr ' ' ',' < "$RECT_FILE" | tr -d '\n')
  screencapture -x -R"$RECT" "$OUT_DIR/tab-$tab.png"
  kill "$PID" 2>/dev/null || true
  wait_for 0.4
done

echo "==> 恢复用户的运行实例"
if [ "$WAS_RUNNING" -eq 1 ]; then
  open -a NemoNotch 2>/dev/null || open "/Applications/NemoNotch.app" 2>/dev/null || true
fi

echo "完成。输出:"
ls -la "$OUT_DIR"/tab-*.png
```

- [ ] **Step 2: 赋可执行权限**

Run: `chmod +x scripts/uitest-screenshots.sh && echo ok`
Expected: `ok`。

- [ ] **Step 3: 运行脚本出全量截图**

Run: `./scripts/uitest-screenshots.sh 2>&1 | tail -20`
Expected: 末尾列出 `tab-overview.png … tab-system.png` 共 6 个文件,各 > 100KB。

- [ ] **Step 4: 人眼逐张确认**

用 Read 工具依次查看 `docs/images/tab-{overview,claude,agents,launcher,pomodoro,system}.png`:
- overview:正在播放的歌 + 封面 + 日历事件 + 天气
- claude:Claude 会话消息 + token 条 + 模型
- agents:Hermes/OpenClaw 两组活跃 agent
- launcher:应用格子(真实已装应用即可)
- pomodoro:进行中饼 + TODO 列表(每项番茄数)
- system:Top 进程排行 + CPU/RAM/电量

任一不对(空白/权限卡/开错屏/裁切偏移),回到对应 Task(seed 或 rect)修。**裁切偏移**:微调 `UITestSeeder.writeCaptureRect` 的 height/y 或确认 target 是内建屏。

- [ ] **Step 5: 提交脚本与图片**

```bash
git add scripts/uitest-screenshots.sh docs/images/tab-*.png
git commit -m "feat(uitest): screenshot orchestration script + generated tab screenshots"
```

---

## Task 9: 更新文档

**Files:**
- Modify: `README.md`、`README_CN.md`、`docs/macos-cookbook.md`、`CLAUDE.md`

- [ ] **Step 1: README.md 换图 + 修正过时内容**

- 顶部两张 hero 图(`docs/images/nemo-notch.png` / `nemo-notch-2.png`)替换为 6 张新图的展示(可用表格或并排 `<img>`,引用 `docs/images/tab-*.png`)。
- "8 Functional Tabs" → "6 Functional Tabs";表格删掉独立的 Media / Calendar / Weather 行,改为 **Overview**(Media + Calendar + Weather 合并)一行;保留 AI Chat / Agents / Launcher / Pomodoro / System。
- Tech Stack 里 `Swift 5` → `Swift 6`。

- [ ] **Step 2: README_CN.md 同步**

按 README.md 的同样改动镜像到中文版(换图、6 Tab、Overview 合并、Swift 6)。

- [ ] **Step 3: macos-cookbook.md 补技术点**

在合适小节(如「12) IPC & subprocess」或新增「截图/自动化」条目)加一条:`--uitest` 自驱动截图技术 —— 运行时 `UITestMode.isActive` 门控副作用、`UITestSeeder` 注入 @Observable 状态、`NotchCoordinator` 跳过 EventMonitor 常驻面板、矩形落盘 + `screencapture -R`,锚到 `NemoNotch/Helpers/UITestSeeder.swift` 与 `scripts/uitest-screenshots.sh`。

- [ ] **Step 4: CLAUDE.md 小修**

若 CLAUDE.md 有 Tab 数量/结构描述,核对并保持与「6 Tab + Overview 合并」一致(当前 CLAUDE.md 已大体准确,按需微调即可)。

- [ ] **Step 5: 提交**

```bash
git add README.md README_CN.md docs/macos-cookbook.md CLAUDE.md
git commit -m "docs: refresh README/README_CN with --uitest screenshots; fix stale tab list"
```

---

## Self-Review(写完后核对)

**Spec 覆盖:**
- §1 `--uitest` 模式 → Task 1 + Task 7 ✓
- §2 副作用抑制 → Task 2(Media)+ Task 7(门控 startServer/connect/probing/weather/tasks 路径)✓
- §3 mock 种子层 → Task 3/4/6 ✓
- §4 截图脚本 → Task 8 ✓
- §5 文档更新 → Task 9 ✓
- 面板常驻(spec 风险项)→ Task 5 ✓

**占位扫描:** 无 TBD/TODO;每个代码步骤均给出完整代码。

**类型一致性:** `UITestMode.isActive(in:)/tab(in:)` 与运行时 `isActive/tab` 一致;`UITestSeeder.seed(...)` 参数 = Task 7 传入的 `aiMonitor.store/registry/...`;`writeCaptureRect(for:on:)`、`tasksURL`、`rectFilePath` 在 Task 6/7/8 一致;mock 监视器满足 `MultiAgentMonitor` 全部成员(`iconAssetName`/`sessionMessages` 用协议默认实现)。

**潜在执行注意:**
- `Tab` 是否已 `RawRepresentable`(rawValue 解析)—— 是(`enum Tab: String`)。
- `NSScreen.isBuiltInDisplay`/`hasNotch` 为项目内既有扩展(`NotchCoordinator.resolveUnifiedNotchSize` 已用)。
- 脚本所有等待用 `osascript delay`,不用 shell `sleep`。
