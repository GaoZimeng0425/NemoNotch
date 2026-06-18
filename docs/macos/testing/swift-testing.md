---
summary: 'Swift Testing（import Testing / @Test / #expect）框架用法与 NemoNotch 测试约定：测纯逻辑、跳过 ScriptingBridge/AX/NSWindow 集成。'
read_when:
  - '为 NemoNotch / macOS 项目写新单元测试'
  - '在 XCTest 和 Swift Testing 之间选择框架'
  - '调试 @Test 函数在 Xcode 中不出现或不执行的问题'
sources: ['N', 'I-21']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# Swift Testing 框架使用指南

## TL;DR

NemoNotch 的新测试**一律用 Swift Testing**（`import Testing`、`@Test`、`#expect`、`#require`），不用 XCTest。  
只测**纯逻辑**：解析器（ConversationParser / GeminiConversationParser）、状态转换（AISessionState 相变）、编码器（序列化/反序列化）。  
**跳过** ScriptingBridge / Accessibility / NSWindow / NSPanel 集成测试——这类测试需要真实 macOS 权限 + GUI 会话，在 CI 容器里运行不稳定。

---

## 可复用模式

### Pattern 1 · 基本测试声明

```swift
// NemoNotchTests/Services/ConversationParserTests.swift
import Testing
@testable import NemoNotch

@Suite("ConversationParser")
struct ConversationParserTests {

    @Test("解析单条 assistant 消息")
    func parseSingleAssistantMessage() throws {
        let line = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}
        """
        let parser = ConversationParser()
        let msg = try #require(parser.parseLine(line))
        #expect(msg.role == .assistant)
        #expect(msg.textContent == "hello")
    }

    @Test("忽略无效 JSON 行不抛出")
    func ignoresInvalidJSON() {
        let parser = ConversationParser()
        let result = parser.parseLine("not json at all")
        #expect(result == nil)
    }
}
```

关键宏：
- `#expect(condition)` — 软断言，失败继续执行后续行
- `#require(optional)` — 强断言，为 `nil` 时立即终止测试（等价 XCTest `XCTUnwrap`）
- `#expect(throws: SomeError.self) { ... }` — 验证抛出特定类型错误

### Pattern 2 · 状态转换测试（@Observable store 无 UI 测纯逻辑）

测 `AISessionStore` 的状态转换时，直接操作 store，无需启动任何窗口：

```swift
@Suite("AISessionStore 状态转换")
@MainActor
struct AISessionStoreTests {

    @Test("upsert 新 session 后 sortedSessions 包含该 session")
    func upsertNewSession() {
        let store = AISessionStore()
        let id = UUID().uuidString
        store.upsert(sessionID: id, source: .claude, project: "/tmp/test")
        #expect(store.sortedSessions.contains { $0.id == id })
    }

    @Test("activeSession 优先选 waitingForApproval 状态")
    func activeSessionPriority() {
        let store = AISessionStore()
        let idleID = UUID().uuidString
        let approvalID = UUID().uuidString
        store.upsert(sessionID: idleID, source: .claude, project: "/tmp/a")
        store.mutate(sessionID: idleID) { $0.phase = .idle }
        store.upsert(sessionID: approvalID, source: .claude, project: "/tmp/b")
        store.mutate(sessionID: approvalID) { $0.phase = .waitingForApproval }
        #expect(store.activeSession?.id == approvalID)
    }
}
```

`@MainActor` 放在 `@Suite` 上，整个 suite 在主线程运行，与 `@Observable` store 的 `@MainActor` 约束一致。

### Pattern 3 · 参数化测试（多用例同一逻辑）

```swift
@Test(
    "GeminiConversationParser 解析各类角色",
    arguments: [
        ("user", MessageRole.user),
        ("model", MessageRole.assistant),
        ("system", MessageRole.system),
    ]
)
func parseRole(rawValue: String, expected: MessageRole) throws {
    let parser = GeminiConversationParser()
    let role = try #require(parser.parseRole(rawValue))
    #expect(role == expected)
}
```

### Pattern 4 · 串行 suite（避免并发状态竞争）

当 suite 测试共享可变状态（如单例、文件系统）时：

```swift
@Suite(.serialized)
struct TaskStoreTests {
    // 所有 @Test 串行执行，不并发
}
```

### Pattern 5 · 测试结构镜像源码结构

```
NemoNotch/
├── Services/
│   ├── ConversationParser.swift
│   └── GeminiConversationParser.swift
└── Models/
    └── AISessionState.swift

NemoNotchTests/
├── Services/
│   ├── ConversationParserTests.swift
│   └── GeminiConversationParserTests.swift
└── Models/
    └── AISessionStateTests.swift
```

改了 `ConversationParser` → 在旁边 `ConversationParserTests.swift` 加聚焦测试，不新建远离源码的测试文件。

### Pattern 6 · 注入 fake 闭包替代 protocol/mock

从 Ironsmith principles §21(I-21)：**直接注入 fake 闭包 client，不搞 protocol/mock 仪式**。

```swift
// 生产代码：副作用收敛成可替换闭包
struct CalendarFetcher {
    var fetchEvents: (Date, Date) async throws -> [CalendarEvent] = CalendarService.live.fetchEvents
}

// 测试：直接替换闭包，无需 protocol + MockCalendarService
@Test("空日历返回空数组")
func emptyCalendar() async throws {
    var fetcher = CalendarFetcher()
    fetcher.fetchEvents = { _, _ in [] }
    let events = try await fetcher.fetchEvents(.now, .now)
    #expect(events.isEmpty)
}
```

### Pattern 7 · 临时文件隔离（涉及文件 IO 的测试）

```swift
@Test("TaskStore 持久化到指定路径")
func taskStorePersistence() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-tasks-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = TaskStore(fileURL: tmp)
    store.add(Task(title: "test"))
    let loaded = TaskStore(fileURL: tmp)
    #expect(loaded.tasks.count == 1)
}
```

`defer` 保证测试结束（包括提前 `throw`）后清理，避免测试间状态污染。

---

## 哪些测试值得写 / 哪些跳过

### ✅ 适合 Swift Testing 的

| 类型 | 例子 |
|------|------|
| 解析器 | `ConversationParser`、`GeminiConversationParser`、`HermesConversationParser` |
| 状态转换 | `AISessionState` 相变、`PomodoroTimerService` 状态机 |
| 序列化/编码 | `AppSettings` UserDefaults round-trip、`TaskStore` JSON |
| 纯算法 | `BadgeViewModel.glow(for:)` 决策逻辑、`CompletionDetector.detect()` |
| UI 模式逻辑（无 NSWindow） | `UITestMode.isActive(in:)`、`UITestMode.tab(in:)` |

### ❌ 跳过（需真实 macOS 权限 + GUI）

| 类型 | 原因 |
|------|------|
| ScriptingBridge / AppleScript | 需要 Automation TCC 授权，CI 没有 |
| `AXUIElement` / AX 树查找 | 需要 Accessibility TCC，CI 没有 |
| `NSWindow` / `NSPanel` 创建 | 需要 Display Server，CI 容器无 GUI 会话 |
| `CGEvent` 合成 | 有副作用（改变前台 App），只跑本地 |
| `MediaRemote` 私有框架 | 需要 TCC + 实际媒体播放状态 |

跳过不代表不验证 —— 用 Stub 在 safe 层覆盖逻辑正确性，真机层（permission-gated-testing.md）覆盖系统边界。

---

## 运行命令

```bash
# NemoNotch 项目
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS'

# 只跑某个 suite（按名过滤）
xcodebuild test \
  -project NemoNotch.xcodeproj \
  -scheme NemoNotch \
  -destination 'platform=macOS' \
  -only-testing:NemoNotchTests/ConversationParserTests

# swift package 工程（如纯 SPM 子模块）
swift test --filter "ConversationParserTests"
swift test --list-tests   # 验证测试是否被枚举
```

---

## 锚点（file:line）

NemoNotch 项目相关：

| 概念 | 文件:行 |
|------|---------|
| Swift Testing 约定声明 | `CLAUDE.md`（NemoNotch）Testing 章节 |
| `AISessionStore` upsert/mutate/mutateOrCreate | `NemoNotch/Services/AISessionStore.swift` |
| `ConversationParser` 增量解析 | `NemoNotch/Services/ClaudeCodeService.swift` |
| `GeminiConversationParser` | `NemoNotch/Services/GeminiProvider.swift` |
| `UITestMode.isActive(in:)` / `tab(in:)` 纯函数（可无 UI 测试） | `NemoNotch/Helpers/UITestMode.swift` |
| `TaskStore(fileURL:)` 可注入路径（隔离测试） | `NemoNotch/Services/TaskStore.swift` |
| `BadgeViewModel.glowState` 纯决策逻辑 | `NemoNotch/Notch/BadgeViewModel.swift` |

Ironsmith principles §21(I-21)相关：

| 概念 | 原文引用 |
|------|---------|
| 用 Swift Testing，不用 XCTest | `AGENTS.md:13` |
| 测试镜像源码结构 | `AGENTS.md:27` |
| 直接注入 fake 闭包，不搞 protocol/mock | §5（副作用收敛） |
| 逻辑与 UI 解耦（`isRunningTests` flag） | §21 |

---

## Pitfalls

**@Test 在 Xcode 中不出现（既非 pass 也非 skip）**  
根因：`ENABLE_TESTING_FRAMEWORKS = NO`（Build Settings），`import Testing` 降级为空实现。  
处理：Build Settings 确认 `ENABLE_TESTING_FRAMEWORKS = YES`；用 `swift test --list-tests` 确认测试被枚举。

**@MainActor suite 调用 async 方法卡死**  
根因：在 `@MainActor` 隔离的 suite 里 `await` 一个同样 `@MainActor` 的方法，Swift 6 默认并发模式下可能形成重入死锁。  
处理：改用 `@Suite(.serialized)` + `nonisolated` 的 helper，或在 `Task { @MainActor in ... }` 内测试。

**swift-testing 与 XCTest 混用 runner 报错**  
根因：同 target 内同时 import `XCUIApplication`（强制 XCTest runner）和 `import Testing`（swift-testing runner）冲突。  
处理：XCUITest 保留在独立 XCTest target；swift-testing target 不引入 `XCUIApplication`。

**`defer` 在 async let 作用域提前退出**  
根因：`async let` 绑定在声明处即触发，`defer` 作用域可能比 `async let` 的实际执行提前结束。  
处理：异步测试中优先用 `addTeardownBlock { ... }`（swift-testing 0.4+），或将清理逻辑包在 `withTaskGroup` 的 `defer`。

---

## 落地 Checklist

- [ ] 新测试文件 `import Testing`，不 `import XCTest`
- [ ] 测试目录结构镜像源码：`NemoNotchTests/Services/XxxTests.swift` 对应 `NemoNotch/Services/Xxx.swift`
- [ ] `@Test` 函数名用人类可读描述（中英文均可）
- [ ] 涉及文件 IO 的测试用 `FileManager.default.temporaryDirectory` + `defer` 清理
- [ ] `@MainActor` store 的测试 suite 标 `@MainActor` 或 `@Suite(.serialized)`
- [ ] 跑 `xcodebuild test` 确认新测试出现在报告中（非仅 Xcode GUI 可见）
- [ ] 不为 ScriptingBridge / AX / NSWindow 写集成测试（跳过，理由注释说明）

---

## 延伸阅读

- [permission-gated-testing.md](./permission-gated-testing.md) — 权限敏感测试分层、automation:read/input
- [../build-release/](../build-release/) — xcodebuild 参数、CI matrix
- Apple：[Swift Testing 文档](https://developer.apple.com/documentation/testing)
- WWDC 2024：[Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/)
- [swift-testing GitHub](https://github.com/apple/swift-testing)
