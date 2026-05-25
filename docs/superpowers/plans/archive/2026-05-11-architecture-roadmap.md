# NemoNotch 架构演进路线图

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. 路线图覆盖 A–E 五个方向，本轮立即执行 **A + C**（C 先做，作为 A 的基础设施）。B/D/E 仅列出意图，留待后续单独拆 plan。

**总目标：** 把当前以 Service 为粒度的单体架构，演进为可扩展的"协议 + 共享存储"架构，为新 AI provider、多屏支持、配置面板重做和会话历史持久化打地基。

**Tech Stack：** Swift 6 + SwiftUI + `@Observable`，遵循项目既有 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 约定，无新依赖。

---

## 路线全景

| 方向 | 类型 | 优先级 | 状态 |
|---|---|---|---|
| A. AISessionStore + 多 provider 重构 | 大重构 | P0 | **本轮执行** |
| C. Service 生命周期协议 | 中重构 | P0（A 的前置） | **本轮执行** |
| B. 多屏幕支持 | 新功能 | P1 | 已有 spec（cb9838d），后续拆 plan |
| D. 配置面板重做 + 主题系统 | 新功能 + 中重构 | P2 | 路线图占位 |
| E. AI 会话搜索 + 历史持久化 | 新功能 | P2（依赖 A） | 路线图占位 |

执行顺序：**C → A → B → E → D**。C 是 A 的副产品式前置；B 独立；E 重度依赖 A 的 store；D 最后做避免重构期间频繁改 settings UI。

---

## C. Service 生命周期协议（本轮第一阶段）

**Goal：** 把"刘海/Tab 可见时才轮询、不可见就停"这个模式提取为协议，让 SystemService、WeatherService、CalendarService(refresh)、NotificationService 统一遵守，而不是每个服务各自定义 `setActive`/`startPolling`/`stopPolling`。

**Architecture：**

```swift
@MainActor protocol LifecycleAware: AnyObject {
    /// active=true 时启动轮询/订阅；false 时停止以释放资源。
    /// 调用是幂等的——重复 setActive(true) 不应重复启动。
    func setActive(_ active: Bool)
}
```

配套一个 `View` 修饰符，把 onAppear/onDisappear 包起来，调用方一行搞定。

**Files：**
- 新建：`NemoNotch/Helpers/LifecycleAware.swift`
- 修改：`SystemService.swift`、`WeatherService.swift`、`CalendarService.swift`、`NotificationService.swift`、`OpenClawService.swift`（如果适用）
- 修改：`SystemTab.swift`（替换现有的 onAppear/onDisappear 写法）、`OverviewTab.swift`（Weather/Calendar section）、`OpenClawTab.swift`

### Task C1：定义协议 + ViewModifier

**Step 1.** 新建 `NemoNotch/Helpers/LifecycleAware.swift`：

```swift
import SwiftUI

@MainActor protocol LifecycleAware: AnyObject {
    func setActive(_ active: Bool)
}

extension View {
    /// 在视图出现时启动 service，消失时停止。幂等。
    func activates(_ service: any LifecycleAware) -> some View {
        self
            .onAppear { service.setActive(true) }
            .onDisappear { service.setActive(false) }
    }
}
```

**Step 2.** 编译验证（应该 zero warnings）。

### Task C2：迁移 SystemService

`SystemService` 已经有 `setActive(_:)`，只需声明遵守协议：

```swift
@MainActor @Observable final class SystemService: LifecycleAware { … }
```

`SystemTab` 把现有的 onAppear/onDisappear 替换为 `.activates(systemService)`。

### Task C3：迁移 WeatherService

当前在 init 里就启动 timer + locationManager。改为：
- init 只保留 `locationManager` 创建，不启动监听
- 新增 `setActive(_:)`：active=true 才 startMonitoringSignificantLocationChanges + 开 refresh timer
- 在 OverviewTab 的 `OverviewWeatherSection` 上挂 `.activates(weatherService)`

注意：weather 数据需要 cache，setActive(false) 不清空 `temperature` 等已显示数据，只是停止更新。

### Task C4：迁移 NotificationService

当前已经做了"空列表停 timer"。补：声明遵守 `LifecycleAware`，`setActive(false)` 时 invalidate timer 但保留 monitoredApps；`setActive(true)` 时按 monitoredApps 状态决定是否启动。注意 badge 是收起状态也要显示的，**所以 NotificationService 不能用 Tab 可见性触发**——它应该跟随刘海整体生命周期（NotchCoordinator 启停），而不是 Tab。

→ 决定：NotificationService 实现协议，但调用方是 NemoNotchApp 的 AppDelegate，应用退入后台时 setActive(false)，回前台 setActive(true)。或者干脆不接 lifecycle，因为它本身已经做了空列表停 timer。**结论：跳过 NotificationService，留现状。**

### Task C5：迁移 CalendarService

CalendarService 有两个不同周期的工作：
1. EKEventStore 观察者（数据变化时回调）——应该常驻
2. `fetchEvents()` 刷新（如果有定期刷新的话）——可以按生命周期暂停

读代码确认是否有定时刷新。如果没有，CalendarService 不需要 setActive；如果有，只暂停定时刷新部分，不动观察者。

### Task C6：OpenClawService

是 WebSocket 服务，连接管理已经有自己的连/断逻辑。判断：用户点开 OpenClawTab 时才连，关掉时不断（因为 OpenClaw 事件需要常驻接收以驱动 badge）。**结论：跳过，留现状。**

### Task C7：提交

```
refactor: introduce LifecycleAware protocol for view-scoped service polling

- Add LifecycleAware protocol + .activates(service) view modifier
- Adopt in SystemService, WeatherService, CalendarService (refresh path)
- Replace ad-hoc onAppear/onDisappear wiring in tab views
```

---

## A. AISessionStore + 多 provider 重构（本轮第二阶段）

**Goal：** 把"每个 provider 自己存 sessions 字典、UI 层手动合并"的当前结构，替换为"一个共享 store 持有所有 session、provider 只负责把 hook 事件翻译成 store mutation"的架构。这让新增 provider（DeepSeek/OpenAI/Codex）只需写解析层，UI 完全无感。

**Architecture：**

```
┌────────────────────────────────────────┐
│         AICLIMonitorService            │
│  (thin facade, holds store + providers) │
└─────┬────────────────────┬─────────────┘
      │                    │
      ▼                    ▼
┌──────────────┐    ┌────────────────────┐
│ HookServer   │    │  AISessionStore    │
│ (socket)     │    │  (single source)   │
└──────┬───────┘    │ - sessions: dict   │
       │ events     │ - sortedSessions   │
       ▼            │ - activeSession    │
┌──────────────┐    └────────▲───────────┘
│ AIProvider   │             │
│ (parses,     │─── mutate ──┘
│  translates) │
└──────────────┘
```

**关键设计决策：**

1. **`AISessionStore` 是 @Observable MainActor**，不是 actor。SwiftUI 集成简单，且所有写入都来自 hook 事件回调（已经 hop 到 main）+ ConversationParser（在 nonisolated 队列上完成解析后 dispatch 回 main）。
2. **Provider 不再持有 sessions**，从 `AIProvider` 协议里删 `var sessions: [String: AISessionState] { get }` 和 `var activeSession: AISessionState? { get }`。
3. **Source 字段已经存在**于 `AISessionState`，store 用它来区分来源。
4. **Hook 安装、文件监听等 provider 私有职责保留**——只是 session state 不再 provider 持有。

**Files：**
- 新建：`NemoNotch/Services/AISessionStore.swift`
- 修改：`NemoNotch/Models/AIProvider.swift`（协议瘦身）
- 修改：`NemoNotch/Services/AICLIMonitorService.swift`（持有 store，暴露给 UI）
- 修改：`NemoNotch/Services/ClaudeCodeService.swift`、`GeminiProvider.swift`（mutation 改走 store）
- 修改：`NemoNotch/Tabs/AIChatTab.swift`、`ChatMessageView.swift`（数据源改）
- 修改：`NemoNotch/NemoNotchApp.swift`（装配 store）

### Task A1：起 AISessionStore 骨架

新建 `Services/AISessionStore.swift`：

```swift
@MainActor @Observable
final class AISessionStore {
    private(set) var sessions: [String: AISessionState] = [:]
    /// 按 lastEventTime 降序，增量维护避免每次重排
    private(set) var sortedSessions: [AISessionState] = []
    /// UI 当前选中的会话（跨 provider）
    var selectedSessionId: String?

    var activeSession: AISessionState? {
        sortedSessions.first { $0.phase == .working || $0.phase == .awaitingPermission }
    }

    func upsert(_ session: AISessionState) { … }
    func remove(id: String) { … }
    func sessions(for source: AISource) -> [AISessionState] {
        sortedSessions.filter { $0.source == source }
    }
}
```

`upsert` 做增量排序：

- 新 session：找到第一个 `lastEventTime < new` 的位置 insert
- 已有 session 且 lastEventTime 没变：原地 update（同 id 替换）
- 已有 session 但 lastEventTime 变了：remove + insert（小 N 场景下 O(N) 可接受）

提交：`feat: add AISessionStore for cross-provider session state`

### Task A2：瘦身 AIProvider 协议

`Models/AIProvider.swift` 当前协议（推测）：

```swift
@MainActor protocol AIProvider: AnyObject {
    var sessions: [String: AISessionState] { get }
    var activeSession: AISessionState? { get }
    var isHookInstalled: Bool { get }
    func handleEvent(_ event: HookEvent)
    func installHooks()
    func respondToPermission(sessionId: String, approved: Bool)
}
```

改为：

```swift
@MainActor protocol AIProvider: AnyObject {
    var source: AISource { get }
    var isHookInstalled: Bool { get }
    func handleEvent(_ event: HookEvent)
    func installHooks()
    func respondToPermission(sessionId: String, approved: Bool)
}
```

注入 store：`init(store: AISessionStore)` 让 provider 拿到引用。

提交：`refactor: slim down AIProvider protocol, inject AISessionStore`

### Task A3：迁移 ClaudeCodeService

把所有 `self.sessions[id] = …` 改成 `store.upsert(…)`，删除 `sessions` 属性和 `activeSession` 计算属性。`handleEvent` 解析后构造 `AISessionState`，source 设为 `.claude`，调 store。

ConversationParser 的回调（nonisolated）调度回 main 后 mutation。

提交：`refactor: ClaudeCodeService writes to AISessionStore`

### Task A4：迁移 GeminiProvider

同 A3。注意 GeminiConversationParser 的 result 类型独立，但翻译成 `AISessionState` 后存入 store。Gemini 特有字段（`thoughtTokens`）的持有方式：保留在 `AISessionState.providerSpecific: AnyHashable?` 或者干脆放进现有字段（看现状）。

→ 实施时如发现 `AISessionState` 已支持，无需扩展；否则加个 `providerMeta: [String: String]` 之类的 dict（保持简单）。

提交：`refactor: GeminiProvider writes to AISessionStore`

### Task A5：AICLIMonitorService 改造

变成 thin facade：

```swift
@MainActor @Observable
final class AICLIMonitorService {
    let store: AISessionStore
    let claudeProvider: ClaudeCodeService
    let geminiProvider: GeminiProvider
    private let hookServer: HookServer

    var activeSession: AISessionState? { store.activeSession }
    var allSessions: [AISessionState] { store.sortedSessions }

    init() {
        store = AISessionStore()
        claudeProvider = ClaudeCodeService(store: store)
        geminiProvider = GeminiProvider(store: store)
        hookServer = HookServer()
        hookServer.onEventReceived = { [weak self] event in
            self?.route(event)
        }
        hookServer.start()
    }

    private func route(_ event: HookEvent) {
        switch event.source {
        case .claude: claudeProvider.handleEvent(event)
        case .gemini: geminiProvider.handleEvent(event)
        }
    }
}
```

提交：`refactor: AICLIMonitorService routes events, store owns state`

### Task A6：AIChatTab 简化

删除 `allSessions` computed property，直接用 `aiService.store.sortedSessions`。selectedSessionId 改用 `store.selectedSessionId`（跨 provider 选中）。

提交：`refactor: AIChatTab reads from AISessionStore directly`

### Task A7：清理 + 验证

- grep 没有遗漏的 `claudeProvider.sessions` / `geminiProvider.sessions` 引用
- 跑一次完整 build
- 手动验证：启动 Claude Code 任务 → 看到 session；启动 Gemini → 看到 session；切换、权限审批、子 agent 显示正常

提交：`refactor: cleanup post AISessionStore migration`

---

## B. 多屏幕支持（路线图占位）

参考 cb9838d 的 spec。要点：
- NotchWindowManager 每屏一个 NotchCoordinator
- Services 跨屏共享（单例式）
- 拖动鼠标到不同屏的刘海应该独立响应
- 后续拆独立 plan

---

## D. 配置面板重做 + 主题系统（路线图占位）

- SettingsView 拆分为多个子视图（General / Tabs / AI / Appearance）
- 引入 `NotchTheme` 的运行时可定制版本
- 用户自定义颜色 / 字体大小 / 刘海高度 override
- 持久化通过 `AppSettings`

---

## E. AI 会话搜索 + 历史持久化（路线图占位）

依赖 A 的 AISessionStore 已统一。
- SwiftData 持久化 sessions（按 source 分表）
- 搜索 UI：按时间 / 工具 / 文件路径 / 文本
- 启动时从 SwiftData 恢复最近 N 条到 store

---

## 验收标准（A + C 完成后）

- [ ] 构建无警告
- [ ] 启动后 SystemTab 不可见时 Activity Monitor 看不到 NemoNotch 的 CPU 持续占用
- [ ] AIChatTab 同时显示 Claude 和 Gemini session，按时间排序正确
- [ ] 切换 session、权限审批、子 agent 显示均正常
- [ ] `grep -r "claudeProvider.sessions\|geminiProvider.sessions" NemoNotch/` 无结果
- [ ] 新增一个 mock provider 实现 AIProvider 协议 ≤ 50 行代码
