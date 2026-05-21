---
summary: 'Use OSLog as the unified logging backend for macOS apps with a parallel CLI stderr channel for diagnostics.'
read_when:
  - 'setting up structured logging for a new macOS app or CLI tool'
  - 'filtering logs in Console.app or temporarily lifting privacy redaction during development'
---

# 03 · 日志与可观测性

## TL;DR

macOS 的 Unified Logging(OSLog)是 GUI 应用的首选日志后端:日志写入内核缓冲区、不阻塞主线程、Console.app 可实时过滤。Peekaboo 以 `typealias SystemLogger = os.Logger` 作为唯一日志类型,所有模块按 `subsystem + category` 两级分类,既能在 Console.app 精确筛选,又能通过 `.mobileconfig` 配置文件在开发机上临时解除隐私脱敏。CLI 侧额外维护一套 stderr 文本格式(`[timestamp] LEVEL [Category]: msg`),两种输出互不干扰。

## Peekaboo 在哪里实现

- 模块:`PeekabooCore`(Core/PeekabooCore/Sources/PeekabooCore/)
- 关键文件:`Core/PeekabooCore/Sources/PeekabooCore/Support/PeekabooServices.swift:426` — `typealias SystemLogger = os.Logger`,全项目统一入口
- 关键文件:`Core/PeekabooCore/Sources/PeekabooCore/Daemon/PeekabooDaemon.swift:88` — `Logger(subsystem: "boo.peekaboo.core", category: "Daemon")`,展示 subsystem/category 命名惯例
- 关键文件:`Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeClient.swift:12` — 跨进程 bridge 侧同样遵循同一 subsystem 格式(`boo.peekaboo.bridge`)
- 相关 docs:`docs/logging-guide.md`、`docs/logging-profiles/README.md`、`docs/logging-profiles/EnablePeekabooLogPrivateData.mobileconfig`

## 设计动机(Why)

早期调试自动化脚本时常遇到两个痛点:其一,直接用 `print()` 或 `NSLog` 无法在 Console.app 中按应用筛选,日志淹没在系统噪音里;其二,文件路径、Session UUID 等动态值被 macOS 默认脱敏成 `<private>`,复现用户问题时根本看不到关键信息。

切换到 `os.Logger` 后第一个问题迎刃而解:subsystem 设为反向域名格式(`boo.peekaboo.*`),category 对应功能模块,Console.app 一行过滤命令即可定位。隐私问题则通过两层策略解决:生产代码对确实不敏感的诊断字段标注 `.public`,开发机装一个 `.mobileconfig` 配置文件临时打开 `Enable-Private-Data`。两层缺一不可——前者是代码级承诺,后者是开发期便利。详见 `docs/logging-profiles/README.md`。

CLI 的 stderr 文本输出(`docs/logging-guide.md`)与 OSLog 并行存在而不冲突:用户跑 `peekaboo see --verbose` 时看到带时间戳的人类可读行,后台同时写入系统 log 供 Console.app 查看。`--json` 模式下 stderr 文本日志被收入 JSON 的 `debug_logs` 字段,方便程序化消费。

## 核心模式(Pattern)

**subsystem / category 命名**:subsystem 用反向域名定位到产品(`com.acme.myapp`),category 对应功能模块或服务(`"Auth"`,`"Capture"`)。两者都是静态字符串,编译期确定。

```swift
// 每个 actor/class 声明一个私有 logger,不跨模块共享
import os.log

private let logger = Logger(
    subsystem: "com.acme.myapp",  // 全项目唯一
    category: "FeatureName"       // 当前模块
)
```

**privacy 标注**:OSLog 对插值字符串默认脱敏(`<private>`)。标量(Int、Bool)永远公开。非敏感的诊断值需手动标注:

```swift
// 敏感:文件路径、UUID — 保持默认,生产日志不泄露
logger.info("Session started \(sessionId)")          // → <private>

// 非敏感:操作名、枚举 — 标注 .public 方便诊断
logger.info("Mode: \(mode, privacy: .public)")

// 标量永远可见,无需标注
logger.debug("Count: \(elementCount)")
```

**开发机解锁私有数据**:安装 `.mobileconfig`(设置 `Enable-Private-Data: true`)或运行:

```bash
sudo log config --mode private_data:on \
  --subsystem com.acme.myapp --persist
# 调试完毕后重置
sudo log config --reset private_data
```

**Console.app 实时筛选**:打开 Console.app → 选中设备 → 搜索栏输入 `subsystem:com.acme.myapp`。可再叠加 `category:FeatureName` 缩小范围。命令行等效:

```bash
log stream --predicate 'subsystem == "com.acme.myapp"' --level debug
```

**CLI/GUI 日志分流**:CLI 命令将 verbose 文本输出到 stderr,保持 stdout 干净供脚本解析;GUI 应用仅写 OSLog,不污染终端。两者底层都调用同一个 `os.Logger` 实例,保证 Console.app 能统一检索。

## 新项目落地步骤(How to apply)

1. 定义全项目唯一的 subsystem 常量(`"com.acme.myapp"`),建议放在单独的 `Logging+Constants.swift` 中集中管理。
2. 为每个功能模块创建私有 `Logger` 实例,category 与模块名一致,避免跨模块共享 logger。
3. 标注所有包含用户数据的插值字段:文件路径、UUID、用户名等保持默认(即 `<private>`);仅对确认不敏感的诊断值加 `privacy: .public`。
4. 配置 `.mobileconfig` 配置文件并纳入仓库(`docs/logging-profiles/` 目录),README 说明安装步骤与安全须知,确保团队成员开发机统一安装。
5. 验证 Console.app 过滤可用:运行应用,在 Console.app 输入 `subsystem:com.acme.myapp`,确认日志可见且 category 分类正确。
6. 引入 CLI 层的 stderr 日志格式(带 timestamp/level/category),通过 `PEEKABOO_LOG_LEVEL` 或 `--verbose` 控制,`--json` 模式下收入输出结构体的 `debug_logs` 字段。
7. 在 CI 中限制最低日志级别为 `.info`,避免 debug 日志在生产构建中写入敏感信息,参考 `docs/logging-guide.md` 中的 `PEEKABOO_LOG_LEVEL` 配置项。

## 常见陷阱(Pitfalls)

**动态字符串默认不可见,却并非"完全安全"**:macOS 对 UUID、文件路径等复杂插值默认脱敏(`<private>`),但简单字符串(如邮箱地址 `"user@example.com"`、API token 前缀)在测试中**并不触发脱敏**——这是 Apple 的实现细节,不能依赖它保护隐私。

可观测信号:在 Console.app 或 `log stream` 输出中看到明文邮箱/路径/token,说明该字段未被脱敏。参见 `docs/logging-profiles/README.md` 中的实测数据:

```
Email: user@example.com    # ← 未脱敏!
Token: sk-1234567890…      # ← 未脱敏!
Session: <private>         # ← UUID 脱敏
Path: <private>            # ← 路径脱敏
```

检查命令:

```bash
log stream --predicate 'subsystem == "com.acme.myapp"' | grep -E "email|token|path"
```

正确做法:对所有可能携带用户隐私的字段主动加 `privacy: .private`(或保持默认),只对确认安全的诊断值标 `.public`。不要把"默认脱敏"等同于"一定安全"。

## 延伸阅读

- Peekaboo:`docs/logging-guide.md`、`docs/logging-profiles/`
- Apple:[Logging](https://developer.apple.com/documentation/os/logging)、[OSLogPrivacy](https://developer.apple.com/documentation/os/oslogprivacy)
- 其它 playbook:[04 · 错误处理](./04-error-handling.md)、[12 · 测试策略](./12-testing-permission-gated.md)

---
*Last verified against Peekaboo @ `106ee4e2`*
