---
summary: 'Adopt Swift 6 strict concurrency with three-layer actor isolation (UI @MainActor / Service actor / Data Sendable struct) and pragmatic @unchecked Sendable patterns.'
read_when:
  - 'migrating to Swift 6 strict concurrency and avoiding SILGen crashes'
  - 'designing actor isolation boundaries in a multi-module macOS app'
---

# 02 · Swift 6 严格并发实践

## TL;DR

Swift 6 严格并发模式在编译期消除数据竞争:UI 层整体标注 `@MainActor`、Service 层独立 `actor` 封装可变状态、数据层以 `Sendable` 值类型穿越边界,三层划分让 isolation 边界清晰可追溯。`Sendable` 标注的最大陷阱在于判定"是否真的安全":公开结构体必须显式声明,`@unchecked Sendable` 须用外部锁保护才合法,漏标或假标都在运行期才爆发(TSan 可检测)。Peekaboo 曾因 Swift 6.2 编译器处理 `key-path + ParsableCommand` 泛型组合时触发 SILGen `emitKeyPathComponentForDecl` 崩溃,最终靠拆分测试目标 + 替换 key-path 写法解决。迁移路径建议先用 `StrictConcurrency` warning 模式逐步收拢警告,再一次性切换 `swiftLanguageModes: [.v6]`,避免初次启用时的错误雪崩。全仓库迁移完成后用 `swift build -Xswiftc -strict-concurrency=complete` 做最终扫描,确保无隐性遗漏。

## Peekaboo 在哪里实现

- 模块:`PeekabooCore`、`PeekabooAutomationKit`、`PeekabooFoundation`、`PeekabooVisualizer`
- 关键文件:`Core/PeekabooCore/Sources/PeekabooCore/Support/PeekabooServices.swift:62` — `@MainActor public final class PeekabooServices`,服务注册中心整体锁定主 actor,所有 UI 自动化调用路径在主线程串行执行
- 关键文件:`Core/PeekabooCore/Sources/PeekabooAgentRuntime/Agent/PeekabooAgentService+Execution.swift:108` — `struct UnsafeTransfer<T>: @unchecked Sendable`,将非 Sendable 的 `AgentEventDelegate` 协议值做"一次性搬运"过 actor 边界,注释明确说明生命周期约束
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Core/Models/Snapshot.swift:5` — `public nonisolated struct UIAutomationSnapshot: Codable, Sendable`,纯数据结构同时标注 `nonisolated + Sendable`,任意上下文可零 hop 访问
- 关键文件:`Core/PeekabooCore/Sources/PeekabooAutomation/Configuration/ConfigurationManager.swift:18` — `public final class ConfigurationManager: @unchecked Sendable`,单例通过外部访问约束(无并发写路径)保护可变状态
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/Support/SnapshotStorageActor.swift:5` — `actor SnapshotStorageActor`,独立 actor 封装文件 I/O,防止多路并发写快照时产生竞态
- 关键文件:`Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools/UISnapshotStore.swift:5` — `actor UISnapshot` + `nonisolated(unsafe)` 缓存字段样本:热路径读取的 `cachedApplicationName` / `cachedWindowTitle` 标注 `nonisolated(unsafe)`,写入只在 actor 隔离上下文执行
- 关键文件:`Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools/UISnapshotStore.swift:60` — `actor UISnapshotManager`,全局快照注册表,共享 `static let shared` 单例
- 关键文件:`Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/OptimizedAnimationQueue.swift:14` — `actor OptimizedAnimationQueue`,动画帧队列用 actor 而非串行 DispatchQueue 管理并发批次
- 关键文件:`Core/PeekabooFoundation/Sources/PeekabooFoundation/ErrorProtocols.swift:172` — `public actor ErrorRecoveryManager`,重试计数状态用 actor 封装,避免多 Task 并发重入
- 相关 docs:`docs/swift6-migration-compact.md`、`docs/swift-6.2-compiler-crash.md`、`docs/silgen-crash-debug.md`、`docs/modern-swift.md`

## 设计动机(Why)

### Swift 5 时代的三类真实痛点

macOS 自动化程序天然多线程:屏幕捕获在后台 ScreenCaptureKit 队列、AX 事件在系统回调线程、UI 反馈必须回主线程。Swift 5 时代这些边界全靠注释和约定,主要引发三类问题:

**1. 状态不一致(最难复现)** — Peekaboo 早期服务注册中心(`PeekabooServices`)在 Swift 5 模式下没有任何 actor 保护,两条异步路径可能同时写入 `services` 字典,症状是间歇性"服务找不到"或返回旧实例,在 CI 中偶发、本地无法稳定复现。

**2. 回调代码无法推理** — ScreenCaptureKit 的 `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` 回调跑在非主线程,早期代码在回调里直接读写 `@IBOutlet` 属性,运行时偶发崩溃,调试栈混乱。

**3. SILGen crash 编译器崩溃** — 升级到 Swift 6.2 后,`Apps/CLI` 测试目标在编译期触发 `swift-frontend` signal 5,崩溃点为 `SILGenModule::emitKeyPathComponentForDecl`。症状:任何测试执行之前测试进程就已退出,`swift test` 输出直接跳到 signal 5 stack dump。根因是 key-path 简写(`map(\.commandDescription.commandName)`)在涉及 `ParsableCommand` 泛型元数据时触发 SILGen 内部断言。解决方案:把 key-path 简写改为显式闭包,并将自动化测试目标从 `peekabooTests` 拆出到独立的 `CLIAutomationTests` target(见 `docs/silgen-crash-debug.md`)。

### Swift 6 的根本转变

Swift 6 将"隔离边界正确性"从运行期约定提升为编译期不变量。`swiftLanguageModes: [.v6]` 一旦启用,任何跨 isolation domain 传递 non-Sendable 类型都是编译错误。Peekaboo 全仓库全部 Package.swift 均已设置此选项(见 Package.swift:88 以及各 `Core/*/Package.swift`)。

## 核心模式(Pattern)

### Pattern 1 · 三层 actor 分层

将代码按访问特征划分为三层,每层的 isolation 语义清晰不重叠:

**UI 层 — `@MainActor`**

所有直接操作 SwiftUI 视图、AppKit 控件的类标注 `@MainActor`。主 actor 提供单线程串行语义,无需手动加锁。标注从叶子节点向上传播:先标注直接调用 `NSWindow`/`NSView` 的类,再向上标注调用它们的 ViewModel,让编译器的 isolation inference 自动处理子类和 extension。

```swift
@MainActor
public final class PeekabooServices {
    // 所有 UI 自动化服务统一在主 actor 串行执行
    public let automation: any UIAutomationServiceProtocol
    public let screenCapture: any ScreenCaptureServiceProtocol
}
```

**Service 层 — 独立 `actor`**

协调后台 I/O 或持有可变缓存的服务对象改用独立 `actor` 实例。后台 actor 无需 `@MainActor` 注解,Swift 运行时自动分配到后台执行器,不阻塞主线程。

```swift
actor SnapshotStorageActor {
    // actor-isolated 状态:编译器保证同时只有一个调用者在访问
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    func saveSnapshot(snapshotId: String, data: UIAutomationSnapshot, at path: URL) throws { ... }
}
```

**数据层 — `Sendable` 值类型**

跨 actor 边界传递的数据使用值类型并显式遵从 `Sendable`。纯数据结构可同时加 `nonisolated`,让编译器无需 hop 即可访问其计算属性。

```swift
public nonisolated struct UIAutomationSnapshot: Codable, Sendable {
    public let version: Int
    public var uiMap: [String: UIElement]
    // ...
}
```

### Pattern 2 · `@unchecked Sendable` 的合法用法

`@unchecked Sendable` 绕过编译器检查,须满足下列条件之一才合理:

**合法用法 A — 外部同步机制保护可变状态**

```swift
// Core/PeekabooCore/Sources/PeekabooAutomation/Configuration/ConfigurationManager.swift:18
public final class ConfigurationManager: @unchecked Sendable {
    public static let shared = ConfigurationManager()
    // 可变状态只在初始化时写入,之后只读,无并发写路径
    // ⚠️ 注释必须说明同步依据,否则未来维护者看不到约束
}
```

**合法用法 B — 一次性搬运(UnsafeTransfer 包装)**

```swift
// Core/PeekabooCore/Sources/PeekabooAgentRuntime/Agent/PeekabooAgentService+Execution.swift:108
struct UnsafeTransfer<T>: @unchecked Sendable {
    let wrappedValue: T
    // ⚠️ 搬运后 wrappedValue 只被一个 Task 持有,不共享
}
```

**合法用法 C — NSLock 保护可变属性(单例注册表场景)**

```swift
final class EventRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable () -> Void] = [:]

    func register(id: String, handler: @escaping @Sendable () -> Void) {
        lock.withLock { handlers[id] = handler }
    }
    func fire(id: String) {
        let h = lock.withLock { handlers[id] }
        h?()
    }
}
```

不满足以上条件时,优先重构为值类型或用 `actor` 封装。

### Pattern 3 · 回调迁移为 async/await

用 `withCheckedContinuation` 包装单完成闭包 API。续体必须**恰好 resume 一次**,所有路径(包括 catch 分支)都须覆盖:

```swift
func fetchConfiguration() async throws -> Config {
    try await withCheckedThrowingContinuation { continuation in
        legacyFetch { result, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: FetchError.emptyResult)
            }
            // ✅ 所有分支都 resume,不会永久挂起
        }
    }
}
```

### Pattern 4 · `nonisolated` 与跨 actor 传递

- 无副作用、不访问隔离状态的方法标注 `nonisolated`,避免不必要的线程 hop
- `actor` 内的只读缓存字段标注 `nonisolated(unsafe)`,由 actor 内写、外部只读
- 必须传递 non-Sendable 协议值时,用 `@unchecked Sendable` 包装结构体搬运

```swift
// UISnapshotStore.swift:12-14 — actor 内的 nonisolated(unsafe) 缓存
actor UISnapshot {
    private(set) nonisolated(unsafe) var cachedApplicationName: String?
    // 写入只在 actor 隔离上下文:setScreenshot() 内赋值
    // 读取从任意上下文可直接访问 applicationName 计算属性
    nonisolated var applicationName: String? { cachedApplicationName }
}
```

### Pattern 5 · AsyncStream 替代回调订阅

将多次回调(事件流)迁移为 `AsyncStream` / `AsyncThrowingStream`。调用方可用 `for await` 消费,Task 取消时自动停止迭代:

```swift
func makeEventStream() -> AsyncStream<AgentEvent> {
    let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
    // 注册回调:每次事件 yield 到 continuation
    startLegacyEventSource { event in
        continuation.yield(event)
    } onFinish: {
        continuation.finish()
    }
    return stream
}

// 消费侧:Task 取消时 for-await 自动退出
Task {
    for await event in makeEventStream() {
        await handleEvent(event)
    }
}
```

Peekaboo 中 `PeekabooAgentService+Execution.swift:48` 使用此模式将 `AgentEventDelegate` 回调桥接到 `AsyncStream<AgentEvent>`,再通过 `Task { @MainActor in ... }` 转发到主线程。

### Pattern 6 · `Task.detached` vs `Task { @MainActor in ... }`

二者的根本区别在于 isolation 继承:

| | `Task { ... }` | `Task.detached { ... }` |
|---|---|---|
| **isolation 继承** | 继承当前 actor 上下文 | 完全非隔离,独立执行器 |
| **在 `@MainActor` 方法里** | 仍在主线程跑 | 在后台跑 |
| **Task 优先级** | 继承当前优先级 | 需手动指定 |
| **何时用** | UI 触发的短异步操作 | 长时间 CPU 密集/后台任务 |

```swift
// ❌ 在 @MainActor 方法里写 Task { ... }:仍在主线程,阻塞 UI
@MainActor func onButtonTap() {
    Task {
        let result = try await heavyCompute() // 仍在 MainActor 上跑!
        self.label.text = result
    }
}

// ✅ 后台密集计算用 Task.detached,结果回主线程更新 UI
@MainActor func onButtonTap() {
    Task.detached(priority: .userInitiated) {
        let result = try await heavyCompute()         // 后台执行
        await MainActor.run { self.label.text = result } // 回主线程
    }
}
```

Task cancellation 必须主动检查,不会自动中断 CPU 密集循环:

```swift
Task.detached {
    for item in largeDataset {
        try Task.checkCancellation()   // 取消时抛 CancellationError
        process(item)
    }
}
```

## 完整代码示例(Starter Code)

以下是一个可编译的完整 Swift 文件骨架,展示三层 actor 分层 + 各 Pattern 的综合应用:

```swift
// SwiftConcurrencyDemo.swift
// swift-tools-version: 6.0  (swiftLanguageModes: [.v6])
// 编译: swift -swift-version 6 SwiftConcurrencyDemo.swift

import Foundation
import os.log

// MARK: - 错误类型

enum ServiceError: Error, Sendable {
    case networkTimeout
    case invalidData(String)
    case cancelled
}

// MARK: - 数据层:纯 Sendable 值类型

/// Pattern 1 数据层:显式 Sendable + Codable,跨 actor 边界安全传递
public struct Snapshot: Codable, Sendable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let applicationName: String
    public let elementCount: Int

    public init(id: UUID = .init(), applicationName: String, elementCount: Int) {
        self.id = id
        self.timestamp = Date()
        self.applicationName = applicationName
        self.elementCount = elementCount
    }
}

// MARK: - 服务层协议

/// 服务协议本身也须标注 Sendable,使 actor 可以持有 any ServiceProtocol 属性
public protocol SnapshotServiceProtocol: Sendable {
    func fetch(for app: String) async throws -> Snapshot
    func eventStream(for app: String) -> AsyncStream<Snapshot>
}

// MARK: - Service 层:独立 actor 封装可变状态

/// Pattern 1 Service 层:独立 actor,不在主线程,不阻塞 UI
public actor SnapshotServiceImpl: SnapshotServiceProtocol {
    private var cache: [String: Snapshot] = [:]
    private let logger = Logger(subsystem: "demo", category: "SnapshotService")

    public init() {}

    public func fetch(for app: String) async throws -> Snapshot {
        // 先查缓存(actor 隔离,无竞争)
        if let cached = cache[app] {
            return cached
        }
        // 模拟后台网络/AX 查询
        try await Task.sleep(for: .milliseconds(50))
        try Task.checkCancellation()           // Pattern 6:显式检查取消

        let snapshot = Snapshot(applicationName: app, elementCount: Int.random(in: 10...100))
        cache[app] = snapshot
        logger.debug("Fetched snapshot for \(app)")
        return snapshot
    }

    /// Pattern 5:AsyncStream 替代回调订阅
    public func eventStream(for app: String) -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            // 模拟定时推送更新(真实场景替换为 AX 观察者回调)
            let task = Task {
                for _ in 0..<5 {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { break }
                    let snap = Snapshot(applicationName: app, elementCount: Int.random(in: 10...100))
                    continuation.yield(snap)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Pattern 2:@unchecked Sendable 配合 NSLock

/// 全局事件注册表——无法改为 actor(需要同步访问),用 NSLock 保护
public final class GlobalEventRegistry: @unchecked Sendable {
    public static let shared = GlobalEventRegistry()
    private let lock = NSLock()
    private var handlers: [String: @Sendable (Snapshot) -> Void] = [:]

    private init() {}

    public func register(id: String, handler: @escaping @Sendable (Snapshot) -> Void) {
        lock.withLock { handlers[id] = handler }
    }

    public func unregister(id: String) {
        lock.withLock { _ = handlers.removeValue(forKey: id) }
    }

    public func broadcast(_ snapshot: Snapshot) {
        let current = lock.withLock { handlers }
        current.values.forEach { $0(snapshot) }
    }
}

// MARK: - UI 层:@MainActor ViewModel

/// Pattern 1 UI 层:整体 @MainActor,SwiftUI @Observable 友好
@MainActor
public final class SnapshotViewModel {
    // @Observable 宏会为这些属性生成观察追踪
    public var snapshot: Snapshot?
    public var isLoading: Bool = false
    public var errorMessage: String?
    public var eventHistory: [Snapshot] = []

    private let service: any SnapshotServiceProtocol
    private var streamTask: Task<Void, Never>?

    public init(service: any SnapshotServiceProtocol) {
        self.service = service
    }

    /// Pattern 6:在 @MainActor 方法里启动后台任务用 Task(继承主 actor 上下文)
    /// 此处仅 await service.fetch,service 是后台 actor,会自动 hop 到其执行器
    public func loadSnapshot(for app: String) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // await 跨 actor 边界:当前在 MainActor,service.fetch 在后台 actor
                let result = try await service.fetch(for: app)
                // await 返回后自动回到 MainActor 上下文更新 UI
                self.snapshot = result
            } catch is CancellationError {
                // 取消不视为错误
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    /// Pattern 5:订阅 AsyncStream
    public func startObserving(app: String) {
        stopObserving()
        streamTask = Task {
            let stream = service.eventStream(for: app)
            for await snap in stream {
                // Task { ... } 在 MainActor 内创建,for-await 回调也在 MainActor 上
                self.eventHistory.append(snap)
                if self.eventHistory.count > 50 {
                    self.eventHistory.removeFirst()
                }
            }
        }
    }

    public func stopObserving() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Pattern 6:CPU 密集任务用 Task.detached,避免阻塞主线程
    public func exportAllSnapshots() {
        Task.detached(priority: .utility) { [snapshots = eventHistory] in
            // 在后台序列化
            let data = try? JSONEncoder().encode(snapshots)
            // 结果回主线程
            await MainActor.run {
                print("Exported \(data?.count ?? 0) bytes")
            }
        }
    }
}

// MARK: - 单元测试注入示例

/// 为测试提供的 Mock:遵从协议,actor-isolated,可注入
actor MockSnapshotService: SnapshotServiceProtocol {
    var stubbedResult: Result<Snapshot, Error> = .success(
        Snapshot(applicationName: "TestApp", elementCount: 5))

    func fetch(for app: String) async throws -> Snapshot {
        try stubbedResult.get()
    }

    func eventStream(for app: String) -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            Task {
                if case .success(let snap) = stubbedResult {
                    continuation.yield(snap)
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - 入口(可编译验证)

@main
struct Demo {
    static func main() async throws {
        let service = SnapshotServiceImpl()
        let viewModel = await SnapshotViewModel(service: service)

        // 模拟 UI 触发加载
        await viewModel.loadSnapshot(for: "Finder")
        try await Task.sleep(for: .milliseconds(200))

        // 订阅事件流
        await viewModel.startObserving(app: "Safari")
        try await Task.sleep(for: .seconds(3))
        await viewModel.stopObserving()

        let history = await viewModel.eventHistory
        print("Received \(history.count) events")
    }
}
```

## 新项目落地步骤

1. **启用 warning 模式** — 在所有 target 的 `swiftSettings` 加 `.enableExperimentalFeature("StrictConcurrency")`,先把所有 concurrency 警告暴露出来,不要直接跳到 Swift 6 mode,否则初次启用时可能出现数百个错误难以逐一处理。

2. **标注 UI 层 `@MainActor`** — 从叶子节点向上标注:先标注直接调用 `NSWindow`/`NSView`/`WKWebView` 的类,再向上标注调用它们的 ViewModel / Coordinator,让 isolation inference 自动覆盖子类和 extension,减少手动标注量。

3. **补全公开结构体 `Sendable`** — 用 `grep -rn "^public struct\|^public class" Sources/ | grep -v Sendable` 快速定位遗漏点。Swift 对 `public` 类型不做隐式 Sendable 推断,一个漏标可能引发连锁报错。

4. **收拢共享可变单例** — 若无法改为值类型,用 `actor` 封装或在确认外部同步机制存在后标注 `@unchecked Sendable`,注释中说明同步依据(锁名 / 队列名 / 写路径约束)。

5. **拆分含 key-path 泛型的测试目标** — 将需要运行时权限的自动化测试与无副作用的逻辑测试分入不同 SwiftPM target(参考 Peekaboo 的 `peekabooTests` vs `CLIAutomationTests`)。Swift 6.2 在 key-path + `ParsableCommand` 泛型组合上有 SILGen crash,拆分可防止 crash 污染整个测试束。

6. **替换 key-path 简写闭包** — 将 `map(\.commandDescription.commandName)` 等 key-path 简写改为显式闭包 `map { $0.commandDescription.commandName }`,当编译器在涉及泛型元数据的文件中 crash 时优先尝试此方案,见 `docs/silgen-crash-debug.md`。

7. **切换 Swift 6 语言模式** — 警告全部清零后,将每个 target 的 `swiftLanguageModes` 设置为 `[.v6]`(或在 `Package.swift` 顶层设置 `swiftLanguageModes: [.v6]`),使 concurrency 检查从 warning 升级为 error。

8. **为单元测试注入 actor 隔离** — 测试中的 Mock 服务遵从 `actor` 而非 `class`,避免测试并发执行时 Mock 状态被多 Task 同时修改。`@MainActor` 层的测试用 `@MainActor` 标注测试方法,或用 `await MainActor.run { ... }` 包装断言。

9. **全严格扫描** — 用 `swift build -Xswiftc -strict-concurrency=complete` 做最终扫描,确认无隐性遗漏(此标志比 Swift 6 mode 更严格,会检查 Swift 5 mode 下未启用的 warning)。

10. **跑安全测试束验证** — 用 `pnpm run test:safe` 跑无权限依赖的核心测试束确认零警告零报错,再用 `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` 开启完整自动化测试。

## 替代方案对比

| 方案 | 优点 | 缺点 | 何时选 |
|------|------|------|--------|
| **本方案:Swift 6 严格并发 + actor** | 编译期消除 race;心智模型清晰;跨 actor 调用天然 async | 学习曲线;旧 API 桥接成本高;Swift 6.2 有 SILGen crash 需规避 | 新 macOS 13+ 项目;主动迁移;团队接受 async/await 模型 |
| **GCD (DispatchQueue)** | 无所不在;mature;同步阻塞可用;C 库 binding 友好 | 编译期不查竞争;callback hell;`DispatchQueue.sync` 易死锁;`@Sendable` 闭包标注繁琐 | 与 C 库 / Objective-C API 的直接 binding;同步计算密集场景;需要 `sync` 语义的临界区 |
| **OperationQueue + Operation** | 取消/依赖关系内置;KVO 友好;`maxConcurrentOperationCount` 限流方便 | API 冗长;子类化 Operation 繁琐;Sendable 难标;与 async/await 混用需要 bridge | 任务队列 + 取消树场景;需要 operation 依赖关系(A 完成后才能执行 B);导出/下载管道 |
| **Combine** | reactive 操作符丰富;`Publisher` 链式组合;macOS 10.15+ 原生 | 比 AsyncStream 内存压力大;订阅生命周期管理复杂;`AnyCancellable` 容易泄露;与 async/await 互转需要 `values` 适配器 | SwiftUI 复杂 UI binding;多信号合并(`combineLatest`/`merge`);需要 debounce/throttle 的搜索框 |
| **手写线程 (Thread/pthread)** | 控制权最高;RT 实时线程可用;零额外开销 | 极易写错;无 Sendable 检查;调试困难 | C 库内部 RT/realtime 场景;音视频低延迟处理;需要绑定 CPU core |

### 本方案 fail 时的降级策略

- **需要支持 macOS 12 以下** — SwiftUI `@Observable` 要求 macOS 14,`actor` 要求 macOS 10.15+(`async/await` 同)。macOS 12 以下用 `ObservableObject` + Combine + `@Published`。
- **需要 SwiftUI < iOS 16 binding** — 回退 `ObservableObject` + Combine,`@MainActor` 标注仍可保留。
- **Objective-C 互操作频繁** — `actor` 不能直接被 ObjC 访问。在 ObjC 边界用串行 `DispatchQueue` 包装,内部向 actor 转发。
- **需要同步阻塞语义** — `actor` 方法必须 `await`,无法同步调用。需要同步访问时改用 `NSLock` + `@unchecked Sendable`,或将调用点迁移到 `MainActor.assumeIsolated { ... }`。

## 调试与取证

### 诊断命令

| 症状 | 排查命令 | 根因 |
|------|---------|------|
| `cannot send 'X' across actor` 编译错 | `swift build 2>&1 \| grep -E "cannot send\|conform.*Sendable\|actor-isolated" -A3` | Sendable 漏标或 isolation 边界跨错 |
| 编译时 `Segmentation fault: 11` 或 LLVM ERROR | `swift build 2>&1 \| tee /tmp/silgen-crash.log; grep -A20 "emitKeyPath\|SILGen\|swift-frontend" /tmp/silgen-crash.log` | SILGen crash:key-path + 泛型元数据组合触发编译器 bug |
| `Data race detected` 运行时 | `swift run -Xswiftc -sanitize=thread 2>&1 \| grep -A5 "DATA RACE"` | 用了 `@unchecked Sendable` 但没正确同步 |
| `Task` 没按预期取消 | `swift package describe --type json \| jq '.targets[].name'` + Instruments Concurrency template 查 Task 树 | 没检查 `Task.isCancelled` / `Task.checkCancellation()`,或 for-await 未终止 |
| `@MainActor` 死锁(主线程等主线程) | `lldb` `process interrupt` → `thread backtrace all \| grep -A5 "MainActor\|_dispatch_main"` | 在 MainActor 上同步调用 `await MainActor.run { ... }` 产生重入死锁 |
| Combine ↔ async 互转过程丢事件 | 在 `continuation.yield` 前后加 `os_log` 计数,对比 in/out 数量 | `AsyncStream` buffer 满 + `.dropOldest` 策略静默丢弃;或 `continuation.finish()` 在最后一个 event yield 之前调用 |

### 常用工具

```bash
# 全严格并发扫描(比 Swift 6 mode 更严格,渐进迁移用)
swift build -Xswiftc -strict-concurrency=complete

# 渐进迁移:只看 warning 不变 error
swift build -Xswiftc -warn-concurrency

# Thread Sanitizer:检测 @unchecked Sendable 假阴
swift test -Xswiftc -sanitize=thread

# 验证 Package.swift 中的 swiftLanguageModes 设置
swift package describe --type json | jq '.targets[] | {name: .name, settings: .settings}'

# SILGen crash:捕获完整 stack dump
swift build 2>&1 | tee /tmp/silgen-crash.log
# 然后查找崩溃帧
grep -n "emitKeyPathComponentForDecl\|SILGenModule\|swift-frontend" /tmp/silgen-crash.log | head -20

# lldb 查 Task / 主线程状态
# (attach to running process)
# (lldb) thread list
# (lldb) thread backtrace all
```

Xcode 工具:
- **Instruments → Swift Concurrency** — 可视化 Task 树、actor hop 次数、主线程占用率
- **Xcode → Thread Performance Checker** — 运行时检测主线程违规(相当于轻量级 TSan)
- **Console.app** subsystem `com.apple.dispatch` — 查 GCD 与 async/await 互转边界

## 常见陷阱(Pitfalls)

**SILGen key-path crash** — Swift 6.2 编译器在处理 key-path + `ParsableCommand` 泛型组合时触发 `swift-frontend` signal 5,崩溃于 `emitKeyPathComponentForDecl`。症状:测试目标在任何测试执行之前就已终止,stack dump 指向 SILGen。规避方案:将 `subcommands.map(\.commandDescription.commandName)` 等写法改写为显式闭包;拆分测试目标隔离编译影响。见 `docs/silgen-crash-debug.md` 完整排查流程。

**`@MainActor` 撒得过广** — 将整个 Service 层全部标注 `@MainActor` 会使 CPU 密集操作(图像处理、JSON 序列化、网络请求)强制跑在主线程,阻塞 UI 刷新。诊断:Instruments Swift Concurrency 视图中主线程占用率异常高。修复:改用独立 `actor` 或 `Task.detached`。

**漏标 `public` 结构体的 `Sendable`** — Swift 对 `public` 类型不做隐式 Sendable 推断,一旦漏标,所有引用它的异步函数连锁报错。排查:从报错最多处向上追溯,通常根因是一个公开结构体缺少 `: Sendable` 声明。

**`@unchecked Sendable` 假阴** — 标注了 `@unchecked Sendable` 但没有真正的同步机制保护 → 运行时 data race。编译器不报错,只有 TSan(`-sanitize=thread`)才能在测试中检测到。务必在注释中说明同步依据,并在 CI 中跑 TSan 构建。

**`Task { ... }` 隐式继承 actor 上下文** — 在 `@MainActor` 方法里写 `Task { ... }`,实际上这个 Task 仍在 `MainActor` 上执行,并非后台。要切换到后台必须用 `Task.detached` 或在 Task 内先 `await` 一个后台 actor 的方法。常见误区:以为 `Task { }` 会像 `DispatchQueue.global().async` 一样自动切到后台。

## 延伸阅读

- Peekaboo:`docs/swift6-migration-compact.md`、`docs/swift-6.2-compiler-crash.md`、`docs/silgen-crash-debug.md`、`docs/modern-swift.md`
- Apple:[Migrating to Swift 6](https://www.swift.org/migration/documentation/migrationguide/)
- Apple:[Concurrency — The Swift Programming Language](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- WWDC 2022:[Eliminate Data Races Using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/)
- WWDC 2024:[Migrate your app to Swift 6](https://developer.apple.com/videos/play/wwdc2024/10169/)
- 其它 playbook:[01 · 模块划分](./01-module-layout.md)、[03 · 日志与可观测性](./03-logging-observability.md)、[04 · 错误处理](./04-error-handling.md)、[09 · SwiftUI + AppKit](./09-swiftui-appkit-liquid-glass.md)

---
*Last verified against Peekaboo @ `660fefb5`*
