---
summary: 'NemoNotch LogService:DDOSLogger + DDFileLogger,日轮转 7 份,nonisolated 静态 API,任意线程可调。'
read_when:
  - '为新服务添加日志调用'
  - '在 actor / @MainActor 边界打日志不想被并发警告'
  - '调整 DEBUG vs Release 日志级别'
  - '需要日志文件落地或 grep/tail 过滤'
sources: ['N §18']
last_verified: { nemonotch: 'fe4e9e5' }
---

# CocoaLumberjack — LogService

## TL;DR

`LogService` 是一个 47 行的薄包装(NemoNotch/Services/LogService.swift)。它在 `init()` 时往 `DDLog` 注册两个 appender:
- `DDOSLogger.sharedInstance` — 把日志桥接到系统 Unified Logging,Console.app 可见
- `DDFileLogger` — 日志文件落入 `~/.NemoNotch/logs/`,日轮转,保留 7 份

对外只暴露四个 `nonisolated static` 函数:`debug / info / warn / error`。**这四个函数不经过 `shared` 单例**——它们直接调 DDLog 的全局宏(`DDLogDebug` 等),`shared` 只用于初始化(注册 appender)。

## 可复用模式

### Pattern 1 · 初始化与 appender 注册

```swift
// NemoNotch/Services/LogService.swift:7-28
final class LogService {
    nonisolated(unsafe) static let shared = LogService()   // ① 单例,仅用于 init
    private let fileLogger: DDFileLogger

    private init() {
        let logDir = NSHomeDirectory() + "/.NemoNotch/logs"
        // 创建目录(如不存在)
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        DDLog.add(DDOSLogger.sharedInstance)               // ② Console.app 桥接

        let logFileManager = DDLogFileManagerDefault(logsDirectory: logDir)
        logFileManager.maximumNumberOfLogFiles = 7         // ③ 保留 7 份(约一周)
        fileLogger = DDFileLogger(logFileManager: logFileManager)
        fileLogger.rollingFrequency = 60 * 60 * 24        // ④ 单位:秒,每天轮转
        DDLog.add(fileLogger)

        #if DEBUG
            dynamicLogLevel = .all
        #else
            dynamicLogLevel = .info                        // ⑤ release 丢弃 debug/verbose
        #endif
    }
}
```

关键注解:
- ① `nonisolated(unsafe) static let` 是合法的全局单例写法——DDLog 内部线程安全,详见 cookbook §15.5。**不要**把这个模式复制到 `@Observable` 服务,那些服务有 actor-bound 状态。
- ③ `maximumNumberOfLogFiles = 7` 是"文件份数"上限,而非"天数"——但与 ④ 的日轮转组合等同于约 7 天保留。
- ④ `rollingFrequency` 单位是**秒**,`24 * 60 * 60` = 86400 = 一天;若误写成 `24` 则每 24 秒轮转一次。
- ⑤ `.debug` / `.verbose` 级别在 release 时由 DDLog 宏在**调用层**截断;但参数表达式仍然求值(Swift 不是宏展开),见 §Pitfalls。

### Pattern 2 · 静态 API(不经过 shared)

```swift
// NemoNotch/Services/LogService.swift:31-47
extension LogService {
    nonisolated static func debug(_ message: String, category: String = "App") {
        DDLogDebug("[\(category)] \(message)")
    }
    nonisolated static func info(_ message: String, category: String = "App") {
        DDLogInfo("[\(category)] \(message)")
    }
    nonisolated static func warn(_ message: String, category: String = "App") {
        DDLogWarn("[\(category)] \(message)")
    }
    nonisolated static func error(_ message: String, category: String = "App") {
        DDLogError("[\(category)] \(message)")
    }
}
```

**关键事实(§18.2 的核心修正):**

`shared` 单例与这四个静态函数**是两个独立机制**:
- `shared` 的唯一职责是运行 `init()` — 注册 appender、设置 `dynamicLogLevel`。它在程序启动时由 `AppDelegate` 调用 `_ = LogService.shared`(cookbook 2507 行)来强制触发初始化。
- `debug/info/warn/error` 直接调 `DDLogDebug` 等全局宏,**不通过 `shared` 访问任何实例状态**。你可以在 `shared` 初始化之前调用它们——但 appender 尚未注册,日志会静默丢失。所以约定:AppDelegate 在最早的生命周期点先初始化 `shared`,再启动其他服务。

`nonisolated static` 的意义:任意 actor、任意线程都可直接调用,无需 `await`、无 isolation 切换。

### Pattern 3 · 调用约定(category = 模块名)

```swift
// 典型调用站 — cookbook §18.4
LogService.info("daemon spawned pid=\(pid)", category: "NowPlayingCLI")
LogService.debug("[Media] notification: \(name.rawValue)", category: "MediaService")
LogService.warn("DisplayServicesGetBrightness symbol not found", category: "HUD")
LogService.error("dlopen MediaRemote failed: \(String(cString: dlerror()))", category: "MediaRemote")
```

`category` 用**模块/服务名**(`"MediaService"`, `"HookServer"`, `"NotchCoordinator"`, `"NowPlayingCLI"`, `"OpenClaw"`)。这样可以:

```bash
tail -F ~/.NemoNotch/logs/*.log | grep '\[HookServer\]'
grep '\[NowPlayingCLI\]' ~/.NemoNotch/logs/*.log
```

### Pattern 4 · CLAUDE.md 规定的覆盖要求

CLAUDE.md §Logging 要求每个新功能在以下点必须打日志:

| 位置 | 级别 | 内容 |
|------|------|------|
| Service init/deinit | `.info` | 生命周期标记 |
| 网络请求、IPC、文件 I/O、子进程 | `.info`(成功)/ `.error`(失败) | 操作 + 结果 |
| 关键状态变化(playback、session phase、连接状态) | `.debug` | 前值/后值 |
| catch / nil fallback / 超时 / 权限拒绝 | `.warn` 或 `.error` | 上下文 |
| Timer / NotificationCenter / Delegate 回调入口 | `.debug` | 确认回调触发 |

## 锚点(file:line)

| 锚点 | 说明 |
|------|------|
| `NemoNotch/Services/LogService.swift:4` | `nonisolated(unsafe) static let shared` 单例声明 |
| `LogService.swift:7-28` | `init()`:目录创建、DDOSLogger、DDFileLogger、rollingFrequency、dynamicLogLevel |
| `LogService.swift:31-47` | 四个 `nonisolated static` 函数(extension) |
| cookbook §15.5 (行 2360-2368) | `nonisolated(unsafe) static let shared` 模式说明 |
| cookbook §18 (行 2637-2701) | 完整 §18 Logging conventions |
| cookbook §18.1 (行 2641) | DDFileLogger setup 代码 |
| cookbook §18.2 (行 2662) | Static API + Gotcha 说明 |
| cookbook §18.3 (行 2680) | DEBUG vs Release 级别 |
| cookbook §18.4 (行 2694) | Category 命名约定 |
| cookbook 行 2507 | `_ = LogService.shared` AppDelegate 强制初始化 |

## Pitfalls

**Pitfall 1:`shared` 与静态函数是两回事**

cookbook §18.2 原文写法容易被误读为"静态函数通过 shared 单例打日志"。实际是:

- `shared` = 初始化副作用(appender 注册)
- `debug/info/warn/error` = 直接调 DDLog 宏,**与 shared 无关**

如果 `LogService.shared` 从未被访问,appender 不会注册,DDLog 有收到宏调用但没有 sink 可以处理——日志静默消失。AppDelegate 中必须有 `_ = LogService.shared` 触发初始化。

**Pitfall 2:debug 参数仍然求值**

```swift
// ❌ 危险:即使 release 截断,formatHeavyStruct() 仍被调用
LogService.debug("state=\(formatHeavyStruct(currentState))", category: "Foo")

// ✅ 把昂贵计算藏到条件里
if dynamicLogLevel.rawValue >= DDLogLevel.debug.rawValue {
    LogService.debug("state=\(formatHeavyStruct(currentState))", category: "Foo")
}
```

DDLog 宏在 release 截断日志输出,但 Swift 函数参数是**即时求值**——传入 `message` 的表达式在 `DDLogDebug` 被调用前已执行。高频路径(每帧、每事件)的 debug 日志必须守 level guard。

**Pitfall 3:`rollingFrequency` 单位是秒**

`fileLogger.rollingFrequency = 24` 会每 24 **秒**轮转一次。正确写法:`60 * 60 * 24`(一天)。

**Pitfall 4:默认 `category: "App"` 是陷阱**

漏填 `category:` 时所有日志都归入 `[App]`,`grep` 过滤失效。团队约定:新增 `LogService.*` 调用必须显式传 `category:`。

**Pitfall 5:日志目录在沙盒中不可写**

当前日志写入 `~/.NemoNotch/logs/`(非 `~/Library/Logs/`)。若将来启用 App Sandbox,这个路径在沙盒容器外,会写失败。需迁移到 `~/Library/Containers/<bundle-id>/Data/Library/Logs/`。

**Pitfall 6:不要把这个单例模式复制给 @Observable 服务**

`nonisolated(unsafe) static let shared` 只对**内部线程安全的对象**安全(DDLog 满足)。`@Observable` 服务绑定 MainActor 状态,用全局单例会绕过编译器的竞态检测。

## 落地 checklist

- [ ] `AppDelegate` 最早生命周期点调用 `_ = LogService.shared` 触发 appender 注册
- [ ] 每个新 Service 的 `init` 写 `.info` 级别生命周期日志
- [ ] 所有 `LogService.*` 调用显式传 `category:`(不用默认 `"App"`)
- [ ] 高频回调(每帧/每事件)的 debug 日志加 level guard
- [ ] 新功能覆盖 CLAUDE.md §Logging 规定的五类锚点(init、外部交互、状态变化、错误路径、异步回调)

## 延伸阅读

- [oslog-foundation.md](./oslog-foundation.md) — 理解 DDOSLogger 下层的 OSLog 机制,Console.app 过滤与 privacy
- ../concurrency/ — Swift 6 actor isolation 与 `nonisolated(unsafe)` 边界
- ../error-handling/ — 错误路径 `.warn/.error` 的日志策略
