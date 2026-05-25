---
summary: 'Model errors in three layers (domain enum / cross-domain wrapper / Codable envelope) with StandardizedError protocol for user message separation.'
read_when:
  - 'designing a typed error hierarchy in a multi-module macOS app'
  - 'serializing errors across CLI/GUI process boundaries'
---

# 04 · 错误处理

## TL;DR

macOS 系统集成应用的错误横跨权限、自动化、网络、AI 等多个域。Peekaboo 的解法是**三层架构**:域错误(`CaptureError`、`AudioInputError` 等)精确描述单模块失败原因;顶层包装枚举 `PeekabooError` 承担跨域统一,遵循 `StandardizedError` 协议;跨进程 IPC 边界(CLI ↔ Mac App)则用 `PeekabooBridgeErrorEnvelope`(`Codable + Sendable + Error`)序列化为 JSON 传输。`StandardizedError` 协议规定了 `code`(枚举常量)、`userMessage`(纯用户可读)、`context`(开发者诊断字典)三件套合约:`LocalizedError.errorDescription` 直接代理到 `userMessage`,永远不拼入底层堆栈或 `NSError` 细节;`context` 字典仅在 `--verbose` / `--json` 模式下输出。跨进程错误路径在服务端编码为 `{code, message, details}` JSON,客户端解码后重建 `PeekabooBridgeErrorEnvelope` 类型再次 `throw`,与 03 · 日志的约定协作:域错误不自行打印,顶层 catch 点(命令入口、MCP 工具入口)负责 `logger.error(...)` 后重新 throw。

## Peekaboo 在哪里实现

- 模块:`PeekabooFoundation`(`Core/PeekabooFoundation/`)
- 关键文件:`Core/PeekabooFoundation/Sources/PeekabooFoundation/StandardizedErrors.swift:47` — `StandardizedError` 协议定义:`code`、`userMessage`、`context` 三件套 + `nonisolated` + `Sendable`;`:53` — `errorDescription` 默认实现直接返回 `userMessage`
- 关键文件:`Core/PeekabooFoundation/Sources/PeekabooFoundation/PeekabooError.swift:4` — 顶层 `PeekabooError` 枚举同时遵循 `LocalizedError`、`StandardizedError`、`PeekabooErrorProtocol` 三个协议;`:149` — `code` 属性映射到 `StandardErrorCode` 枚举常量;`:231` — `context` 属性按 case 返回诊断字典
- 关键文件:`Core/PeekabooFoundation/Sources/PeekabooFoundation/ErrorTypes.swift:9` — `CaptureError`(域错误样本,27 个 case,展示 `LocalizedError + Sendable` 最小实现)
- 关键文件:`Core/PeekabooFoundation/Sources/PeekabooFoundation/ErrorProtocols.swift:21` — `PeekabooErrorProtocol`:带 `category`、`isRecoverable`、`suggestedAction` 的增强协议
- 关键文件:`Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeModels.swift:247` — `PeekabooBridgeErrorEnvelope`:跨进程序列化信封,`Codable + Sendable + Error`,字段:`code(PeekabooBridgeErrorCode)`、`message`、`details?`、`permission?`
- 关键文件:`Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeClient+Transport.swift:46` — 解码失败时封装为新 `PeekabooBridgeErrorEnvelope(code: .decodingFailed)` 再 throw,保持信封类型不被 type-erased
- 相关 docs:`docs/error-handling-guide.md`

## 设计动机(Why)

### 为什么不把所有错误塞进一个大 enum

单 enum 方案看起来最简单:`enum AppError { case permissionDenied; case windowNotFound; case networkFailed; ... }`。问题在两点:

**类型信息丢失**。`PeekabooError.captureFailed("reason")` 与 `CaptureError.captureFailed("reason")` 携带相同语义,但调用侧无法通过 `switch` 分支来判断"这个错误是来自网络层还是 UI 层"——所有上下文都挤进 case 的 associated value 字符串里。当某个模块想要添加特定的重试策略或用户引导时,只能靠字符串前缀判断,维护成本随 case 数量平方级增长。

**`LocalizedError` 翻译爆炸**。`errorDescription` 的 `switch` 需要穷举所有 case。Peekaboo 的 `PeekabooError` 已经有 30+ case,`CaptureError` 单独有 27 个——合并后单一 `switch` 将超过 60 条分支,且每次新增功能都需要改同一文件,极易引发 merge 冲突和遗漏分支。

分层设计的收益:`CaptureError` 的 `switch` 只负责截图相关的 27 种情况;顶层 `PeekabooError` 用 `.capture(CaptureError)` 包一层,调用侧 catch 时只匹配一种顶层类型,需要详细信息时再解包内层。

### 为什么用 `StandardizedError` 协议而不只是 `LocalizedError`

`LocalizedError` 只规定了 `errorDescription`、`failureReason`、`recoverySuggestion`、`helpAnchor` 四个可选字符串——全是面向用户的自然语言,没有机器可读的错误码,也没有开发者诊断载体。

`StandardizedError` 在此基础上加了三件套合约:

| 属性 | 类型 | 用途 |
|------|------|------|
| `code` | `StandardErrorCode` | 机器可读枚举,CLI `--json` 输出、测试断言、监控告警 |
| `userMessage` | `String` | 纯面向用户的自然语言,`errorDescription` 直接代理到此处 |
| `context` | `[String: String]` | 开发者诊断 payload:文件路径、底层 NSError code、session ID 等 |

`nonisolated` 标注使三个属性可以从任意并发上下文访问——这对 `actor` 内部 throw 出来的错误在外部 catch 时很重要,Swift 6 的 Sendable 检查要求错误类型本身也是 `Sendable`(见 `StandardizedErrors.swift:47`)。

### 跨进程通信为何用 Codable envelope 而非 NSError 桥接

CLI 进程与 Mac App(Bridge Host)之间使用 UNIX socket + JSON 通信。`NSError` 桥接依赖 Objective-C runtime 的 `NSCoding` 机制,无法跨越进程边界的序列化层——即使通过 `NSXPCConnection` 也需要 `NSSecureCoding` 和注册类白名单,引入大量 Objective-C 样板。

`PeekabooBridgeErrorEnvelope` 方案的核心思路是:把错误"压平"为三个 JSON 字段(`code`、`message`、`details`),发送方在服务端将任意 `Error` 映射到信封,接收方解码后将信封直接 `throw`——信封本身就遵循 `Error`,无需再次重建原始类型。这样两端的 Swift 运行时类型信息完全解耦,协议演进时只需维护枚举 `PeekabooBridgeErrorCode` 的 `Codable` 兼容性。

真实代码体现(见 `PeekabooBridgeClient+Transport.swift:46`):

```swift
// 解码失败时,不把原始 DecodingError 直接 throw
// 而是包成信封保持类型一致,上游 catch 只需处理一种类型
do {
    response = try self.decoder.decode(PeekabooBridgeResponse.self, from: responseData)
} catch {
    throw PeekabooBridgeErrorEnvelope(
        code: .decodingFailed,
        message: "Bridge host returned an invalid response",
        details: "\(error)")
}
```

## 核心模式(Pattern)

### Pattern 1 · 三层 Error 骨架

```swift
// ── 层 1:域错误,只管本模块失败原因 ──
enum CaptureError: LocalizedError, Sendable {
    case permissionDenied
    case windowNotFound(String)
    // ...27 个 case
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is required"
        case let .windowNotFound(name): return "Window '\(name)' not found"
        }
    }
}

// ── 层 2:顶层统一 Error,遵循 StandardizedError ──
// Core/PeekabooFoundation/Sources/PeekabooFoundation/PeekabooError.swift:4
public nonisolated enum PeekabooError: LocalizedError, StandardizedError, PeekabooErrorProtocol {
    case captureFailed(String)    // 域错误被"压平"为顶层 case
    case appNotFound(String)
    // ...

    public var code: StandardErrorCode { /* 映射到字符串枚举 */ }
    public var userMessage: String      { self.errorDescription ?? "Unknown error" }
    public var context: [String: String]{ /* 诊断字典 */ }
}

// ── 层 3:跨进程信封,Codable 序列化 ──
// Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeModels.swift:247
public struct PeekabooBridgeErrorEnvelope: Codable, Sendable, Error {
    public let code: PeekabooBridgeErrorCode  // 枚举,Codable
    public let message: String                // 用户可读
    public let details: String?               // 可选技术细节
    public let permission: PeekabooBridgePermissionKind?  // 权限类错误附带
}
```

### Pattern 2 · `StandardizedError` 三件套协议

```swift
// Core/PeekabooFoundation/Sources/PeekabooFoundation/StandardizedErrors.swift:47
public protocol StandardizedError: LocalizedError, Sendable {
    nonisolated var code: StandardErrorCode { get }
    nonisolated var userMessage: String { get }
    nonisolated var context: [String: String] { get }
}

// 默认实现:errorDescription 代理到 userMessage,不拼诊断信息
extension StandardizedError {
    public nonisolated var errorDescription: String? { userMessage }
}
```

`code` 属性使用 `StandardErrorCode` 枚举(`StandardizedErrors.swift:6`),rawValue 是全大写下划线风格的字符串常量(`"CAPTURE_FAILED"`)——CLI `--json` 输出时写入 `error_code` 字段,监控告警和测试断言直接对比枚举值即可。

### Pattern 3 · `PeekabooBridgeErrorEnvelope` 跨进程编解码

服务端(Mac App Bridge Host)将任意 `Error` 映射为信封 `throw`(见 `PeekabooBridgeServer+ServiceHandlers.swift:175`):

```swift
// 服务端:将领域语义错误编码为信封
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

客户端(CLI)在 Transport 层接收 JSON 响应时解码为信封,再 `throw`(见 `PeekabooBridgeClient+Transport.swift:63`):

```swift
// 客户端:解码响应,信封 case 直接 throw
case let .error(envelope):
    throw envelope   // PeekabooBridgeErrorEnvelope 本身遵循 Error

// 上游 catch 时可以模式匹配信封字段:
} catch let envelope as PeekabooBridgeErrorEnvelope
    where envelope.code == .versionMismatch { ... }
```

**协议演进安全**:新增 `PeekabooBridgeErrorCode` case 时旧版 CLI 解码会失败(`.decodingFailed`)而不是静默忽略——这是有意的设计,优于 `decodeIfPresent` 默认值的方式,因为它迫使客户端显式处理未知 code。

### Pattern 4 · throws vs Result 的取舍

| 场景 | 推荐方式 | 原因 |
|------|---------|------|
| 单个同步/异步操作 | `throws` | async/await 原生整合,调用链简洁 |
| 并发扇出,需收集所有子任务结果 | `[Result<T, Error>]` | `TaskGroup` 内 `group.addTask` 不能 throw 给外层;用 `Result` 收集后统一处理 |
| 同步流水线,调用方需要保留错误持久化 | `Result<T, E>` | 函数式组合;错误可存入 `struct` 或数组 |
| 测试工厂/stub | `Result<T, E>` | 注入已知失败状态比 mock throw 更直观 |

```swift
// ✅ 并发扇出:用 Result 收集,不用 throws
let results: [Result<SnapshotData, Error>] = await withTaskGroup(
    of: Result<SnapshotData, Error>.self
) { group in
    for id in snapshotIds {
        group.addTask {
            do {
                return .success(try await fetchSnapshot(id: id))
            } catch {
                return .failure(error)
            }
        }
    }
    return await group.reduce(into: []) { $0.append($1) }
}

// ✅ 单个操作:直接 throws
let snapshot = try await fetchSnapshot(id: currentId)
```

### Pattern 5 · catch + log 桥(自动 log 而不丢失 throw)

03 · 日志的约定是:域错误不自行打印,顶层 catch 点负责记录。但实际业务中多个层次都需要"记录 + 继续传播",手动在每处 catch 写 `logger.error(...)` 再 `throw` 容易遗漏。

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

// 调用方:
let result = try await logged("captureScreen", logger: logger) {
    try await captureService.captureScreen(displayIndex: 0)
}
```

该函数不包装错误——调用方仍然 catch 原始类型,不引入新的类型层。仅在**顶层入口**(命令入口、MCP 工具入口)使用;中间层直接 `throw`,不调用 `logged`。

### Pattern 6 · `recoverySuggestion` / `suggestedAction` 分层

`StandardizedErrors.swift:124` 中 `StandardizedError` extension 提供了基于 `code` 的默认建议:

```swift
extension StandardizedError {
    public nonisolated var recoverySuggestion: String? {
        switch code {
        case .screenRecordingPermissionDenied:
            "Grant Screen Recording permission in System Settings"
        case .accessibilityPermissionDenied:
            "Grant Accessibility permission in System Settings"
        case .timeout:
            "Try the operation again or increase the timeout"
        default:
            nil
        }
    }
}
```

权限类错误**必须**给出 System Settings 路径;网络类错误给出重试提示;验证类错误保持 `nil`——不要给"无效坐标"提供恢复建议,那会误导用户。

### Pattern 7 · `ErrorContext` 构建器

`StandardizedErrors.swift:62` 的 `ErrorContext` 是一个简单的可变字典构建器,用于在 `context` 属性的实现中避免硬编码字典字面量:

```swift
// Core/PeekabooFoundation/Sources/PeekabooFoundation/StandardizedErrors.swift:62
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

## 完整代码示例(Starter Code)

以下单个 Swift 文件展示了完整的三层错误架构实现,可直接拷入新项目使用。

```swift
// ErrorHandlingStarter.swift
// Demonstrates the three-layer error architecture used in Peekaboo.
// Requires: Swift 6.2+, macOS 14+, import os

import Foundation
import os.log

// MARK: - Layer 0: Error Code Registry (machine-readable constants)

public enum AppErrorCode: String, Sendable, Codable {
    // Network
    case networkTimeout          = "NETWORK_TIMEOUT"
    case networkUnreachable      = "NETWORK_UNREACHABLE"
    case networkBadStatus        = "NETWORK_BAD_STATUS"
    // Persistence
    case persistenceWriteFailed  = "PERSISTENCE_WRITE_FAILED"
    case persistenceReadFailed   = "PERSISTENCE_READ_FAILED"
    case persistenceNotFound     = "PERSISTENCE_NOT_FOUND"
    // Generic
    case unknownError            = "UNKNOWN_ERROR"
}

// MARK: - Layer 0: StandardizedError Protocol (three-piece contract)

/// Three-piece contract: code (machine-readable) + userMessage (human-readable) + context (diagnostics).
/// `errorDescription` is automatically delegated to `userMessage` so LocalizedError callers
/// always receive the user-facing message, never raw diagnostic payloads.
public protocol StandardizedError: LocalizedError, Sendable {
    nonisolated var code: AppErrorCode { get }
    nonisolated var userMessage: String { get }
    nonisolated var context: [String: String] { get }
}

extension StandardizedError {
    public nonisolated var errorDescription: String? { userMessage }
    public nonisolated var context: [String: String] { [:] }  // default: empty
}

// MARK: - Layer 1: Domain Errors (one enum per module)

/// Network domain: only describes networking failures.
/// Does NOT inherit StandardizedError — domain errors stay lean.
public enum NetworkError: Error, LocalizedError, Sendable {
    case timeout(host: String, after: TimeInterval)
    case unreachable(host: String)
    case badStatus(Int, url: String)

    public var errorDescription: String? {
        switch self {
        case let .timeout(host, seconds):
            return "Connection to \(host) timed out after \(Int(seconds))s"
        case let .unreachable(host):
            return "Host \(host) is unreachable"
        case let .badStatus(code, url):
            return "Server returned HTTP \(code) for \(url)"
        }
    }
}

/// Persistence domain.
public enum PersistenceError: Error, LocalizedError, Sendable {
    case writeFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case notFound(key: String)

    public var errorDescription: String? {
        switch self {
        case let .writeFailed(path, reason): return "Failed to write \(path): \(reason)"
        case let .readFailed(path, reason):  return "Failed to read \(path): \(reason)"
        case let .notFound(key):             return "Record '\(key)' not found"
        }
    }
}

// MARK: - Layer 2: Top-level Wrapper (StandardizedError — cross-domain unification)

/// AppError wraps all domain errors. Callers only need to catch one type.
/// Conforming to StandardizedError separates userMessage from diagnostic context.
public nonisolated enum AppError: StandardizedError {
    case network(NetworkError)
    case persistence(PersistenceError)
    case operationFailed(String)

    // Machine-readable code for JSON output, monitoring alerts, and test assertions.
    public var code: AppErrorCode {
        switch self {
        case let .network(e):
            switch e {
            case .timeout:     return .networkTimeout
            case .unreachable: return .networkUnreachable
            case .badStatus:   return .networkBadStatus
            }
        case let .persistence(e):
            switch e {
            case .writeFailed: return .persistenceWriteFailed
            case .readFailed:  return .persistenceReadFailed
            case .notFound:    return .persistenceNotFound
            }
        case .operationFailed:
            return .unknownError
        }
    }

    // User-facing message: never contains stack traces, NSError domain strings,
    // or raw file paths.
    public var userMessage: String {
        switch self {
        case let .network(e):       return e.localizedDescription
        case let .persistence(e):   return e.localizedDescription
        case let .operationFailed(msg): return msg
        }
    }

    // Developer diagnostics: shown only in --verbose / --json mode.
    public var context: [String: String] {
        switch self {
        case let .network(e):
            switch e {
            case let .timeout(host, seconds):
                return ["host": host, "timeout_seconds": "\(Int(seconds))"]
            case let .unreachable(host):
                return ["host": host]
            case let .badStatus(code, url):
                return ["http_status": "\(code)", "url": url]
            }
        case let .persistence(e):
            switch e {
            case let .writeFailed(path, reason): return ["path": path, "reason": reason]
            case let .readFailed(path, reason):  return ["path": path, "reason": reason]
            case let .notFound(key):             return ["key": key]
            }
        case .operationFailed:
            return [:]
        }
    }

    // Optional recovery suggestion. Permission errors MUST provide System Settings path.
    // Validation errors return nil — do not mislead users with inapplicable suggestions.
    public var recoverySuggestion: String? {
        switch self {
        case .network: return "Check your network connection and try again."
        case .persistence: return nil
        case .operationFailed: return nil
        }
    }
}

// MARK: - Layer 3: Cross-process Envelope (Codable serialization over IPC)

/// Flattens any AppError into three JSON fields for UNIX-socket / XPC transport.
/// The envelope itself conforms to Error so callers can `throw` it directly after decoding.
public struct AppErrorEnvelope: Codable, Sendable, Error {
    public let code: AppErrorCode    // machine-readable, Codable
    public let userMessage: String   // human-readable message
    public let details: String?      // optional diagnostic details

    public init(code: AppErrorCode, userMessage: String, details: String? = nil) {
        self.code = code
        self.userMessage = userMessage
        self.details = details
    }
}

// MARK: - Envelope Codec (AppError ↔ AppErrorEnvelope)

extension AppErrorEnvelope {
    /// Encode an AppError into a transport envelope.
    /// Called on the server side before serialising to JSON.
    public static func encode(_ error: AppError) -> AppErrorEnvelope {
        AppErrorEnvelope(
            code: error.code,
            userMessage: error.userMessage,
            details: error.context.isEmpty ? nil
                : error.context.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        )
    }

    /// Attempt to rebuild a rich AppError from an envelope.
    /// Returns nil for unknown codes — callers should treat the envelope itself as the error.
    public func toAppError() -> AppError? {
        switch code {
        case .networkTimeout:
            return .network(.timeout(host: context(for: "host") ?? "unknown", after: 30))
        case .persistenceNotFound:
            return .persistence(.notFound(key: context(for: "key") ?? "unknown"))
        default:
            return nil  // unknown code: caller uses envelope.userMessage directly
        }
    }

    private func context(for key: String) -> String? {
        // Parse "key=value; key2=value2" back into a lookup
        details?.split(separator: ";")
            .compactMap { pair -> (String, String)? in
                let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]), String(parts[1]))
            }
            .first { $0.0 == key }?
            .1
    }
}

// MARK: - Catch + Log Bridge

/// Wraps an async throwing closure: logs on failure then re-throws the original error.
/// Use ONLY at top-level entry points (command entry, MCP tool entry).
/// Intermediate layers should `throw` directly without calling `logged`.
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
        throw error   // preserve original error type — do NOT wrap
    }
}

// MARK: - Demo: Full Call Chain

@main
struct ErrorHandlingDemo {
    static func main() async {
        let logger = Logger(subsystem: "com.example.app", category: "Main")

        // ── 1. throws path ──────────────────────────────────────────────
        do {
            let _ = try await logged("fetchUserData", logger: logger) {
                try await fetchUserData(userId: "alice")
            }
        } catch let appError as AppError {
            print("AppError code:", appError.code.rawValue)
            print("User message:", appError.userMessage)
            print("Context:", appError.context)
            if let suggestion = appError.recoverySuggestion {
                print("Suggestion:", suggestion)
            }
        } catch let envelope as AppErrorEnvelope {
            // Cross-process path: envelope was decoded and re-thrown
            print("IPC Error [\(envelope.code.rawValue)]:", envelope.userMessage)
            if let details = envelope.details { print("Details:", details) }
        } catch {
            print("Unexpected:", error)
        }

        // ── 2. Result fan-out path ────────────────────────────────────────
        let userIds = ["alice", "bob", "carol"]
        let results: [Result<String, Error>] = await withTaskGroup(
            of: Result<String, Error>.self
        ) { group in
            for id in userIds {
                group.addTask {
                    do {
                        return .success(try await fetchUserData(userId: id))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        for (id, result) in zip(userIds, results) {
            switch result {
            case let .success(data): print("\(id): \(data)")
            case let .failure(error): print("\(id) failed: \(error.localizedDescription)")
            }
        }
    }

    // Simulates a function that can throw AppError
    static func fetchUserData(userId: String) async throws -> String {
        if userId == "alice" {
            throw AppError.network(.timeout(host: "api.example.com", after: 30))
        }
        return "data:\(userId)"
    }
}
```

## 新项目落地步骤(How to apply)

1. **定义 `StandardizedError` 协议**(或直接复制 `StandardizedErrors.swift` 中的版本),确立 `code`、`userMessage`、`context` 三件套为全项目错误合约;协议标注 `Sendable`,所有遵循者也需标注。

2. **为每个功能域创建独立 `enum`**(`CaptureError`、`NetworkError` 等),遵循 `LocalizedError + Sendable`;每个 case 只描述本域失败原因,不混入其他域的语义,不自行打印日志。

3. **`errorDescription` 只写面向用户的自然语言**:技术细节(文件路径、底层 `NSError.code`、堆栈摘要)放入 `context` 字典,不拼进 `userMessage`。

4. **引入顶层包装枚举**(`AppError` / `PeekabooError`)遵循 `StandardizedError`;将所有域错误聚合为 `.network(NetworkError)` 等 case;调用侧只 catch 一种顶层类型,需要详细信息时再解包。

5. **为每个跨进程边界写 `Codable` 信封类型**(`AppErrorEnvelope`):字段为 `code: MyCodableEnum`、`message: String`、`details: String?`;发送端 `encode(error)`,接收端解码后直接 `throw envelope`——信封本身遵循 `Error`,无需重建原始类型。

6. **版本化信封枚举**:若协议会演进,在信封中加 `version: Int` 字段(默认值 1),新 case 在旧客户端解码失败时降级到 `.unknownCode`(类似 `PeekabooBridgeErrorCode` 的 `decodingFailed` 处理)。

7. **暴露 `recoverySuggestion` / `suggestedAction`**:权限类错误**必须**给出 System Settings 具体路径,网络类给出重试提示,验证类保持 `nil`。

8. **在顶层入口用 `logged` 桥记录**:命令入口、MCP 工具入口调用 `logged("opName", logger:) { ... }`,中间层直接 `throw`,不记录日志,避免同一错误被重复记录(见 [03 · 日志](./03-logging-observability.md))。

9. **在测试中断言用户消息不含诊断 payload**:验证 `error.userMessage` 不包含 `NSError`、`Foundation._NSSwiftError`、文件绝对路径等技术字符串;分别断言 `code.rawValue`、`userMessage`、`recoverySuggestion` 的期望值。

10. **定期审查域错误 case 数量**:在 CI 中用 `grep -c "^    case " Core/PeekabooFoundation/Sources/.../ErrorTypes.swift` 输出 case 数并设置阈值告警——超过 30 个 case 通常意味着需要引入新的域错误枚举而非继续往一个 enum 里塞。

## 替代方案对比

| 方案 | 优点 | 缺点 | 何时选 |
|------|------|------|-------|
| **本方案:三层 + StandardizedError + Codable envelope** | 类型信息保留;用户消息隔离;跨进程友好;机器可读 code | 初始样板代码多;需维护多个枚举文件 | 中大型 app,有 CLI/GUI/Daemon 多 host |
| **单 enum 大 case** | 简单;一处定义 | case 数膨胀;`errorDescription` switch 难以维护;跨模块 PR 冲突频繁 | < 20 个错误的小工具 |
| **NSError + userInfo** | Cocoa 框架友好;ObjC 桥接自然 | type-erased;Swift 类型推断弱;`userInfo` 字典无类型约束 | 主要靠 Cocoa API 且需要 ObjC 互操作的项目 |
| **`Result<T, E>` 作为主要传播方式** | 显式;函数式组合;批量收集友好 | async/await 时代代码冗长;不是 Swift 惯用风格 | 同步流水线;并发扇出结果收集(`TaskGroup` 内部) |
| **第三方:swift-error-extras / Sentry SDK** | 自动上报、错误聚合、Slack 告警 | 引入三方依赖;隐私敏感(错误上传到外部服务器) | 需要 telemetry 后端的产品 |

**本方案的局限**:Mac App Store 沙盒下若使用 `NSXPCConnection` 做进程间通信,Cocoa 要求 `NSSecureCoding`——此时 `Codable` 信封无法直接传输,需改为 `NSError` + `userInfo` 字典桥接,或在 XPC 协议方法中直接传递已序列化的 `Data`(JSON)再在另一端解码。

## 调试与取证

| 症状 | 排查命令 | 根因 |
|------|---------|------|
| 用户 Alert 显示英文堆栈或 NSCocoaErrorDomain | `log show --predicate 'category == "Error"' --last 5m` 查看实际 `error.localizedDescription` | `errorDescription` 直接拼接了 `NSError.localizedDescription` 或底层堆栈字符串 |
| CLI `--json` 输出 envelope 字段缺失 | `peekaboo <cmd> --json 2>&1 \| jq '.error \| {code, message, context}'` | envelope 编码时遗漏了字段,或 `context` 字典没有序列化为 JSON |
| Error 被 catch 但日志没有记录 | 在 catch 添加 `logger.error(...)` 后重跑;或在 `logged` 桥入口打断点 | 中间层直接吞掉了 error(`catch { }` 空体),或忘记调用 `logged` 桥 |
| 跨进程 Error 解码失败(`decodingFailed`) | `log stream --predicate 'subsystem CONTAINS "bridge"' --info` 查看原始 JSON;再用 `jq` 检查 `code` 字段值 | 服务端新增了 `PeekabooBridgeErrorCode` case,客户端枚举没有同步更新(协议演进不兼容) |
| `LocalizedError.errorDescription` 返回 nil | LLDB: `po error.localizedDescription` 返回 Optional.none | 域错误 enum 没有实现 `LocalizedError` 默认(或没有遵循 `StandardizedError` 的 `errorDescription` 代理) |
| 错误类型膨胀难以追踪 | `grep -rn "^    case " Core/ \| grep -c "case"` 统计每个文件 case 数 | 没有分层 wrapper,所有 case 堆入同一 enum |

**常用工具集**:

```bash
# 实时监控 Error category 日志(开发机)
log stream \
  --predicate 'subsystem CONTAINS "boo.peekaboo" AND category == "Error"' \
  --level debug

# 查询最近 5 分钟 error 级别日志
log show \
  --predicate 'subsystem CONTAINS "boo.peekaboo"' \
  --last 5m \
  --level error

# 解析 CLI JSON 输出中的错误信封
peekaboo see --app Finder --json 2>&1 | jq '.error | {code, message, context}'

# 检查 Bridge 通信错误(含 details 字段)
log stream \
  --predicate 'subsystem == "boo.peekaboo.bridge"' \
  --info \
  --level debug

# LLDB 交互式排查
# (lldb) po error
# (lldb) po (error as? AppError)?.code
# (lldb) po (error as? AppError)?.context
# (lldb) frame variable
# (lldb) bt
```

## 常见陷阱(Pitfalls)

**域错误枚举 case 爆炸**。随功能迭代,同一含义的错误被以不同命名重复添加。典型信号:`CaptureError` 同时存在 `.screenRecordingPermissionDenied`(第 13 行)和 `.permissionDeniedScreenRecording`(第 28 行)——编译器不告警,调用侧只 catch 其中一个时会静默漏掉另一个。预防方法:新增 domain error case 前先搜索语义等价 case;权限类错误统一归入顶层 `PeekabooError.permissionDenied*` 系列,不在域 Error 里重复定义。

**把诊断信息拼进 `errorDescription`**。将底层 `NSError.localizedDescription` 或堆栈字符串直接 `+` 进用户可见的 `errorDescription`,导致用户终端或 Alert 出现 `Error Domain=NSCocoaErrorDomain Code=...` 或 `Foundation._NSSwiftError` 字样。正确做法:技术细节写入 `context` 字典,`errorDescription` 只保留一句用户能理解的描述。

**Codable envelope 字段加减破坏兼容性**。新版 Server 增加了信封字段(例如把 `details: String?` 改为 `details: ErrorDetails?`),旧版 CLI 解码时报 `DecodingError.typeMismatch`——对应 `PeekabooBridgeErrorCode.decodingFailed`。可观测信号:旧 CLI 二进制对新版 App 的所有跨进程调用返回 `decodingFailed`。处理方式:在信封中加 `schemaVersion: Int = 1` 字段,客户端先检查版本再解码;或将新增字段设为 `Optional` + `decodeIfPresent`(默认 nil)确保向前兼容。

**`@unchecked Sendable` 在 Error 上滥用**。为绕过 Swift 6 Sendable 检查,给含有 `[String: Any]` context 字典的 Error 标注 `@unchecked Sendable`。可观测信号:并发场景下 context 字典从多个 task 并发读写,产生 data race(runtime 崩溃或 TSan 告警)。正确处理:将 `context` 改为 `[String: String]`(值类型,天然 Sendable);或在 `context` 访问路径上加 actor 隔离。

## 延伸阅读

- Peekaboo 内部:`docs/error-handling-guide.md`(CLI 格式化输出、`ErrorFormatter`、重试策略)
- Apple 官方:[Error Handling](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/)
- Apple 官方:[LocalizedError](https://developer.apple.com/documentation/foundation/localizederror)、[CustomNSError](https://developer.apple.com/documentation/foundation/customnserror)
- 其它 playbook:[02 · Swift 6 并发](./02-swift6-concurrency.md)(async error 边界与 Sendable 约束)、[03 · 日志](./03-logging-observability.md)(error 走 log 的"谁 auto-log"约定)、[12 · 测试](./12-testing-permission-gated.md)(error path 测试与权限敏感测试 gating)

---
*Last verified against Peekaboo @ `d576fa0f`*
