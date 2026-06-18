---
summary: '状态所有权边界 + 依赖注入两种选型:Ironsmith 闭包式 client(无 protocol/mock 仪式)与 NemoNotch protocol-first,按场景选,不二选一。'
read_when:
  - '设计新服务时,决定状态放哪层、哪些状态禁止进共享 store'
  - '选择 DI 方式:闭包 client 还是 protocol-first'
  - '菜单栏 app 的外壳结构与 AppKit 桥接决策'
sources:
  - 'I §2 顶层架构与分层'
  - 'I §3 应用外壳:菜单栏 + AppKit 薄桥接'
  - 'I §4 状态管理与所有权边界'
  - 'I §5 依赖注入:闭包式 client'
  - 'N §17.2 Closure injection over AppDelegate.shared'
  - 'N §17.3 Protocol-first multi-provider design'
last_verified:
  nemonotch: 'fe4e9e5'
  ironsmith: 'principles 文档 §2/§3/§4/§5'
---

# 状态所有权与依赖注入

## TL;DR

**状态所有权**：写下哪些状态禁止进共享 store，比说"状态放 store"更有价值。将局部 UI 状态与跨界面共享状态分开，并明确禁止事项。

**DI 选型**：两种方式都经过生产验证，按场景选：
- **闭包式 client（Ironsmith）**：副作用隔离优先，可测性强，不需要 protocol/mock 仪式。
- **Protocol-first（NemoNotch）**：多个具体实现共享消费端，零改 UI 加 provider 时优先。

---

## 可复用模式

### 1. 应用外壳：菜单栏 + AppKit 薄桥接

菜单栏 app 外壳推荐用 AppKit 手写，而非 SwiftUI `MenuBarExtra`（后者在弹窗尺寸、激活行为、sheet 处理上限制多）：

```swift
// App body 只暴露 Settings 场景
@main struct IronsmithApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { SettingsView().environment(appDelegate.inferenceStore) }
    }
}

// 菜单栏控制器用 AppKit
final class IronsmithMenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    init(/* … */) {
        statusItem.button?.image = NSImage(systemSymbolName: "hammer", …)
        statusItem.button?.image?.isTemplate = true  // 自动适配深浅色
        // …
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // 必须手动激活，否则弹窗可能拿不到键盘焦点
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
```

要点：
- `NSPopover.behavior = .applicationDefined`：自己控制关闭时机。
- `hostingController.sizingOptions = [.preferredContentSize]`：让 SwiftUI 内容决定弹窗尺寸。
- 关闭前先 `dismissAttachedSheetIfNeeded`：有 sheet 挂着时直接关 popover 会残留。
- `applicationShouldTerminateAfterLastWindowClosed → false`：菜单栏 app 后台常驻。
- **手动补 Edit 菜单**（`NSMenuItem` Cut/Copy/Paste/SelectAll）：菜单栏 app 默认没有标准菜单，文本框快捷键失效。

### 2. 状态所有权边界

白纸黑字写出哪些状态禁止进共享 store，比泛泛说"状态放 store"更有约束力。

**Ironsmith 示例**（两个 store 的职责边界）：

| Store | 持有内容 | 明确禁止 |
|---|---|---|
| `InferenceStore`（跨界面共享） | providers、persistedModels、remoteModels、选中模型、连接问题、账号/额度、错误状态 | 局部 UI 状态 |
| `ToolLibraryStore`（弹窗局部） | 工具列表 UI、选中工具、生成进度、导出/启动状态、prompt 文本、sandbox 开关 | **禁止进 InferenceStore** |

**NemoNotch 示例**（服务职责边界）：

| 服务 | 持有内容 | 明确禁止 |
|---|---|---|
| `AISessionStore`（单一真相源） | sessions、sortedSessions、activeSession | provider 内部状态；UI 只读不写 |
| `AIChatTab`（Tab 局部 UI） | 选中会话 index、滚动位置 | 写 AISessionStore |

**通用四层职责**（Ironsmith 分层契约）：

| 层 | 职责 | 明确禁止 |
|---|---|---|
| **View** | 渲染状态、发出意图 | 不直接碰网络/文件/进程/Keychain |
| **Store** (`@Observable`) | 协调工作流、持有状态 | 局部 UI 状态不塞共享 store |
| **Repository** | 包装持久化访问 | 不发网络、不碰 Keychain、不起进程、不持久化"发现来的"远程数据 |
| **Closure Client** | 包装一切副作用 | — |

### 3. DI 选型 A：闭包式 client（Ironsmith）

适用场景：
- 副作用隔离优先（Keychain、网络、文件、进程）
- 需要高可测性，不想为测试写 protocol + mock
- 单一实现（或实现数量少），不需要 protocol 多态

```swift
// 定义：结构体 + 闭包字段
struct CredentialClient {
    var loadAPIKey: (String) throws -> String?
    var saveAPIKey: (String, String) throws -> Void
    var deleteAPIKey: (String) throws -> Void
}

// 生产实现：.live 静态工厂
extension CredentialClient {
    static var live: Self {
        let store = ProviderCredentialStore()
        return Self(
            loadAPIKey:   { try store.loadAPIKey(for: $0) },
            saveAPIKey:   { try store.saveAPIKey($0, for: $1) },
            deleteAPIKey: { try store.deleteAPIKey(for: $0) }
        )
    }
}

// 异步场景加 @Sendable
struct OllamaClient {
    var isInstalled: @Sendable () async -> Bool
    var listModels: @Sendable () async throws -> [LocalModel]
}

// 依赖容器：集中组装所有 client
struct InferenceDependencies {
    var credentialClient: CredentialClient
    var remoteModelClient: RemoteModelClient
    var languageModelClient: LanguageModelClient
    // …
}
extension InferenceDependencies {
    static var live: Self { /* 组装所有 .live，传递共享依赖 */ }
}

// 测试注入：直接替换闭包
let testDeps = InferenceDependencies(
    credentialClient: CredentialClient(
        loadAPIKey: { _ in nil },
        saveAPIKey: { _, _ in },
        deleteAPIKey: { _ in }
    ),
    languageModelClient: LanguageModelClient(
        makeLanguageModel: { _, _ in FakeLanguageModel() }
    )
)
```

优势：
- 无需 protocol + conformance，直接替换闭包即可测试。
- 依赖容器 `InferenceDependencies` 是所有副作用的"单入口"，组装一次，到处使用。
- 适合"AI 编译修复流程"等原本极难测试的场景：副作用全是可替换闭包。

### 4. DI 选型 B：Protocol-first（NemoNotch）

适用场景：
- 有多个具体实现且并行存在（如 ClaudeCodeService + GeminiProvider）
- 消费端（UI、Badge、Registry）需要统一接口，不关心具体类型
- 添加新 provider 不改 UI

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

// 具体实现各自独立
final class ClaudeCodeService: AIProvider { /* Claude 专属字段、HookServer 等 */ }
final class GeminiProvider: AIProvider { /* Gemini 专属字段、GeminiConversationParser 等 */ }

// 消费端只用协议
final class AICLIMonitorService {
    private var providers: [any AIProvider] = []
    func register(_ provider: any AIProvider) { providers.append(provider) }
}
```

关键规则：
- **不要把 provider-specific 字段（如 Claude 的 `cacheReadTokens`、Gemini 的 `thoughtTokens`）强塞进协议**。保留在具体类型，需要时 downcast。
- **`Observable` 必须在协议 composition 中**（大写 O，macro-synthesized）。若缺失，持有 `any AIProvider` 的 View 会静默停止响应变化。
- 同样模式适用于 `MultiAgentMonitor`（OpenClawService + HermesService）、`ConversationParserProtocol` 等。

### 5. 两种 DI 的对比与选型

| 维度 | 闭包式 client | Protocol-first |
|---|---|---|
| **多实现并行** | 不适合（切换需修改注入代码） | 天然支持 |
| **可测性** | 极强（直接换闭包） | 良好（注入 fake conformance） |
| **代码量** | 少（无 protocol/conformance） | 稍多 |
| **适用场景** | 副作用隔离（Keychain/网络/文件） | AI provider、agent monitor 等并行存在的 provider |
| **添加新 provider** | 需改注入代码 | 只加新实现，零改消费端 |
| **查找具体类型** | 天然可见 | 需要 downcast |

两种方式可在同一项目共存（NemoNotch 用 protocol-first 管 AI provider，若要接入 Keychain 抽象同样可用闭包 client）。

---

## 锚点（file:line）

| 模式 | 锚点 |
|---|---|
| 菜单栏 AppKit 桥接 | `I §3`；`IronsmithMenuBarController.swift` |
| 四层职责与禁止事项 | `I §2`；`AGENTS.md:31-34` |
| InferenceStore 边界 | `I §4`；`InferenceStore.swift` |
| 闭包 client 示例 | `I §5`；`CredentialClient.swift`、`InferenceDependencies.swift` |
| 测试注入 | `I §5`；`ToolLibraryTestSupport.swift` |
| Protocol-first AIProvider | `N §17.3`；`NemoNotch/Services/AICLIMonitorService.swift:5` |
| 闭包注入替代全局单例 | `N §17.2`；`NemoNotch/NemoNotchApp.swift:105-188` |

---

## Pitfalls

1. **闭包 client 忘加 `@Sendable`**：并发场景（async 闭包跨 actor）会在 Swift 6 下报错，需显式标注。
2. **Protocol 中遗漏 `Observable`**：持有 `any AIProvider` 的 View 静默停止观察变化，无编译报错。
3. **强行统一 provider-specific 字段到协议**：造成"最小公分母"协议，破坏各 provider 独立性；provider 专属字段保留在具体类型。
4. **全局单例 `AppDelegate.shared` 回潮**：一处"为了方便"添加，逐步蔓延。每次添加时代价等于日后清理的成本×所有调用者数量。
5. **菜单栏 app 用 `MenuBarExtra`**：弹窗尺寸无法自由控制，sheet 处理有限制，激活行为难以定制。
6. **`NSPopover` 打开前未 `activate`**：弹窗出现但文本框拿不到键盘焦点，`Cmd+C/V` 失效。
7. **`isRunningTests` 时不跳过菜单栏/窗口**：UI 层影响核心逻辑测试，应在测试环境跳过所有 AppKit 控制器。

---

## 落地 Checklist

- [ ] 明确写出各 store/service 的"禁止事项"，而不只是"职责"
- [ ] 局部 UI 状态（进度条、弹窗选中项）不进共享 store
- [ ] 副作用（Keychain/网络/文件/进程）收敛到 closure client 或 repository
- [ ] 多 provider 并行场景用 protocol-first，确保 `Observable` 在 protocol composition 中
- [ ] provider-specific 字段留在具体类型，消费端用 downcast 按需访问
- [ ] 闭包 client 依赖容器 `.live` 工厂统一组装，测试路径替换为 fake 闭包
- [ ] 菜单栏 app 使用 `NSStatusItem + NSPopover`，手动补 Edit 菜单
- [ ] `isRunningTests` 时跳过菜单栏控制器和窗口安装

---

## 延伸阅读

- [`observable-service-layer.md`](./observable-service-layer.md) — 服务标准形态与 AppDelegate 装配细节
- [`single-source-store.md`](./single-source-store.md) — 多 provider 写入同一 store 的中心 store 模式
- [`protocol-first-providers.md`](./protocol-first-providers.md) — Protocol-first 的完整模式（独立 Result 类型、Registry）
- [`persistence.md`](./persistence.md) — 持久化选型：SwiftData vs UserDefaults/JSON
- [`../keychain/`](../keychain/) — Keychain 与 closure client 结合的凭证管理
