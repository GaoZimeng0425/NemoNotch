---
summary: 'Adopt Swift 6 strict concurrency to eliminate data races at compile time, including SILGen crash workarounds.'
read_when:
  - 'enabling Swift 6 language mode or migrating an existing codebase'
  - 'debugging actor-isolation errors or SILGen compiler crashes'
---

# 02 · Swift 6 严格并发实践

## TL;DR

Swift 6 严格并发模式在编译期而非运行期消除数据竞争,代价是每一个跨 actor 边界的传递都必须被显式标注。Peekaboo 全仓库启用了 `swiftLanguageModes: [.v6]`,UI 层和 Service 层各自划定 actor 边界,数据模型以 `Sendable` 结构体穿越边界。迁移过程中遭遇了 SILGen `emitKeyPathComponentForDecl` 编译器崩溃,并摸索出一套可重复的规避方法。Peekaboo 曾因此触发过真实的 SILGen crash,文中记录了规避方法。

## Peekaboo 在哪里实现

- 模块:`PeekabooCore`、`PeekabooAutomation`、`PeekabooAutomationKit`、`PeekabooFoundation`、`PeekabooVisualizer`
- 关键文件:`Core/PeekabooCore/Sources/PeekabooCore/Support/PeekabooServices.swift:62` — `@MainActor public final class PeekabooServices`,Service 注册中心锁定主 actor,符合 macOS UI 自动化主线程要求
- 关键文件:`Core/PeekabooCore/Sources/PeekabooAgentRuntime/Agent/PeekabooAgentService+Execution.swift:108` — `struct UnsafeTransfer<T>: @unchecked Sendable`,将非 Sendable 的 `AgentEventDelegate` 跨 actor 搬运
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Core/Models/Snapshot.swift:5` — `public nonisolated struct UIAutomationSnapshot: Codable, Sendable`,纯数据结构同时标注 `nonisolated + Sendable`
- 关键文件:`Core/PeekabooCore/Sources/PeekabooAutomation/Configuration/ConfigurationManager.swift:18` — `public final class ConfigurationManager: @unchecked Sendable`,单例以外部同步机制保护可变状态
- 相关 docs:`docs/swift6-migration-compact.md`、`docs/swift-6.2-compiler-crash.md`、`docs/silgen-crash-debug.md`

## 设计动机(Why)

macOS 自动化程序天然多线程:屏幕捕获在后台队列,AX 事件在系统回调线程,UI 反馈必须回到主线程。Swift 5 时代这些边界全靠注释和约定,漏检则在运行期产生难以复现的竞争崩溃。

Swift 6 将此类错误前移到编译期。Peekaboo 全仓库强制启用(`swiftLanguageModes: [.v6]`,见各 `Package.swift`),边界漏标立刻报错。代价是初次启用时连锁错误较多,且 Swift 6.2 编译器在处理 key-path + `ParsableCommand` 泛型组合时触发 SILGen crash,导致 `Apps/CLI` 测试束无法编译,最终靠拆分目标和替换 key-path 写法解决(见 `docs/swift-6.2-compiler-crash.md`)。

## 核心模式(Pattern)

### 1. 分层 actor 边界

将代码按访问特征分为三层:

- **UI 层**:所有 SwiftUI 视图和直接交互 AppKit 的类标注 `@MainActor`,利用主 actor 单线程语义避免手动加锁。
- **Service 层**:协调子服务的对象可标注 `@MainActor`,前提是所有调用方都在主线程。后台密集运算改用独立 `actor` 实例。
- **数据层**:跨边界传递的数据使用值类型并显式遵从 `Sendable`。纯数据结构可同时加 `nonisolated`,让编译器无需 hop 即可直接访问。

### 2. `@unchecked Sendable` 的使用边界

`@unchecked Sendable` 绕过编译器检查,须满足以下条件之一才合理使用:

1. 可变状态已由外部锁/串行队列保护(如 `ConfigurationManager` 的单例写法)
2. 仅作"一次性搬运",传递后不再被修改(如 `UnsafeTransfer<T>` 包装 non-Sendable 协议值)

不满足时,优先重构为值类型或用 `actor` 封装状态。

### 3. 回调迁移为 async/await

用 `withCheckedContinuation` 包装单完成闭包 API,确保续体恰好 resume 一次;若续体未被 resume,调用方的 `await` 将永久挂起且无编译期警告,所有路径(包括 catch 分支)都须确保 resume。调用方的 actor 上下文决定 `await` 后的执行线程,包装函数本身通常无需额外 actor 标注。

### 4. `nonisolated` 与跨 actor 传递

- 无副作用、不访问隔离状态的方法标注 `nonisolated`,避免不必要的线程 hop
- 公开值类型结构体加 `nonisolated`,明确表示可在任意上下文访问
- 必须传递 non-Sendable 协议值时,用 `@unchecked Sendable` 包装结构体搬运,注释说明生命周期约束

## 新项目落地步骤(How to apply)

1. **启用** `StrictConcurrency` 为 warning 模式(`swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]`),先消除警告再切换语言模式,避免一次涌入大量编译错误
2. **标注** 所有直接操作 UI 或 AppKit 的类为 `@MainActor`,优先从叶子节点向上标注——叶子节点即直接调用 `NSWindow`/`NSView` 的类,再向上标注调用它们的 ViewModel,最后标注 coordinator 层,让编译器的 isolation inference 自动传播到子类和 extension
3. **拆分** 含有 key-path 泛型的测试目标,将需要运行时权限的自动化测试与无副作用的纯逻辑测试分入不同 SwiftPM target,防止 SILGen crash 污染整个测试束(参考 `docs/swift-6.2-compiler-crash.md` 中的目标拆分方案)
4. **补全** 所有跨模块公开结构体的 `Sendable` 声明,重点排查 `public struct`(编译器不会对 public 类型隐式推断 Sendable)
5. **收拢** 共享可变单例:若无法改为值类型,用 `actor` 封装或在确认外部同步机制存在后标注 `@unchecked Sendable`,并在注释中说明同步依据
6. **替换** key-path 简写闭包(`map(\.property)`)为显式闭包(`map { $0.property }`),当编译器在涉及 `ParsableCommand` 等泛型元数据的文件中 crash 时优先尝试此方案
7. **验证** 用 `pnpm run test:safe` 跑无权限依赖的核心测试束,确认 Swift 6 模式下零警告零报错,再用 `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` 可选开启完整自动化测试

## 常见陷阱(Pitfalls)

- **SILGen key-path crash** — Swift 6.2 编译器在处理 key-path + `ParsableCommand` 泛型组合时会触发 `swift-frontend` signal 5 崩溃于 `emitKeyPathComponentForDecl`。症状:测试目标在任何测试执行之前就终止,stack dump 指向 SILGen。规避:将 `subcommands.map(\.commandDescription.commandName)` 等写法改写为显式闭包;拆分测试目标隔离编译影响。见 `docs/silgen-crash-debug.md` 的完整排查流程。

- **`@MainActor` 撒得过广** — 将整个 service 层全部标注 `@MainActor` 会使 CPU 密集操作(图像处理、网络请求)强制跑在主线程,阻塞 UI 刷新。应改用独立 `actor` 或 `Task.detached`。

- **漏标 public 结构体的 Sendable** — Swift 对 `public` 类型不做隐式 Sendable 推断,一旦漏标,所有引用它的异步函数连锁报错,需从报错最多处向上追溯根因。

## 延伸阅读

- Peekaboo:`docs/swift6-migration-compact.md`、`docs/swift-6.2-compiler-crash.md`、`docs/silgen-crash-debug.md`、`docs/modern-swift.md`
- Apple:[Migrating to Swift 6](https://www.swift.org/migration/documentation/migrationguide/)
- 其它 playbook:[01 · 模块划分](./01-module-layout.md)、[04 · 错误处理](./04-error-handling.md)、[09 · SwiftUI + AppKit](./09-swiftui-appkit-liquid-glass.md)

---
*Last verified against Peekaboo @ `fe396d2e`*
