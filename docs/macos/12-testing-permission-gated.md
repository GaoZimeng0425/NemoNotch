---
summary: 'Gate permission-sensitive tests behind compile-time flags and environment variables so CI runs only the safe subset.'
read_when:
  - 'configuring test targets that require screen recording or accessibility permissions'
  - 'preventing permission dialogs or test failures in CI environments without macOS entitlements'
---

# 12 · 测试策略 + 权限敏感测试 gating

## TL;DR

macOS 自动化项目中，部分测试需要屏幕录制或 Accessibility 权限，在 CI 直接运行会触发系统弹窗或报错。Peekaboo 用编译期标志 `PEEKABOO_SKIP_AUTOMATION` 与运行期环境变量将测试拆成四个层级，CI 默认只跑安全集，本地按需解锁。Swift Testing 的 `.enabled(if:)` 与 `@Tag` 让 gating 逻辑清晰且零入侵。

## Peekaboo 在哪里实现

- 配置文件：`package.json` 第 26–31 行 — `test:safe` / `test:automation` / `test:automation:read` / `test:automation:input` / `test:automation:local` 五条脚本
- 关键文件：`Apps/CLI/Tests/CoreCLITests/TestTags.swift:4–53` — 集中定义所有 `Tag` 扩展与 `CLITestEnvironment` 环境检查工具
- 关键文件：`Apps/CLI/Tests/CLIAutomationTests/PermissionCommandTests.swift:6–50` — 用 `StubAutomationService` 和 `StubScreenCaptureService` 做无权限隔离测试的范例
- 关键文件：`Apps/CLI/Tests/CLIAutomationTests/AnnotationIntegrationTests.swift:6–17` — 双重 `#if !PEEKABOO_SKIP_AUTOMATION` + `.enabled(if:)` 的嵌套 gating 示例
- 相关 docs：`docs/swift-testing-playbook.md`、`docs/manual-testing.md`、`docs/test-refactor.md`

## 设计动机（Why）

CI runner 无 GUI 会话、无 Screen Recording 授权，调用 `CGWindowListCreateImage` 或 `AXUIElement` 的代码会立即失败，甚至触发系统弹窗挂起进程。早期做法是整体注释 automation 测试，代价是本地跑不到真正的回归覆盖。

分级 gating 同时满足两个互斥需求：**CI 快速稳定无副作用**；**本地开发者端到端真机验证**。用环境变量而非代码分支控制边界，各层测试独立演进，不会互相误伤。`#if` 编译期剔除与 `.enabled(if:)` 运行期跳过可叠加：前者让 CI 构建零开销，后者让 Xcode 报告能看到"已跳过"而非"缺失"。

## 核心模式（Pattern）

### 分级测试矩阵

| 层级 | pnpm 脚本 | 关键环境变量 | 可在 CI 运行 |
|------|-----------|-------------|-------------|
| safe | `test:safe` | `-Xswiftc -DPEEKABOO_SKIP_AUTOMATION` | 是 |
| automation:read | `test:automation:read` | `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` `RUN_AUTOMATION_READ=true` | 需权限 |
| automation:input | `test:automation:input` | `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` `PEEKABOO_RUN_INPUT_AUTOMATION_TESTS=true` | 需权限 |
| local | `test:automation:local` | 以上全部 + `RUN_LOCAL_TESTS=true` + `PEEKABOO_CLI_PATH` | 否 |

**safe 层**：`#if !PEEKABOO_SKIP_AUTOMATION` 块将整个 automation suite 文件排除在编译之外，CI 构建产物中根本不存在权限相关代码。

**automation:read 层**：只验证 AX 树读取、窗口列表枚举等只读操作，不合成键鼠事件，需要 Accessibility 权限但不影响用户焦点。

**automation:input 层**：包含 `CGEvent` 键鼠合成，可能改变前台 app，须独立运行（`--package-path Core/PeekabooCore`）。

**local 层**：全权限机器端到端调用真实 CLI 二进制，最接近生产的冒烟验证。

### 环境变量 gating 实现

编译期用 Swift 条件编译标志：

```swift
// Apps/CLI/Tests/CLIAutomationTests/MenuCommandTests.swift:8
#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.serialized, .tags(.automation))
struct MenuCommandTests {
    // ...
}
#endif
```

运行期用 Swift Testing 的 `.enabled(if:)` trait：

```swift
// Apps/CLI/Tests/CoreCLITests/TestTags.swift:50
@preconcurrency nonisolated(unsafe) static var runAutomationScenarios: Bool {
    flag("RUN_AUTOMATION_TESTS") || flag("RUN_LOCAL_TESTS")
}
```

```swift
@Suite(.serialized, .tags(.automation),
       .enabled(if: CLITestEnvironment.runAutomationScenarios))
struct MyAutomationSuite { ... }
```

更细粒度时，单个 `@Test` 也可独立设置 `.enabled(if:)`，实现 suite 层通过、test 层二次过滤的双重门控：

```swift
@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] == "true"))
func capturesMainDisplay() async throws { ... }
```

### Mock 与真机的决策边界

| 场景 | 策略 |
|------|------|
| 验证 JSON 输出结构、命令解析 | Stub 服务，完全脱离权限 |
| 验证 AX 元素查找（只读） | automation:read，真实 AX API |
| 验证点击/拖拽/键入 | automation:input，真实 CGEvent |
| 验证跨进程端到端 | local，真实二进制 + 全权限 |

Stub 层的核心价值是让**逻辑正确性**与**权限行为**分离验证。`PermissionCommandTests` 用 `accessibilityPermissionGranted = false` 构造无权限场景，验证 JSON 报告结构——这在有权限的本地机上反而无法重现。

### Swift Testing 与 XCTest 共存

Peekaboo 已全面迁移至 Swift Testing：`import Testing` + `@Suite`、`#expect`、`#require` 取代 XCTest 调用。两个框架可在同一 target 内共存，逐文件替换即可。UI Automation（`XCUIApplication`）和性能基准（`XCTMetric`）暂不支持迁移，保留在 XCTest 中。

## 新项目落地步骤（How to apply）

1. 将测试文件按职责拆分到不同目录（`SafeTests/`、`AutomationTests/`），在 `Package.swift` 中注册为独立 target，避免 safe 与 automation 代码耦合。
2. 在 `TestTags.swift` 中集中声明 `Tag` 扩展和环境变量检查工具，所有测试文件统一引用，不在各文件内联 `ProcessInfo` 读取。
3. 对每个 automation suite 文件添加 `#if !PEEKABOO_SKIP_AUTOMATION` / `#endif` 包裹，并在 safe 脚本中传入 `-Xswiftc -DPEEKABOO_SKIP_AUTOMATION`。
4. 在 automation suite 声明处加 `.enabled(if: CLITestEnvironment.runAutomationScenarios)`，让 Xcode 报告能显示"已跳过"而非"缺失"。
5. CI 默认只执行 safe 层；nightly 或手动触发时，配置权限后才运行 automation:read；本地开发者用 automation:local 做最终验证。

## 常见陷阱（Pitfalls）

**陷阱 1：automation 测试混入 CI 触发权限报错**

可观测信号：CI 日志出现 `AXError`（如 `-25204 kAXErrorNotImplemented`）或 `CGScreenCaptureAccessNotGranted`，测试卡死或以非零状态退出，后续全部跳过。

根因：`PEEKABOO_SKIP_AUTOMATION` 未随 CI 脚本传入，或新增 automation suite 缺少 `#if` 保护。处理方式：CI 脚本强制使用 `pnpm run test:safe`，PR checklist 要求新 automation 文件必须添加 `#if !PEEKABOO_SKIP_AUTOMATION` 包裹。

**陷阱 2：Stub 走 happy path 而真机失败**

可观测信号：CI 全绿，但本地运行 `pnpm run test:automation:read` 报"窗口列表为空"或"AX 元素找不到"，且只在特定 macOS 版本复现。

根因：Stub 返回固定 fixture，无法覆盖真实 API 在不同 macOS 版本下的行为差异。处理方式：在 nightly CI 中增设有权限的 macOS runner 周期运行 automation:read 层，将失败纳入报警。

**陷阱 3：Swift Testing 与 XCTest 混用导致 runner 遗漏测试**

可观测信号：`@Test` 函数在 CI 报告中从未出现（既非通过也非跳过），但 Xcode GUI 可手动运行。

根因：target 的 **Enable Testing Frameworks** 未开启，`import Testing` 降级为空实现，测试被静默忽略。处理方式：在 Build Settings 确认 `ENABLE_TESTING_FRAMEWORKS = YES`，并检查 `swift test` 输出总测试数是否与预期一致。

## 延伸阅读

- Peekaboo：`docs/swift-testing-playbook.md`、`docs/manual-testing.md`、`docs/test-refactor.md`
- Apple：[Swift Testing](https://developer.apple.com/documentation/testing)
- 其它 playbook：[03 · 日志](./03-logging-observability.md)、[04 · 错误处理](./04-error-handling.md)、[05 · 权限](./05-permissions-state-machine.md)、[11 · 工程混合](./11-swiftpm-xcode-poltergeist.md)

---
*Last verified against Peekaboo @ `0c88b05b`*
