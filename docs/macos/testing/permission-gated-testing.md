---
summary: '四级测试矩阵（safe / automation:read / automation:input / local）通过编译期 #if 标志 + 运行期 env 双重门控，让 CI 构建零权限开销、Xcode 报告可见跳过状态。'
read_when:
  - '设计需要屏幕录制 / AX / CGEvent 权限的测试分层'
  - 'CI 跑权限敏感测试报错 AXError / CGScreenCaptureAccessNotGranted'
  - '为新 macOS 项目搭建 safe + automation 测试矩阵'
sources: ['P12']
last_verified:
  peekaboo: '5301a030e6e5d8b4217f5ad6d7b88991d887bd74'
  nemonotch: 'fe4e9e5'
---

# 权限敏感测试 Gating — 四级矩阵

## TL;DR

macOS 自动化项目中，屏幕录制（Screen Recording）、Accessibility 只读、CGEvent 合成各需不同 TCC 权限，CI runner 一个都拿不到。  
解决方案：**编译期 `#if !SKIP_AUTOMATION`（通过 `-Xswiftc -DSKIP_AUTOMATION` 传入）+ 运行期 `.enabled(if: RUN_AUTOMATION_TESTS == "true")` 双重门控**，让：

- CI 构建传编译标志 → automation 文件彻底不参与编译，链接产物零权限符号
- 本地 Xcode 不传标志 → automation 文件参与编译、由 env var 控制是否执行，报告显示"已跳过"

两层缺一不可：单纯编译期测试"不存在"；单纯运行期链接仍引入权限框架（entitlement 缺失构建报错）。

---

## 可复用模式

### Pattern 1 · 四级测试矩阵

| 层级 | 脚本入口 | 关键 env var | 编译标志 | 可在无权限 CI 运行 |
|------|---------|-------------|---------|-----------------|
| **safe** | `test:safe` | — | `-Xswiftc -DSKIP_AUTOMATION` | 是（默认） |
| **automation:read** | `test:automation:read` | `RUN_AUTOMATION_TESTS=true` | 无 | 需 AX + Screen Recording 权限 |
| **automation:input** | `test:automation:input` | `RUN_AUTOMATION_TESTS=true` | 无 | 否（有副作用：改变前台 app） |
| **local** | `test:automation:local` | `RUN_AUTOMATION_TESTS=true` + `RUN_LOCAL_TESTS=true` | 无 | 否（需 Display + 真机二进制） |

automation:read 与 automation:input 必须拆开：CGEvent 键鼠合成可能改变前台 App、触发快捷键，在共享 CI agent 上会污染并发 job。

### Pattern 2 · 编译期 #if 包裹

每个 automation suite 文件最外层：

```swift
// AutomationTests/ScreenCaptureTests.swift
#if !SKIP_AUTOMATION
import Testing
import ScreenCaptureKit   // 只在 automation 构建中链接

@Suite(
    .serialized,
    .tags(.automationRead),
    .enabled(if: TestEnvironment.runAutomationTests)
)
struct ScreenCaptureTests { ... }
#endif
```

`#if` 块内代码在 safe 构建中**不参与编译**，`ScreenCaptureKit` 等框架不被链接，CI 不会因 entitlement 缺失在链接阶段报错。

### Pattern 3 · 运行期 .enabled(if:) 门控

suite 级（整批测试同一条件）：

```swift
@Suite(.serialized, .tags(.automationRead), .enabled(if: TestEnvironment.runAutomationTests))
struct WindowListTests { ... }
```

test 级（单测再加额外条件）：

```swift
@Suite(.enabled(if: TestEnvironment.runAutomationTests))
struct AnnotationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_ANNOTATION_TESTS"] == "true"))
    func annotatedScreenshot() async throws { ... }
}
```

### Pattern 4 · TestEnvironment — 集中持有所有 env 读取

**绝不在单个测试文件内联 `ProcessInfo.processInfo.environment` 读取。**  
集中到 `TestEnvironment.swift`（safe target）或 `CLITestEnvironment.swift`（automation target）：

```swift
// TestEnvironment.swift
import Foundation
import Testing

@preconcurrency
enum TestEnvironment {
    @inline(__always)
    private nonisolated static func flag(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key]?.lowercased() == "true"
    }

    /// 统一门控 key：RUN_AUTOMATION_TESTS
    /// 所有 automation suite 检查这一个 key；package.json 脚本设置这一个 key。
    @preconcurrency nonisolated(unsafe) static var runAutomationTests: Bool {
        flag("RUN_AUTOMATION_TESTS")
    }

    /// read-only AX / screen：runAutomationTests AND (RUN_AUTOMATION_READ OR RUN_LOCAL_TESTS)
    @preconcurrency nonisolated(unsafe) static var runAutomationRead: Bool {
        runAutomationTests && (flag("RUN_AUTOMATION_READ") || flag("RUN_LOCAL_TESTS"))
    }

    /// input synthesis：runAutomationTests AND RUN_AUTOMATION_INPUT
    @preconcurrency nonisolated(unsafe) static var runAutomationInput: Bool {
        runAutomationTests && flag("RUN_AUTOMATION_INPUT")
    }

    /// local full-binary：runAutomationTests AND RUN_LOCAL_TESTS
    @preconcurrency nonisolated(unsafe) static var runLocal: Bool {
        runAutomationTests && flag("RUN_LOCAL_TESTS")
    }
}
```

### Pattern 5 · Stub 服务 — 逻辑正确性与权限行为分离

```swift
// StubScreenCaptureService — safe 层测试用，零权限
final class StubScreenCaptureService: ScreenCaptureServiceProtocol, @unchecked Sendable {
    var permissionGranted: Bool
    var captureHandler: ((Int?) async throws -> CaptureResult)?

    init(permissionGranted: Bool = true) { self.permissionGranted = permissionGranted }

    func captureScreen(displayIndex: Int?) async throws -> CaptureResult {
        if let h = captureHandler { return try await h(displayIndex) }
        return CaptureResult(imageData: Data(repeating: 0xFF, count: 1024), applicationName: "Stub")
    }
}
```

Stub 价值：可在 safe 层制造"无 AX 权限"场景（注入 `permissionGranted = false`），这在有权限的本地机上反而无法自然重现。

### Pattern 6 · package.json / Makefile 脚本暴露

```json
{
  "scripts": {
    "test":                    "pnpm run test:safe",
    "test:safe":               "swift test -Xswiftc -DSKIP_AUTOMATION --no-parallel",
    "test:automation:read":    "RUN_AUTOMATION_TESTS=true RUN_AUTOMATION_READ=true swift test --no-parallel",
    "test:automation:input":   "RUN_AUTOMATION_TESTS=true RUN_AUTOMATION_INPUT=true swift test --no-parallel",
    "test:automation:local":   "RUN_AUTOMATION_TESTS=true RUN_LOCAL_TESTS=true swift test --no-parallel",
    "test:all":                "pnpm run test:safe && pnpm run test:automation:read"
  }
}
```

`test`（默认）指向 `test:safe`，确保裸 `pnpm test` 在任何机器不意外触发权限请求。

### Pattern 7 · CI matrix + nightly

```yaml
# .github/workflows/ci.yml — PR/push，仅 safe 层
- name: Build and test (safe only)
  run: swift test -Xswiftc -DSKIP_AUTOMATION --no-parallel
  # 不设置任何 RUN_AUTOMATION_TESTS — 确保 gating 不因遗漏关闭而失效

---
# .github/workflows/nightly.yml — 有权限 runner
- name: Run automation:read tests
  run: swift test --no-parallel
  env:
    RUN_AUTOMATION_TESTS: "true"
    RUN_AUTOMATION_READ: "true"
```

---

## 锚点（file:line）

基于 Peekaboo 源码（SHA `5301a030`）：

| 概念 | 文件:行 |
|------|---------|
| Tag 扩展 + CLITestEnvironment（automation target） | `Apps/CLI/Tests/CLIAutomationTests/TestTags.swift:1–68` |
| Tag 扩展（safe target） | `Apps/CLI/Tests/CoreCLITests/TestTags.swift:1–53` |
| `#if !PEEKABOO_SKIP_AUTOMATION` 包裹 + Stub 注入示范 | `Apps/CLI/Tests/CLIAutomationTests/PermissionCommandTests.swift:6–115` |
| suite 级 + test 级双层 `.enabled(if:)` | `Apps/CLI/Tests/CLIAutomationTests/AnnotationIntegrationTests.swift:6–17` |
| Stub 完整实现（handler 闭包注入） | `Apps/CLI/Tests/CLIAutomationTests/Support/TestServices.swift:21–130` |
| local 层（RUN_LOCAL_TESTS + binary 路径）判断 | `Apps/CLI/Tests/CLIRuntimeTests/CLIRuntimeSmokeTests.swift:1–10` |
| 脚本全集 | `package.json`（项目根） |

---

## Pitfalls

### ⚠ Bug (a) — 裸 `-D` 不向 Swift 编译器传 `#if` 标志

**现象**：`package.json` 里写 `-DSKIP_AUTOMATION`（裸 `-D`），但测试构建时 automation 文件照样被编译，`#if !SKIP_AUTOMATION` 形同虚设。

**根因**：`swift test` / `xcodebuild` 的 `-D` 是传给构建系统（Make/Ninja）的预处理器宏，**不会**传入 Swift 编译器的 `#if` 条件编译。Swift 编译器需要 `-Xswiftc -DSKIP_AUTOMATION`。

**修正写法**（必须完整两段）：
```bash
swift test -Xswiftc -DSKIP_AUTOMATION --no-parallel
#          ^^^^^^^^ ^^^^^^^^^^^^^^^^^ 缺任何一段都不生效
```

Xcode Build Settings 写法：`OTHER_SWIFT_FLAGS = -DSKIP_AUTOMATION`（不需要 `-Xswiftc` 前缀，因为 pbxproj 直接传 swiftc）。

---

### ⚠ Bug (b) — suite 读的 env key 与脚本设置的 key 对不上，input 测试永不启用

**原始 Peekaboo 的 bug（已在本文修正）**：

- `TestTags.swift` 中 `runAutomationActions` 读的是 `RUN_AUTOMATION_ACTIONS`
- `package.json` 的 `test:automation:input` 脚本设置的是 `PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true`
- 两个 key 永远对不上 → `runAutomationActions` 在 `test:automation:input` 脚本下永远为 `false` → input 测试从未真正启用

**教训**：**门控 env key 全链路用同一个名**——suite `TestEnvironment` 里读什么 key，`package.json` 脚本设什么 key，CI YAML `env:` 块写什么 key，必须逐字相同。

**检查方式**：
```bash
# 确认 suite 读到的 key 名
grep -r "ProcessInfo.*environment\[" Tests/
# 确认脚本设置的 key 名
grep "RUN_\|INCLUDE_\|SKIP_" package.json
# 对比两组，不能有任何拼写差异
```

本文统一使用 `RUN_AUTOMATION_TESTS` 作为基础门控 key，无其他别名。

---

### Pitfall 3 — automation 测试混入 CI 触发权限报错

**信号**：CI 日志出现 `AXError -25204` 或 `CGScreenCaptureAccessNotGranted`，测试卡死。

**根因**：新增 automation suite 文件缺少 `#if !SKIP_AUTOMATION` 包裹，或 CI 脚本漏传 `-Xswiftc -DSKIP_AUTOMATION`。

**处理**：PR checklist 要求新 automation 文件必须添加 `#if` 包裹；用 lint 规则扫描 automation 目录下不含 `#if` 的 `.swift` 文件：
```bash
find Tests/AutomationTests -name "*.swift" | xargs grep -L "#if !SKIP_AUTOMATION"
```

---

### Pitfall 4 — Stub 走 happy path，真机 nightly 失败

**根因**：Stub 返回固定 fixture，无法覆盖真实 API 在不同 macOS 版本的行为差异（如 macOS 15 改变了 `CGWindowListCreateImage` 对屏幕外窗口的处理）。

**处理**：nightly CI 设有权限的 macOS runner，周期运行 automation:read 层，纳入报警，不阻塞 PR CI，但 release 前必须修复。

---

### Pitfall 5 — swift-testing `@Tag` 改名后过滤失效

**信号**：`swift test --filter "Tags/automationRead"` 输出 "0 tests run"。

**根因**：重构时改了 `@Tag static var` 名称，但 `package.json --filter` 参数未同步。

**处理**：改名后立刻验证：`swift test --list-tests | grep Tags`。

---

## 落地 Checklist

- [ ] `Package.swift` 拆分 safe target（`CoreTests/`）与 automation target（`AutomationTests/`），避免 safe 层链接权限框架
- [ ] `TestEnvironment.swift` 集中持有所有 env 读取，统一 key 名 `RUN_AUTOMATION_TESTS`
- [ ] 每个 automation suite 文件最外层加 `#if !SKIP_AUTOMATION` / `#endif`
- [ ] `package.json` `test:safe` 脚本包含 `-Xswiftc -DSKIP_AUTOMATION`（两段都要有）
- [ ] `package.json` 各 automation 脚本设置的 env key 与 `TestEnvironment` 里读的 key 字面一致
- [ ] `@Suite(...)` 处加 `.enabled(if: TestEnvironment.runAutomationTests)`
- [ ] CI PR job 只调用 `test:safe`，不设 `RUN_AUTOMATION_TESTS`
- [ ] nightly workflow 单独运行 `test:automation:read`，失败纳入报警

---

## 延伸阅读

- [swift-testing.md](./swift-testing.md) — Swift Testing 框架用法、NemoNotch 约定
- [../permissions/](../permissions/) — TCC 权限状态机与 PermissionCard 模式
- [../build-release/](../build-release/) — CI matrix、Xcode 版本固定、DMG 打包
- Peekaboo 原始文档：`docs/swift-testing-playbook.md`、`docs/manual-testing.md`
- Apple：[Swift Testing 文档](https://developer.apple.com/documentation/testing)
- WWDC 2024：[Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/)
