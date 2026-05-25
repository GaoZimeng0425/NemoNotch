---
summary: 'Gate permission-sensitive tests behind compile-time flags and environment variables, mixing swift-testing tags with XCTest skip patterns for CI vs local matrix.'
read_when:
  - 'designing a test pyramid that includes screen capture / AX automation that CI cannot run'
  - 'choosing between Stub and real-device tests for permission-sensitive code'
---

# 12 · 测试策略 + 权限敏感测试 gating

## TL;DR

macOS 自动化项目中，屏幕录制、Accessibility、CGEvent 合成各需不同权限，CI runner 一个都拿不到。Peekaboo 把测试分成**四级矩阵**（safe / automation:read / automation:input / local），编译期 `#if !PEEKABOO_SKIP_AUTOMATION` 让 CI 构建产物里根本不含权限相关代码，运行期 `.enabled(if: CLITestEnvironment.runAutomationRead)` 让 Xcode 报告能显示"已跳过"而非"缺失"。Swift Testing 的 `@Tag` + `.enabled(if:)` 组合提供细粒度的 suite/test 双层门控，`TestTags.swift` 集中持有所有 `Tag` 声明与环境变量读取逻辑，避免各文件内联 `ProcessInfo`。Stub 服务（`StubScreenCaptureService` / `StubAutomationService`）让逻辑正确性与权限行为分离验证；nightly CI 再对接真实权限 runner 覆盖 Stub 无法捕捉的 macOS 版本差与系统边界。Swift Testing 与 XCTest 在同一 target 内可共存，逐文件替换，XCUITest 和 `XCTMetric` 保留在 XCTest 中。

## Peekaboo 在哪里实现

- 配置文件：`package.json` — `test:safe` / `test:automation` / `test:automation:read` / `test:automation:input` / `test:automation:local` 五条脚本（与 pnpm 完全对齐）
- 关键文件：`Apps/CLI/Tests/CLIAutomationTests/TestTags.swift:1–68` — **自动化 target 的** `Tag` 扩展全集 + `CLITestEnvironment`：`runAutomationRead`、`runAutomationActions`、`runAutomationScenarios` 三个公开属性，读取多个 env var 的合并逻辑
- 关键文件：`Apps/CLI/Tests/CoreCLITests/TestTags.swift:1–53` — **安全 target 的** `Tag` 扩展 + 简化版 `CLITestEnvironment`（`runAutomationScenarios`），safe 层 import 这里
- 关键文件：`Apps/CLI/Tests/CLIAutomationTests/PermissionCommandTests.swift:6–115` — `#if !PEEKABOO_SKIP_AUTOMATION` 包裹全文件 + `StubScreenCaptureService`/`StubAutomationService` Stub 隔离示范
- 关键文件：`Apps/CLI/Tests/CLIAutomationTests/AnnotationIntegrationTests.swift:6–17` — suite 级 `#if` + `.enabled(if: CLITestEnvironment.runAutomationActions && env == "true")` 双层过滤
- 关键文件：`Apps/CLI/Tests/CLIAutomationTests/Support/TestServices.swift:21–130` — `StubScreenCaptureService` 和 `StubAutomationService` 的完整实现：handler 闭包注入 + 默认 fixture 返回，展示协议桩模式
- 关键文件：`Apps/CLI/Tests/CLIRuntimeTests/CLIRuntimeSmokeTests.swift:1–10` — `CLIRuntimeEnvironment.shouldRunSmokeTests`：local 层判断（`RUN_LOCAL_TESTS` + 能定位到 peekaboo 二进制）
- 相关 docs：`docs/swift-testing-playbook.md`、`docs/manual-testing.md`、`docs/test-refactor.md`

## 设计动机（Why）

### 为什么分四级，而非两级（有权限 / 无权限）？

权限粒度不同：屏幕录制（Screen Recording）和 AX 只读是两个独立授权；CGEvent 合成（`kTCCServicePostEvent`）又是第三个，且合成键鼠事件有**副作用**（可能改变前台 app、触发快捷键），在共享 CI agent 上运行会污染其他并发 job。把 automation:read 和 automation:input 拆开，让只读验证能在有 AX 权限的 nightly CI 上安全运行，而输入合成永远留在本地开发者机器。

Local 层则不只是"更多权限"，它还依赖**真实二进制路径**（`PEEKABOO_CLI_PATH`）和跨进程通信，是最接近生产的冒烟验证，在无 Display Server 的 CI 容器上根本跑不起来。

### 为什么要编译期 + 运行期双重 gating？

单纯的编译期 `#if`：CI 构建产物里根本不含权限代码，链接体积小，不会因遗漏 mock 导致符号找不到。缺点是 Xcode 的测试报告里这些测试"不存在"——看不出是被跳过还是从未写过。

单纯的运行期 `.enabled(if:)`：Xcode 报告可见"已跳过"，但 CI 构建仍会链接所有真实框架（如 `ScreenCaptureKit`），一旦 entitlement 缺失就在构建阶段报错。

叠加使用：CI 构建传 `-Xswiftc -DPEEKABOO_SKIP_AUTOMATION` 彻底排除 automation 文件，safe 层只链接 Stub；本地 Xcode 不传该 flag，automation 文件参与构建并由 `.enabled(if:)` 控制是否执行，报告完整可见。

### 为什么 Stub 不够，还要混真机测试？

Stub 的核心价值是让逻辑正确性与权限行为分离——`PermissionCommandTests` 把 `accessibilityPermissionGranted = false` 注入 Stub，制造"无 AX 权限"场景，这在有权限的本地机上反而无法自然重现。

但 Stub 永远走 happy path。真实的 `CGWindowListCreateImage` 在 macOS 版本差下可能返回 `nil` 而非抛错；真实的 AX 树查找在 macOS 14 和 macOS 15 的 `AXError` 码不同；真实的 `CGEvent.postToPid` 对没有桌面会话的进程会静默丢弃事件。这些边界只有真机 automation:read/local 才能捕捉，nightly CI 定期跑真机层把这些差异纳入报警。

### Swift Testing 与 XCTest 为何共存？

Swift Testing（`import Testing`）在 Swift 5.9 / Xcode 15 正式 GA，`#expect`/`#require`/`@Suite`/`@Tag` 让 gating 逻辑远比 `XCTSkip` 清晰，并发测试支持开箱即用（`@Suite(.serialized)` 控制串行）。Peekaboo 已全面迁移到 Swift Testing。

但两类测试目前尚无替代方案：**UI Automation**（`XCUIApplication`）强依赖 XCTest runner；**性能基准**（`XCTMetric`）没有 Swift Testing 等价物。这两类保留在 XCTest 中，两个框架可在同一 target 共存，逐文件替换，不需要一次性迁移。

## 核心模式（Pattern）

### Pattern 1 · 四级测试矩阵

| 层级 | pnpm 脚本 | 关键环境变量 | 编译标志 | 可在 CI 运行 |
|------|-----------|-------------|---------|------------|
| safe | `test:safe` | — | `-DPEEKABOO_SKIP_AUTOMATION` | 是（默认） |
| automation:read | `test:automation:read` | `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` `RUN_AUTOMATION_READ=true` | 无 | 需 AX 权限 |
| automation:input | `test:automation:input` | `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` `PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true` | 无 | 否（有 side effect） |
| local | `test:automation:local` | 以上全部 + `RUN_LOCAL_TESTS=true` + `PEEKABOO_CLI_PATH` | 无 | 否（需 Display + 真机二进制） |

`test:safe`：传 `-Xswiftc -DPEEKABOO_SKIP_AUTOMATION`，整批 automation suite 文件排出编译，CI 构建产物零权限代码。

`test:automation:read`：只读 AX 树、枚举窗口列表等，不合成键鼠事件，可接受在授权 nightly runner 上运行。

`test:automation:input`：`CGEvent` 键鼠合成，可能改变前台 app，须独立运行（`--package-path Core/PeekabooCore`），严格限本地。

`test:all`：先跑 safe，再跑完整 automation，等价于 `test:safe && test:automation`，用于本地最终验证。

### Pattern 2 · 编译期 `#if` 包裹

每个 automation suite 文件最外层包裹 `#if !PEEKABOO_SKIP_AUTOMATION`：

```swift
// Apps/CLI/Tests/CLIAutomationTests/MenuCommandTests.swift:8
#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.serialized, .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct MenuCommandTests {
    // ...
}
#endif
```

`#if` 块内的代码在 safe 构建中**不参与编译**，link 阶段不引用 `ScreenCaptureKit` / `AXorcist` 等权限相关符号，CI 构建不会因 entitlement 缺失报链接错误。

### Pattern 3 · 运行期 `.enabled(if:)` gating

suite 级 gating（全部测试按同一条件）：

```swift
@Suite(.serialized, .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct WindowCommandCLITests { ... }
```

test 级二次过滤（suite 层通过，单测再加条件）：

```swift
@Suite(.serialized, .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationActions))
struct AnnotationIntegrationTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RUN_ANNOTATION_INTEGRATION_TESTS"] == "true")
    )
    func `Annotated screenshot generation with window bounds`() async throws { ... }
}
```

两层门控保证：suite 层控制大类别（automation:read vs actions），test 层控制更小的高破坏性场景（需额外 opt-in flag）。

### Pattern 4 · `@Tag` 与 `.enabled(if:)` 组合

`@Tag` 提供**过滤维度**，`.enabled(if:)` 控制**是否执行**，两者互补：

```swift
// 跑所有 .safe 标签的测试（不受 gating）
swift test --filter "Tags/safe"

// 跑 automation 标签的测试（但只有 env var 设置后才真正执行）
RUN_AUTOMATION_READ=true swift test --filter "Tags/automation"
```

Tag 还可在 Xcode Test Navigator 中折叠查看，加速定位失败测试。

### Pattern 5 · `TestTags.swift` 集中管理

两个 TestTags 文件分别服务两个 target：

```
Apps/CLI/Tests/CoreCLITests/TestTags.swift      ← safe target 使用
Apps/CLI/Tests/CLIAutomationTests/TestTags.swift ← automation target 使用
```

**绝不在单个测试文件内联** `ProcessInfo.processInfo.environment` 读取。原因：
1. 统一修改 env var 名称时只改一处
2. 测试文件中直接散落 `ProcessInfo` 读取难以搜索
3. `@preconcurrency nonisolated(unsafe)` 等并发注解只需写一次

### Pattern 6 · 测试 fixture 与真机环境隔离

使用 `/tmp/peekaboo-test-<pid>-<name>` 临时目录，配合 `addTeardownBlock` 保证清理：

```swift
// 典型的 fixture 设置模式（来自 AnnotationIntegrationTests.swift）
let sessionId = String(ProcessInfo.processInfo.processIdentifier)
let outputPath = "/tmp/test-annotation-\(sessionId).png"
defer {
    try? FileManager.default.removeItem(atPath: outputPath)
}
```

Swift Testing 中用 `addTeardownBlock`（XCTest 风格）或 `defer` 块。关键：即使测试因 `#require` 失败提前返回，`defer` 也确保 tmp 文件被清除。

### Pattern 7 · CI matrix 设计

GitHub Actions matrix 按 OS × Xcode 版本交叉：

```yaml
# 节选自典型 CI 设计
strategy:
  matrix:
    os: [macos-14, macos-15]
    xcode: ['16.0', '16.2']
  fail-fast: false
```

Nightly job 单独声明，开启 automation:read：

```yaml
# nightly.yml
- run: pnpm run test:automation:read
  env:
    RUN_AUTOMATION_READ: "true"
    PEEKABOO_INCLUDE_AUTOMATION_TESTS: "true"
```

## 完整代码示例（Starter Code）

以下是可直接拷进新项目的最小可运行骨架，覆盖本 playbook 全部核心模式。分为 10 个代码块，总计约 290 行。

**平台要求**：macOS 14+，Swift 5.9+（swift-testing GA），Xcode 15+。

**嵌入方式**：
- `TestTags.swift` → 你的 safe 测试 target（如 `CoreTests/`）
- `TestEnvironment.swift` → safe + automation 共享（如作为 `TestSupport` 库 target）
- 其余文件 → 对应测试 target

---

**① TestTags.swift — Tag 扩展与环境检查（safe target）**

```swift
// TestTags.swift — safe target
// macOS 14+, Swift 5.9+, swift-testing GA (Xcode 15+)
// Drop this file into your safe test target (e.g. CoreTests/).
// All automation test files should import Testing and reference these tags.

import Foundation
import Testing

// MARK: - Tag Registry

extension Tag {
    // Execution tier
    @Tag static var safe: Self           // runs in every CI job, no permissions
    @Tag static var automationRead: Self // read-only AX/screen, nightly CI
    @Tag static var automationInput: Self // CGEvent synthesis, local only
    @Tag static var localOnly: Self      // full CLI binary, local only

    // Feature areas
    @Tag static var permissions: Self
    @Tag static var screenshot: Self
    @Tag static var axAutomation: Self
    @Tag static var inputSynthesis: Self
    @Tag static var windowManagement: Self
    @Tag static var jsonOutput: Self

    // Reliability markers
    @Tag static var flaky: Self          // known intermittent — quarantine before fix
    @Tag static var regression: Self     // added for a specific bug fix
    @Tag static var requiresDisplay: Self
    @Tag static var requiresPermissions: Self
}

// MARK: - Environment Gate (safe target)

/// Read-only view of test-gating environment variables.
/// All env reads are centralised here — never inline ProcessInfo in test files.
@preconcurrency
enum TestEnvironment {
    @inline(__always)
    private nonisolated static func flag(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key]?.lowercased() == "true"
    }

    /// true when PEEKABOO_INCLUDE_AUTOMATION_TESTS=true (base gate)
    @preconcurrency nonisolated(unsafe) static var includeAutomationTests: Bool {
        flag("PEEKABOO_INCLUDE_AUTOMATION_TESTS")
    }

    /// true for read-only AX / screen enumeration tests
    /// Enabled by: RUN_AUTOMATION_READ=true OR RUN_LOCAL_TESTS=true
    @preconcurrency nonisolated(unsafe) static var runAutomationRead: Bool {
        includeAutomationTests
            && (flag("RUN_AUTOMATION_READ") || flag("RUN_LOCAL_TESTS"))
    }

    /// true for CGEvent input-synthesis tests
    /// Enabled by: PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true AND includeAutomationTests
    @preconcurrency nonisolated(unsafe) static var runAutomationInput: Bool {
        includeAutomationTests && flag("PEEKABOO_RUN_INPUT_AUTOMATION_TESTS")
    }

    /// true for local full-binary end-to-end tests
    /// Enabled by: RUN_LOCAL_TESTS=true AND includeAutomationTests
    @preconcurrency nonisolated(unsafe) static var runLocal: Bool {
        includeAutomationTests && flag("RUN_LOCAL_TESTS")
    }

    /// Convenience: any automation test should run
    @preconcurrency nonisolated(unsafe) static var runAnyAutomation: Bool {
        runAutomationRead || runAutomationInput || runLocal
    }
}
```

---

**② SafePermissionTests.swift — Swift Testing safe 层示范**

```swift
// SafePermissionTests.swift — safe target (no #if guard needed here)
// Uses Stub injection to verify logic without real permissions.
// Compile with: swift test -Xswiftc -DPEEKABOO_SKIP_AUTOMATION

import Foundation
import Testing
@testable import MyApp        // replace with your actual module name

@Suite(.tags(.safe, .permissions))
struct SafePermissionTests {

    @Test("permissions JSON lists all three entries when all denied")
    func permissionsJSONAllDenied() async {
        let stub = StubScreenCaptureService(permissionGranted: false)
        let axStub = StubAccessibilityService(granted: false)

        let result = PermissionChecker.currentStatus(
            screenCapture: stub,
            accessibility: axStub
        )

        #expect(result.count == 3)
        #expect(result.first(where: { $0.name == "Screen Recording" })?.isGranted == false)
        #expect(result.first(where: { $0.name == "Accessibility" })?.isGranted == false)
    }

    @Test("permissions JSON marks Event Synthesizing as not required by default")
    func eventSynthesizingNotRequired() async {
        let result = PermissionChecker.currentStatus(
            screenCapture: StubScreenCaptureService(permissionGranted: true),
            accessibility: StubAccessibilityService(granted: true)
        )
        #expect(result.first(where: { $0.name == "Event Synthesizing" })?.isRequired == false)
    }
}
```

---

**③ AutomationReadTests.swift — automation:read 层示范（swift-testing）**

```swift
// AutomationReadTests.swift — automation target
// Requires: PEEKABOO_INCLUDE_AUTOMATION_TESTS=true RUN_AUTOMATION_READ=true
// pnpm run test:automation:read

#if !PEEKABOO_SKIP_AUTOMATION
import Foundation
import Testing
@testable import MyApp

@Suite(
    .serialized,
    .tags(.automationRead, .screenshot),
    .enabled(if: TestEnvironment.runAutomationRead)
)
struct ScreenCaptureReadTests {

    @Test("captures main display and returns non-empty PNG data")
    func captureMainDisplay() async throws {
        let service = RealScreenCaptureService()
        let result = try await service.captureScreen(displayIndex: nil, scale: .standard)
        #expect(result.imageData.count > 1_000)   // sanity: at least 1 KB
    }

    @Test(
        "captures window by title (requires at least one visible window)",
        .enabled(if: TestEnvironment.runAutomationRead)
    )
    func captureWindowByTitle() async throws {
        let service = RealScreenCaptureService()
        let result = try await service.captureWindow(
            appIdentifier: "Finder",
            windowIndex: nil,
            scale: .standard
        )
        #expect(!result.applicationName.isEmpty)
    }
}
#endif
```

---

**④ AutomationInputTests.swift — automation:input 层示范（XCTest skip 对比）**

```swift
// AutomationInputTests.swift — automation target
// swift-testing style with .enabled(if:)
// pnpm run test:automation:input

#if !PEEKABOO_SKIP_AUTOMATION
import Foundation
import Testing
@testable import MyApp

@Suite(
    .serialized,
    .tags(.automationInput, .inputSynthesis),
    .enabled(if: TestEnvironment.runAutomationInput)
)
struct InputSynthesisTests {

    @Test("types 'hello' into focused text field")
    func typeHello() async throws {
        // Arrange: launch test host, focus text field
        let driver = RealInputDriver()
        // Act
        try await driver.type("hello", cadence: .fixed(milliseconds: 30))
        // Assert: read back via AX value
        // (omitted — depends on your test host setup)
    }
}

// MARK: — XCTest equivalent (for comparison / migration reference)
// XCTest style: use XCTSkipUnless instead of .enabled(if:)
// Keep in XCTest only when you need XCUIApplication or XCTMetric.

import XCTest

final class InputSynthesisXCTests: XCTestCase {
    func testTypeHelloXCTest() async throws {
        try XCTSkipUnless(
            TestEnvironment.runAutomationInput,
            "Set PEEKABOO_INCLUDE_AUTOMATION_TESTS=true PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true"
        )
        let driver = RealInputDriver()
        try await driver.type("hello", cadence: .fixed(milliseconds: 30))
    }
}
#endif
```

---

**⑤ StubServices.swift — 协议桩：Stub vs 真机对比**

```swift
// StubServices.swift — shared test support
// Pattern: protocol injection lets you swap Stub ↔ Real without touching test logic.
// Modelled on Apps/CLI/Tests/CLIAutomationTests/Support/TestServices.swift

import Foundation
@testable import MyApp

// MARK: - Protocols (define in production module)

protocol ScreenCaptureServiceProtocol: Sendable {
    var permissionGranted: Bool { get }
    func captureScreen(displayIndex: Int?, scale: CaptureScalePreference) async throws -> CaptureResult
}

protocol AccessibilityServiceProtocol: Sendable {
    var granted: Bool { get }
}

// MARK: - Stub (test support, zero permissions required)

@MainActor
final class StubScreenCaptureService: ScreenCaptureServiceProtocol {
    var permissionGranted: Bool
    /// Inject a custom handler per test; nil → return defaultResult
    var captureScreenHandler: ((Int?, CaptureScalePreference) async throws -> CaptureResult)?

    init(permissionGranted: Bool = true) {
        self.permissionGranted = permissionGranted
    }

    func captureScreen(displayIndex: Int?, scale: CaptureScalePreference) async throws -> CaptureResult {
        if let handler = captureScreenHandler {
            return try await handler(displayIndex, scale)
        }
        return CaptureResult(
            imageData: Data(repeating: 0xFF, count: 1024),
            applicationName: "Stub",
            windowTitle: "Stub Window"
        )
    }
}

@MainActor
final class StubAccessibilityService: AccessibilityServiceProtocol {
    var granted: Bool
    init(granted: Bool = true) { self.granted = granted }
}

// MARK: - Real (production path, requires permissions)

final class RealScreenCaptureService: ScreenCaptureServiceProtocol {
    var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    func captureScreen(displayIndex: Int?, scale: CaptureScalePreference) async throws -> CaptureResult {
        // calls CGWindowListCreateImage / ScreenCaptureKit
        fatalError("Replace with real implementation")
    }
}
```

---

**⑥ 编译期 `#if PEEKABOO_SKIP_AUTOMATION` 整块跳过**

```swift
// AXReadIntegrationTests.swift — automation target
// The ENTIRE file is excluded from compilation when PEEKABOO_SKIP_AUTOMATION is set.
// This prevents ScreenCaptureKit / AXorcist from being linked in CI builds.

#if !PEEKABOO_SKIP_AUTOMATION
import Testing
import ScreenCaptureKit   // only linked when automation is included
@testable import MyApp

@Suite(.tags(.automationRead), .enabled(if: TestEnvironment.runAutomationRead))
struct AXReadIntegrationTests {
    @Test("window list is non-empty when Accessibility is granted")
    func windowListNonEmpty() async throws {
        let windows = try await AXWindowEnumerator.listAll()
        #expect(!windows.isEmpty)
    }
}
#endif
```

---

**⑦ Fixture helper — 临时目录 + tear down**

```swift
// TestFixtureHelpers.swift — test support target
// Usage: let tmp = try makeTempDir()
//        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }

import Foundation
import Testing

/// Creates a unique temp directory under /tmp for the current test session.
/// Always pair with a teardown block or defer to avoid leaving artifacts.
func makeTempDir(label: String = "test") throws -> URL {
    let pid = ProcessInfo.processInfo.processIdentifier
    let dir = URL(fileURLWithPath: "/tmp/peekaboo-\(label)-\(pid)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// Swift Testing — addTeardownBlock (available from swift-testing 0.4+)
// XCTest equivalent: addTeardownBlock { ... } in setUp()

// Example usage inside a @Test function:
//
//  @Test func myTest() async throws {
//      let tmp = try makeTempDir(label: "capture")
//      defer { try? FileManager.default.removeItem(at: tmp) }
//      // ... test body ...
//  }
```

---

**⑧ package.json scripts（完整 test:* 集合）**

这些脚本已存在于 Peekaboo `package.json`，新项目对照添加：

```json
{
  "scripts": {
    "test": "pnpm run test:safe",
    "test:safe": "swift test --package-path Apps/CLI -Xswiftc -DPEEKABOO_SKIP_AUTOMATION --no-parallel",
    "test:automation": "PEEKABOO_INCLUDE_AUTOMATION_TESTS=true swift test --package-path Apps/CLI --no-parallel",
    "test:automation:read": "RUN_AUTOMATION_READ=true PEEKABOO_INCLUDE_AUTOMATION_TESTS=true swift test --package-path Apps/CLI --no-parallel",
    "test:automation:input": "PEEKABOO_INCLUDE_AUTOMATION_TESTS=true PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true swift test --package-path Core/PeekabooCore --no-parallel",
    "test:automation:local": "bash -lc 'BIN_PATH=$(swift build --package-path Apps/CLI --show-bin-path) && RUN_LOCAL_TESTS=true PEEKABOO_INCLUDE_AUTOMATION_TESTS=true PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true PEEKABOO_CLI_PATH=\"$BIN_PATH/peekaboo\" swift test --package-path Apps/CLI --no-parallel'",
    "test:all": "bash -lc 'set -euo pipefail; cd Apps/CLI && swift test -Xswiftc -DPEEKABOO_SKIP_AUTOMATION --no-parallel && PEEKABOO_INCLUDE_AUTOMATION_TESTS=true swift test --no-parallel'"
  }
}
```

---

**⑨ CI workflow YAML（GitHub Actions matrix + nightly）**

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test-safe:
    name: "test:safe (${{ matrix.os }} / Xcode ${{ matrix.xcode }})"
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [macos-14, macos-15]
        xcode: ['16.0', '16.2']
      fail-fast: false
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: ${{ matrix.xcode }}
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
      - name: Build and test (safe only)
        run: pnpm run test:safe
        # PEEKABOO_SKIP_AUTOMATION is injected via -Xswiftc flag in test:safe script
        # No env vars needed — safe layer needs zero permissions

---
# .github/workflows/nightly.yml
name: Nightly Automation Tests

on:
  schedule:
    - cron: '0 2 * * *'   # 02:00 UTC nightly
  workflow_dispatch:

jobs:
  test-automation-read:
    name: "test:automation:read (macos-15 / Xcode 16.2)"
    runs-on: macos-15        # must be a real macOS runner with GUI session
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - uses: maxim-lobanov/setup-xcode@v1
        with: { xcode-version: '16.2' }
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
      - name: Grant Screen Recording (headless CI workaround)
        run: |
          # Grant TCC for the test runner bundle ID
          tccutil reset ScreenCapture com.apple.dt.xctest.tool || true
      - name: Run automation:read tests
        run: pnpm run test:automation:read
        env:
          PEEKABOO_INCLUDE_AUTOMATION_TESTS: "true"
          RUN_AUTOMATION_READ: "true"
```

---

**⑩ `CLITestEnvironment` 完整版（automation target，对照 TestTags.swift）**

```swift
// TestTags+AutomationTarget.swift
// Full CLITestEnvironment for the automation test target.
// Mirrors Apps/CLI/Tests/CLIAutomationTests/TestTags.swift

import Darwin
import Foundation
import Testing

@preconcurrency
enum CLITestEnvironment {
    @preconcurrency
    @inline(__always)
    private nonisolated static func flag(_ key: String) -> Bool {
        ProcessInfo.processInfo.environment[key]?.lowercased() == "true"
    }

    /// Base gate: PEEKABOO_INCLUDE_AUTOMATION_TESTS=true
    @preconcurrency
    private nonisolated(unsafe) static var runAutomationTests: Bool {
        flag("PEEKABOO_INCLUDE_AUTOMATION_TESTS")
    }

    /// Read-only AX/screen: base gate AND (RUN_AUTOMATION_READ OR RUN_LOCAL_TESTS)
    @preconcurrency nonisolated(unsafe) static var runAutomationRead: Bool {
        runAutomationTests && (flag("RUN_AUTOMATION_READ") || flag("RUN_LOCAL_TESTS"))
    }

    /// Input synthesis (CGEvent): base gate AND (RUN_AUTOMATION_ACTIONS OR RUN_LOCAL_TESTS)
    @preconcurrency nonisolated(unsafe) static var runAutomationActions: Bool {
        runAutomationTests && (flag("RUN_AUTOMATION_ACTIONS") || flag("RUN_LOCAL_TESTS"))
    }

    /// Any automation scenario
    @preconcurrency nonisolated(unsafe) static var runAutomationScenarios: Bool {
        runAutomationRead || runAutomationActions
    }
}
```

## 新项目落地步骤（How to apply）

1. **拆分测试 target**：在 `Package.swift` 中将 safe 测试（`CoreTests/`）与 automation 测试（`AutomationTests/`）注册为独立 target，避免 safe 层被迫链接 `ScreenCaptureKit` / AXorcist。
2. **建立 `TestTags.swift`**：在 safe target 和 automation target 各建一个（或共享一个 `TestSupport` 库 target），集中声明 `extension Tag` 和 `enum CLITestEnvironment` / `enum TestEnvironment`，**绝不**在各测试文件内联 `ProcessInfo` 读取。
3. **`#if !PEEKABOO_SKIP_AUTOMATION` 包裹**：对每一个 automation suite 文件的最外层添加 `#if !PEEKABOO_SKIP_AUTOMATION` / `#endif`；safe 层文件**不需要**这个包裹，因为 safe target 根本不包含 automation 文件。
4. **`.enabled(if:)` 运行期 gating**：在 `@Suite(...)` 声明处加 `.enabled(if: CLITestEnvironment.runAutomationRead)`（或对应级别），Xcode 报告中会显示"已跳过"而非测试不存在。单个测试如有额外条件再加 test 级 `.enabled(if:)`。
5. **Stub 协议设计**：为所有需要权限的服务提取协议（`ScreenCaptureServiceProtocol`、`AccessibilityServiceProtocol` 等），实现 Stub 版本并通过构造器注入。Safe 层测试**只用 Stub**，不引用任何真实框架。
6. **Fixture 隔离**：任何测试产生的文件写入 `/tmp/peekaboo-<label>-<pid>-<uuid>/`，在 `defer` 或 `addTeardownBlock` 中清理，防止测试间状态污染。
7. **`package.json` 暴露脚本**：添加 `test:safe` / `test:automation:read` / `test:automation:input` / `test:automation:local` / `test:all` 五条脚本；`test`（默认）指向 `test:safe`，确保 `pnpm test` 在任何机器上都不会意外触发权限请求。
8. **CI 配置**：PR / push CI job 只调用 `test:safe`；不传 `RUN_AUTOMATION_READ` 或 `PEEKABOO_INCLUDE_AUTOMATION_TESTS`，确保 gating 在 CI 上不会因遗漏关闭而失效。
9. **Nightly 真机 job**：独立 nightly workflow，在有真实 macOS GUI 会话的 runner 上运行 `test:automation:read`；将失败纳入 Slack / 邮件报警，不阻塞 PR CI。
10. **测试报告整理**：定期检查 `swift test` 输出中"Test Suites skipped"数量是否符合预期；若某个 suite 从不出现在报告（既非 passed 也非 skipped），排查 `#if` 是否误包裹了 safe 层代码或 `.enabled(if:)` 条件永远为 false。

## 替代方案对比（When NOT to use）

| 方案 | 优点 | 缺点 | 适用场景 |
|------|------|------|---------|
| **本方案：swift-testing + XCTest 共存 + 编译期+运行期双重 gating** | 报告完整可见；CI 构建零权限开销；细粒度 `@Tag` 过滤；Stub/真机清晰分层 | 两个 TestTags 文件需同步维护；`#if` 包裹增加文件样板 | macOS 14+，权限敏感，Xcode 15+，项目长期维护 |
| **纯 XCTest（传统方案）** | 历史积累丰富，Xcode 完美支持；`XCTSkip` 语义清晰 | API verbose（`XCTAssertEqual` vs `#expect`）；`@Tag`/`.enabled(if:)` 无对应物；并发 test 支持弱 | 维护老代码库；需要 XCUITest / XCTMetric 的项目 |
| **纯 swift-testing（不保留 XCTest）** | 统一框架，代码最简洁；并发原生支持；`@Tag` 灵活过滤 | `XCUIApplication` / `XCTMetric` 无法迁移；框架相对新，部分工具链集成待完善 | 纯单元+集成测试，不需要 UI Automation 或性能基准 |
| **Quick / Nimble（BDD 风格）** | `describe`/`it` 语义接近规格说明；`expect().to(equal())` 可读性强 | 第三方 SPM 依赖；额外维护负担；与 swift-testing 重叠功能多 | 团队有 RSpec/Jasmine 背景；偏好 BDD 规格风格 |
| **Snapshot testing（pointfreeco/swift-snapshot-testing）** | 视觉回归测试零成本维护；PNG diff 直观 | 需要 Reference image 管理（版本控制膨胀）；macOS 版本/字体渲染变化导致 false positive | UI 组件回归（配合本方案使用，不替代） |
| **常规三层金字塔（Unit / Integration / UI）不做权限 gating** | 结构简单，入门门槛低 | 权限依赖隐含在测试代码里，CI 失败难以区分是逻辑错误还是权限缺失；无法在 CI 和本地差异化执行 | 不涉及系统权限的普通 app |

**降级策略**：若 swift-testing 在某个工具链版本有 runner bug（历史上有过 Xcode 15.0 的并发 suite 问题），在受影响的 matrix slot 临时切回 XCTest + `XCTSkip` 等价实现，其他 matrix slot 继续用 swift-testing——两者可在同一 target 共存，不需要全量切换。

## 非原生环境（Non-Native Targets）

### 测试 Electron / Web 应用

Peekaboo 也支持对 Electron app（Slack、VSCode、Discord 等）执行 AX 自动化和截图。这类 app 的测试有两个额外的维度需要处理：

**截图层面**：`ScreenCaptureKit` 对 Electron 窗口与原生 Cocoa 窗口行为一致，无需特殊处理，safe 层 Stub + automation:read 真机矩阵适用。

**AX 操作层面**：Electron/Chromium 的 AX 树不完整（大量 `AXWebArea` 不暴露具体 input field），这类测试在 CI 上更脆弱。建议：
- 把"验证 AX 树能枚举到 Electron 主窗口"放入 automation:read（相对稳定）
- 把"验证能在 Electron 文本框内输入字符"放入 automation:input，并标记 `.flaky`，在 nightly 报警而非阻塞 PR CI
- Headless CI（无 GUI 会话）根本无法运行 Electron，不要在标准 CI matrix 中启用

**Web 测试（非 macOS 原生）**：如果项目同时包含 Web 组件，不要混入 swift-testing matrix。Web 侧用 Playwright / Cypress 独立跑；macOS 侧用本 playbook 的矩阵。两套 CI job 的 gating 环境变量命名空间独立，不互相干扰。

### 测试 macOS UI（XCUITest 关系）

`XCUITest`（`XCUIApplication`）通过 Sandbox 进程注入运行，无法测试系统级权限请求（TCC 弹窗）、全局快捷键、跨进程 AX 等能力。Peekaboo 对这类边界场景用的是 **automation:read / local 真机测试**而非 XCUITest。

明确分工：
- XCUITest → 验证 app 自身 UI 流（按钮点击、导航、表单提交），适合沙盒内功能
- automation:read/input → 验证跨进程 AX、系统 API 边界、权限状态机
- local → 验证真实 CLI 二进制的端到端行为

不要混用：在同一 target 里同时 import `XCUIApplication` 和 swift-testing 的 `@Test` 会导致 runner 兼容性问题（XCUITest 需要 XCTest 的测试主机进程）。

## 调试与取证（Debug & Forensics）

| 症状 | 排查命令 | 根因 |
|------|---------|------|
| CI 跑了 automation 测试然后失败（`AXError -25204`） | `env \| grep PEEKABOO` 检查 env var | gating 未生效：新 automation 文件缺 `#if` 包裹，或 CI 脚本未传 `-DPEEKABOO_SKIP_AUTOMATION` |
| 真机跑挂在 AX 权限（`kAXErrorAPIDisabled`） | `tccutil reset Accessibility com.apple.dt.xctest.tool` | 测试 host bundle 没有 Accessibility 授权，或 TCC 数据库损坏 |
| swift-testing 测试未运行（既非 pass 也非 skip） | `swift test --list-tests \| grep MyTest` 确认测试是否被枚举 | `@Tag`/`.enabled(if:)` 条件永远 false，或 `ENABLE_TESTING_FRAMEWORKS = NO` |
| XCTest 与 swift-testing 混用 runner 报错 | `swift test --filter MyTest 2>&1 \| grep "framework"` | 同 target 内同时 import `XCUIApplication`（强制 XCTest runner）和 `import Testing`（swift-testing runner）冲突 |
| 测试间状态污染（第二次跑同测试失败） | 检查 tmp 文件残留：`ls /tmp/peekaboo-*` | Fixture 没清干净：`defer { try? FileManager.default.removeItem(at: tmp) }` 缺失或被提前 return 绕过 |
| Stub 总返回 success，真机失败（nightly 报警） | `RUN_AUTOMATION_READ=true PEEKABOO_INCLUDE_AUTOMATION_TESTS=true swift test --package-path Apps/CLI --no-parallel` 本地复现 | Stub 没覆盖真实失败路径（特定 macOS 版本的 API 差异）；在 nightly 真机 job 里才能捕捉 |
| swift-testing 并发跑挂（资源竞争 / 截图互相干扰） | `swift test --num-workers 1 --package-path Apps/CLI` | 多 worker 并发调用屏幕录制 API；用 `@Suite(.serialized)` 或 `--no-parallel` 强制串行 |

### 工具箱

```bash
# 枚举所有测试（验证 gating 是否正常过滤）
swift test --package-path Apps/CLI --list-tests

# 只跑指定测试（调试单个失败）
swift test --package-path Apps/CLI --filter "PermissionCommandTests"

# 强制单线程（排查并发竞争）
swift test --package-path Apps/CLI --num-workers 1

# Xcode workspace 方式运行（完整 test plan）
xcodebuild test \
  -workspace Apps/Peekaboo.xcworkspace \
  -scheme PeekabooCLI \
  -testPlan SafeTests \
  -destination 'platform=macOS'

# 重置 Accessibility TCC（测试 host 没有权限时）
tccutil reset Accessibility com.apple.dt.xctest.tool
tccutil reset ScreenCapture com.apple.dt.xctest.tool

# 录制测试过程视频（调试 UI/屏幕相关失败）
xcrun simctl io booted recordVideo /tmp/test-run.mp4

# 查看 safe vs automation 脚本差异
pnpm run test:safe -- --verbose
PEEKABOO_INCLUDE_AUTOMATION_TESTS=true pnpm run test:automation -- --verbose

# env var 一次性编排（不修改 shell 环境）
env PEEKABOO_SKIP_AUTOMATION=1 swift test --package-path Apps/CLI

# GitHub Actions：本地模拟 CI 跑法
act push --job test-safe
```

### 关键 log 开启

```bash
# 查看 TCC 权限决策（需 sudo）
log stream --predicate 'subsystem == "com.apple.TCC"' --level debug

# 查看 AX API 调用错误
log stream --predicate 'process == "peekaboo" AND messageType == error'

# ScreenCaptureKit 诊断
log stream --predicate 'subsystem == "com.apple.screencapturekit"'
```

## 常见陷阱（Pitfalls）

**陷阱 1：automation 测试混入 CI 触发权限报错**

可观测信号：CI 日志出现 `AXError`（如 `-25204 kAXErrorNotImplemented`）或 `CGScreenCaptureAccessNotGranted`，测试卡死或以非零状态退出，后续全部跳过。

根因：`PEEKABOO_SKIP_AUTOMATION` 未随 CI 脚本传入，或新增 automation suite 文件缺少 `#if !PEEKABOO_SKIP_AUTOMATION` 包裹。

处理方式：CI 脚本强制使用 `pnpm run test:safe`（内含 `-Xswiftc -DPEEKABOO_SKIP_AUTOMATION`）；在 PR checklist 中要求新 automation 文件必须添加 `#if` 包裹；可用 lint 规则扫描 `CLIAutomationTests/` 目录下不含 `#if` 的 `.swift` 文件。

**陷阱 2：Stub 走 happy path 而真机失败**

可观测信号：CI 全绿，但本地运行 `pnpm run test:automation:read` 报"窗口列表为空"或"AX 元素找不到"，且只在特定 macOS 版本复现。

根因：Stub 返回固定 fixture，无法覆盖真实 API 在不同 macOS 版本下的行为差异（如 macOS 15 改变了 `CGWindowListCreateImage` 对屏幕外窗口的处理方式）。

处理方式：在 nightly CI 中增设有权限的 macOS runner 周期运行 automation:read 层，将失败纳入报警，不阻塞 PR CI，但必须在 release 前修复。

**陷阱 3：Swift Testing 与 XCTest 混用导致 runner 遗漏测试**

可观测信号：`@Test` 函数在 CI 报告中从未出现（既非通过也非跳过），但 Xcode GUI 可手动运行。

根因：target 的 `ENABLE_TESTING_FRAMEWORKS = NO`（Build Settings），`import Testing` 降级为空实现，测试被静默忽略。

处理方式：在 Build Settings 确认 `ENABLE_TESTING_FRAMEWORKS = YES`；检查 `swift test` 输出总测试数是否与预期一致；用 `swift test --list-tests` 验证所有 `@Test` 函数都被枚举。

**陷阱 4：测试 fixture 没清干净导致后续测试看到旧 state**

可观测信号：第一次跑通过，第二次跑同一测试失败（报文件已存在 / 内容与预期不符）；在 CI 上偶发，本地单独运行正常。

根因：`defer` 块因测试中途 `throw` 而未到达，或测试用了 `async let` 使 `defer` 作用域提前结束；`/tmp/peekaboo-test-<pid>` 目录残留。

处理方式：一律用 `addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }`（XCTest）或 Swift Testing 的 `withKnownIssue { ... }` + `defer` 双保险；在 CI 脚本开头加 `rm -rf /tmp/peekaboo-test-*` 清理上次残留。

**陷阱 5：swift-testing `@Tag` 改名后 `package.json` scripts 没同步**

可观测信号：运行 `swift test --filter "Tags/automationRead"` 输出 "0 tests run"，但测试文件明明存在。

根因：重构时把 `@Tag static var automationRead` 改成了 `@Tag static var automation_read`（或反之），但 `package.json` 的 `--filter` 参数和 CI 注释文档都引用旧 tag 名，实际传入的 filter 匹配不到任何测试。

处理方式：重命名 tag 后立刻用 `swift test --list-tests | grep Tags` 验证 tag 名在运行时的字面量；更新 `package.json` 注释；在 PR 描述中注明 tag 重命名，避免其他开发者书签失效。

## 延伸阅读

- Peekaboo：`docs/swift-testing-playbook.md`、`docs/manual-testing.md`、`docs/test-refactor.md`
- Apple：[Swift Testing 文档](https://developer.apple.com/documentation/testing)
- WWDC 2024：[Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/)
- [swift-testing GitHub](https://github.com/apple/swift-testing)
- 其它 playbook：[03 · 日志](./03-logging-observability.md)、[04 · 错误处理](./04-error-handling.md)、[05 · 权限状态机](./05-permissions-state-machine.md)、[06 · AXorcist](./06-ax-automation-axorcist.md)、[07 · CGEvent 拟真输入](./07-cgevent-input-synthesis.md)、[11 · 工程混合](./11-swiftpm-xcode-poltergeist.md)

---
*Last verified against Peekaboo @ `5301a030e6e5d8b4217f5ad6d7b88991d887bd74`*
