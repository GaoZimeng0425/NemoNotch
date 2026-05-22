---
summary: 'Use OSLog as the unified logging backend with subsystem/category conventions, privacy markers, and mobileconfig for development unlock.'
read_when:
  - 'wiring up logging for a new macOS app with both CLI and GUI components'
  - 'debugging missing or over-redacted logs in Console.app'
---

# 03 · 日志与可观测性

## TL;DR

macOS 的 Unified Logging(OSLog)是 GUI 应用与系统 daemon 的首选日志后端:日志写入内核缓冲区、不阻塞主线程、Console.app 可实时过滤、系统级落盘由 `logd` 统一管理。Peekaboo 以 `typealias SystemLogger = os.Logger` 作为全项目唯一的日志类型,所有模块按反向域名格式的 `subsystem`(如 `boo.peekaboo.core`)加功能性 `category`(如 `"Daemon"`)两级分类,既能在 Console.app 精准筛选,又能通过 `.mobileconfig` 配置文件在开发机上临时解除隐私脱敏。CLI 侧额外维护一套并行的 stderr 文本格式(`[timestamp] LEVEL [Category]: msg`),两种输出互不干扰——前者服务于 Console.app 和 `log` 命令行工具,后者供终端脚本人工阅读。`privacy:` 标注是显式 API 契约而非运行期猜测:简单字符串(邮箱、API key 前缀)在默认配置下**不会被脱敏**,只有 UUID 和文件路径等特定模式才触发 `<private>` 替换;新项目应主动为所有含用户数据的插值字段标注隐私级别。CLI / GUI / Daemon 三形态共用同一 `Logger` 实例池,Console.app 的过滤结果覆盖整个产品线。

## Peekaboo 在哪里实现

- 模块:`PeekabooCore`(`Core/PeekabooCore/Sources/PeekabooCore/`)、`PeekabooBridge`(`Core/PeekabooCore/Sources/PeekabooBridge/`)
- 关键文件:`Core/PeekabooCore/Sources/PeekabooCore/Support/PeekabooServices.swift:426` — `typealias SystemLogger = os.Logger`,全项目统一日志类型入口;`:65` — `PeekabooServices` 自身使用 `SystemLogger(subsystem: "boo.peekaboo.core", category: "Services")` 的典型声明方式
- 关键文件:`Core/PeekabooCore/Sources/PeekabooCore/Daemon/PeekabooDaemon.swift:88` — `private let logger = Logger(subsystem: "boo.peekaboo.core", category: "Daemon")`,展示 subsystem 与 category 的命名惯例;`:129` — 典型调用站:`self.logger.info("Peekaboo daemon started mode=\(self.configuration.mode.rawValue)")`(标量插值,无需 privacy 标注)
- 关键文件:`Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeClient.swift:12` — `actor PeekabooBridgeClient` 内的 logger 声明:`let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "client")`;跨进程 bridge 使用独立 subsystem `boo.peekaboo.bridge` 与核心服务的 `boo.peekaboo.core` 分离
- 关键文件:`Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeHost.swift:11` — `private nonisolated static let logger = Logger(...)`;actor 内部用 `nonisolated static` 声明 logger 避免 `Sendable` 警告的典型写法
- 关键文件:`Core/PeekabooCore/Sources/PeekabooAutomation/Services/Audio/AudioInputService.swift:59` — `@Observation @ObservationIgnored private let logger = Logger(subsystem: "boo.peekaboo.core", category: "AudioInputService")`;在 `@Observable` 类中用 `@ObservationIgnored` 排除 logger 被观察
- 关键文件:`docs/logging-profiles/EnablePeekabooLogPrivateData.mobileconfig` — `PayloadType: com.apple.system.logging` + `Enable-Private-Data: true`,按 subsystem 分段精准开启 private data 捕获;关键 key: `Subsystems.boo.peekaboo.core.DEFAULT-OPTIONS.Enable-Private-Data`
- 相关 docs:`docs/logging-guide.md`(CLI verbose 格式、`PEEKABOO_LOG_LEVEL`、JSON `debug_logs` 字段)、`docs/logging-profiles/README.md`(隐私机制实测数据 + mobileconfig 安装步骤)

## 设计动机(Why)

### 为什么不用 `print()` 或 `NSLog()`

`print()` 将所有内容直接输出到 stdout,没有日志级别、没有结构化字段、没有 privacy 保护——敏感值原样出现在终端或被管道传入任意下游进程。`NSLog` 略好:它写入 Console.app,但仅支持 `%@` 格式化字符串,同样没有 privacy 标注,且在写入量较大时会阻塞调用线程。两者的共同缺陷是**无法在 Console.app 按应用/模块过滤**:一旦其他进程日志量多,目标应用的输出就被淹没。

OSLog 的内核缓冲写入是**异步零拷贝**:日志数据先写入共享内存,`logd` 在后台批量持久化,调用线程几乎不受影响;在 `--debug` 级别关闭时,格式化字符串甚至不会被求值(编译器插入条件 guard)。这是 `print`/`NSLog` 在高频路径(如每帧、每事件)上不可接受而 OSLog 可以接受的根本原因。

### 为什么不自封装一层抽象

常见的做法是定义一个 `protocol Logger { func log(...) }`,在生产实现中桥接 OSLog,在测试中注入 mock。Peekaboo 有意避开这条路:

1. **OSLog 已经是最优接口**:它的 Swift overlay 提供了字符串插值的编译期 privacy 检查,自封装层无法透传这个类型安全性——一旦包在协议后面,`\(value, privacy: .public)` 的编译期标注就失效了。
2. **层数越少越好诊断**:当日志丢失或乱序时,排查步骤是"OSLog → Console.app",中间层只会增加假设面积。
3. **测试验证不依赖 mock logger**:Peekaboo 的测试策略是验证**副作用**(截图结果、自动化操作结果)而不是验证"某条 log 被调用了 N 次";需要验证输出时直接用 `log stream` 命令行工具在集成测试中抓取。

唯一例外:`typealias SystemLogger = os.Logger` 是一个零成本的名字别名,它不引入协议边界,只是为了让全仓库 import 路径统一(避免部分文件写 `import os` 而非 `import os.log`),换一个名字无需改调用站。

### `privacy:` 字段的实际行为

macOS 的 privacy 脱敏**不是正则匹配**,而是基于插值值的类型与运行期格式规则:

| 类型 | 默认行为 | 原因 |
|------|---------|------|
| `Int`、`Bool`、`Float`、`Double` 等标量 | **永远公开**,无法脱敏 | 标量无隐私风险,系统强制 public |
| 静态字符串字面量(`"Hello"`) | **永远公开** | 编译期确定,不含运行期数据 |
| UUID(如 `Foundation.UUID`) | 默认 `<private>` | UUID 格式被识别为高熵标识符 |
| 文件路径(以 `/` 开头的字符串) | 默认 `<private>` | 可能含用户名等个人信息 |
| 普通动态字符串(如邮箱、API token) | **不触发脱敏**,原样输出 | ⚠️ 反直觉!系统不会识别语义 |

最后一条是最大陷阱:`"user@example.com"` 和 `"sk-1234567890abcdef"` 在 Peekaboo 的实测中均以明文出现在 `log stream` 输出里(见 `docs/logging-profiles/README.md:39-43`)。**不能把"默认脱敏"等同于"一定安全"**——正确做法是对所有可能含用户隐私的字段主动标注 `privacy: .private`(或保持默认、避免传入),只对确认不敏感的诊断值标 `privacy: .public`。

privacy 脱敏发生在**写入时**:如果没有安装 mobileconfig 或运行 `log config --mode private_data:on`,被标注为 `<private>` 的值**永远不会被存储**——`sudo log show` 也无法还原,因为原始值从未进入磁盘。这是 Apple 设计的有意选择,也是为什么 `sudo` 无法"解锁"已写入的 private log 的根本原因。

## 核心模式(Pattern)

### Pattern 1 · subsystem / category 命名规范

`subsystem` 使用反向域名定位到产品,**按功能域分 subsystem 而不是按 Swift 模块分**。Peekaboo 的分法:

| subsystem | 覆盖范围 |
|-----------|---------|
| `boo.peekaboo.core` | Core 服务、Daemon、Audio、Agent Runtime |
| `boo.peekaboo.bridge` | UNIX socket IPC(BridgeClient/Host/Server) |
| `boo.peekaboo.app` | macOS GUI App |
| `boo.peekaboo.cli` | CLI tool 专属路径 |
| `boo.peekaboo.inspector` | PeekabooInspector app |

`category` 用**名词**标识功能模块或 actor/class 名,与类名保持一致,方便在 Console.app 的 `category:` 过滤中精确匹配(如 `category:Daemon`、`category:AudioInputService`)。不要用动词或描述行为的词作 category——它是过滤标签,不是 log message 本身。

```swift
// Core/PeekabooCore/Sources/PeekabooCore/Daemon/PeekabooDaemon.swift:88
private let logger = Logger(subsystem: "boo.peekaboo.core", category: "Daemon")
```

### Pattern 2 · privacy 标注

```swift
// ✅ 标量永远公开,无需标注
logger.debug("Element count: \(elementCount)")         // Int → 公开
logger.info("Daemon started mode=\(mode.rawValue)")    // 枚举 rawValue → 公开

// ✅ 非敏感诊断值主动标注 .public,方便 Console.app 显示
logger.info("Fetching \(url, privacy: .public)")       // URL 路径 → 明确公开
logger.debug("Op: \(operation.rawValue, privacy: .public)")

// ✅ 含用户数据的字段保持默认(= .private)或明确标注
logger.error("Auth failed for \(userId)")              // → <private>,正确
logger.warning("File not found: \(filePath, privacy: .private)")  // 明确标注更自记录

// ❌ 普通字符串不会自动脱敏!
logger.info("Token: \(apiToken)")                      // 实测 → 明文输出!
// 应改为:
logger.info("Token: \(apiToken, privacy: .private)")
```

### Pattern 3 · 开发机解锁私有数据

**首选:安装 mobileconfig(团队统一,无需每次 sudo)**

```bash
# 从仓库打开 profile,按系统提示安装
open docs/logging-profiles/EnablePeekabooLogPrivateData.mobileconfig
# macOS 15+ → System Settings > General > Device Management
# macOS 14  → System Settings > Privacy & Security > Profiles
# 安装后等待 1-2 分钟生效

# 验证:生成新日志
./peekaboo --version
# 查看 private 字段是否已解锁
log stream --predicate 'subsystem CONTAINS "boo.peekaboo"' --level debug
```

**备选:临时 `log config`(无需 mobileconfig,仅当前 session 有效)**

```bash
sudo log config --mode private_data:on \
  --subsystem boo.peekaboo.core \
  --subsystem boo.peekaboo.bridge \
  --persist
# 调试完毕后重置(重要!)
sudo log config --reset private_data
```

**注意**:mobileconfig 的 `Enable-Private-Data` 作用于**写入时**,必须在产生日志**之前**安装好;对已写入的 `<private>` 日志无效。

### Pattern 4 · Console.app 实时筛选与命令行等效

```bash
# 实时流式输出 debug 级别
log stream \
  --predicate 'subsystem CONTAINS "boo.peekaboo"' \
  --level debug

# 叠加 category 过滤
log stream \
  --predicate 'subsystem == "boo.peekaboo.core" AND category == "Daemon"' \
  --level info

# 历史查询(最近 1 小时)
log show \
  --predicate 'subsystem CONTAINS "boo.peekaboo"' \
  --start "$(date -v-1H '+%Y-%m-%d %H:%M:%S')" \
  --level debug

# Console.app 搜索栏等效输入:
#   subsystem:boo.peekaboo.core category:Daemon
```

### Pattern 5 · `Logger` extension 集中管理实例

避免在每个文件中各自硬编码 `Logger(subsystem: "boo.peekaboo.core", category: "Foo")` 散落——typo 会导致 Console.app 过滤失效且难以察觉。将所有 logger 实例集中到一个 extension 文件:

```swift
// Logger+Peekaboo.swift
import OSLog

extension Logger {
    // MARK: - boo.peekaboo.core
    static let daemon   = Logger(subsystem: "boo.peekaboo.core", category: "Daemon")
    static let services = Logger(subsystem: "boo.peekaboo.core", category: "Services")
    static let audio    = Logger(subsystem: "boo.peekaboo.core", category: "AudioInputService")

    // MARK: - boo.peekaboo.bridge
    static let bridgeClient = Logger(subsystem: "boo.peekaboo.bridge", category: "client")
    static let bridgeHost   = Logger(subsystem: "boo.peekaboo.bridge", category: "host")
    static let bridgeServer = Logger(subsystem: "boo.peekaboo.bridge", category: "server")
}
```

调用时 `Logger.daemon.info(...)`,subsystem 字符串只在一处定义,重构时全局生效。

### Pattern 6 · CLI / GUI / Daemon 三形态共享 logger

三形态共享同一 subsystem/category 命名空间,Console.app 的 predicate 过滤可统一覆盖整条链路。CLI 侧**额外**写 stderr 文本(供终端交互和脚本 `grep`),但底层同样调用 `Logger` 实例:

```swift
// CLI 层的 verbose 输出包装器(非 OSLog 替代,是并行输出)
func verboseLog(_ message: String, category: String, level: String = "VERBOSE") {
    let ts = ISO8601DateFormatter().string(from: Date())
    fputs("[\(ts)] \(level) [\(category)]: \(message)\n", stderr)
    // OSLog 同步写入,不影响上面的 stderr 输出
}

// GUI 层: 只用 OSLog,不写 stderr
// Daemon 层: 只用 OSLog,stdout/stderr 均保持干净
// CLI 层: OSLog + stderr 双写
```

`--json` 模式下,CLI 将 stderr 文本行收入输出结构体的 `debug_logs` 字段,方便自动化脚本消费(见 `docs/logging-guide.md:129-144`)。

## 完整代码示例(Starter Code)

以下 6 个文件组成新 macOS 项目的日志脚手架,可直接拷入使用。macOS 11+ (`os.Logger` 的现代 Swift overlay) 要求。

```swift
// MARK: - 1. Logging+Subsystems.swift
// 全项目唯一的 subsystem 常量定义。
// 放在 Foundation 层(或 PeekabooCore 同级),供所有模块 import。
// macOS 11+

import Foundation

public enum LogSubsystem {
    /// 主应用 bundle identifier 即 subsystem 根,其余按功能域加后缀
    public static let core      = "com.acme.myapp.core"
    public static let ui        = "com.acme.myapp.ui"
    public static let network   = "com.acme.myapp.network"
    public static let bridge    = "com.acme.myapp.bridge"
    public static let cli       = "com.acme.myapp.cli"
}
```

```swift
// MARK: - 2. Logger+Categories.swift
// 集中管理所有 Logger 实例,避免 subsystem 字符串散落各文件。
// 新增模块时只在此文件加一行,不需改其他地方。

import OSLog

extension Logger {
    // MARK: Core
    public static let services  = Logger(subsystem: LogSubsystem.core,    category: "Services")
    public static let daemon    = Logger(subsystem: LogSubsystem.core,    category: "Daemon")
    public static let audio     = Logger(subsystem: LogSubsystem.core,    category: "AudioInput")
    public static let agent     = Logger(subsystem: LogSubsystem.core,    category: "AgentRuntime")

    // MARK: UI
    public static let mainWindow = Logger(subsystem: LogSubsystem.ui,     category: "MainWindow")
    public static let menuBar    = Logger(subsystem: LogSubsystem.ui,     category: "MenuBar")

    // MARK: Network
    public static let network   = Logger(subsystem: LogSubsystem.network, category: "NetworkClient")

    // MARK: Bridge (IPC)
    public static let bridgeHost   = Logger(subsystem: LogSubsystem.bridge, category: "host")
    public static let bridgeClient = Logger(subsystem: LogSubsystem.bridge, category: "client")

    // MARK: CLI
    public static let cliCommand = Logger(subsystem: LogSubsystem.cli,   category: "Command")
}
```

```swift
// MARK: - 3. NetworkService.swift (典型 call site 示例)
// 展示 privacy 标注最佳实践:URL 主动标 .public,token/userid 保持默认脱敏。

import Foundation
import OSLog

public actor NetworkService {
    // actor 内部用 nonisolated static 声明,避免 Sendable 警告
    private nonisolated static let log = Logger.network

    public func fetch(_ url: URL) async throws -> Data {
        // URL.absoluteString 是动态字符串,但 URL 本身通常是非敏感的请求路径 → .public
        Self.log.info("Fetching \(url.absoluteString, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse else {
            Self.log.error("Non-HTTP response for \(url.absoluteString, privacy: .public)")
            throw URLError(.badServerResponse)
        }

        // 状态码是 Int → 标量,永远公开,无需标注
        Self.log.debug("Response \(http.statusCode) bytes=\(data.count)")

        if http.statusCode >= 400 {
            // 不要把 response body 打进 log — 可能含用户数据
            Self.log.warning("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public)")
        }
        return data
    }

    public func authenticate(userId: String, token: String) async throws {
        // userId 和 token 含用户身份信息 → 保持默认脱敏(= .private)
        // 如果需要调试,安装 mobileconfig 即可看到;生产日志中永远是 <private>
        Self.log.info("Authenticating user \(userId) token=\(token)")
        //                                  ^^^^^^         ^^^^^^^ → 均脱敏为 <private>
    }
}
```

```swift
// MARK: - 4. PeekabooLogger.swift (CLI/GUI/Daemon 三形态共享工厂)
// CLI 模式下额外写 stderr 文本;GUI/Daemon 只用 OSLog。
// 两者互不冲突,Console.app 的 predicate 过滤在任意形态下均有效。

import Foundation
import OSLog

public enum HostingEnvironment {
    case cli        // 命令行工具,用户面向 terminal
    case gui        // macOS.app,用户不看 terminal
    case daemon     // 后台 daemon,stdout/stderr 被 launchd 捕获
}

public struct PeekabooLogger {
    public let environment: HostingEnvironment
    private let oslog: Logger

    public init(subsystem: String, category: String, environment: HostingEnvironment) {
        self.oslog = Logger(subsystem: subsystem, category: category)
        self.environment = environment
    }

    /// 写 OSLog,CLI 模式下同时写 stderr
    public func info(_ message: String, category: String? = nil) {
        oslog.info("\(message, privacy: .public)")
        writeStderrIfCLI(message: message, level: "INFO", category: category)
    }

    public func debug(_ message: String, category: String? = nil) {
        oslog.debug("\(message, privacy: .public)")
        writeStderrIfCLI(message: message, level: "DEBUG", category: category)
    }

    public func warning(_ message: String, category: String? = nil) {
        oslog.warning("\(message, privacy: .public)")
        writeStderrIfCLI(message: message, level: "WARN", category: category)
    }

    public func error(_ message: String, category: String? = nil) {
        oslog.error("\(message, privacy: .public)")
        writeStderrIfCLI(message: message, level: "ERROR", category: category)
    }

    // MARK: Private

    private func writeStderrIfCLI(message: String, level: String, category: String?) {
        guard environment == .cli else { return }
        let ts = isoTimestamp()
        let cat = category.map { " [\($0)]" } ?? ""
        fputs("[\(ts)] \(level)\(cat): \(message)\n", stderr)
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
```

```swift
// MARK: - 5. CLIOutputEnvelope.swift (--json 模式日志收集)
// CLI 命令在 --json 模式下将 debug log 收入 JSON 输出的 debug_logs 字段,
// 方便自动化脚本或 AI agent 消费。

import Foundation

public struct CLIOutputEnvelope<T: Encodable>: Encodable {
    public var success: Bool
    public var data: T?
    public var error: String?
    /// 仅在 --verbose + --json 同时开启时填充
    public var debugLogs: [String]?

    private enum CodingKeys: String, CodingKey {
        case success, data, error
        case debugLogs = "debug_logs"
    }

    public init(success: Bool, data: T? = nil, error: String? = nil, debugLogs: [String]? = nil) {
        self.success = success
        self.data = data
        self.error = error
        self.debugLogs = debugLogs
    }
}

/// 在 CLI 命令执行期间收集 verbose log 行
public final class DebugLogCollector {
    private var lines: [String] = []
    private let iso = ISO8601DateFormatter()

    public init() {
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func append(_ message: String, level: String = "VERBOSE", category: String? = nil) {
        let ts = iso.string(from: Date())
        let cat = category.map { " [\($0)]" } ?? ""
        lines.append("[\(ts)] \(level)\(cat): \(message)")
    }

    public func collected() -> [String] { lines }
}
```

```bash
# MARK: - 6. install-logging-profile.sh
# 安装 mobileconfig 脚本,供 onboarding 或 CI 环境一键配置。
# 需要用户交互确认(profiles install 会弹出系统 UI)。

#!/usr/bin/env bash
set -euo pipefail

PROFILE="docs/logging-profiles/EnablePeekabooLogPrivateData.mobileconfig"
PROFILE_NAME="Peekaboo Private Data Logging"

if [ ! -f "$PROFILE" ]; then
  echo "ERROR: profile not found at $PROFILE" >&2
  exit 1
fi

echo "Installing logging profile: $PROFILE_NAME"
echo "This will prompt for authentication in System Settings."
echo ""

# profiles install 会打开系统 UI 让用户确认安装
open "$PROFILE"

echo ""
echo "Follow the prompts in System Settings:"
echo "  macOS 15+: General > Device Management"
echo "  macOS 14 : Privacy & Security > Profiles"
echo ""
echo "After installation, wait 1-2 minutes, then run:"
echo "  log stream --predicate 'subsystem CONTAINS \"boo.peekaboo\"' --level debug"
echo "to verify private data is now visible."
```

## 新项目落地步骤

1. **定义 subsystem 常量**:新建 `Logging+Subsystems.swift`,写入 `enum LogSubsystem` 枚举(参考 Starter Code §1)。subsystem 格式必须是反向域名,与 bundle identifier 前缀保持一致(`com.acme.myapp.{功能域}`)。一旦发布就不能改——Console.app 历史查询和 mobileconfig 都硬编码这个字符串。

2. **集中注册 Logger 实例**:新建 `Logger+Categories.swift`,为每个功能域添加 `static let` 属性(参考 Starter Code §2)。所有 `Logger(subsystem:category:)` 调用**只在这一个文件出现**,其余地方通过 `Logger.network.info(...)` 访问。

3. **在每个 actor/class 使用正确声明方式**:
   - `struct` / `class`:用 `private let log = Logger.network`(实例属性)
   - `actor`:用 `private nonisolated static let log = Logger.network`(避免 `Sendable` 警告)
   - `@Observable class`:加 `@ObservationIgnored private let log = Logger.network`(避免被 observation 跟踪)

4. **标注 privacy**:审查每个插值字段。标量无需标注;URL、操作名等非敏感诊断值标 `privacy: .public`;userId、filePath、token 等保持默认(隐式 `private`)或显式标注 `privacy: .private`。将 privacy review 加入 PR checklist(见步骤 9)。

5. **准备 mobileconfig 模板**:复制 `docs/logging-profiles/EnablePeekabooLogPrivateData.mobileconfig`,修改 `PayloadIdentifier`、`PayloadUUID`(生成新 UUID)、`Subsystems` 字段,替换为新项目的 subsystem 列表。将 mobileconfig 纳入仓库 `docs/logging-profiles/` 目录。

6. **编写安装脚本**:参考 Starter Code §6,新建 `scripts/install-logging-profile.sh`,在 README 或 onboarding 文档中说明安装步骤。团队成员入职时一步完成开发机配置,不需手动操作 System Settings。

7. **设置 CLI stderr 格式**:若项目有 CLI 分支,引入 `PeekabooLogger`(Starter Code §4)或等效的双写包装;`--verbose` flag 控制是否输出 stderr,`--json` 模式下通过 `DebugLogCollector`(Starter Code §5)收集并放入 `debug_logs` 字段。

8. **在 CI 收集崩溃/失败日志**:在测试 step 失败后加如下命令,将相关日志归档为 artifact:

   ```yaml
   # .github/workflows/test.yml (示意)
   - name: Collect logs on failure
     if: failure()
     run: |
       log show \
         --predicate 'subsystem CONTAINS "com.acme.myapp"' \
         --last 10m \
         --level debug \
         > "$RUNNER_TEMP/app-test.log" 2>&1 || true
       log collect \
         --output "$RUNNER_TEMP/app-test.logarchive" || true
     shell: bash
   - uses: actions/upload-artifact@v4
     if: failure()
     with:
       name: test-logs
       path: |
         ${{ runner.temp }}/app-test.log
         ${{ runner.temp }}/app-test.logarchive
   ```

9. **建立 log review checklist**:在 PR 模板加以下 checklist,每次涉及 logging 改动时勾选:

   ```
   - [ ] 所有新 Logger 实例已加入 Logger+Categories.swift,未出现散落的 Logger(subsystem:...) 调用
   - [ ] 动态字符串插值已标注 privacy:,不依赖"默认脱敏"来保护用户数据
   - [ ] 没有把密码、API token、私钥直接传入 logger(即使标了 .private 也不应 log 敏感凭据)
   - [ ] debug 级别日志不在 info/warning 路径出现(避免生产 log 爆量)
   - [ ] 新 subsystem 已添加到 mobileconfig 的 Subsystems 字段
   ```

10. **验证 Console.app 可用**:运行应用,在 Console.app 搜索栏输入 `subsystem:com.acme.myapp`,确认日志可见且 category 分类正确;安装 mobileconfig 后生成新日志,验证 private 字段已解锁(不再显示 `<private>`)。

## 替代方案对比

| 方案 | 优点 | 缺点 | 何时选 |
|------|-----|-----|-------|
| **OSLog(`os.Logger`)(本方案)** | 内核异步缓冲,零阻塞;Console.app 深度集成;编译期 privacy 检查;macOS/iOS 统一后端;系统级落盘由 `logd` 管理 | macOS/iOS 专属,不跨 Linux;接口略 verbose(`subsystem`/`category` 两个参数) | 任何 macOS/iOS 14+ 项目首选 |
| **apple/swift-log** | 跨平台(macOS/Linux);后端可插拔(OSLog、stdout、文件等);SSWG 标准接口,与 SwiftNIO/Vapor 生态一致 | macOS 上 Console.app 集成不如原生 OSLog;privacy 标注无法透传;多一层中间件 | 跨平台 Swift 服务、Server-Side Swift、SSWG 生态项目 |
| **`print()` / `NSLog()`** | 零依赖,零设置,立即可用 | 无 privacy 保护;无结构化字段;无 Console.app 精确过滤;`NSLog` 在高频调用时阻塞线程 | 临时调试脚本,不入仓库 |
| **CocoaLumberjack** | 老生态成熟;支持多 sink(文件/Syslog/ASL);社区文档丰富 | 维护态减缓(OSLog 出现后新增量少);无编译期 privacy;Objective-C 风格 API | 维护中的 Objective-C 遗留项目,或需要写本地日志文件的场景 |
| **自封装 logger 抽象层(protocol-based)** | 完全控制接口;可 mock 用于单元测试;可按需切换后端 | 重复造轮子;OSLog 的编译期 privacy 标注无法透传协议边界;增加排查假设面积 | 需要在单元测试中 assert 具体 log 调用次数/内容的严格架构;跨平台项目中隔离平台差异 |

## 调试与取证

### 常用命令速查

```bash
# 1. 实时流式监控(最常用,先跑这条再触发操作)
log stream \
  --predicate 'subsystem CONTAINS "boo.peekaboo"' \
  --level debug \
  --style syslog

# 2. 历史查询:最近 1 小时
log show \
  --predicate 'subsystem CONTAINS "boo.peekaboo"' \
  --last 1h \
  --level debug

# 3. 历史查询:指定时间窗口
log show \
  --predicate 'subsystem CONTAINS "boo.peekaboo"' \
  --start '2026-05-21 10:00:00' \
  --end   '2026-05-21 10:30:00' \
  --level info

# 4. 打包归档(供给用户或 CI artifact)
log collect --output ~/Desktop/peekaboo.logarchive --last 1h

# 5. 查看 log 写入频次(排查爆量问题)
log stats \
  --predicate 'subsystem == "boo.peekaboo.core"' \
  --last 10m

# 6. 管理 mobileconfig
profiles list                                                    # 列出已安装 profile
open docs/logging-profiles/EnablePeekabooLogPrivateData.mobileconfig  # 安装
profiles remove -identifier com.peekaboo.PrivateDataLogging      # 移除(需 admin)

# 7. 全系统取证(包含 log、崩溃报告、系统状态)
sysdiagnose -f /tmp -u
```

### 按症状诊断

| 症状 | 命令 | 根因与解法 |
|------|-----|---------|
| Console.app 过滤显示 0 条 | `log stream --predicate 'subsystem CONTAINS "boo.peekaboo"'`(不加 level 先确认有无) | subsystem 字符串打错字(typo)或 app 未运行;用 `log stream --predicate 'process == "peekaboo"'` 确认进程是否在写 log |
| 日志全是 `<private>` | 安装 mobileconfig + 重启 app;或 `sudo log config --mode private_data:on --subsystem boo.peekaboo.core --persist` | privacy 默认严格;mobileconfig 作用于写入时,必须先装好再产生日志 |
| 简单字符串(邮箱/token)明文出现 | `log stream --predicate '...' \| grep -E "email\|token\|@"` | 普通动态字符串不触发系统脱敏;补标 `privacy: .private` |
| log 写入后 `log show` 看不到历史 | `log collect --output x.logarchive --last 1h` 后用 Console.app 打开 | 系统 log 默认保留窗口有限(~3天);用 `log collect` 在失效前归档 |
| 测试输出夹杂业务 log | 测试进程的 subsystem 与生产一致 → Console.app 混合 | 在测试 target 中传入不同 subsystem(如加 `.test` 后缀),或 CI 中用 `--predicate` 排除测试进程 |
| 日志爆量导致性能下降 | `log stats --predicate 'subsystem == "boo.peekaboo.core"' --last 1m` 看每秒写入条数 | debug 日志误用了 info 级别,或 hot path 内循环打 log;将高频路径降为 `.debug` 或完全移除 |
| 跨进程操作无法关联 | `log stream --predicate '...' --style json \| jq '.activityIdentifier'` | 没有用 `OSSignpostID` 串联;在操作入口生成 `OSSignpostID`,在跨进程调用时传递 correlation id 并记录到 log message |
| 用户报问题但 log 不够细 | 引导用户运行:`log show --predicate 'subsystem CONTAINS "boo.peekaboo"' --last 2h --level debug > ~/Desktop/peekaboo-debug.log && zip ~/Desktop/peekaboo-debug.log.zip ~/Desktop/peekaboo-debug.log` | 没有准备用户友好的日志收集脚本;考虑在 app 内提供"Export Logs"菜单项 |

### Peekaboo 专属:pblog.sh 快捷工具

```bash
# scripts/pblog.sh 是 Peekaboo 自带的 log 查看器
./scripts/pblog.sh -f                  # 实时追踪
./scripts/pblog.sh -p                  # 包含 private data(需 sudo 或 mobileconfig)
./scripts/pblog.sh -c AudioInputService -l 30m  # 按 category 过滤最近 30 分钟
./scripts/pblog.sh -e -l 1h            # 只看 error
./scripts/pblog.sh -p -c ClickService -s "session" -f  # 组合过滤 + 实时
```

## 常见陷阱

**陷阱 1:简单字符串不脱敏但误以为安全**

可观测信号:在 `log stream` 输出中看到明文邮箱、API token 前缀、用户名,但代码中没有加 `privacy: .public`。

原因:macOS 只脱敏 UUID 格式字符串和文件路径(以 `/` 开头),普通字符串一律原样输出(实测见 `docs/logging-profiles/README.md:39-61`)。`"user@example.com"` 和 `"sk-1234567890abcdef"` 均以明文出现。

修复:对所有含用户数据的字段主动标注 `privacy: .private`。添加到 PR review checklist,搜索全仓库 `logger\..*"` 检查是否有未标注的字符串插值:

```bash
grep -rn 'logger\.\(info\|debug\|warning\|error\).*\\(.*[^,]"' \
  Core/PeekabooCore/Sources/ | grep -v 'privacy:'
```

---

**陷阱 2:subsystem 名字打错导致 Console.app 过滤失效**

可观测信号:Console.app 输入 `subsystem:boo.peekaboo.core` 显示 0 条结果,但 app 明确在运行且有操作。

原因:subsystem 字符串拼错(如 `boo.peekaboo.coe`、`boo.peekaboo.Core`——注意大小写敏感),或新文件中直接硬编码而不是引用 `Logger.xxx` 集中实例。

修复:将所有 `Logger(subsystem:category:)` 构造调用迁移到 `Logger+Categories.swift`,其他文件只用 `Logger.xxx` 属性访问;在 CI 加 lint 规则禁止直接构造:

```bash
# 检查散落的 Logger(subsystem: 调用(Logger+Categories.swift 除外)
grep -rn 'Logger(subsystem:' Core/ Apps/ \
  | grep -v 'Logger+Categories.swift' | grep -v '// OK'
```

---

**陷阱 3:string interpolation 漏标 privacy 导致 token/路径泄露**

可观测信号:在 Console.app 或 `log stream` 中看到 API token、文件路径、用户名明文出现(参见陷阱 1)。更隐蔽的情况:加了 `privacy: .public` 的字段在生产日志里暴露了本不该公开的数据。

原因:`privacy: .public` 和 `privacy: .private` 是**相互独立**的显式声明。`privacy: .public` 意为"我确认这个值在生产日志中安全",若误标了含 token 的字段为 `.public`,则无论是否安装 mobileconfig 都会明文输出。

修复:代码 review 时重点关注 `privacy: .public` 标注——它是白名单操作,只有确认安全的值才应加;含凭据、路径、用户 ID 的字段绝不标 `.public`。

---

**陷阱 4:CI 测试时 log 污染输出**

可观测信号:CI 的测试 stdout/stderr 中夹杂着 OSLog 业务日志,使测试报告难以阅读;或测试的 subsystem 与生产相同导致 `log stats` 频次虚高。

原因:测试 target 的 `subsystem` 与生产代码共用同一字符串;或 `Logger.xxx` 静态实例在测试 target 中被直接 import 使用。

修复:为测试环境传入不同 subsystem(如 `com.acme.myapp.tests`);在 CI 的 `xcodebuild test` 命令后加环境变量 `APP_LOG_SUBSYSTEM_SUFFIX=.tests` 并在代码中读取。或更简单地:在单元测试中不验证 log 调用,只验证业务副作用。

---

**陷阱 5:`Logger` 在 actor 边界外创建导致 `Sendable` 警告**

可观测信号:编译时警告 `Capture of 'log' with non-sendable type 'Logger' in a @Sendable closure`(Swift 6 strict concurrency 下)。

原因:`Logger` 本身是 `Sendable`(macOS 11+),但若将其声明为 `let log = Logger(...)` 的实例属性并在 `async` 闭包中捕获,严格 isolation 检查可能在某些上下文下报警。

修复:在 `actor` 内部使用 `private nonisolated static let log = Logger.xxx`(参见 `PeekabooBridgeHost.swift:11`);在 `@Observable` 类中加 `@ObservationIgnored`(参见 `AudioInputService.swift:59`)。`static` 声明规避了跨 isolation 边界传递实例的问题。

## 延伸阅读

- Peekaboo:`docs/logging-guide.md`(CLI verbose 格式参考)、`docs/logging-profiles/README.md`(privacy 实测数据 + mobileconfig 安装详解)
- Apple:[Logging](https://developer.apple.com/documentation/os/logging)、[OSLogPrivacy](https://developer.apple.com/documentation/os/oslogprivacy)
- WWDC 2020:[Explore logging in Swift](https://developer.apple.com/videos/play/wwdc2020/10168/) — `os.Logger` 的 Swift overlay 设计动机与 privacy API 详解
- WWDC 2023:[Debug with structured logging](https://developer.apple.com/videos/play/wwdc2023/10226/) — Console.app 新过滤能力、`OSSignpost` 跨进程关联
- 其它 playbook:[02 · Swift 6 并发](./02-swift6-concurrency.md)(actor isolation 与 Logger Sendable)、[04 · 错误处理](./04-error-handling.md)、[12 · 测试策略](./12-testing-permission-gated.md)

---

*Last verified against Peekaboo @ `6cee1875`*
