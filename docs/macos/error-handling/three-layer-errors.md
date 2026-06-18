---
summary: '三层错误模型:域枚举 → 顶层包装(StandardizedError) → 跨进程 Codable 信封,用户消息与诊断 payload 严格分离。'
read_when:
  - '为多模块 macOS app 设计类型化错误层次结构'
  - '需要跨 CLI/GUI/Daemon 进程边界序列化错误'
  - '实现 Swift 6 Sendable 错误且有 actor 并发边界'
  - '需要机器可读错误码用于 CLI --json 输出或监控告警'
sources: ['P04']
last_verified:
  peekaboo: 'd576fa0f'
  nemonotch: 'fe4e9e5'
---

# 三层错误模型

## TL;DR

macOS 系统集成应用的错误横跨权限、自动化、网络、AI 等多个域。推荐架构是**三层**:

| 层 | 类型 | 职责 |
|---|---|---|
| 层 1 · 域错误 | `enum CaptureError: LocalizedError, Sendable` | 精确描述单模块失败原因,不混入其他域语义 |
| 层 2 · 顶层包装 | `enum AppError: StandardizedError` | 跨域统一;提供机器可读 `code`、用户可读 `userMessage`、诊断 `context` 三件套 |
| 层 3 · 跨进程信封 | `struct AppErrorEnvelope: Codable, Sendable, Error` | 压平为 `{code, message, details}` JSON,跨 UNIX socket / XPC 传输 |

核心规则:`LocalizedError.errorDescription` **只返回** `userMessage`,永远不拼入底层堆栈或 `NSError` 细节;`context` 字典仅在 `--verbose` / `--json` 模式输出。日志桥接 `logged()` 在顶层入口统一记录——中间层直接 `throw`,不自行打印(见 [../logging/](../logging/))。

---

## 可复用模式

### Pattern 1 · 三层 Error 骨架

```swift
// ── 层 1:域错误,只管本模块失败原因 ──
enum CaptureError: LocalizedError, Sendable {
    case permissionDenied
    case windowNotFound(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required"
        case let .windowNotFound(name): return "Window '\(name)' not found"
        }
    }
}

// ── 层 2:顶层统一 Error,遵循 StandardizedError ──
// Peekaboo: Core/PeekabooFoundation/Sources/PeekabooFoundation/PeekabooError.swift:4
public nonisolated enum AppError: StandardizedError {
    case capture(CaptureError)
    case network(NetworkError)
    case operationFailed(String)

    public var code: AppErrorCode { /* 映射到字符串枚举 */ }
    public var userMessage: String { /* 代理到域错误 localizedDescription */ }
    public var context: [String: String] { /* 诊断字典,含路径、NSError code 等 */ }
}

// ── 层 3:跨进程信封,Codable 序列化 ──
// Peekaboo: Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeModels.swift:247
public struct AppErrorEnvelope: Codable, Sendable, Error {
    public let code: AppErrorCode   // 枚举,Codable,rawValue 全大写下划线
    public let message: String      // 用户可读
    public let details: String?     // 可选技术细节
}
```

**为什么不用单一大 enum:**
- 类型信息丢失:无法通过 `switch` 分支判断错误来自哪个子域。
- `errorDescription` 的 `switch` case 数平方级增长,每次新功能都要改同一文件,易产生 merge 冲突。
- 分层后:`CaptureError` 的 `switch` 只处理本域 27 种情况;顶层用 `.capture(CaptureError)` 包一层,调用侧按需解包。

---

### Pattern 2 · `StandardizedError` 三件套协议

```swift
// Peekaboo: Core/PeekabooFoundation/Sources/PeekabooFoundation/StandardizedErrors.swift:47
public protocol StandardizedError: LocalizedError, Sendable {
    nonisolated var code: AppErrorCode { get }       // 机器可读枚举
    nonisolated var userMessage: String { get }      // 纯面向用户自然语言
    nonisolated var context: [String: String] { get } // 开发者诊断 payload
}

// 默认实现:errorDescription 代理到 userMessage
extension StandardizedError {
    public nonisolated var errorDescription: String? { userMessage }
}
```

`nonisolated` 标注使三个属性可以从任意并发上下文访问——Swift 6 的 Sendable 检查要求错误类型本身也是 `Sendable`。

`code` 属性使用字符串枚举(rawValue 全大写下划线风格:`"CAPTURE_FAILED"`)——CLI `--json` 输出时写入 `error_code` 字段,监控告警和测试断言直接对比枚举值。

**为什么 `StandardizedError` 优于裸 `LocalizedError`:**`LocalizedError` 只有四个可选自然语言字符串,没有机器可读错误码,也没有开发者诊断载体。`StandardizedError` 三件套合约让用户消息与诊断 payload 在类型系统层面分离,不依赖调用方遵守约定。

---

### Pattern 3 · `recoverySuggestion` / `suggestedAction` 分层

```swift
// Peekaboo: Core/PeekabooFoundation/Sources/PeekabooFoundation/StandardizedErrors.swift:124
extension StandardizedError {
    public nonisolated var recoverySuggestion: String? {
        switch code {
        case .screenRecordingPermissionDenied:
            return "Grant Screen Recording permission in System Settings"
        case .timeout:
            return "Try the operation again or increase the timeout"
        default:
            return nil  // 验证类错误保持 nil,不要误导用户
        }
    }
}
```

规则:权限类错误**必须**给出 System Settings 具体路径;网络类给出重试提示;验证类保持 `nil`——"无效坐标"不该有恢复建议。

---

### Pattern 4 · `PeekabooBridgeErrorEnvelope` 跨进程编解码

**为什么用 Codable envelope 而非 NSError 桥接:**`NSError` 桥接依赖 ObjC runtime 的 `NSCoding`,无法跨 UNIX socket 序列化层——即使用 `NSXPCConnection` 也需要 `NSSecureCoding` 和类白名单注册,引入大量 ObjC 样板。Codable envelope 方案把错误"压平"为三个 JSON 字段,信封本身遵循 `Error`,接收端解码后直接 `throw`,无需重建原始类型,两端 Swift 运行时类型信息完全解耦。

```swift
// 服务端:将领域语义错误编码为信封
// Peekaboo: Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeServer+ServiceHandlers.swift:175
guard let result = snapshots.getDetectionResult(snapshotId: id) else {
    throw PeekabooBridgeErrorEnvelope(
        code: .notFound,
        message: "No detection result for snapshot \(id)")
}

// 权限类错误附带 permission 字段,客户端可据此引导用户
guard services.permissions.checkAppleScriptPermission() else {
    throw PeekabooBridgeErrorEnvelope(
        code: .permissionDenied,
        message: "AppleScript permission not granted",
        permission: .appleScript)
}
```

```swift
// 客户端:解码失败时包成信封保持类型一致,不把原始 DecodingError 直接 throw
// Peekaboo: Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeClient+Transport.swift:46
do {
    response = try self.decoder.decode(PeekabooBridgeResponse.self, from: responseData)
} catch {
    throw PeekabooBridgeErrorEnvelope(
        code: .decodingFailed,
        message: "Bridge host returned an invalid response",
        details: "\(error)")
}

// 响应为 error case 时直接 throw 信封
case let .error(envelope):
    throw envelope   // PeekabooBridgeErrorEnvelope 本身遵循 Error

// 上游 catch 时可以模式匹配信封字段
} catch let envelope as PeekabooBridgeErrorEnvelope
    where envelope.code == .versionMismatch { ... }
```

**协议演进安全:**新增 `PeekabooBridgeErrorCode` case 时旧版客户端解码会失败(`.decodingFailed`)而不是静默忽略——这是有意的设计,迫使客户端显式处理未知 code。

---

### Pattern 5 · `logged()` 日志桥(catch + log,不丢失 throw)

域错误不自行打印日志,顶层 catch 点(命令入口、MCP 工具入口)负责记录。`logged()` 桥让"记录 + 继续传播"成为一行调用,避免多处 catch 重复 log。

```swift
// 通用 logged 桥——记录后重新 throw,保留原始错误类型
func logged<T>(
    _ label: String,
    logger: Logger,
    _ work: () async throws -> T
) async throws -> T {
    do {
        return try await work()
    } catch {
        logger.error(
            "\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        throw error   // 保留原始错误,不包装
    }
}

// 调用方(顶层入口):
let result = try await logged("captureScreen", logger: logger) {
    try await captureService.captureScreen(displayIndex: 0)
}
```

关键约定:
- 仅在**顶层入口**使用 `logged`(命令入口、MCP 工具入口)。
- 中间层直接 `throw`,不记录日志,避免同一错误被重复记录。
- `logged` **不包装**错误——调用方仍然 catch 原始类型。

详见 [../logging/](../logging/) 中关于"谁 auto-log"的完整约定。

---

### Pattern 6 · `throws` vs `Result` 的取舍

| 场景 | 推荐方式 | 原因 |
|------|---------|------|
| 单个同步/异步操作 | `throws` | async/await 原生整合,调用链简洁 |
| 并发扇出,需收集所有子任务结果 | `[Result<T, Error>]` | `TaskGroup` 内 `addTask` 不能 throw 给外层;用 `Result` 收集后统一处理 |
| 同步流水线,调用方需要保留错误持久化 | `Result<T, E>` | 函数式组合;错误可存入 `struct` 或数组 |
| 测试工厂/stub | `Result<T, E>` | 注入已知失败状态比 mock throw 更直观 |

```swift
// ✅ 并发扇出:用 Result 收集,不用 throws
let results: [Result<SnapshotData, Error>] = await withTaskGroup(
    of: Result<SnapshotData, Error>.self
) { group in
    for id in snapshotIds {
        group.addTask {
            do { return .success(try await fetchSnapshot(id: id)) }
            catch { return .failure(error) }
        }
    }
    return await group.reduce(into: []) { $0.append($1) }
}

// ✅ 单个操作:直接 throws
let snapshot = try await fetchSnapshot(id: currentId)
```

---

### Pattern 7 · `ErrorContext` 构建器

```swift
// Peekaboo: Core/PeekabooFoundation/Sources/PeekabooFoundation/StandardizedErrors.swift:62
public struct ErrorContext {
    private var items: [String: String] = [:]
    public mutating func add(_ key: String, _ value: String) { items[key] = value }
    public mutating func add(_ key: String, _ value: Any)    { items[key] = String(describing: value) }
    public func build() -> [String: String] { items }
}

// 使用:
public var context: [String: String] {
    var ctx = ErrorContext()
    ctx.add("app", appName)
    ctx.add("display_index", displayIndex)
    return ctx.build()
}
```

避免在 `context` 属性里硬编码字典字面量,`ErrorContext` 构建器使 key/value 对逐行添加,代码可读性更好。

---

## 锚点(file:line)

所有路径相对 Peekaboo 仓库根:

| 符号 | 文件:行 | 说明 |
|------|---------|------|
| `StandardizedError` 协议定义 | `Core/PeekabooFoundation/Sources/PeekabooFoundation/StandardizedErrors.swift:47` | `code`、`userMessage`、`context` 三件套 + `nonisolated` + `Sendable` |
| `errorDescription` 默认实现 | `StandardizedErrors.swift:53` | 直接返回 `userMessage` |
| `ErrorContext` 构建器 | `StandardizedErrors.swift:62` | 可变字典构建器 |
| `recoverySuggestion` 默认实现 | `StandardizedErrors.swift:124` | 基于 `code` 的恢复建议 |
| `PeekabooError` 顶层枚举 | `Core/PeekabooFoundation/Sources/PeekabooFoundation/PeekabooError.swift:4` | 同时遵循 `LocalizedError`、`StandardizedError`、`PeekabooErrorProtocol` |
| `code` 属性 | `PeekabooError.swift:149` | 映射到 `StandardErrorCode` 枚举常量 |
| `context` 属性 | `PeekabooError.swift:231` | 按 case 返回诊断字典 |
| `CaptureError` 域错误样本 | `Core/PeekabooFoundation/Sources/PeekabooFoundation/ErrorTypes.swift:9` | 27 个 case,`LocalizedError + Sendable` 最小实现 |
| `PeekabooErrorProtocol` | `Core/PeekabooFoundation/Sources/PeekabooFoundation/ErrorProtocols.swift:21` | 增强协议:`category`、`isRecoverable`、`suggestedAction` |
| `PeekabooBridgeErrorEnvelope` | `Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeModels.swift:247` | 跨进程信封,`Codable + Sendable + Error` |
| 客户端解码保护 | `Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeClient+Transport.swift:46` | 解码失败包成信封,不 type-erase |
| 服务端信封 throw | `Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeServer+ServiceHandlers.swift:175` | 任意 `Error` 映射为信封 |

---

## Pitfalls

**域错误枚举 case 爆炸。** 同一含义的错误被以不同命名重复添加(如 `.screenRecordingPermissionDenied` 与 `.permissionDeniedScreenRecording` 并存)——编译器不告警,调用侧只 catch 其中一个会静默漏掉另一个。预防:新增 case 前先搜索语义等价 case;权限类错误统一归入顶层包装枚举,不在域 Error 里重复定义。

**把诊断信息拼进 `errorDescription`。** 将底层 `NSError.localizedDescription` 或堆栈字符串直接 `+` 进 `errorDescription`,导致用户终端或 Alert 出现 `Error Domain=NSCocoaErrorDomain Code=...` 字样。正确做法:技术细节写入 `context` 字典,`errorDescription` 只保留一句用户能理解的描述。

**Codable envelope 字段加减破坏兼容性。** 新版服务端增加了信封字段(如把 `details: String?` 改为 `details: ErrorDetails?`),旧版客户端解码时报 `DecodingError.typeMismatch`——对应 `.decodingFailed`。处理方式:在信封中加 `schemaVersion: Int = 1` 字段,或将新增字段设为 `Optional` + `decodeIfPresent`(默认 nil)确保向前兼容。

**`@unchecked Sendable` 在 Error 上滥用。** 为绕过 Swift 6 Sendable 检查给含有 `[String: Any]` context 字典的 Error 标注 `@unchecked Sendable`,并发场景下产生 data race。正确处理:将 `context` 改为 `[String: String]`(值类型,天然 Sendable);或在 `context` 访问路径上加 actor 隔离。

**中间层自行 log 导致重复记录。** 中间层在 catch 里调用了 `logger.error(...)` 再 `throw`,顶层入口的 `logged()` 桥会再次记录同一错误。原则:中间层只 `throw`,不记录日志。

---

## 落地 checklist

1. **定义 `StandardizedError` 协议**,确立 `code`、`userMessage`、`context` 三件套为全项目错误合约;协议标注 `Sendable`,所有遵循者也需标注。
2. **为每个功能域创建独立 `enum`**(`CaptureError`、`NetworkError` 等),遵循 `LocalizedError + Sendable`;每个 case 只描述本域失败原因,不混入其他域语义,不自行打印日志。
3. **`errorDescription` 只写面向用户的自然语言**:技术细节(文件路径、底层 `NSError.code`、堆栈摘要)放入 `context` 字典,不拼进 `userMessage`。
4. **引入顶层包装枚举**(`AppError`)遵循 `StandardizedError`;将所有域错误聚合为 `.network(NetworkError)` 等 case;调用侧只 catch 一种顶层类型,需要详细信息时再解包。
5. **为每个跨进程边界写 `Codable` 信封类型**:字段为 `code: MyCodableEnum`、`message: String`、`details: String?`;发送端 `encode(error)`,接收端解码后直接 `throw envelope`——信封本身遵循 `Error`,无需重建原始类型。
6. **版本化信封枚举**:若协议会演进,在信封中加 `version: Int` 字段(默认值 1),新 case 在旧客户端解码失败时降级到 `.unknownCode`(类似 `decodingFailed` 处理)。
7. **暴露 `recoverySuggestion`**:权限类错误**必须**给出 System Settings 具体路径,网络类给出重试提示,验证类保持 `nil`。
8. **在顶层入口用 `logged` 桥记录**:命令入口、MCP 工具入口调用 `logged("opName", logger:) { ... }`,中间层直接 `throw`,不记录日志。
9. **在测试中断言用户消息不含诊断 payload**:验证 `error.userMessage` 不包含 `NSError`、`Foundation._NSSwiftError`、文件绝对路径等技术字符串;分别断言 `code.rawValue`、`userMessage`、`recoverySuggestion`。
10. **定期审查域错误 case 数量**:超过 30 个 case 通常意味着需要引入新的域错误枚举。在 CI 中用 `grep -c "^    case "` 设置阈值告警。

---

## 延伸阅读

- [../logging/](../logging/) — error 走 log 的"谁 auto-log"约定,`logged()` 桥的日志侧配合
- [../concurrency/](../concurrency/) — async error 边界与 `Sendable` 约束(`StandardizedError` 需要 `nonisolated`)
- [../testing/](../testing/) — error path 测试与权限敏感测试 gating
- [../ipc/](../ipc/) — UNIX socket + JSON IPC 全流程,`PeekabooBridgeErrorEnvelope` 的传输层上下文
- Peekaboo 内部:`docs/error-handling-guide.md`(CLI 格式化输出、`ErrorFormatter`、重试策略)
- Apple 官方:[Error Handling](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/)、[LocalizedError](https://developer.apple.com/documentation/foundation/localizederror)、[CustomNSError](https://developer.apple.com/documentation/foundation/customnserror)
