---
summary: 'Swift 6 严格并发三层模型:@MainActor @Observable final class 服务、独立 actor 封装 I/O、Sendable 值类型穿越边界,外加 @unchecked Sendable / nonisolated(unsafe) 安全边界登记。'
read_when:
  - '迁移到 Swift 6 严格并发,消除编译期数据竞争'
  - '设计 macOS 应用 actor 隔离边界,规避 SILGen 崩溃'
  - '在 @MainActor @Observable 服务里安全跨越 actor 边界'
sources: ['P02', 'N §15', 'I-4']
last_verified:
  peekaboo: '660fefb5'
  nemonotch: 'fe4e9e5'
---

# Swift 6 严格并发实践

## TL;DR

Swift 6 在编译期消除数据竞争:`@MainActor @Observable final class` 作为 UI-facing 服务的默认形态,独立 `actor` 封装后台 I/O,`Sendable` 值类型跨边界传递。三层划分让 isolation 边界清晰可追溯。边界难以满足时有两个安全阀:`@unchecked Sendable`(须有外部同步机制 + 注释说明不变量)和 `nonisolated(unsafe)`(须绑定到具名队列/执行器且注释说明)。Peekaboo 曾因 key-path + `ParsableCommand` 泛型组合触发 Swift 6.2 SILGen crash,靠拆分测试目标 + 替换 key-path 写法解决。迁移路径:先 `-warn-concurrency` warning 模式收拢警告,再切 `swiftLanguageModes: [.v6]`。

---

## 可复用模式

### Pattern 1 · 三层 actor 分层

按访问特征划分三层,每层 isolation 语义不重叠:

**UI 层 — `@MainActor @Observable final class`**

NemoNotch 中 15 个服务均采用此形态:`AICLIMonitorService`、`AISessionStore`、`CalendarService`、`ClaudeCodeService`、`GeminiProvider`、`HermesService`、`HookServer`、`HUDService`、`LauncherService`、`MediaService`、`NotificationService`、`OpenClawService`、`SystemService`、`WeatherService`、`AgentMonitorRegistry`。

```swift
// NemoNotch/Services/MediaService.swift (§15.1)
@MainActor
@Observable
final class MediaService {
    var playbackState = PlaybackState()
    // 所有可变状态在 MainActor;SwiftUI 通过 @Observable 自动观察
}
```

Ironsmith / Peekaboo 中的等价写法:

```swift
// Peekaboo: Core/PeekabooCore/Sources/PeekabooCore/Support/PeekabooServices.swift:62
@MainActor
public final class PeekabooServices {
    public let automation: any UIAutomationServiceProtocol
    public let screenCapture: any ScreenCaptureServiceProtocol
}

// Ironsmith: Inference/InferenceStore.swift
@MainActor
@Observable
final class ModelSelectionStore {
    var selectedModelID: String? {
        didSet {
            if let selectedModelID { userDefaults.set(selectedModelID, forKey: Key.selectedModelID) }
            else { userDefaults.removeObject(forKey: Key.selectedModelID) }
        }
    }
    @ObservationIgnored private let userDefaults: UserDefaults
}
```

**Service 层 — 独立 `actor`**

协调后台 I/O 或持有可变缓存,不阻塞主线程:

```swift
// Peekaboo: Core/PeekabooCore/Sources/PeekabooAutomation/.../SnapshotStorageActor.swift:5
actor SnapshotStorageActor {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    func saveSnapshot(snapshotId: String, data: UIAutomationSnapshot, at path: URL) throws { ... }
}
```

**数据层 — `Sendable` 值类型**

跨 actor 边界传递的数据使用值类型并显式遵从 `Sendable`;可附加 `nonisolated` 让计算属性无需 hop:

```swift
// Peekaboo: Core/PeekabooAutomationKit/.../Snapshot.swift:5
public nonisolated struct UIAutomationSnapshot: Codable, Sendable {
    public let version: Int
    public var uiMap: [String: UIElement]
}
```

---

### Pattern 2 · `@unchecked Sendable` — 三种合法用法

`@unchecked Sendable` 绕过编译器检查,**必须**满足下列条件之一,并用注释说明不变量。

**用法 A — 只写一次后只读(初始化后无并发写)**

```swift
// Peekaboo: Core/PeekabooAutomation/Configuration/ConfigurationManager.swift:18
public final class ConfigurationManager: @unchecked Sendable {
    public static let shared = ConfigurationManager()
    // 可变状态只在初始化时写入,之后只读,无并发写路径
    // ⚠️ 注释必须说明同步依据,否则未来维护者看不到约束
}
```

**用法 B — 一次性搬运(UnsafeTransfer 包装)**

```swift
// Peekaboo: Core/PeekabooAgentRuntime/Agent/PeekabooAgentService+Execution.swift:108
struct UnsafeTransfer<T>: @unchecked Sendable {
    let wrappedValue: T
    // ⚠️ 搬运后 wrappedValue 只被一个 Task 持有,不共享
}
```

NemoNotch 中等价用法(搬运 C API 返回的 `[String: Any]?`):

```swift
// NemoNotch/Services/NowPlayingCLI.swift:438-440
private struct InfoBox: @unchecked Sendable {
    let info: [String: Any]?
}
// Invariant: written once on `queue`, read once on MainActor; never aliased.

// NemoNotch/Services/MediaService.swift:4-7
private struct NowPlayingInfoBox: @unchecked Sendable {
    let info: [String: Any]?
    init(info: [String: Any]?) { self.info = info }
}
```

**用法 C — NSLock 保护可变属性**

```swift
// 单例注册表场景
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

---

### Pattern 3 · `nonisolated(unsafe)` 绑定到具名队列

用于 `@MainActor` 类中被后台队列独占访问的可变字段。**每个字段旁必须注释说明 owning queue 名称**。

```swift
// NemoNotch/Services/HookServer.swift:7-11
@ObservationIgnored nonisolated(unsafe) private var socketFd: Int32 = -1
@ObservationIgnored nonisolated(unsafe) private var acceptSource: DispatchSourceRead?
private let socketQueue = DispatchQueue(label: "com.nemonotch.hookserver", qos: .userInitiated)
@ObservationIgnored nonisolated(unsafe) private var responseWaiters: [String: (String) -> Void] = [:]
// ⚠️ 以上三个字段仅在 socketQueue 上访问
```

actor 内 hot-path 只读缓存字段:

```swift
// Peekaboo: Core/PeekabooAgentRuntime/MCP/Tools/UISnapshotStore.swift:12-14
actor UISnapshot {
    private(set) nonisolated(unsafe) var cachedApplicationName: String?
    // 写入只在 actor 隔离上下文执行;读取通过 nonisolated 计算属性暴露
    nonisolated var applicationName: String? { cachedApplicationName }
}
```

`nonisolated(unsafe) static let shared` 单例:

```swift
// NemoNotch/Services/LogService.swift:4
nonisolated(unsafe) static let shared = LogService()
// ⚠️ 仅适用于内部线程安全的单例(如 DDLog);有 actor-bound 状态的服务不能用此模式
```

---

### Pattern 4 · 回调从后台队列重入 MainActor

`NotificationCenter` / `DispatchSource` / `URLSession` 回调可能在非 MainActor 线程触发,用 `Task { @MainActor [weak self] in }` 重入:

```swift
// NemoNotch/Services/MediaService.swift:200-204
nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
    Task { @MainActor [weak self] in
        LogService.debug("[Media] notification: \(name.rawValue)", category: "media")
        self?.updateNowPlaying()
    }
}
```

**不要** 依赖 `OperationQueue.main` 作为 MainActor 替代——两者在 Swift 6 中是不同的 isolation domain,`Task { @MainActor in }` hop 仍然必要。

---

### Pattern 5 · AsyncStream 替代回调订阅

将多次回调(事件流)桥接到 `AsyncStream`,调用方用 `for await` 消费,Task 取消时自动停止:

```swift
// Peekaboo: PeekabooAgentService+Execution.swift:48 附近
func makeEventStream() -> AsyncStream<AgentEvent> {
    let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
    startLegacyEventSource { event in
        continuation.yield(event)
    } onFinish: {
        continuation.finish()
    }
    return stream
}

Task { @MainActor in
    for await event in makeEventStream() {
        await handleEvent(event)
    }
}
```

---

### Pattern 6 · `Task` vs `Task.detached`:isolation 继承

| | `Task { ... }` | `Task.detached { ... }` |
|---|---|---|
| isolation 继承 | 继承当前 actor 上下文 | 完全非隔离,独立执行器 |
| 在 `@MainActor` 方法里 | 仍在主线程跑 | 在后台跑 |
| 何时用 | UI 触发的短异步操作 | 长时间 CPU 密集/后台任务 |

```swift
// ❌ 在 @MainActor 方法里写 Task { ... }:仍在 MainActor,阻塞 UI
@MainActor func onButtonTap() {
    Task { let result = try await heavyCompute() }  // 仍在主线程!
}

// ✅ 后台密集计算用 Task.detached,结果回主线程
@MainActor func onButtonTap() {
    Task.detached(priority: .userInitiated) {
        let result = try await heavyCompute()
        await MainActor.run { self.label = result }
    }
}
```

可取消的 dismiss timer 模式(NemoNotch HUD):

```swift
// NemoNotch/Services/HUDService.swift:283-292
private var dismissTask: Task<Void, Never>?

private func restartDismissTimer() {
    dismissTask?.cancel()
    dismissTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(NotchConstants.hudDismissDelay))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: NotchConstants.hudDismissDuration)) {
            activeHUD = nil
        }
    }
}
```

---

### Pattern 7 · 回调迁移为 async/await

用 `withCheckedThrowingContinuation` 包装单完成闭包 API,所有路径**恰好 resume 一次**:

```swift
func fetchConfiguration() async throws -> Config {
    try await withCheckedThrowingContinuation { continuation in
        legacyFetch { result, error in
            if let error { continuation.resume(throwing: error) }
            else if let result { continuation.resume(returning: result) }
            else { continuation.resume(throwing: FetchError.emptyResult) }
        }
    }
}
```

---

## 锚点(file:line)

| 模式 | 文件:行 | 项目 |
|---|---|---|
| `@MainActor @Observable final class` 服务 | `NemoNotch/Services/MediaService.swift:1` | NemoNotch |
| `@MainActor @Observable final class` 服务(入口) | `NemoNotch/NemoNotchApp.swift:105-188` | NemoNotch |
| `@unchecked Sendable` InfoBox | `NemoNotch/Services/NowPlayingCLI.swift:438-440` | NemoNotch |
| `@unchecked Sendable` NowPlayingInfoBox | `NemoNotch/Services/MediaService.swift:4-7` | NemoNotch |
| `nonisolated(unsafe)` 队列绑定字段 | `NemoNotch/Services/HookServer.swift:7-11` | NemoNotch |
| `nonisolated(unsafe) static let shared` | `NemoNotch/Services/LogService.swift:4` | NemoNotch |
| `Task { @MainActor } re-dispatch` | `NemoNotch/Services/MediaService.swift:200-204` | NemoNotch |
| 可取消 dismiss timer | `NemoNotch/Services/HUDService.swift:283-292` | NemoNotch |
| `@MainActor final class PeekabooServices` | `Core/PeekabooCore/…/PeekabooServices.swift:62` | Peekaboo |
| `UnsafeTransfer` 一次性搬运 | `Core/PeekabooCore/…/PeekabooAgentService+Execution.swift:108` | Peekaboo |
| `ConfigurationManager @unchecked Sendable` | `Core/PeekabooAutomation/…/ConfigurationManager.swift:18` | Peekaboo |
| `UIAutomationSnapshot nonisolated Sendable` | `Core/PeekabooAutomationKit/…/Snapshot.swift:5` | Peekaboo |
| `actor SnapshotStorageActor` | `Core/PeekabooAutomationKit/…/SnapshotStorageActor.swift:5` | Peekaboo |
| `nonisolated(unsafe)` actor 缓存字段 | `Core/PeekabooAgentRuntime/…/UISnapshotStore.swift:12-14` | Peekaboo |
| `@MainActor @Observable ModelSelectionStore` | `Ironsmith/Core/Inference/ModelSelectionStore.swift` | Ironsmith |

---

## Pitfalls

### P1 · `@Observable` 必须 `final`

`@Observable` 宏在非 `final` 类上展开会产生误导性诊断——错误指向宏展开内部,不指向类声明。**始终写 `final`**。

### P2 · `@MainActor` 撒得过广

将整个 Service 层全部标注 `@MainActor` 会使 CPU 密集操作(JSON 序列化、图像处理、网络请求)强制跑在主线程,阻塞 UI 刷新。诊断:Instruments Swift Concurrency 视图中主线程占用率异常高。修复:改用独立 `actor` 或 `Task.detached`。

### P3 · 漏标 `public` 结构体的 `Sendable`

Swift 对 `public` 类型不做隐式 Sendable 推断——一旦漏标,所有引用它的异步函数连锁报错。快速定位:

```bash
grep -rn "^public struct\|^public class" Sources/ | grep -v Sendable
```

### P4 · `@unchecked Sendable` 假阴

标注了但没有真正的同步机制——运行时 data race。编译器不报错,只有 TSan 能在测试中检测到:

```bash
swift test -Xswiftc -sanitize=thread
```

**务必**在注释中说明同步依据(锁名 / 队列名 / 写路径约束),并在 CI 中跑 TSan。

### P5 · `nonisolated(unsafe)` 混用上下文

`nonisolated(unsafe)` 字段**只**在 owning queue/actor 上访问——任何从 `@MainActor` 代码的直接写都引入竞争,编译器不报错。`deinit` 是 `nonisolated` 的,teardown 时须 `socketQueue.sync { … }` 清理。

### P6 · `Task { ... }` 不等于 `DispatchQueue.global().async`

在 `@MainActor` 方法里写 `Task { ... }` 并不切换到后台——Task 继承当前 actor 上下文,仍在 MainActor 上执行。要切后台须用 `Task.detached` 或先 `await` 一个后台 actor 的方法。

### P7 · `OperationQueue.main` ≠ MainActor

Swift 6 中两者是不同的 isolation domain。即便 observer 传入 `queue: .main`,在回调闭包内对 `@MainActor` 属性赋值仍需 `Task { @MainActor in }` hop。

### P8 · SILGen key-path crash (Swift 6.2)

Swift 6.2 编译器在 key-path + `ParsableCommand` 泛型组合时触发 `swift-frontend` signal 5,崩溃于 `SILGenModule::emitKeyPathComponentForDecl`。症状:测试目标在任何测试执行之前就已终止。

规避:
1. `map(\.commandDescription.commandName)` → `map { $0.commandDescription.commandName }` 改为显式闭包。
2. 把涉及 key-path 泛型的测试目标从 `peekabooTests` 拆出到独立的 `CLIAutomationTests` target。

诊断命令:

```bash
swift build 2>&1 | tee /tmp/silgen-crash.log
grep -n "emitKeyPathComponentForDecl\|SILGenModule\|swift-frontend" /tmp/silgen-crash.log | head -20
```

### P9 · `@MainActor` 死锁

在 `MainActor` 上同步调用 `await MainActor.run { ... }` 产生重入死锁。诊断:

```bash
# lldb
process interrupt
thread backtrace all | grep -A5 "MainActor\|_dispatch_main"
```

---

## 落地 checklist

迁移路径,按顺序执行:

1. **启用 warning 模式** — 在所有 target 的 `swiftSettings` 加 `.enableExperimentalFeature("StrictConcurrency")` 或用 `-warn-concurrency`,先暴露警告,不直接切 Swift 6 mode(初次启用可能出现数百个错误)。

2. **标注 UI 层 `@MainActor`** — 从叶子节点向上:先标注直接操作 `NSWindow`/`NSView` 的类,再向上标注 ViewModel / Coordinator,让 isolation inference 自动覆盖子类和 extension。

3. **补全 `public` 结构体 `Sendable`** — 用 P3 命令定位遗漏点;`public` 类型不做隐式推断,一个漏标引发连锁报错。

4. **收拢共享可变单例** — 优先改为 `actor`,若无法改则标注 `@unchecked Sendable` 并注释同步依据(P4)。

5. **登记每个 `@unchecked Sendable` 和 `nonisolated(unsafe)`** — 在 NemoNotch 项目中须更新 `docs/macos-cookbook.md` §15 增加对应条目(参见 CLAUDE.md 中的 Cookbook 更新规则)。

6. **拆分含 key-path 泛型的测试目标** — 参见 P8。

7. **切换 Swift 6 语言模式** — 警告清零后,在 `Package.swift` 设置 `swiftLanguageModes: [.v6]`。

8. **为测试注入 actor 隔离** — Mock 服务遵从 `actor`;`@MainActor` 层测试用 `@MainActor` 标注或 `await MainActor.run { }` 包装断言。

9. **全严格扫描** — `swift build -Xswiftc -strict-concurrency=complete` 做最终扫描(比 Swift 6 mode 更严格)。

10. **CI 跑 TSan** — `swift test -Xswiftc -sanitize=thread` 检测 `@unchecked Sendable` 假阴。

### 边界登记格式(NemoNotch 专用)

每次新增 `@unchecked Sendable` 或 `nonisolated(unsafe)` 时,在同一个 commit 里在 `docs/macos-cookbook.md` §15 追加一行:

```
**`TypeName` bridge** — `NemoNotch/Path/File.swift:LINE  FieldOrType`
// Invariant: <同步依据>
```

---

## 调试工具

| 症状 | 命令 |
|---|---|
| `cannot send 'X' across actor` 编译错 | `swift build 2>&1 \| grep -E "cannot send\|conform.*Sendable\|actor-isolated" -A3` |
| SILGen crash signal 5 | `swift build 2>&1 \| tee /tmp/silgen-crash.log && grep "emitKeyPath\|SILGen" /tmp/silgen-crash.log \| head -20` |
| `Data race detected` 运行时 | `swift run -Xswiftc -sanitize=thread 2>&1 \| grep -A5 "DATA RACE"` |
| 渐进迁移:只看 warning | `swift build -Xswiftc -warn-concurrency` |
| 全严格扫描 | `swift build -Xswiftc -strict-concurrency=complete` |
| 验证 swiftLanguageModes 设置 | `swift package describe --type json \| jq '.targets[] \| {name:.name, settings:.settings}'` |

Xcode 工具:
- **Instruments → Swift Concurrency** — 可视化 Task 树、actor hop 次数、主线程占用率。
- **Xcode → Thread Performance Checker** — 运行时检测主线程违规(轻量级 TSan)。

---

## 延伸阅读

- 本区块索引: [`../concurrency/index.md`](./index.md)
- NemoNotch Cookbook §15: [`../macos-cookbook.md#15-swift-6-concurrency-conventions`](../../macos-cookbook.md)
- Peekaboo 迁移文档(项目内): `docs/swift6-migration-compact.md`、`docs/swift-6.2-compiler-crash.md`、`docs/silgen-crash-debug.md`
- 架构模式参考: [`../architecture/`](../architecture/)
- Apple 官方: [Migrating to Swift 6](https://www.swift.org/migration/documentation/migrationguide/)、[Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- WWDC 2022: [Eliminate Data Races Using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/)
- WWDC 2024: [Migrate your app to Swift 6](https://developer.apple.com/videos/play/wwdc2024/10169/)
