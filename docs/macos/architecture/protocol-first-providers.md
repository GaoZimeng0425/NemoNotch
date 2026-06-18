---
summary: 'Protocol-first 多 provider 模式:AIProvider / MultiAgentMonitor 协议、Registry 聚合、独立 Result 类型不强行统一、添加 provider 零改 UI。'
read_when:
  - '设计多个并行存在的 AI provider（Claude/Gemini/DeepSeek 等）'
  - '设计多个并行存在的 agent monitor（OpenClaw/Hermes 等）'
  - '决定哪些字段进协议、哪些留在具体类型'
  - '理解 Registry 聚合模式与 AISessionStore 的区别'
sources:
  - 'N §17.3 Protocol-first multi-provider design'
  - 'N CLAUDE.md Agent monitoring — registry pattern'
  - 'N CLAUDE.md Protocol-First Extensible Design'
  - 'I §8 Provider / Model 抽象'
last_verified:
  nemonotch: 'fe4e9e5'
  ironsmith: 'principles 文档 §8'
---

# Protocol-First 多 Provider 设计

## TL;DR

多个具体实现并行存在时（AI provider、agent monitor），用协议定义**最小公共接口**，各实现保留**独立 Result 类型和内部状态**；消费端（UI、Registry）只依赖协议；添加新 provider 只实现协议，零改消费端代码。

---

## 可复用模式

### 1. AIProvider 协议

```swift
@MainActor
protocol AIProvider: AnyObject, Observable {
    var source: AISource { get }
    var isHookInstalled: Bool { get set }

    func handleEvent(_ event: HookEvent)
    func installHooks()
    func uninstallHooks()
    func respondToPermission(sessionId: String, approved: Bool)
}
```

设计原则：
- **只放真正共有的接口**，不强行统一 provider-specific 字段。
- **`Observable`（宏合成，大写 O）必须在 protocol composition 中**：持有 `any AIProvider` 的 SwiftUI View 依赖此协议才能追踪变化。省去会静默停止观察，无编译报错。
- `@MainActor` 确保所有实现的属性修改和 UI 读取都在主线程。

### 2. 具体实现保留独立字段

```swift
final class ClaudeCodeService: AIProvider {
    let source: AISource = .claude
    var isHookInstalled: Bool = false

    // Claude 专属：不进协议
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var hookServerPort: Int = 0

    private let hookServer: HookServer
    private let conversationParser: ConversationParser

    func handleEvent(_ event: HookEvent) { /* Claude 专属处理逻辑 */ }
}

final class GeminiProvider: AIProvider {
    let source: AISource = .gemini
    var isHookInstalled: Bool = false

    // Gemini 专属：不进协议
    var thoughtTokens: Int = 0
    var geminiModel: String = ""

    private let geminiParser: GeminiConversationParser

    func handleEvent(_ event: HookEvent) { /* Gemini 专属处理逻辑 */ }
}
```

**provider-specific 字段的访问方式**：
```swift
// 需要 Claude 专属字段时，downcast
if let claude = provider as? ClaudeCodeService {
    print("cache tokens: \(claude.cacheReadTokens)")
}

// 或协议扩展提供可选访问
extension AIProvider {
    var cacheReadTokens: Int? { (self as? ClaudeCodeService)?.cacheReadTokens }
}
```

### 3. 独立 Result 类型，不强行统一

同理适用于 `ConversationParser`：

```swift
// 不做统一 ParseResult
protocol ConversationParserProtocol {
    associatedtype ParseResult
    func parseIncremental(from offset: UInt64) -> ParseResult
}

struct ClaudeParseResult {
    var messages: [ChatMessage]
    var tokenUsage: ClaudeTokenUsage   // Claude 专属：cacheRead、cacheCreation
    var newOffset: UInt64
    var interrupted: Bool
}

struct GeminiParseResult {
    var messages: [ChatMessage]
    var thoughtTokens: Int             // Gemini 专属
    var newOffset: UInt64
}
```

强行统一 Result 类型会导致"最小公分母"数据结构，所有 provider 都要填不属于自己的字段（空值或默认值），降低可读性和类型安全。

### 4. MultiAgentMonitor 协议与 Registry

```swift
@MainActor
protocol MultiAgentMonitor: AnyObject, Observable {
    var isInstalled: Bool { get }
    var isOnline: Bool { get }
    var hasActiveAgents: Bool { get }
    var agents: [AgentState] { get }
}

@MainActor
@Observable
final class AgentMonitorRegistry {
    private(set) var installedMonitors: [any MultiAgentMonitor] = []

    // 统一读接口——消费端只依赖这里
    var anyActiveAgent: Bool {
        installedMonitors.contains { $0.hasActiveAgents }
    }

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

注册新 monitor（在 AppDelegate 装配时）：
```swift
let openClaw = OpenClawService()
let hermes = HermesService()
registry.register(openClaw)
registry.register(hermes)
```

消费端（AgentMonitorTab、Badge）只读 `registry.activeAgents` 和 `registry.anyActiveAgent`，完全不知道 OpenClaw 或 Hermes 的存在。

### 5. ProviderCatalog 单一真相源（Ironsmith 模式）

多 provider 的元数据（名称、URL、认证方式、排序）集中成一张静态表，不在 UI 或测试里散落重复：

```swift
struct ProviderDescriptor: Identifiable, Hashable {
    let kind: ProviderKind
    let displayName: String
    let defaultBaseURLString: String
    let authMode: ProviderAuthMode          // .none / .apiKey / .platformCredits
    let sortOrder: Int
    // …
}

enum ProviderCatalog {
    static let descriptors: [ProviderDescriptor] = [
        ProviderDescriptor(kind: .openai, displayName: "OpenAI", …),
        ProviderDescriptor(kind: .anthropic, displayName: "Anthropic", …),
        // …
    ]
    static func descriptor(for kind: ProviderKind) -> ProviderDescriptor? { … }
    static func makeProvider(for kind: ProviderKind) -> ProviderConfig? { … }
}
```

好处：UI 展示 provider 列表时直接读 `ProviderCatalog.descriptors`，不会在组件里散落重复的名称/URL 字符串。

### 6. 选择标识符跨刷新稳定

多 provider 场景下，用户选择的 provider/model 需要跨远程列表刷新保持有效：

```swift
// 稳定标识符格式：providerIdentifier::modelIdentifier
let selectionIdentifier = "openai::gpt-4-turbo"

// 即使远程列表重新拉取，只要 identifier 匹配就能还原选择
UserDefaults.standard.set(selectionIdentifier, forKey: "selectedModel")
```

不要用列表 index 或 array offset 作为持久化标识符，远程列表顺序可能变化。

---

## 锚点（file:line）

| 概念 | 锚点 |
|---|---|
| AIProvider 协议 | `N §17.3`；`NemoNotch/Services/AICLIMonitorService.swift:5` |
| ClaudeCodeService 实现 | `NemoNotch/Services/ClaudeCodeService.swift:5` |
| GeminiProvider 实现 | `NemoNotch/Services/GeminiProvider.swift:5` |
| MultiAgentMonitor 协议 | `N §17.3`；`NemoNotch/Services/AgentMonitorRegistry.swift:5` |
| AgentMonitorRegistry | `NemoNotch/Services/AgentMonitorRegistry.swift:5` |
| OpenClawService 实现 | `NemoNotch/Services/OpenClawService.swift:6` |
| HermesService 实现 | `NemoNotch/Services/HermesService.swift:5` |
| ProviderCatalog | `I §8`；`ProviderCatalog.swift` |
| 选择标识符稳定性 | `I §8`；`AGENTS.md:54` |

---

## Pitfalls

1. **协议中遗漏 `Observable`**：持有 `any AIProvider` 的 View 静默停止响应变化。这是最难发现的 bug 之一，没有编译错误，只有 UI 不更新。
2. **provider-specific 字段塞进协议**：形成"最小公分母"协议，每个 provider 都要填不属于自己的字段，破坏独立性。
3. **强行统一 Result 类型**：解析结果各有特色（Claude 的 cache token、Gemini 的 thought token），统一后所有 provider 都填充不相关的空字段。
4. **消费端直接 import 具体类型**：打破"添加 provider 零改 UI"的目标；消费端应只依赖协议和 Registry 接口。
5. **Registry 中 `installedMonitors` 可变但无写保护**：外部代码可以直接 `append`，绕过 `register` 的初始化逻辑。应加 `private(set)` + `register` 方法。
6. **provider 在实例化后才 register**：若 Badge 在 `register` 前就读 `registry.anyActiveAgent`，会得到 false 而非等待；确保 registry 在 View 注入前已完成 register。
7. **ProviderCatalog 散落在多处定义**：名称/URL 字符串出现在 UI 组件、测试 fixture、Settings 视图多处时，一处改动需要同步多处；集中到单一 catalog。

---

## 落地 Checklist

- [ ] 协议只包含真正共有的最小接口
- [ ] `Observable` 在 protocol composition 中（大写 O）
- [ ] provider-specific 字段留在具体类型，按需 downcast 访问
- [ ] 各 provider 的 Result 类型保持独立，不强行统一数据结构
- [ ] Registry 暴露统一读接口（`anyActiveAgent`、`activeAgents`），消费端不引用具体 monitor 类型
- [ ] `register()` 在 AppDelegate 装配时调用，保证 View 注入前完成
- [ ] provider 元数据集中到 ProviderCatalog，不在 UI 散落重复字符串
- [ ] 选择标识符使用稳定的 `providerID::modelID` 格式，不用列表 index

---

## 延伸阅读

- [`single-source-store.md`](./single-source-store.md) — provider 写入统一 store 的中心 store 模式
- [`state-ownership-and-di.md`](./state-ownership-and-di.md) — protocol-first 与闭包 client 的对比与选型
- [`observable-service-layer.md`](./observable-service-layer.md) — @Observable 服务标准形态
- [`../ipc/`](../ipc/) — HookServer + hook installer（provider 接收事件的 IPC 层）
