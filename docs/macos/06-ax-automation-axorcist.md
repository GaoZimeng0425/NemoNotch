---
summary: 'Use AXorcist as a Swift-native consumer of macOS Accessibility API with query DSL, timeout, focus protection, and Electron/web fallbacks.'
read_when:
  - 'driving non-native UI in production code beyond XCTest UI testing'
  - 'handling AX tree differences across Electron / web browsers / terminals'
---

# 06 · AXorcist 元素查找 + Focus

## TL;DR

macOS Accessibility API 的原始 C 接口(`AXUIElementRef`)繁琐且易出错:元素句柄随窗口状态改变而失效,app 解析需要处理名称/bundleId/PID 多种形式,focus 操作不当会打断用户工作流,超时机制需要自行实现。AXorcist 将这些低层细节封装为 Swift-native 的类型安全 API:消费方通过 `AXApp(runningApp).element` 进入 AX 树,用 `children()`/`role()`/`title()` 遍历匹配元素,所有调用均带可配置的 messaging timeout。核心三元组:**query DSL**（声明"找什么"而非"怎么找"）+ **focus 保护**（操作前快照 frontmostApp,操作后恢复）+ **retry with deadline**（防止 AX 慢应用卡死主线程）。重要警示:Electron/Chromium 系应用（VSCode、Discord、Slack）的 AX 树由 Chromium bridge 生成,部分 input 元素不暴露 `AXValue`,`AXSetValue` 返回 success 但字段不变是常见陷阱;终端 emulator 不是 AX 元素而是 PTY,`setValue` 不起作用。Peekaboo 消费 AXorcist 的主要位点在 `PeekabooAutomationKit`,`WindowManagementService`、`FocusUtilities`、`TypeService` 是最佳参考实现。

## Peekaboo 在哪里实现

- **模块**:`AXorcist/`(submodule,提供 `AXApp`/`Element`/`Attribute` 等公开 API)+ `Core/PeekabooAutomationKit`(主要消费方)
- **关键文件**:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Utilities/FocusUtilities.swift:178` — 注释"AX handles can go stale after activation";第 201 行演示激活后重新 query refreshedHandle 防止 stale 的标准写法
- **关键文件**:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/WindowManagementService+Resolution.swift:51` — `WindowTarget` 枚举驱动 app resolving 的多 strategy 分支;第 91 行 `AXApp(runningApp).element` 是进入 AX 树的入口范本
- **关键文件**:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/AXTreeCollector.swift:64` — `collect(window:deadline:budget:)` 展示带 deadline + `AXTraversalBudget`(maxDepth/maxElementCount)的树遍历最佳实践
- **关键文件**:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/TypeService+TargetResolution.swift:82` — `findTextFieldByQuery` 展示 `AXApp(frontApp).element` + 递归 role+label 匹配模式
- **关键文件**:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/ElementDetectionWindowResolver.swift:102` — `windowsWithTimeout()` 应对 Chrome 多进程空窗口列表;第 104 行用带超时版本的 window 枚举取代默认 `windows()`
- **关键文件**:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/ElementClassifier.swift:50` — `supportedActionLookupRoles` 注释说明 Chromium/Tauri 可能将 clickable 内容藏进容器角色(`AXGroup`/`AXImage` 等)
- **关键文件**:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/ElementDetectionService.swift:215` — 检测第一次遍历结果稀疏时触发 web focus fallback(`AXWebArea` 查找),专门应对 Chromium/Tauri 隐藏内容
- **关键文件**:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/DialogService+Resolution.swift:132` — `dialogWindowCandidates` 对 Electron/Tauri 限制搜索范围到 `focusedWindow`/`mainWindow`,防止无边界子树遍历
- **相关 docs**:`docs/focus.md`、`docs/application-resolving.md`、`docs/automation.md`

## 设计动机(Why)

### 裸 `AXUIElementRef` C API 的四大坑

1. **句柄生命周期无保证**:`AXUIElementRef` 本质是一个"此刻有效"的句柄。窗口激活、Space 切换、最小化后句柄立即失效,后续对任意属性的读写都会返回 `kAXErrorInvalidUIElement`(-25202)。C API 没有任何内置的 retain-on-copy 机制;Swift 的 ARC 拿到的只是一个外来 `CFTypeRef`,失效判断全靠调用方。

2. **属性名 stringly-typed**:所有属性通过字符串常量访问——`kAXRoleAttribute`、`kAXValueAttribute`、`kAXFocusedAttribute`——拼错不报编译错误,运行期才返回 `kAXErrorAttributeUnsupported`。类型转换需要 `CFTypeRef` → `AnyObject` → 具体类型的一系列强转,任何一步失败都是静默 nil。

3. **超时无内置**:默认 AX messaging timeout 为 6 秒(Apple 内部),不可配置。在 Electron/慢响应应用上,`AXUIElementCopyAttributeValue` 会阻塞当前线程整整 6 秒。分布式通知或 `@MainActor` 上的 AX 调用会让 UI 完全卡住。

4. **app resolving 仅 PID**:AX C API 入口只有 `AXUIElementCreateApplication(pid_t)`,但脚本/agent 场景输入的是名称或 bundle ID,需要通过 `NSWorkspace.runningApplications` 自行转换,还要处理多实例、已终止、helper 进程等边界情况。

### AXorcist 解决了什么

- **类型安全属性**:`Attribute<T>` 泛型包装,`.role`/`.value`/`.title`/`.focused` 等常见属性均预定义,类型错误在编译期发现
- **`Element` 值类型包装**:对底层 `AXUIElementRef` 做 `Sendable` 包装,可在 Swift 6 strict concurrency 下安全传递
- **per-call messaging timeout**:`element.setMessagingTimeout(seconds)` + `windowsWithTimeout(timeout:)` 在单次调用粒度上覆写系统默认超时
- **query DSL**:`role()`/`children()`/`title()`/`windows()` 等方法组合使用,可以声明式描述"找 role=AXTextField 且 title 包含 'Search' 的元素",不需要写 C 函数链

### AXorcist 不解决、需要消费方处理的

- **focus stealing**:AXorcist 提供元素访问能力,但是否激活 app、是否切换 Space、是否使用 background delivery——这些 UX 决策属于消费方的责任(见 `FocusUtilities.swift` 的三层保护策略)
- **元素缓存失效**:AXorcist 没有内置的 element cache 机制。消费方如果把 `Element` 存进成员变量跨操作复用,失效后调用方法会返回 `-25202`。每次操作前重新 query 是消费方约定
- **跨 app 状态协调**:多 app 协作场景(如从 A 复制、激活 B、粘贴)的焦点切换序列和竞态防护,AXorcist 不处理

## 核心模式(Pattern)

### Pattern 1 · 进入 AX 树:AXApp → Element

```swift
// 从 NSRunningApplication 获取 app 根节点
let appElement = AXApp(runningApp).element   // 类型: Element
let windows = appElement.windows()           // [Element]?
let children = someElement.children()        // [Element]?
let role = someElement.role()                // String?  e.g. "AXButton"
let title = someElement.title()              // String?
```

`AXApp` 是进入 AX 树的唯一入口。所有 AX 调用保持在 `@MainActor` 或显式 `DispatchQueue.main` 上——AX 框架的线程要求是在主线程调用。

### Pattern 2 · App Resolving 三态决策树

根据 `WindowManagementService+Resolution.swift:51` 中 `WindowTarget` 枚举和 `ApplicationService+Discovery.swift:108` 中的 `findApplication` 实现,**精确度降序排列**:

```
输入: bundleId / name / pid
         │
         ▼
     PID 直接匹配?─── 是 ──→ NSRunningApplication(processIdentifier:)  ← 最稳定
         │
         否
         │
         ▼
  bundle ID 精确匹配?─── 是 ──→ NSWorkspace.runningApplications.first { $0.bundleIdentifier == id }
         │                           ⚠️ 同一 bundleId 多实例 → 取第一个,不一定是目标
         否
         │
         ▼
  名称模糊匹配(含大小写 + 前缀 + 含子串)
         │
         ▼
  仍未找到 → throw NotFoundError.application(name)
```

**经验法则**:
| 场景 | 推荐 strategy | 原因 |
|------|--------------|------|
| 用户单次操作("打开 Safari 的标签") | `name` 或 `bundleId` | 简单直观 |
| 脚本化、跨步骤复用 | `pid` 或 `CGWindowID` | 窗口存活期内唯一 |
| 多实例 app(多个 Terminal) | `pid` | `bundleId`/name 会命中错误实例 |
| app 重启后 | 重新 resolve | PID 不持久,重启后变化 |

### Pattern 3 · 元素匹配:role + label 打分

`TypeService+TargetResolution.swift` 中 `resolveTargetElement` 的打分策略:identifier 完全匹配 +400,label 完全匹配 +300,value 完全匹配 +200,以此类推。消费方实现类似逻辑时:

```swift
// TypeService+TargetResolution.swift:82 — 递归 role+label 匹配范本
@MainActor
private func searchTextFields(in element: Element, matching query: String) -> Element? {
    let role = element.role()?.lowercased() ?? ""
    if role.contains("textfield") || role.contains("textarea") || role.contains("searchfield") {
        let label = element.label()?.lowercased() ?? ""
        let placeholder = element.placeholderValue()?.lowercased() ?? ""
        if label.contains(query) || placeholder.contains(query) {
            return element  // 用完即丢,不要缓存到成员变量
        }
    }
    return element.children()?.compactMap {
        searchTextFields(in: $0, matching: query)
    }.first
}
```

**不要**依赖固定数组下标或深度路径——AX 树结构随 app 版本可变。

### Pattern 4 · Element 缓存 vs 重新查询

AX element 句柄的有效期仅在"该窗口存在且未发生激活切换"期间。以下事件会使句柄失效:

| 触发事件 | 失效信号 | 处置 |
|---------|---------|------|
| app 激活/切换 | `kAXErrorInvalidUIElement`(-25202) | 重新 `AXApp(runningApp).element` 向下 query |
| Space 切换 | 同上 | 重新 resolve app,重新 query |
| 窗口最小化 | 同上或 `-25201` | 先 restore 窗口,再 query |
| app 重启 | PID 变化 | 重新 resolve app |

**结论**:在同一操作步骤内(如"找到元素 → 立刻 click")可以复用句柄。跨步骤、跨 `await` 点绝对不要复用——每次操作前重新从 `AXApp` 向下 query。

```swift
// 正确:每次操作前 query
func clickSearchButton() async throws {
    let appElement = AXApp(runningApp).element     // 每次重建
    guard let btn = findButton(in: appElement, label: "Search") else {
        throw AXDriverError.elementNotFound
    }
    btn.performAction(.press)                       // 立即使用
}

// 错误:缓存 Element 跨操作复用
var cachedButton: Element?                         // ❌ 会 stale
```

### Pattern 5 · App Resolving 三态实现

```swift
// 三级优先 resolving:pid > bundleId > name
func resolveApp(bundleID: String? = nil, name: String? = nil, pid: pid_t? = nil)
    throws -> NSRunningApplication
{
    // 1. PID 最精确
    if let pid, let app = NSRunningApplication(processIdentifier: pid) {
        return app
    }
    let running = NSWorkspace.shared.runningApplications

    // 2. bundleId 精确匹配(注意多实例取第一个)
    if let bundleID, let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
        return app
    }
    // 3. 名称模糊匹配
    if let name {
        let lower = name.lowercased()
        if let app = running.first(where: { ($0.localizedName ?? "").lowercased() == lower }) {
            return app
        }
        if let app = running.first(where: { ($0.localizedName ?? "").lowercased().contains(lower) }) {
            return app
        }
    }
    throw AXDriverError.appNotFound
}
```

### Pattern 6 · Focus 保护包装

`FocusUtilities.swift:178-207` 的三层保护策略,消费方应照此实现:

```swift
// 操作前快照 frontmostApp,操作后恢复
func withFocusProtection(perform action: () async throws -> Void) async throws {
    // 步骤 1: 记录当前前台 app
    let previousApp = NSWorkspace.shared.frontmostApplication

    do {
        try await action()
    } catch {
        // 恢复焦点后再 rethrow
        previousApp?.activate()
        throw error
    }

    // 步骤 2: 恢复焦点(仅在需要时)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApp?.processIdentifier {
        previousApp?.activate()
    }
}
```

关键:激活目标 app 后,**必须重新 query** element 句柄而不是复用激活前的句柄(`FocusUtilities.swift:201`):

```swift
// ✅ 激活后重新 findWindow
let runningApp = initialHandle.app.application
runningApp.activate()
// 等待 isActive
guard let refreshedHandle = windowIdentityService.findWindow(byID: windowID, in: runningApp) else {
    throw AXDriverError.elementNotFound
}
```

### Pattern 7 · 超时降级路径

```
query timeout? ─── 是 ──→ throw AXDriverError.timeout
                                    │
                                    ▼
                          消费方降级决策:
                          ├── 可以跳过? → log + skip current step
                          ├── 必须成功? → 用户提示 + 等待重试
                          └── Electron 目标? → 见"非原生环境"节
```

`AXTreeCollector.swift:98` 每次递归前检查 `Date() < deadline`。新消费方照此写 deadline guard:

```swift
// 带 deadline 的遍历包装
func queryWithDeadline<T>(
    deadline: Date,
    query: () throws -> T?
) throws -> T {
    guard Date() < deadline else { throw AXDriverError.timeout }
    guard let result = try query() else { throw AXDriverError.elementNotFound }
    return result
}
```

## 完整代码示例(Starter Code)

以下约 250 行可编译的独立 Swift 文件覆盖 AXorcist 消费者的核心用法。它基于 Peekaboo 的实测实现重组,不依赖 Peekaboo 内部模块,只依赖 `AXorcist` submodule + macOS SDK。

**权限要求**:macOS 13+,Accessibility 权限(System Settings → Privacy & Security → Accessibility)。  
**嵌入方式**:将此文件加入 SPM 包的 `Sources/` 目录,在 `Package.swift` 依赖中添加 AXorcist submodule。

```swift
// UIAutomationDriver.swift — Starter Code for Playbook 06
// Compiles on macOS 13+. Requires Accessibility permission.
// Dependencies: AXorcist (submodule), AppKit, ApplicationServices.
//
// MARK: - Usage summary
//   let driver = UIAutomationDriver()
//   let app    = try driver.resolveApp(bundleID: "com.apple.TextEdit")
//   try await driver.withFocusProtection {
//       let field = try driver.query(in: app, role: "AXTextField", label: "Find")
//       try driver.setValue(element: field, value: "hello")
//   }

import AppKit
import ApplicationServices
import AXorcist
import Foundation

// MARK: - Error Types

public enum AXDriverError: Error, Sendable {
    /// No running app matches the given bundleId / name / pid
    case appNotFound
    /// AX tree query returned no element matching the predicate
    case elementNotFound
    /// Query exceeded the deadline
    case timeout
    /// AX action succeeded but element became invalid (stale handle, -25202)
    case staleElement(Int32)
    /// Focus restore failed after the operation
    case focusRestoreFailed
    /// Accessibility permission not granted
    case permissionDenied
}

// MARK: - Element Cache (weak reference)

/// Wrap an AX element with a timestamp so callers can decide when to invalidate.
public struct CachedElement: Sendable {
    public let element: Element
    public let capturedAt: Date

    /// Returns true if the element was captured more than `seconds` ago.
    public func isExpired(after seconds: TimeInterval = 1.0) -> Bool {
        Date().timeIntervalSince(capturedAt) > seconds
    }
}

// MARK: - Main Driver

/// `UIAutomationDriver` is the single entry point for all AX operations.
/// Keep it as an `actor` to protect shared state (cache, frontmost app snapshot).
@MainActor
public final class UIAutomationDriver {

    // Simple in-memory cache: key → cached element.
    // Elements expire after 1 second (configurable); always re-query across await points.
    private var elementCache: [String: CachedElement] = [:]

    public init() {
        precondition(
            AXIsProcessTrusted(),
            "Accessibility permission not granted. Go to System Settings → Privacy & Security → Accessibility."
        )
    }

    // MARK: - App Resolving (three-way priority: pid > bundleId > name)

    /// Resolve a running NSRunningApplication.
    /// Priority: pid (most stable) → bundleId (exact) → name (fuzzy).
    public func resolveApp(
        bundleID: String? = nil,
        name: String? = nil,
        pid: pid_t? = nil
    ) throws -> NSRunningApplication {
        // 1. PID — survives app name/bundleId ambiguity; use for multi-instance apps
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            return app
        }

        let running = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }

        // 2. Bundle ID — exact match, guaranteed unique per app binary
        if let bundleID,
           let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
            return app
        }

        // 3. Name — case-insensitive exact, then contains
        if let name {
            let lower = name.lowercased()
            if let app = running.first(where: {
                ($0.localizedName ?? "").lowercased() == lower
            }) { return app }
            if let app = running.first(where: {
                ($0.localizedName ?? "").lowercased().contains(lower)
            }) { return app }
        }

        throw AXDriverError.appNotFound
    }

    // MARK: - Element Query (with timeout)

    /// Search for an element in `app`'s AX tree matching `role` and optionally `label` / `identifier`.
    /// - Parameter timeout: seconds before throwing `.timeout` (default: 5.0)
    public func query(
        in app: NSRunningApplication,
        role: String,
        label: String? = nil,
        identifier: String? = nil,
        timeout: TimeInterval = 5.0
    ) throws -> Element {
        let deadline = Date().addingTimeInterval(timeout)
        let appElement = AXApp(app).element
        guard let windows = appElement.windows(), !windows.isEmpty else {
            throw AXDriverError.elementNotFound
        }
        for window in windows {
            if let found = searchElement(
                in: window,
                role: role,
                label: label,
                identifier: identifier,
                deadline: deadline)
            {
                return found
            }
        }
        throw AXDriverError.elementNotFound
    }

    /// Recursive AX tree search with deadline guard.
    private func searchElement(
        in element: Element,
        role: String,
        label: String?,
        identifier: String?,
        deadline: Date
    ) -> Element? {
        guard Date() < deadline else { return nil }  // AXTreeCollector.swift:98 pattern

        let elementRole = element.role()?.lowercased() ?? ""
        if elementRole == role.lowercased() {
            var score = 0
            if let label {
                let t = element.title()?.lowercased() ?? ""
                let l = element.label()?.lowercased() ?? ""
                let p = element.placeholderValue()?.lowercased() ?? ""
                let lLow = label.lowercased()
                if t == lLow || l == lLow { score += 300 }
                else if t.contains(lLow) || l.contains(lLow) || p.contains(lLow) { score += 100 }
            }
            if let identifier {
                let id = element.attribute(Attribute<String>("AXIdentifier")) ?? ""
                if id == identifier { score += 400 }
            }
            if label == nil && identifier == nil { score = 1 }
            if score > 0 { return element }
        }

        return element.children()?.compactMap {
            searchElement(in: $0, role: role, label: label, identifier: identifier, deadline: deadline)
        }.first
    }

    // MARK: - Focus Protection

    /// Execute `action` while protecting the user's current frontmost app.
    /// Restores focus to the previously frontmost app after the action completes (or throws).
    public func withFocusProtection(
        perform action: () async throws -> Void
    ) async throws {
        // Snapshot the current frontmost app before any AX operation
        let previousApp = NSWorkspace.shared.frontmostApplication
        var actionError: Error?

        do {
            try await action()
        } catch {
            actionError = error
        }

        // Restore focus if the frontmost app changed
        if let prev = previousApp,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != prev.processIdentifier
        {
            let activated = prev.activate()
            if !activated, actionError == nil {
                throw AXDriverError.focusRestoreFailed
            }
        }

        if let err = actionError { throw err }
    }

    // MARK: - Actions

    /// Tap (AXPress) an element.
    public func tap(element: Element) throws {
        let result = element.performAction(.press)
        guard result == .success else {
            throw AXDriverError.staleElement(result.rawValue)
        }
    }

    /// Write a value to an AX element (works for AXTextField / AXTextArea in native apps).
    /// WARNING: On Electron/Chromium apps, this may return success but have no visible effect.
    /// In that case fall back to CGEvent synthesis (see Playbook 07).
    public func setValue(element: Element, value: String) throws {
        let axErr = element.setAttribute(Attribute<String>.value, value: value)
        guard axErr == .success else {
            // -25204 = sandbox blocked; -25200 = API disabled; -25202 = stale element
            throw AXDriverError.staleElement(axErr.rawValue)
        }
    }

    /// Read the current value of an AX element.
    public func getValue(element: Element) -> String? {
        element.attribute(Attribute<String>.value)
    }

    // MARK: - Element Cache

    /// Store a recently-queried element in the in-process cache.
    public func cache(element: Element, forKey key: String) {
        elementCache[key] = CachedElement(element: element, capturedAt: Date())
    }

    /// Retrieve a cached element if it is not expired.
    /// Always re-query if nil is returned — the element may have gone stale.
    public func cachedElement(forKey key: String, maxAge: TimeInterval = 1.0) -> Element? {
        guard let cached = elementCache[key], !cached.isExpired(after: maxAge) else {
            elementCache.removeValue(forKey: key)
            return nil
        }
        return cached.element
    }

    /// Invalidate the entire cache (call after any app activation or window change).
    public func invalidateCache() {
        elementCache.removeAll()
    }
}

// MARK: - Demo / main

@main
struct Demo {
    static func main() async {
        guard AXIsProcessTrusted() else {
            print("ERROR: Accessibility permission required.")
            print("  System Settings → Privacy & Security → Accessibility → add this app")
            exit(1)
        }

        let driver = await UIAutomationDriver()

        // ---- Resolve app (try bundleId → name → pid) ----
        let app: NSRunningApplication
        do {
            app = try await driver.resolveApp(bundleID: "com.apple.TextEdit")
        } catch {
            print("Could not find TextEdit: \(error)")
            return
        }
        print("Found: \(app.localizedName ?? "?") pid=\(app.processIdentifier)")

        // ---- Focus protection + query + setValue ----
        do {
            try await driver.withFocusProtection {
                // Query a text area; re-query after every await — never cache across steps
                let field = try driver.query(
                    in: app,
                    role: "AXTextArea",
                    timeout: 5.0)

                // Cache for rapid repeated reads within the same step
                driver.cache(element: field, forKey: "mainTextField")

                try driver.setValue(element: field, value: "Hello from UIAutomationDriver")
                print("Set value OK")

                // Read back
                if let current = driver.getValue(element: field) {
                    print("Current value: \(current)")
                }
            }
        } catch AXDriverError.timeout {
            print("Query timed out — is TextEdit open with a document?")
        } catch AXDriverError.elementNotFound {
            print("No AXTextArea found — open a TextEdit document first")
        } catch AXDriverError.staleElement(let code) {
            // -25202: element became invalid mid-operation; re-query and retry
            print("Stale element (AXError \(code)) — invalidating cache and retrying")
            driver.invalidateCache()
        } catch {
            print("Unexpected error: \(error)")
        }
    }
}
```

## 新项目落地步骤(How to apply)

1. **添加 AXorcist submodule**:在项目根目录执行 `git submodule add <AXorcist 仓库 URL> AXorcist`,在 `Package.swift` 中加入 `.package(path: "./AXorcist")` 并在 target 依赖中添加 `.product(name: "AXorcist", package: "AXorcist")`。

2. **权限 preflight**:应用启动时(或第一次执行 AX 操作前)调用 `AXIsProcessTrusted()`。若返回 `false`,弹出引导对话框或 CLI 提示,链接 `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`。不要静默失败——AX 调用在无权限时会成功返回但数据为空,极难排查。

3. **实现 `resolveApp` 包装层**:在业务代码和 AXorcist 之间加一层 `UIAutomationDriver`(参见 Starter Code)。对外暴露 `bundleID`/`name`/`pid` 三态接口,内部按优先级 pid → bundleId → name 查找 `NSRunningApplication`,最终调用 `AXApp(runningApp).element` 进入 AX 树。

4. **注入 timeout 配置**:不要硬编码 timeout 值。定义 `struct AXDriverConfig { var queryTimeout: TimeInterval = 5.0; var elementExpiry: TimeInterval = 1.0 }`,在初始化时注入。对已知慢速目标(Electron、Java 应用)适当加大 queryTimeout(8-10 秒)。

5. **接入 focus 保护**:任何会激活目标 app 的操作都用 `withFocusProtection` 包裹。在操作前快照 `NSWorkspace.shared.frontmostApplication`,操作后如果前台 app 变了则恢复。激活后必须重新 query element 句柄(见 `FocusUtilities.swift:201`)。

6. **错误降级**:区分两类错误并给出对应降级路径:
   - `AXDriverError.elementNotFound`(AX 树中找不到)→ 扩大搜索范围、增大 timeout、触发 web focus fallback
   - `AXDriverError.staleElement(-25202)`(句柄失效)→ `invalidateCache()` + 重新 query
   - `AXDriverError.staleElement(-25204)`(sandbox 阻止)→ 检查 entitlements

7. **log 集成**:在 `AXApp` 初始化和每次 `query` 调用前后加 `os.log` debug 级别日志,记录 app pid、element role、query 耗时。生产代码关闭 verbose,但保留 warning/error 级别的 `-25202`/`-25204` 记录,以便通过 `log stream --predicate` 快速定位问题。

8. **测试时 mock 注入**:定义 `UIAutomationDriving` 协议,生产实现注入 `UIAutomationDriver`,测试中注入记录调用的 `MockUIAutomationDriver`。这样无需真实 Accessibility 权限即可跑单元测试。需要真实 AX 的测试加 `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` 环境变量 gating(见 [12 · 测试策略](./12-testing-permission-gated.md))。

9. **CI 配置 AX 权限**:在 CI runner(macOS Hosted Action 或本地 Mac mini)上,用 `sqlite3 TCC.db "INSERT OR REPLACE INTO access ..."` 预授权,或在 workflow 中用 `sudo` + `tccutil reset Accessibility` + 重新授权脚本。避免在 CI 中跑需要真实 UI 焦点的 AX 测试(用 mock 替代)。

10. **Electron/非原生目标专用适配层**:检测目标 app 的 bundle ID 是否属于已知 Electron 框架,若是则走专用路径:AX `setValue` 优先 → 失败后 AX click-focus + CGEvent `.cghidEventTap` + ≥1 ms 间隔 → 坐标点击兜底。参见"非原生环境"节各目标的详细策略。

## 替代方案对比(When NOT to use)

| 方案 | 优点 | 缺点 | 何时选 |
|------|------|------|--------|
| **AXorcist(本方案)** | Swift-native、query DSL、type-safe attribute、timeout 内置、Sendable 包装 | 需要 AXorcist submodule、macOS 限定、非 MAS 沙盒友好 | 生产代码中的 macOS UI 自动化主路径 |
| **裸 AX C API** | 零依赖、完整控制 | stringly-typed、无超时内置、C 接口繁琐、Swift 6 下类型安全差 | 极简工具或已有庞大 C 代码库的渐进迁移 |
| **XCTest UI Testing (`XCUIApplication`)** | Apple 官方、高级 `XCUIElement.tap()` / `typeText()` | 仅限测试 target、生产代码不可用、每次测试冷起动慢 | Xcode UI 测试、截图对比、交互回归测试 |
| **AppleScript GUI Scripting (`osascript`)** | 语义级操作、无需坐标、人类可读 | 进程间 AppleEvents 慢(10-100 ms/call)、依赖 app 实现 scripting dict、不适合高频 | 一次性脚本、菜单/URL/打印等语义操作 |
| **私有 SkyLight + AX 组合** | 最深入的 window 控制(CGS 私有 API)、background 投递最可靠 | 私有 API、Mac App Store 拒绝、Apple 可能随时移除 | 自用工具/企业内部分发、需要 Space 级别窗口操作 |
| **Chrome DevTools Protocol (CDP)** | 直接操作 DOM、可靠性高、绕过 UI 层 | 需要目标 app 以 `--remote-debugging-port` 启动(生产版通常不开) | 专门针对自有 Electron/Chrome app 的自动化测试 |

**本方案失败时的决策树**:

```
AX query 无结果?
├── 目标是原生 Cocoa app → 检查权限 + 增大 timeout
├── 目标是 Electron/Chrome → 见"非原生环境"节
├── 需要语义操作(菜单/URL) → osascript
└── 所有 AX 方案均失效 → CGEvent 合成(见 07 playbook)
```

## 非原生环境(Non-Native Targets)

### Electron / Chromium 系(VSCode / Discord / Slack / Notion / Figma 桌面)

**架构根因**:Electron 应用由主进程(Node.js)和若干渲染进程(Chromium)组成。AX 树由 Chromium bridge 生成,不是原生 Cocoa 控件的自然 AX 暴露。两个具体问题:

1. **AX 树不完整**:内容区域通常是 `AXWebArea → AXGroup`,部分 input 元素不暴露 `AXValue`,`AXSetValue` 返回 `.success` 但字段内容没有变化。`ElementClassifier.swift:50` 中专门把 `AXGroup`/`AXImage`/`AXCell` 等容器角色加入 `supportedActionLookupRoles`,因为 Chromium/Tauri 会把 clickable 内容藏在这些容器里,需要额外的 `AXPress` 探测。

2. **窗口列表偶发为空**:`ElementDetectionWindowResolver.swift:102` 注释:"Chrome and other multi-process apps occasionally return an empty window list unless we set an explicit AX messaging timeout"——使用 `windowsWithTimeout()` 而非默认 `windows()`。

**症状**:
- `setValue(element:value:)` 返回 success,但用户看到文本框没有变化
- `query(role: "AXTextField")` 返回空或只找到 `AXWebArea`
- `windows()` 返回空数组(Chrome/VSCode 多进程时偶发)

**处置策略(优先级降序)**:

```swift
// 1. 先尝试 AX setValue
do {
    try driver.setValue(element: inputElement, value: text)
    // 验证:读回 value,确认变化
    if driver.getValue(element: inputElement) == text { return }
    // 字段没变 → 降级
} catch { }

// 2. AX click-focus + cghidEventTap + ≥1 ms 间隔(见 Playbook 07)
AXUIElementPerformAction(inputElement.axElement, kAXPressAction as CFString)
Thread.sleep(forTimeInterval: 0.05)  // 等 Electron IPC 完成聚焦
// 然后走 CGEvent Unicode path,每字符间隔 ≥1 ms

// 3. 坐标点击聚焦 + cghidEventTap(最脆弱,依赖坐标稳定性)
```

**检测 Electron 目标**:

```bash
# 查看 Frameworks 目录确认是否为 Electron app
ls "/Applications/Visual Studio Code.app/Contents/Frameworks/" | grep -i electron
# → 存在 Electron Framework.framework

# 或检查 Info.plist 的 NSPrincipalClass
defaults read "/Applications/Slack.app/Contents/Info.plist" NSPrincipalClass
# → AtomApplication (Slack Electron)
```

**Peekaboo 实证**:
- `ElementClassifier.swift:50`:Chromium/Tauri 容器角色需要 AXPress 探测
- `ElementDetectionWindowResolver.swift:102`:Chrome 多进程空窗口列表 → 用 `windowsWithTimeout()`
- `ElementDetectionService.swift:215`:第一遍稀疏 → web focus fallback
- `DialogService+Resolution.swift:132`:Electron/Tauri 限制到 `focusedWindow`/`mainWindow` 防止无边界遍历

### Web 浏览器(Chrome / Safari / Edge / Arc 的页面内)

**架构根因**:浏览器将 web content 的 AX 树通过桥接层暴露出来,但覆盖不完整。Chrome 的暴露质量相对较好,Safari 有时只暴露 `AXWebArea` 而缺少内部 input 节点。

**症状**:
- AX query 找到 `AXWebArea` 或 `AXGroup`,而非 `AXTextField`
- 部分页面在 Accessibility Inspector 里完全是空树
- Safari 的特定页面不暴露 AX 细节

**处置**:

```bash
# 1. 确认 Chrome 已开启 AX 暴露
open -a "Google Chrome" --args --force-renderer-accessibility
# 或在已运行的 Chrome 中:
defaults write com.google.Chrome AXEnabled -bool true

# 2. 检查 AX 树
# 打开 Accessibility Inspector → 选择 Chrome → 浏览 AX 树
open /Applications/Xcode.app/Contents/Applications/Accessibility\ Inspector.app

# 3. Chrome 浏览器内 AX 诊断
# 在 Chrome 地址栏输入:
# chrome://accessibility
# 可以看到每个 tab 的 AX 树暴露状态并强制开启

# Safari:偏好 → 高级 → 辅助功能 → 勾选"允许辅助功能设备控制您的电脑"
```

**AX 找到 `AXWebArea` 后的操作**:

```swift
// 在 AXWebArea 下找 AXTextField
if let webArea = findElement(role: "AXWebArea", in: windowElement),
   let inputField = findElement(role: "AXTextField", in: webArea)
{
    // 读取 AXFocused 状态
    let isFocused = inputField.attribute(Attribute<Bool>("AXFocused")) ?? false
    if !isFocused {
        inputField.performAction(.press)  // 聚焦
        Thread.sleep(forTimeInterval: 0.05)
    }
    try driver.setValue(element: inputField, value: text)
}
```

**跨浏览器差异**:

| 浏览器 | AX 暴露质量 | 建议 |
|--------|------------|------|
| Chrome | 较好,可配置 `--force-renderer-accessibility` | 首选 AX setValue |
| Safari | 自动暴露,但 WebKit 版本依赖 | 先 Accessibility Inspector 验证 |
| Edge | 同 Chrome(Chromium 内核) | 同 Chrome 策略 |
| Arc | Chromium 内核,AX 暴露同 Chrome | 同 Chrome 策略 |

### 终端 Emulator(Terminal.app / iTerm2 / Alacritty / WezTerm / kitty / Ghostty)

**架构根因**:终端 emulator 不是普通的 Cocoa 控件,内容是 PTY(pseudoterminal)缓冲区。`AXTextArea` 只能**读** PTY buffer,不能通过 AX API 可靠地写入——因为终端的"输入"是 PTY write,不是 UI 控件的 value 变更。

**症状**:
- `setValue(element:value:)` 在终端 AXTextArea 上执行后没有字符出现在 shell
- `AXValue` 可读(读到当前屏幕内容),但 `AXSetValue` 不起作用或被拒绝
- 某些 emulator(`kitty`、`Alacritty`)AX 树为空——它们使用 GPU 渲染,完全不实现 AX

**处置**:

```swift
// 正确方式:CGEvent Unicode path + 确保终端在前台
// Terminal.app 和 iTerm2 响应 CGEvent 键盘输入

// 步骤 1: 激活目标终端窗口
targetTerminalApp.activate()
Thread.sleep(forTimeInterval: 0.1)

// 步骤 2: 使用 CGEvent 合成(Playbook 07)
let driver = HumanInputDriver()  // 见 Playbook 07 Starter Code
try await driver.type("echo hello\n", cadence: .fixed(milliseconds: 20))

// 注意 option-as-meta:iTerm2 默认把 Option 键作为 Meta
// 若需要 Alt+字母,用 Unicode path + option flag:
// event.flags = .maskAlternate
```

**emulator AX 支持矩阵**:

| Emulator | AX 树 | 读 buffer | 写输入 |
|----------|-------|----------|--------|
| Terminal.app | 有,`AXTextArea` | 可读 | 不可靠,用 CGEvent |
| iTerm2 | 有,较完整 | 可读 | 不可靠,用 CGEvent |
| Alacritty | 无(GPU 渲染) | 不支持 | 只能 CGEvent |
| WezTerm | 部分 | 有限 | 用 CGEvent |
| kitty | 无(GPU 渲染) | 不支持 | 只能 CGEvent |
| Ghostty | 部分(macOS native renderer) | 有限 | 优先 CGEvent |

**osascript 替代**:对 Terminal.app 和 iTerm2,可用 AppleScript 执行命令:

```bash
osascript -e 'tell application "Terminal" to do script "echo hello" in window 1'
osascript -e 'tell application "iTerm2" to tell current session of current window to write text "echo hello"'
```

### Tauri(Rust)/ Java Swing / Qt

**Tauri (Rust)**:AX 树接近 web 浏览器——Tauri 的前端是 WebKit WebView,后端是 Rust。内容区域暴露 `AXWebArea`,策略同 Safari/Chrome 的 web 内容。`DialogService+Resolution.swift:132` 中 Tauri 被明确列为需要限制子树搜索范围的目标。

```swift
// Tauri app 的 dialog 查找:限制到 focusedWindow/mainWindow,不全树遍历
// 对应 DialogService+Resolution.swift:132
let candidates: [Element] = [
    app.focusedWindow(),
    app.mainWindow(),
].compactMap(\.self)
```

**Java Swing**:通过 Java AccessibilityBridge 暴露 AX。需要在 JVM 启动参数中启用:

```bash
java -Dapple.awt.application.appearance=NSAppearanceNameAqua \
     -Djavax.accessibility.assistive_technologies=\
       com.apple.java.accessibility.AccessibilityBridge \
     -jar MyApp.jar
```

Bridge 暴露质量依赖 Swing 控件类型;`JTextField` 通常暴露为 `AXTextField` 可写,但复杂自定义控件可能不暴露。

**Qt**:macOS 下的 AX 支持弱于 Windows;Qt 的 `QAccessible` bridge 覆盖基本控件但自定义 widget 通常缺少 AX 暴露。建议用 Qt Test 框架做内部集成测试,外部自动化场景优先用坐标点击 + CGEvent。

## 调试与取证(Debug & Forensics)

### 常用工具

```bash
# 1. Accessibility Inspector — 实时查看 AX 树
open /Applications/Xcode.app/Contents/Applications/Accessibility\ Inspector.app
# 点击目标 app 窗口:可看到 role、title、value、AXIdentifier、是否 AXFocused、可用 actions

# 2. log stream — 实时 AX 事件流
log stream --predicate 'subsystem CONTAINS "accessibility"' --info
log stream --predicate 'subsystem CONTAINS "com.apple.AppKit" AND category == "Accessibility"' --level debug

# 3. AX 权限验证(Swift one-liner)
swift -e 'import ApplicationServices; print("AX trusted:", AXIsProcessTrusted())'

# 4. 检查进程的 AX attribute 名称(osascript)
osascript -e 'tell application "System Events" to get attribute names of process "TextEdit"'

# 5. Chrome 内置 AX 诊断
# 在 Chrome 地址栏: chrome://accessibility
# 可以看到 AX 树并强制开启每个 tab 的 accessibility

# 6. Safari Web Inspector → Accessibility tab
# Safari → 偏好 → 高级 → 勾选"在菜单栏中显示开发者菜单" → 开发 → Web Inspector

# 7. 检查进程树(Electron 主进程/渲染进程分离)
pstree -p $(pgrep -f "Electron")
ps aux | grep -i "vscode\|electron" | grep -v grep

# 8. lldb 单点调试 AX 调用
# 附加到目标进程后:
# (lldb) expression (int)AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &result)
# (lldb) po result
```

### 症状排查映射表

| 症状 | 诊断命令 | 根因 | 处置 |
|------|---------|------|------|
| `kAXErrorInvalidUIElement`(-25202) | Accessibility Inspector 刷新树 | 窗口切换/激活后 element 句柄失效 | `invalidateCache()` + 重新 query |
| query 永远 timeout | `log stream` 看 AX 消息 | 主线程阻塞 / app 无响应 / 权限缺 | 检查 `AXIsProcessTrusted()`;对 Electron 用 `windowsWithTimeout()` |
| Electron 字段 setValue 无效 | Accessibility Inspector 看 AXValue 是否 settable | Chromium AX bridge 不暴露可写属性 | 降级到 AX click-focus + CGEvent(见 Playbook 07) |
| 焦点被偷走 | `log NSWorkspace.shared.frontmostApplication` 前后值 | 操作中没有 focus protection | 用 `withFocusProtection` 包裹 |
| 多窗口 app resolving 选错 | `peekaboo list apps` 或 `ps aux` 看 pid | bundleId/name 不唯一 | 改用 pid 精确定位 |
| `windows()` 返回空 | Accessibility Inspector 看 AX 树 | Chrome/Electron 多进程默认超时返回空 | 换用 `windowsWithTimeout()` |
| `-25204` sandbox error | `codesign -dv --entitlements :- <app>` | 沙盒 app 的 AX 权限受限 | 检查 entitlements;App Sandbox + AX 需要 `com.apple.security.automation.apple-events` |
| 终端 setValue 无效 | Accessibility Inspector 看 AXRole | 终端是 PTY,不是 AX 控件 | 改用 CGEvent 键盘合成(见 Playbook 07) |

### 关键 log 过滤词

```bash
# AXorcist 专属日志(Peekaboo 使用 subsystem "boo.peekaboo.core")
log stream --predicate 'subsystem CONTAINS "boo.peekaboo" AND category == "AXTreeCollector"' --info

# macOS AX framework 内部
log stream --predicate 'subsystem == "com.apple.accessibility.AX" OR subsystem CONTAINS "accessibility"' --level debug

# 权限相关
log stream --predicate 'subsystem CONTAINS "TCC"' --info
```

## 常见陷阱(Pitfalls)

- **缓存 AX Element 引用后再操作 — 可观测信号:`kAXErrorInvalidUIElement`(-25202)**。AX element 句柄在窗口激活、切 Space、最小化后会立即失效。`FocusUtilities.swift:178` 注释明确写道"AX handles can go stale after activation",并在第 201 行重新 query 了 refreshedHandle。处理方式:将 `Element` 视为一次性句柄,每次操作前重新从 `AXApp` 向下 query,不要跨 `await` 点复用。

- **不设 deadline/timeout 导致主线程卡死 — 可观测信号:UI 彩虹转圈 / 进程 spin**。Electron 等应用的 AX 响应极慢,`children()` 可能阻塞数秒。`AXTreeCollector.swift:98` 每次递归前检查 `Date() < deadline`。处理方式:所有 AX 查询包裹在带 deadline 的循环里,超时后抛出 error 而非无限等待。

- **多实例 app 用 name/bundleId resolving 选错进程 — 可观测信号:操作发生在错误的 app 窗口上**。`--app Terminal` 在两个 Terminal 进程同时运行时会命中第一个。`docs/application-resolving.md` 建议"Use PIDs for precision"。处理方式:多实例场景改用 pid 精确定位。

- **直接 activate 抢夺焦点破坏用户工作流 — 可观测信号:用户报"操作后我的窗口被切走了"**。`docs/focus.md` 提供了 `--focus-background` 选项(通过 process-targeted event 投递而非激活 app)。处理方式:后台操作优先使用 background delivery,仅需要前台 focus 时才走完整 activate 流程。

- **Electron AX 树误信(命令成功但用户看不到变化) — 可观测信号:`setValue` 返回 `.success` 但字段没变**。Chromium AX bridge 对部分控件的 `AXSetValue` 总是报告成功但实际上是只读的。处理方式:操作后立即 `getValue` 读回并对比,不一致则降级到 CGEvent 路径(见 Playbook 07)。`ElementClassifier.swift:50` 的注释是诊断起点。

- **沙盒 app AX 限制 — 可观测信号:`AXError -25204`**。沙盒 app 操作其它 app 的 AX 树时会遇到 `-25204 kAXErrorCannotComplete`。处理方式:检查 entitlements 是否包含 `com.apple.security.automation.apple-events`;开发期可关闭 sandbox(仅限内部工具)。

## 延伸阅读

- Peekaboo:`docs/focus.md`、`docs/application-resolving.md`、`docs/automation.md`、`AXorcist/` submodule
- Apple:[Accessibility for Developers](https://developer.apple.com/accessibility/)、[AXUIElement Reference](https://developer.apple.com/documentation/applicationservices/axuielement_h)、[Accessibility Programming Guide](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/)
- Chrome 内置诊断:`chrome://accessibility`(在 Chrome 地址栏打开)
- WebKit Accessibility:[WebKit Accessibility Overview](https://webkit.org/blog/3302/aria-and-accessibility-inspector/)
- 其它 playbook:[05 · 权限三态状态机](./05-permissions-state-machine.md)、[07 · CGEvent 拟真输入](./07-cgevent-input-synthesis.md)、[10 · Visualizer 屏上 overlay](./10-visualizer-overlay.md)

---
*Last verified against Peekaboo @ `b8c6c48bc7e788949421b8aa48655bcbb491b348`*
