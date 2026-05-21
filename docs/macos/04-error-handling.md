---
summary: 'Model errors in three layers—domain, cross-domain wrapper, and Codable envelope—to separate user messages from diagnostic payloads.'
read_when:
  - 'designing error types that span multiple modules or cross process boundaries'
  - 'improving error messages shown to users while preserving detailed diagnostics for developers'
---

# 04 · 错误处理

## TL;DR

macOS 系统集成应用的错误横跨权限、自动化、网络、AI 等多个域,如果每个模块各自定义 Error 类型,调用侧的 catch 很快就变成无穷的 `if let`。Peekaboo 的解法是三层架构:域错误(`CaptureError`、`AudioInputError` 等)描述具体失败原因;顶层包装类型 `PeekabooError` 承担跨域统一;跨进程边界则用 `PeekabooBridgeErrorEnvelope`(Codable)序列化传输。`LocalizedError` 负责用户可读消息,`context: [String: String]` 附带开发者诊断 payload,两者在同一个 case 里分离,互不干扰。

## Peekaboo 在哪里实现

- 模块:`PeekabooFoundation`(Core/PeekabooFoundation/)
- 关键文件:`Core/PeekabooFoundation/Sources/PeekabooFoundation/PeekabooError.swift:4` — 顶层 `PeekabooError` 枚举,同时遵循 `LocalizedError`、`StandardizedError`、`PeekabooErrorProtocol` 三个协议
- 关键文件:`Core/PeekabooFoundation/Sources/PeekabooFoundation/StandardizedErrors.swift:47` — `StandardizedError` 协议定义:`code`、`userMessage`、`context` 三件套
- 关键文件:`Core/PeekabooFoundation/Sources/PeekabooFoundation/ErrorTypes.swift:9` — `CaptureError`(域错误样本,27 个 case)
- 关键文件:`Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeModels.swift:247` — `PeekabooBridgeErrorEnvelope`:跨进程序列化信封,`Codable + Sendable + Error`
- 相关 docs:`docs/error-handling-guide.md`

## 设计动机(Why)

Peekaboo 早期让各模块自由定义 Error 类型,结果 `CaptureError`、`PermissionError`、`WindowError` 各自独立演化。到了集成阶段,`CaptureError` 里同时出现了 `.screenRecordingPermissionDenied` 和 `.permissionDeniedScreenRecording` 两个语义相同的 case(见 `ErrorTypes.swift:19,28`),调用者只能用穷举 switch 才能捕获完整。

另一个踩坑点是跨进程传输。CLI 进程与 host 进程之间使用 XPC 风格的 Bridge 通信,Swift Error 不能直接跨进程传递——必须序列化。`PeekabooBridgeErrorEnvelope` 的 `Codable` 设计由此而来:发送方将错误编码为 `{code, message, details}` 三字段 JSON,接收方解码后重建语义,不依赖任何 Swift 运行时类型信息。

用户可读消息与开发者诊断分离的需求来自真实报告:初期把底层 `NSError.localizedDescription`(常含 Objective-C 类名和堆栈片段)直接拼进 `errorDescription`,用户在终端看到满屏看不懂的英文。`StandardizedError` 协议把这两条路分开:`userMessage` 保证是面向用户的自然语言,`context` 字典只在 `--verbose` / `--json` 模式下输出。

## 核心模式(Pattern)

**三层 Error 骨架**:

```swift
// ── 层 1:域错误,只管本模块失败原因 ──
enum CaptureError: LocalizedError {
    case permissionDenied
    case windowNotFound(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:  return "Screen Recording permission is required"
        case let .windowNotFound(name): return "Window '\(name)' not found"
        }
    }
}

// ── 层 2:顶层统一 Error,遵循 StandardizedError ──
enum AppError: StandardizedError {
    case capture(CaptureError)
    case network(String)

    var code: StandardErrorCode { /* 映射到字符串常量 */ }
    var userMessage: String      { /* 用户可读,不含技术细节 */ }
    var context: [String: String]{ /* 开发者诊断 payload */ }
}

// ── 层 3:跨进程信封,Codable 序列化 ──
struct BridgeErrorEnvelope: Codable, Error {
    let code: String        // "CAPTURE_FAILED"
    let message: String     // 用户可读
    let details: String?    // 可选技术细节
}
```

**throws vs Result**:函数内部传递用 `throws`,使调用链保持简洁;只在需要并发扇出(多任务并行收集结果)或需要在值类型中持久化错误时改用 `Result`。

**谁负责日志**:顶层 catch 点(命令入口、MCP 工具入口)负责 `logger.error(...)`,域错误不自行打印——见 [03 · 日志](./03-logging-observability.md) 的"谁 auto-log"约定。

## 新项目落地步骤(How to apply)

1. 定义 `StandardizedError` 协议(或直接复制 `StandardizedErrors.swift` 中的版本),确立 `code`、`userMessage`、`context` 三件套为全项目错误合约。
2. 封装各功能域错误为独立 `enum`(`CaptureError`、`NetworkError` 等),每个 case 只描述该域特有的失败原因,不混入其它域的语义。
3. 标注 `errorDescription` 时只写面向用户的自然语言,技术细节(文件路径、底层 `NSError.code`)放入 `context` 字典,不拼进 `userMessage`。
4. 分层引入顶层 `AppError`(或等价包装枚举),将所有域错误聚合为 `.capture(CaptureError)`、`.network(...)` 等 case,调用侧只需 catch 一种类型。
5. 封装跨进程/跨边界传输的 Error 为 `Codable` 信封结构体(`code: String` + `message: String` + 可选 `details: String?`),发送前序列化,接收后从信封重建语义,不依赖 Swift 运行时类型。
6. 暴露 `recoverySuggestion`(或 `suggestedAction`)字段:权限类错误给出 System Settings 跳转路径,网络类错误给出重试提示,验证类错误保持 `nil`。
7. 补充错误测试:验证 `code` 字符串常量、`userMessage` 不含技术噪音、`recoverySuggestion` 非 nil 的 case 有明确文字。

## 常见陷阱(Pitfalls)

**域错误枚举 case 爆炸**:随着功能迭代,同一含义的错误被重复添加为不同 case 名。典型信号:同一文件里出现含义相同但命名互为镜像的 case(如 `CaptureError` 中同时存在 `.screenRecordingPermissionDenied`(第 12 行)和 `.permissionDeniedScreenRecording`(第 28 行))。编译器对此不告警,bug 在于调用侧只 catch 其中一个 case 时会漏掉另一个。

可观测信号:对一个枚举做 exhaustive `switch` 时,编译器生成的 case 数量超过 20;或 grep 某文件 `"case "` 行数远大于预期(`grep -c "case " ErrorTypes.swift` 返回 81,对一个 27-case 枚举来说正常,但代码审查时可定期执行此命令核查是否有重复语义 case)。

预防:引入顶层统一枚举后,在域 Error 的 PR checklist 中要求新增 case 前先搜索是否已有语义等价 case;权限类错误统一归入顶层 `PeekabooError.permissionDenied*` 系列,不在域 Error 里重复定义。

**把诊断信息拼进 `errorDescription`**:将底层 `NSError.localizedDescription` 或堆栈字符串直接 `+` 进用户可见的 `errorDescription`,导致用户终端或 Alert 中出现 Objective-C 类名、文件路径等无法理解的英文。可观测信号:用户反馈或截图中错误信息包含 `Error Domain=NSCocoaErrorDomain Code=...` 或 `Foundation._NSSwiftError` 字样。正确做法:技术细节写入 `context` 字典,仅在 `--verbose` / `--json` 模式下输出,`errorDescription` 只保留一句用户能理解的描述。

## 延伸阅读

- Peekaboo:`docs/error-handling-guide.md`
- Apple:[Error Handling](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/)
- 其它 playbook:[02 · Swift 6 并发](./02-swift6-concurrency.md)、[03 · 日志](./03-logging-observability.md)、[12 · 测试](./12-testing-permission-gated.md)

---
*Last verified against Peekaboo @ `8d68d182`*
