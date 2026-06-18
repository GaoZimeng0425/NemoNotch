---
summary: 'NemoNotch AISessionStore:中心 store 模式——provider 只写、UI 只读 sortedSessions、activeSession 优先级比较器、upsert/mutate/mutateOrCreate API。'
read_when:
  - '多个 provider 需要写入同一份状态，UI 需要统一读取'
  - '设计"谁是当前活跃会话"的优先级逻辑'
  - '添加新 AI provider 时确保不改 UI'
  - '理解 AISessionStore 的 upsert/mutate/mutateOrCreate 语义'
sources:
  - 'N §17.3 Protocol-first multi-provider design'
  - 'N CLAUDE.md AISessionStore 设计'
  - 'N CLAUDE.md AI Service Architecture 图'
last_verified:
  nemonotch: 'fe4e9e5'
  ironsmith: 'N/A'
---

# 单一真相源 Store（AISessionStore 模式）

## TL;DR

多 provider 场景下，所有写入收敛到一个 `@MainActor @Observable` 中心 store；provider 只调 `upsert / mutate / mutateOrCreate`；UI 只读 `sortedSessions`，从不触碰 provider 内部状态。新增 provider 只需实现写入接口，UI 零改动。

---

## 可复用模式

### 1. Store 结构与核心 API

```swift
@MainActor
@Observable
final class AISessionStore {
    // UI 消费的两个出口
    private(set) var sortedSessions: [AISessionState] = []   // 按 lastEventTime 降序，每次 mutation 重建
    var activeSession: AISessionState? { /* 优先级比较器 */ }

    // provider 写入接口（三个）
    func upsert(_ session: AISessionState) { /* 插入或整体替换 */ }
    func mutate(id: SessionID, _ transform: (inout AISessionState) -> Void) { /* 原地修改 */ }
    func mutateOrCreate(id: SessionID, default: AISessionState, _ transform: (inout AISessionState) -> Void) { /* 不存在则创建后修改 */ }

    // 过滤出口（Badge 等只关心某一 provider）
    func sessions(for source: AISource) -> [AISessionState] {
        sortedSessions.filter { $0.source == source }
    }
}
```

设计原则：
- `sortedSessions` 是缓存字段，每次 mutation 完整重建（按 `lastEventTime` 降序）。不要让 UI 直接迭代 `sessions` 字典，保证排序稳定。
- **`private(set)` 强制 provider 只通过三个写入方法修改**，UI 无写入路径。
- `sessions(for:)` 过滤出口供 Badge 等只关心单一 provider 的场景使用。

### 2. activeSession 优先级比较器

"当前活跃会话"不是简单取最新，而是有明确的优先级链：

```
waitingForApproval > processing / compacting > waitingForInput > idle > ended
同优先级内按 lastEventTime 降序（取最新）
```

```swift
var activeSession: AISessionState? {
    sortedSessions.max { a, b in
        let pa = priority(a.phase), pb = priority(b.phase)
        if pa != pb { return pa < pb }
        return a.lastEventTime < b.lastEventTime
    }
}

private func priority(_ phase: SessionPhase) -> Int {
    switch phase {
    case .waitingForApproval: return 5
    case .processing, .compacting: return 4
    case .waitingForInput: return 3
    case .idle: return 2
    case .ended: return 1
    }
}
```

**为什么这样设计**：用户最关心的是"需要我操作"的会话（permission 审批），其次是"正在工作"的会话，而不是最近有过事件的任何会话。

### 3. Provider 写入模式（只调 store API）

```swift
// ClaudeCodeService — 只写，不读 sortedSessions
final class ClaudeCodeService: AIProvider {
    private unowned let store: AISessionStore

    func handleEvent(_ event: HookEvent) {
        switch event.type {
        case .sessionStart:
            store.upsert(AISessionState(id: event.sessionId, source: .claude, phase: .idle, …))
        case .preToolUse:
            store.mutateOrCreate(id: event.sessionId, default: makeDefault(event)) { session in
                session.phase = .processing
                session.lastEventTime = event.timestamp
            }
        case .permissionRequest:
            store.mutate(id: event.sessionId) { session in
                session.phase = .waitingForApproval
                session.pendingPermission = event.permissionPayload
            }
        }
    }
}
```

```swift
// GeminiProvider — 同样只写
final class GeminiProvider: AIProvider {
    private unowned let store: AISessionStore

    func handleEvent(_ event: HookEvent) {
        store.mutateOrCreate(id: event.sessionId, default: makeDefault(event)) { session in
            session.phase = self.phase(for: event)
            session.lastEventTime = event.timestamp
        }
    }
}
```

关键：**provider 不持有会话列表**，也不读 `sortedSessions`。所有状态由 store 托管。

### 4. UI 只读 sortedSessions

```swift
struct AIChatTab: View {
    @Environment(AISessionStore.self) var store

    var body: some View {
        List(store.sortedSessions) { session in
            SessionRowView(session: session)
        }
    }
}

// Badge 只关心 Claude 的活跃状态
struct ClaudeBadge: View {
    @Environment(AISessionStore.self) var store

    var body: some View {
        let claudeSessions = store.sessions(for: .claude)
        // … 渲染 claudeSessions
    }
}
```

UI **绝不**直接读 provider 的内部状态（如 `ClaudeCodeService.currentSessions`）。所有读取路径都经过 store。

### 5. AICLIMonitorService 拥有 store

```swift
@MainActor
@Observable
final class AICLIMonitorService {
    let store = AISessionStore()    // 拥有并持有

    private var providers: [any AIProvider] = []

    func setup() {
        let claude = ClaudeCodeService(store: store)
        let gemini = GeminiProvider(store: store)
        providers = [claude, gemini]
    }
}
```

`AICLIMonitorService` 是 store 的唯一拥有者，providers 通过 `unowned` 引用写入。

### 6. Registry 模式（AgentMonitorRegistry）

多 agent monitor 场景同理，Registry 暴露统一读接口：

```swift
@MainActor
@Observable
final class AgentMonitorRegistry {
    private(set) var installedMonitors: [any MultiAgentMonitor] = []

    // 统一读出口
    var anyActiveAgent: Bool { installedMonitors.contains { $0.hasActiveAgents } }
    var activeAgents: [AgentState] {
        installedMonitors
            .flatMap { $0.agents.filter { !$0.isIdle } }
            .sorted { $0.lastEventTime > $1.lastEventTime }
    }

    func register(_ monitor: any MultiAgentMonitor) {
        installedMonitors.append(monitor)
    }
}
```

与 AISessionStore 的区别：Registry 聚合的是 monitor 本身（`installedMonitors`），而不是把 monitor 的状态归拢到一个中心 store。两种方式都合理，取决于 agent 状态是否需要统一排序和跨 monitor 去重。

---

## 锚点（file:line）

| 概念 | 锚点 |
|---|---|
| AISessionStore 设计 | `NemoNotch/Services/AISessionStore.swift:11` |
| upsert/mutate/mutateOrCreate | `NemoNotch/Services/AISessionStore.swift:52-68` |
| activeSession 优先级比较器 | `NemoNotch/Services/AISessionStore.swift:39` |
| ClaudeCodeService 写入示例 | `NemoNotch/Services/ClaudeCodeService.swift:5` |
| GeminiProvider 写入示例 | `NemoNotch/Services/GeminiProvider.swift:5` |
| AICLIMonitorService 拥有 store | `NemoNotch/Services/AICLIMonitorService.swift:5` |
| AgentMonitorRegistry | `NemoNotch/Services/AgentMonitorRegistry.swift:5` |
| sessions(for:) 过滤出口 | `N §17.4` 协议部分；见 AISessionStore 实现 |

---

## Pitfalls

1. **UI 直接读 provider 内部状态**：provider 重构时 UI 跟着改，破坏"添加 provider 零改 UI"的目标。
2. **sortedSessions 不是缓存而是每次现算**：在 SwiftUI 渲染热路径上每次 sort 一遍会产生不必要的计算；应在每次 mutation 后重建缓存并存入 `private(set)` 属性。
3. **provider 读 sortedSessions 做业务逻辑**：provider 的职责是写入，读取会形成循环依赖（provider 读 store，store 由 provider 填充）。
4. **activeSession 取"最新"而非"最高优先级"**：用户看到的"当前会话"应该是需要注意的，而不是最近触发过事件的。
5. **多个 provider 对同一 sessionId 并发 mutate**：因为 `@MainActor`，所有写入串行化，不需要额外锁；但不同 provider 共用同一 sessionId 会互相覆盖，需要在 `sessionId` 中区分来源（如加 source prefix）。
6. **store 被注入为 `@weak`**：provider 通过 `unowned` 持有 store；store 生命周期与 `AICLIMonitorService` 一致，`unowned` 比 `weak` 更合适（无需 optional 解包）。

---

## 落地 Checklist

- [ ] 定义中心 store 的三个写入方法（upsert / mutate / mutateOrCreate）
- [ ] `sortedSessions` 作为缓存，每次 mutation 完整重建
- [ ] `activeSession` 按优先级链（需要操作 > 工作中 > 等待输入 > 空闲 > 结束）选取
- [ ] provider 只通过 store API 写入，不持有会话列表，不读 `sortedSessions`
- [ ] UI 只读 `sortedSessions` 和 `sessions(for:)`，不访问 provider 内部
- [ ] store 由 monitor service 拥有，provider 通过 `unowned` 引用写入
- [ ] `sessions(for:)` 过滤出口供只关心单一 provider 的场景使用
- [ ] 新增 provider 只需实现写入逻辑，零改 UI

---

## 延伸阅读

- [`protocol-first-providers.md`](./protocol-first-providers.md) — AIProvider / MultiAgentMonitor 协议与 Registry 完整模式
- [`observable-service-layer.md`](./observable-service-layer.md) — 服务标准形态与 @MainActor 约束
- [`state-ownership-and-di.md`](./state-ownership-and-di.md) — 状态所有权边界与 DI 选型
- [`../concurrency/`](../concurrency/) — @MainActor 串行化保证与 Swift 6 并发约束
