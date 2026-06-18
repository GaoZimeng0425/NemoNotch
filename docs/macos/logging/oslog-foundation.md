---
summary: 'OSLog 底层原理:subsystem/category 两级命名、privacy 标注、Console.app/log stream 调试,以及何时纯 OSLog 就够用。'
read_when:
  - '用 Console.app 或 log stream 调试日志为何看不到'
  - '理解 DDOSLogger 下层的系统 Unified Logging 机制'
  - '评估新项目是否需要 CocoaLumberjack 还是纯 OSLog'
  - '日志中含用户数据、需要 privacy 保护'
sources: ['P03', 'N §18']
last_verified: { peekaboo: '6cee1875', nemonotch: 'fe4e9e5' }
---

# OSLog 底层基础

## TL;DR

macOS Unified Logging(OSLog)是 GUI 应用与 daemon 的系统日志后端:内核异步缓冲写入、`logd` 统一持久化、Console.app 实时过滤、`log stream` 命令行查询。CocoaLumberjack 的 `DDOSLogger` **在 OSLog 上叠加**文件落地能力;NemoNotch 两者一起用(DDOSLogger + DDFileLogger),既得 Console.app 可见性,又得本地文件可 `grep`。

纯 OSLog 适合:无需文件落地、macOS 14+、不需要复杂 sink 管理的新项目或 daemon。

## CocoaLumberjack 与 OSLog 的关系

```
LogService.info(...)
    │
    ▼
DDLogInfo(...)           ← CocoaLumberjack 宏 (CocoaLumberjackSwift)
    │
    ├──▶ DDOSLogger      ← 桥接到 os_log() — Console.app / log stream 可见
    │
    └──▶ DDFileLogger    ← 落盘到 ~/.NemoNotch/logs/ — grep/tail 可用
```

`DDOSLogger.sharedInstance` 内部调用 `os_log()`/`os_signpost()`,所以 NemoNotch 的每条 `LogService.*` 日志**同时出现**在 Console.app 和文件中。这也是为什么 `log stream --predicate 'process == "NemoNotch"'` 能抓到 NemoNotch 日志。

## 可复用模式

### Pattern 1 · subsystem / category 两级命名(Peekaboo 参考)

Peekaboo 以反向域名为 subsystem、功能名词为 category:

```swift
// Core/PeekabooCore/.../PeekabooDaemon.swift:88
private let logger = Logger(subsystem: "boo.peekaboo.core", category: "Daemon")

// Core/PeekabooCore/.../PeekabooBridgeHost.swift:11
// actor 内部用 nonisolated static,避免 Sendable 警告
private nonisolated static let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "host")

// Core/PeekabooCore/.../AudioInputService.swift:59
// @Observable 类中用 @ObservationIgnored 排除 logger 被跟踪
@ObservationIgnored private let logger = Logger(subsystem: "boo.peekaboo.core", category: "AudioInputService")
```

**NemoNotch 的等效位置:** NemoNotch 用 CocoaLumberjack 而非裸 `Logger`,category 通过 `LogService.info("...", category: "MediaService")` 的字符串参数传入。

### Pattern 2 · privacy 标注

privacy 脱敏**不是正则匹配**,而是基于类型与系统规则:

| 类型/形式 | 默认行为 | 说明 |
|-----------|---------|------|
| `Int`、`Bool`、`Float` 等标量 | 永远公开 | 标量无隐私风险 |
| 静态字符串字面量 | 永远公开 | 编译期确定 |
| UUID | 默认 `<private>` | 高熵标识符 |
| 文件路径(以 `/` 开头) | 默认 `<private>` | 可能含用户名 |
| 普通动态字符串(邮箱、token) | **不脱敏,原样输出** | ⚠️ 反直觉 |

```swift
// ✅ 标量无需标注
logger.debug("count=\(count)")

// ✅ 非敏感诊断值主动标 .public
logger.info("Fetching \(url.absoluteString, privacy: .public)")

// ✅ 含用户数据保持默认或显式标注
logger.error("Auth failed for \(userId)")              // → <private>
logger.warning("File: \(filePath, privacy: .private)") // 显式更自记录

// ❌ 普通字符串不会自动脱敏!
logger.info("Token: \(apiToken)")                      // 实测 → 明文输出
// 应改为:
logger.info("Token: \(apiToken, privacy: .private)")
```

### Pattern 3 · Console.app / log stream 调试命令

```bash
# 实时追踪 NemoNotch 日志
log stream --predicate 'process == "NemoNotch"' --level debug

# 按 subsystem 过滤(如果项目配置了 subsystem)
log stream --predicate 'subsystem CONTAINS "boo.peekaboo"' --level debug

# 加 category 精确过滤
log stream --predicate 'subsystem == "boo.peekaboo.core" AND category == "Daemon"' --level info

# 历史查询:最近 1 小时
log show \
  --predicate 'subsystem CONTAINS "boo.peekaboo"' \
  --last 1h \
  --level debug

# 打包归档
log collect --output ~/Desktop/app.logarchive --last 1h
```

### Pattern 4 · 开发机解锁 private data

privacy 脱敏发生在**写入时**。已写入为 `<private>` 的日志无法还原——必须在产生日志**之前**安装配置。

**mobileconfig(推荐,团队统一):**
```bash
# 安装 profile(弹出系统 UI 确认)
open docs/logging-profiles/EnablePeekabooLogPrivateData.mobileconfig
# macOS 15+: System Settings > General > Device Management
# macOS 14:  System Settings > Privacy & Security > Profiles
# 等待 1-2 分钟生效,再重新运行 app 产生新日志
```

**临时方式(当前 session 有效):**
```bash
sudo log config --mode private_data:on \
  --subsystem boo.peekaboo.core --persist
# 调试完毕后重置
sudo log config --reset private_data
```

### Pattern 5 · actor 边界 Logger 声明

```swift
// struct / class:实例属性
private let log = Logger(subsystem: "...", category: "...")

// actor:nonisolated static,避免 Sendable 警告
private nonisolated static let log = Logger(subsystem: "...", category: "...")

// @Observable class:加 @ObservationIgnored 排除跟踪
@ObservationIgnored private let log = Logger(subsystem: "...", category: "...")
```

### Pattern 6 · 何时纯 OSLog 就够用

不需要 CocoaLumberjack 的场景:
- **无文件落地需求**:日志只需要 Console.app 可见,无需 `tail -F` 或 bug report 打包
- **daemon / CLI 工具**:stdout/stderr 被 launchd 捕获,或用户直接在终端看
- **macOS 14+ 新项目**:OSLog 的 Swift overlay(`os.Logger`)已是 first-class,API 简洁

需要 CocoaLumberjack 的场景:
- 需要**本地文件**落地(bug report、`grep` 历史)
- 需要**轮转 + 保留策略**(`DDFileLogger.rollingFrequency` / `maximumNumberOfLogFiles`)
- **跨平台或遗留 ObjC** 代码已集成 CocoaLumberjack

**NemoNotch 选 CocoaLumberjack 的原因**:需要 `~/.NemoNotch/logs/` 文件落地供用户 bug report 和开发者 `tail -F` 实时观测;同时通过 `DDOSLogger` 保留 Console.app 可见性。

## 锚点(file:line)

| 锚点 | 说明 |
|------|------|
| `Core/PeekabooCore/.../PeekabooDaemon.swift:88` | `Logger(subsystem:category:)` 典型声明 |
| `Core/PeekabooCore/.../PeekabooBridgeHost.swift:11` | actor 内 `nonisolated static let logger` |
| `Core/PeekabooCore/.../AudioInputService.swift:59` | `@Observable` 类中 `@ObservationIgnored private let logger` |
| `docs/logging-profiles/EnablePeekabooLogPrivateData.mobileconfig` | mobileconfig 模板 |
| `docs/logging-guide.md` | CLI verbose 格式、`PEEKABOO_LOG_LEVEL`、JSON `debug_logs` 字段 |
| P03(Peekaboo 日志 playbook)行 17 | `typealias SystemLogger = os.Logger` 全项目统一入口 |
| NemoNotch/Services/LogService.swift:15 | `DDLog.add(DDOSLogger.sharedInstance)` — CocoaLumberjack→OSLog 桥接点 |

## Pitfalls

**Pitfall 1:普通字符串不脱敏**

`"user@example.com"` 和 `"sk-1234567890"` 在实测中均以明文出现于 `log stream` 输出。"没有标 `.public`"不等于"安全"——必须显式标 `privacy: .private`。

**Pitfall 2:subsystem 大小写敏感**

`"boo.peekaboo.Core"` 和 `"boo.peekaboo.core"` 是两个不同 subsystem,Console.app 的 predicate 过滤区分大小写。统一用小写。

**Pitfall 3:mobileconfig 作用于写入时**

已写入为 `<private>` 的日志永远无法还原(设计如此)。调试 private 字段前必须先安装 mobileconfig 或临时开启 `log config`,然后重新产生日志。

**Pitfall 4:不用 swift-log**

本知识库统一以 CocoaLumberjack(应用层)/ OSLog(底层)为准,不引入 apple/swift-log。

背景:Peekaboo 的模块分层 playbook(P01,Peekaboo SHA: `6cee1875`)脚手架曾采用 `apple/swift-log` 作为通用后端,但 swift-log 在 macOS 上无法透传 `os.Logger` 的编译期 privacy 标注(协议边界截断了类型安全),且 Console.app 集成不如原生 OSLog 深;NemoNotch 从未引入。新项目一律用 CocoaLumberjack + OSLog,不用 swift-log。

**Pitfall 5:`Logger` 在 actor 内直接作实例属性**

Swift 6 strict concurrency 下,`actor` 中声明 `let log = Logger(...)` 实例属性并在 `async` 闭包中捕获可能报 `Sendable` 警告。用 `private nonisolated static let` 规避(见 Pattern 5)。

**Pitfall 6:debug 日志在高频路径**

OSLog 的内核异步缓冲几乎零阻塞——但如果在每帧/每事件路径大量插值复杂对象,**字符串格式化本身**仍有 CPU 开销。级别 guard 不只是"不输出",更是"不格式化":
```swift
if dynamicLogLevel.rawValue >= DDLogLevel.debug.rawValue {
    logger.debug("frame=\(expensiveDescription())")
}
```

## 落地 checklist

- [ ] 新项目 subsystem 用反向域名,一旦发布不能改(Console.app 历史查询硬编码此字符串)
- [ ] 所有动态字符串插值审查 privacy 标注,不依赖"默认脱敏"保护用户数据
- [ ] `actor` 内用 `nonisolated static let`、`@Observable` 内加 `@ObservationIgnored`
- [ ] 开发机安装 mobileconfig 解锁 private data(产生日志前装好)
- [ ] PR checklist 加 privacy 审查:含凭据/路径/用户 ID 的字段不标 `.public`
- [ ] 评估项目是否需要文件落地;如需要,接入 CocoaLumberjack DDFileLogger

## 延伸阅读

- [cocoalumberjack-logservice.md](./cocoalumberjack-logservice.md) — NemoNotch 的实际实现
- Apple [Logging](https://developer.apple.com/documentation/os/logging)
- Apple [OSLogPrivacy](https://developer.apple.com/documentation/os/oslogprivacy)
- WWDC 2020 [Explore logging in Swift](https://developer.apple.com/videos/play/wwdc2020/10168/)
- WWDC 2023 [Debug with structured logging](https://developer.apple.com/videos/play/wwdc2023/10226/)
- Peekaboo `docs/logging-profiles/README.md` — privacy 实测数据 + mobileconfig 安装详解
- ../concurrency/ — Swift 6 actor isolation 与 nonisolated 边界
