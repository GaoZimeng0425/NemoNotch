---
summary: 'Structure a macOS app into unidirectional SPM layers (Foundation → Protocols → Domain → Apps) with submodule criteria for shared libraries, starter Package.swift, and debug forensics for cyclic deps and cache drift.'
read_when:
  - 'starting a new macOS app and setting up SwiftPM module boundaries'
  - 'evaluating whether to split code into a git submodule'
---

# 01 · 模块划分与依赖方向

## TL;DR

把 macOS 应用拆成单向层次模块:Foundation(零依赖基础类型)→ Protocols(接口层,只依赖 Foundation)→ 功能实现模块(Visualizer / AutomationKit,依赖 Protocols + ExternalDependencies)→ PeekabooCore(组装层,唯一允许横跨多层的汇聚点)→ Apps(消费层,只 import Core)。每层只能向下依赖,SPM 的编译隔离会把一次改动的重编文件数从 700+ 降到几十个,增量构建从 43 秒降至 5 秒以内。把可独立发布、有外部消费者的第三方库切成 git submodule(AXorcist、Tachikoma 等);其余实现模块以 `path:` 方式留在主仓库 `Core/` 目录。CLI / Mac.app / PeekabooInspector 三态共用同一套 Core 库,通过 `PeekabooProtocols` 的协议边界而非具体类型对接。本篇新增完整 `Package.swift` 骨架(~200 行),可直接拷入新项目作为起点,同时补充 SPM cache 清理、循环依赖检测、模块边界违反检测等调试命令。

## Peekaboo 在哪里实现

- 模块:`Core/PeekabooFoundation`、`Core/PeekabooProtocols`、`Core/PeekabooAutomationKit`、`Core/PeekabooVisualizer`、`Core/PeekabooExternalDependencies`、`Core/PeekabooCore`、`Apps/CLI`
- 关键文件:`Core/PeekabooFoundation/Package.swift:25` — Package 级别 `dependencies: []`;target 级别同样 `dependencies: []` 在第 29 行——两处均为零依赖声明,是整个依赖图的绝对底层
- 关键文件:`Core/PeekabooCore/Package.swift:44-50` — PeekabooCore 同时以 `path:` 方式引用 `../PeekabooAutomationKit`、`../PeekabooFoundation`、`../PeekabooProtocols`、`../PeekabooExternalDependencies`、`../PeekabooVisualizer`、`../../Tachikoma`,是唯一允许横跨多层的"组装点"
- 关键文件:`Core/PeekabooExternalDependencies/Package.swift:22-46` — 把 AXorcist、AsyncAlgorithms、Algorithms、Commander、Logging、SystemPackage、OrderedCollections 全部聚合到单一 target,统一 re-export
- 关键文件:`Core/PeekabooProtocols/Package.swift:30-31` — Protocols 层 `dependencies: [.package(path: "../PeekabooFoundation")]`,只向下依赖 Foundation,不引任何平台框架
- 关键文件:`Apps/CLI/Package.swift:34` — CLI target 的 `dependencies` 声明 `PeekabooCore`,消费层通过 Core 统一入口获取所有能力
- 相关 docs:`docs/module-architecture-refactoring.md`、`docs/swift-module-plan.md`、`docs/ARCHITECTURE.md`

## 设计动机(Why)

### 问题:上帝模块引发的雪崩重编

Peekaboo 的初始架构是一个"上帝模块":**727 个 Swift 文件**,其中 132 个塞进 `PeekabooCore`,任意一个文件改动都触发 **700+ 文件重编(占全仓 96%)**,增量构建耗时 **43 秒**(见 `docs/module-architecture-refactoring.md:13-21`)。

根因是三个结构性问题:

1. **无接口边界**:具体类型直接跨层引用,叶子改动"传染"到所有依赖方
2. **循环依赖**:`PeekabooCore → Tachikoma → TachikomaMCP → 回调 PeekabooCore 的类型`,SPM 直接报错(`docs/module-architecture-refactoring.md:20`)
3. **第三方依赖散落**:AXorcist、Commander、swift-log 等分布在各个模块的 `Package.swift` 里,版本升级需要逐一追查

### 为什么不放进一个大 Package(monorepo single target)

单一 Package 内多 target 方案看起来最简单,但 target 间依赖管理弱:SPM 不阻止你在 target A 内直接 import target B 的内部类型(只要都在同一 Package),循环引用的报错会更晚、更难定位。更严重的是无法独立运行 `swift build --target X` 来验证某层的编译边界——单 Package 内任意 target 的改动都会触发整个 Package 的类型检查。

### 为什么不分到独立的 git repo(切 submodule 的临界点)

切 git submodule 的成本是:**每次跨 repo 改动需要先 push 子仓库再 bump 主仓库 gitlink**,否则会出现 gitlink 漂移——本地和 CI 拉到的版本不一致。Peekaboo 经验:AXorcist 满足三个条件后才切成 submodule:① 有外部消费者(其他项目在用);② 能独立 release(有自己的语义版本 tag);③ 单一职责,不依赖主仓库私有 API。不满足这三条的模块留在 `Core/` 以 `path:` 引用,改动简单,不需要 ping-pong 式提交。

### 切错的成本

过早把还在演进的模块切成 submodule,会导致:
- 每次改 API 需要在两个仓库之间反复提交(ping-pong),PR review 散乱
- gitlink 漂移导致 CI 失败:主仓库 gitlink 指向的 SHA 与本地开发用的不一致
- 循环依赖检测延迟:split repo 后 SPM 在本地 resolve 时才报错,而不是编译时

## 核心模式(Pattern)

### 依赖方向图(含 Peekaboo 实际模块名)

```
┌──────────────────────────────────────────────────────────────────────┐
│  Apps 层                                                              │
│  peekaboo(CLI)    Peekaboo.app    PeekabooInspector                  │
│  Apps/CLI         Apps/Mac        Apps/PeekabooInspector             │
└────────────────────────────┬─────────────────────────────────────────┘
                             │ 只能向下依赖(只 import PeekabooCore)
┌────────────────────────────▼─────────────────────────────────────────┐
│  组装层   Core/PeekabooCore                                           │
│    PeekabooCore(umbrella) / PeekabooAutomation / PeekabooAgentRuntime│
│    @_exported import 重导出所有子模块 → 提供单一入口                   │
└───────────┬─────────────────────┬─────────────────────┬──────────────┘
            │                     │                     │
┌───────────▼──────┐  ┌───────────▼──────────┐  ┌──────▼──────────────┐
│Core/PeekabooVisu-│  │Core/PeekabooAutomation│  │Core/PeekabooExternal│
│  alizer          │  │  Kit                 │  │  Dependencies       │
│  (视觉反馈层)    │  │  (AX 自动化低层实现)  │  │  (第三方依赖聚合)   │
└───────────┬──────┘  └───────────┬──────────┘  │  AXorcist / async-  │
            │                     │             │  algorithms /       │
            └──────────┬──────────┘             │  Commander /        │
                       │                        │  swift-log …        │
                       │                        └─────────────────────┘
┌──────────────────────▼───────────────────────────────────────────────┐
│  接口层   Core/PeekabooProtocols                                      │
│  ApplicationServiceProtocol / ClickServiceProtocol                   │
│  AgentServiceProtocol / PermissionsServiceProtocol …                 │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │
┌──────────────────────────────────▼───────────────────────────────────┐
│  基础层   Core/PeekabooFoundation   (dependencies: [])               │
│  BasicTypes / ErrorTypes / PeekabooError / ElementType / ClickType … │
└──────────────────────────────────────────────────────────────────────┘

  ─────────────────── git submodules (独立仓库) ───────────────────────
  AXorcist · Tachikoma · Commander · TauTUI · Swiftdansi
  (独立仓库独立演进,主仓库只锁 gitlink SHA;见 .gitmodules)
```

### `path:` 字段引用 Core 子目录的写法

在 `Core/PeekabooCore/Package.swift` 中用相对路径引用同级目录:

```swift
// Core/PeekabooCore/Package.swift:44-50
dependencies: [
    .package(path: "../PeekabooAutomationKit"),   // 兄弟目录
    .package(path: "../PeekabooFoundation"),
    .package(path: "../PeekabooProtocols"),
    .package(path: "../PeekabooExternalDependencies"),
    .package(path: "../PeekabooVisualizer"),
    .package(path: "../../Tachikoma"),            // submodule 在仓库根
]
```

在 `Apps/CLI/Package.swift` 中:

```swift
// Apps/CLI/Package.swift:120-122
dependencies: [
    .package(path: "../../Core/PeekabooFoundation"),
    .package(path: "../../Core/PeekabooVisualizer"),
    .package(path: "../../Core/PeekabooCore"),
    // …
]
```

### `@_exported import` 重导出的使用场景

PeekabooCore 作为 umbrella 模块,用 `@_exported` 让消费方只写一行 import:

```swift
// Core/PeekabooCore/Sources/PeekabooCore/PeekabooCore.swift
@_exported import PeekabooAutomation
@_exported import PeekabooAgentRuntime
@_exported import PeekabooFoundation
@_exported import PeekabooProtocols
```

**注意**:`@_exported` 是 Swift 私有 SPI,有两个副作用:① 消费方能看到所有重导出模块的 `public` 符号,包括你不想暴露的实现细节;② 如果滥用在实现层(非 umbrella),会导致调用方隐式依赖不该依赖的模块,让边界检查失效。**只在 umbrella 组装层使用**,实现模块之间不得互相 `@_exported`。

### target conditioning — `.when(platforms:)` 与 debug/release 差异

```swift
// PeekabooProtocols/Package.swift:12-17
let protocolTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=50",
        "-Xfrontend", "-warn-long-expression-type-checking=50",
    ], .when(configuration: .debug)),   // 只在 debug build 开启编译耗时警告
]
```

macOS-only 能力(如 AppKit)用平台条件:

```swift
swiftSettings: [
    .define("PEEKABOO_MACOS", .when(platforms: [.macOS])),
]
```

### 协议注入示例(正确的依赖反转)

```swift
// Core/PeekabooProtocols — 只声明协议,不依赖任何实现
// ServiceProtocols.swift:14
public protocol ApplicationServiceProtocol: Sendable {
    func listApplications() async throws -> [String]
    func focusApplication(name: String) async throws
    // ...
}

// Core/PeekabooAutomationKit — 依赖协议实现具体逻辑
public final class ApplicationService: ApplicationServiceProtocol {
    public func listApplications() async throws -> [String] { /* impl */ }
}

// 错误:AutomationKit 直接引用 Visualizer 具体类型
// 正确:构造时注入遵守协议的实例
public final class AutomationRunner {
    private let feedback: VisualizerProtocol
    public init(feedback: VisualizerProtocol) { self.feedback = feedback }
}
```

## 完整代码示例(Starter Code)

以下是可直接拷入新 macOS 项目的完整 `Package.swift` 骨架,展示四层分离 + Swift 6 严格模式。同时附最小可运行的 Protocols 协议文件和 AutomationKit 实现文件,验证依赖反转能正确编译。

### 项目布局

```
MyApp/
├── Package.swift                          ← 此文件(主入口)
├── Core/
│   ├── MyFoundation/Sources/MyFoundation/
│   │   └── BasicTypes.swift
│   ├── MyProtocols/Sources/MyProtocols/
│   │   └── ServiceProtocols.swift
│   ├── MyAutomationKit/Sources/MyAutomationKit/
│   │   └── FooImpl.swift
│   └── MyApp/Sources/MyApp/             ← 组装层(umbrella)
│       └── MyAppUmbrella.swift
└── Apps/
    └── CLI/Sources/CLI/
        └── main.swift
```

### Package.swift — 主入口(根 Package,扁平多 target 方式)

```swift
// Package.swift — MyApp starter, Swift 6 strict mode
// swift-tools-version: 6.2
import PackageDescription

// ─────────────────────────────────────────────────────
// MARK: - Shared Swift Settings
// ─────────────────────────────────────────────────────

/// 底层模块使用:无 isolation,允许并发最大化
let foundationSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

/// 接口层使用:MainActor default isolation,使协议方法对 UI 调用友好
let protocolSettings: [SwiftSetting] = foundationSettings + [
    .defaultIsolation(MainActor.self),
    // 开发期间开启编译耗时警告,避免"胖"类型推断拖慢增量构建
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=50",
        "-Xfrontend", "-warn-long-expression-type-checking=50",
    ], .when(configuration: .debug)),
]

/// 实现层使用:无 global isolation,保留细粒度 actor 控制
let kitSettings: [SwiftSetting] = foundationSettings + [
    .enableExperimentalFeature("SwiftTesting"),   // 支持 Swift Testing 宏
]

/// 组装层 & Apps 层
let coreSettings: [SwiftSetting] = foundationSettings

// ─────────────────────────────────────────────────────
// MARK: - Package
// ─────────────────────────────────────────────────────

let package = Package(
    name: "MyApp",
    platforms: [
        .macOS(.v14),
    ],
    // Products: 对外暴露的 library/executable
    products: [
        .library(name: "MyFoundation",    targets: ["MyFoundation"]),
        .library(name: "MyProtocols",     targets: ["MyProtocols"]),
        .library(name: "MyAutomationKit", targets: ["MyAutomationKit"]),
        .library(name: "MyAppCore",       targets: ["MyAppCore"]),
        .executable(name: "my-cli",       targets: ["MyCLI"]),
    ],
    // 外部依赖集中声明(对应 PeekabooExternalDependencies 思路)
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.6.4"),
        // 将来需要 AXorcist 时取消注释:
        // .package(url: "https://github.com/steipete/AXorcist.git", exact: "0.1.2"),
    ],
    targets: [

        // ── Layer 1: Foundation ────────────────────────
        // 零外部依赖.放入所有稳定基础类型、枚举、DTO、Error 层次
        .target(
            name: "MyFoundation",
            dependencies: [],
            path: "Core/MyFoundation/Sources/MyFoundation",
            swiftSettings: foundationSettings
        ),
        .testTarget(
            name: "MyFoundationTests",
            dependencies: ["MyFoundation"],
            path: "Core/MyFoundation/Tests/MyFoundationTests",
            swiftSettings: foundationSettings
        ),

        // ── Layer 2: Protocols ─────────────────────────
        // 只依赖 Foundation;暴露所有服务协议;不引入 AppKit 等平台框架
        .target(
            name: "MyProtocols",
            dependencies: ["MyFoundation"],
            path: "Core/MyProtocols/Sources/MyProtocols",
            swiftSettings: protocolSettings
        ),
        .testTarget(
            name: "MyProtocolsTests",
            dependencies: ["MyProtocols"],
            path: "Core/MyProtocols/Tests/MyProtocolsTests",
            swiftSettings: protocolSettings
        ),

        // ── Layer 3: Implementation ────────────────────
        // 依赖 Foundation + Protocols + 外部依赖
        // 同层模块(AutomationKit / Visualizer)不互相依赖
        .target(
            name: "MyAutomationKit",
            dependencies: [
                "MyFoundation",
                "MyProtocols",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Core/MyAutomationKit/Sources/MyAutomationKit",
            swiftSettings: kitSettings
        ),
        .testTarget(
            name: "MyAutomationKitTests",
            dependencies: ["MyAutomationKit"],
            path: "Core/MyAutomationKit/Tests/MyAutomationKitTests",
            swiftSettings: kitSettings
        ),

        // ── Layer 4a: Core (umbrella / assembly) ───────
        // 唯一允许横跨多层的汇聚点;用 @_exported 提供单一 import 入口
        .target(
            name: "MyAppCore",
            dependencies: [
                "MyFoundation",
                "MyProtocols",
                "MyAutomationKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Core/MyApp/Sources/MyApp",
            swiftSettings: coreSettings
        ),

        // ── Layer 4b: Apps (CLI executable) ────────────
        // 只 import MyAppCore;通过协议消费实现,不直接引用底层具体类型
        .executableTarget(
            name: "MyCLI",
            dependencies: ["MyAppCore"],
            path: "Apps/CLI/Sources/CLI",
            swiftSettings: coreSettings
        ),
    ],
    // Swift 6 strict language mode — 全局开启
    swiftLanguageModes: [.v6]
)
```

### 协议层最小示例

```swift
// Core/MyProtocols/Sources/MyProtocols/ServiceProtocols.swift
import Foundation
import MyFoundation

// 只声明协议,不引入任何实现、不导入 AppKit
public protocol FooServiceProtocol: Sendable {
    func doFoo(input: String) async throws -> String
}
```

### 实现层最小示例

```swift
// Core/MyAutomationKit/Sources/MyAutomationKit/FooImpl.swift
import Foundation
import Logging
import MyFoundation
import MyProtocols

// 实现具体服务;依赖注入协议而非具体类型
public final class FooService: FooServiceProtocol, @unchecked Sendable {
    private let logger = Logger(label: "com.myapp.foo")

    public init() {}

    public func doFoo(input: String) async throws -> String {
        logger.debug("doFoo called", metadata: ["input": .string(input)])
        return "result: \(input)"
    }
}
```

### 组装层 umbrella

```swift
// Core/MyApp/Sources/MyApp/MyAppUmbrella.swift
// @_exported 使 Apps 层只需 import MyAppCore 即可获得所有公共符号
@_exported import MyFoundation
@_exported import MyProtocols
@_exported import MyAutomationKit
```

### App 层通过协议消费实现(依赖反转)

```swift
// Apps/CLI/Sources/CLI/main.swift
import MyAppCore   // 一行 import 获得所有层

// App 层只知道协议,不知道 FooService 具体实现
struct App {
    let fooService: any FooServiceProtocol

    func run() async throws {
        let result = try await fooService.doFoo(input: "hello")
        print(result)
    }
}

// 组装点:在入口处注入具体实现
let app = App(fooService: FooService())
try await app.run()
```

### 验证编译

```bash
# 在项目根目录初始化并验证 Package.swift 语法
swift package describe

# 独立验证各层边界
swift build --target MyFoundation
swift build --target MyProtocols
swift build --target MyAutomationKit
swift build --target MyAppCore
swift build --target MyCLI

# 确认无循环依赖
swift package show-dependencies
```

## 新项目落地步骤(How to apply)

1. **建 Foundation 模块**:创建 `Core/YourFoundation/Package.swift`,`dependencies: []`,放入最稳定的基础类型(枚举、DTO、错误层次)。在模块目录内单独 `swift build` 确认零依赖通过。

2. **建 Protocols 模块**:创建 `Core/YourProtocols/Package.swift`,只依赖 Foundation;把所有服务接口定义为 `public protocol`,不引入任何 AppKit / ScreenCaptureKit 等平台框架。验证:`swift build --target YourProtocols`。

3. **建 ExternalDependencies 聚合模块**(可选,多第三方依赖时强烈推荐):创建 `Core/YourExternalDependencies/Package.swift`,把所有第三方包集中在此,用 `@_exported import` 统一暴露。其他模块只依赖这一个 target 即可获得所有第三方符号。版本升级只改这一个文件。

4. **按功能域拆分实现模块**(Visualizer、AutomationKit 等):判定边界的原则是"能否在不修改其他模块的情况下独立替换这个模块"——能则说明边界清晰。每个模块只依赖 Foundation + Protocols + ExternalDependencies;**同一层的模块之间不互相依赖**,用构造函数注入协议代替直接引用具体类型。

5. **建组装层 Core**:在 `Core/YourCore/Package.swift` 中汇聚所有实现模块,用 `@_exported import` 提供单一入口。Core 是唯一允许同时引用多个实现模块的地方。Apps 层只 `import YourCore`。

6. **收拢 Apps 层依赖到 Core**:CLI、Mac.app、扩展等各自的 `Package.swift` 只依赖 YourCore(和可能的 UI-only 依赖如 TauTUI)。通过协议接口使用 Core 提供的能力,不直接引用底层具体类型。

7. **建立 Xcode workspace**:若有 `.xcodeproj`(如 Mac.app),创建 `Apps/Workspace.xcworkspace`,同时引用 xcodeproj 和根 Package.swift,使 Xcode 能同时解析 SPM 包和 Xcode 工程目标。

8. **评估 submodule 切割条件**:满足以下**全部**条件才切 git submodule:① 能独立 release(有自己的语义版本);② 其他项目也可能用到它;③ 单一职责,不依赖主仓库私有 API。否则保持在 `Core/` 目录内。Peekaboo 示例:AXorcist 满足三条,切为 submodule;PeekabooVisualizer 只供 Peekaboo 内部使用,用 `path:`。

9. **配置 CI 独立层验证**:在 CI pipeline 中逐层运行 `swift build --target Layer`,确保各层的编译边界在 CI 中有守护,而不只是本地手工验证。

10. **设立模块边界 SwiftLint 规则**:在 `.swiftlint.yml` 中配置自定义规则,禁止 Apps 层文件直接 `import` 底层实现模块(如 `import PeekabooAutomationKit`)而非通过 `PeekabooCore`。这样边界违反在 `pnpm run lint` 时立即暴露,而不是等到 review 才发现。

## 替代方案对比

| 方案 | 优点 | 缺点 | 何时选 |
|------|------|------|--------|
| **本方案:多 Package + `path:` 内部引用** | 严格分层、独立测试、增量快、循环依赖被 SPM 强制拦截 | 初始配置工程量大;`path:` 依赖不能被外部项目直接消费 | 中大型 macOS app,有清晰职责划分,≥5 个功能域 |
| **单 SwiftPM Package + 多 target** | 配置简单、SPM cache 共享更高效 | target 间依赖管理弱,易出现隐式依赖;无法独立 `swift build` 验证边界 | 100 文件以内的小工具、单人项目、快速原型 |
| **git submodule + 独立 repo** | 可独立开源/复用;外部项目可直接用 `.package(url:)` 引入 | gitlink 漂移;跨 repo 改动需 ping-pong 提交;CI 配置复杂 | 库已成熟、有外部消费者(Peekaboo 的 AXorcist、Commander) |
| **Tuist / XcodeGen 项目生成** | 工程文件可 review、git diff 干净;支持丰富 build configuration | 工具链额外依赖;学习曲线;与纯 SPM 工程互操作需配置 | 大量 build configuration、多 platform target、大团队需要统一工程文件 |
| **裸 `.xcodeproj` 手工管理** | Apple 原生工具,零额外依赖 | 易脏 diff;合并冲突难解;SPM 集成靠 Xcode GUI,不透明 | 单人简单 app、只有 Mac.app 一个 target 且不需要 CLI |

### 本方案 fail 时改用什么

- **模块数 < 5,代码量 < 100 文件**:monorepo single Package + 多 target 更划算,配置开销高于收益
- **某个模块已有外部消费者**:从 `path:` 迁移到 git submodule;改动步骤:① 为模块建独立 git repo;② 主仓库改用 `.package(url:, exact:)`
- **需要跨 iOS/macOS/watchOS 共享代码**:考虑 Tuist,它的 `multiplatform` 支持比裸 SPM 更人性化
- **团队需要 Xcode 友好的工程文件**:XcodeGen 生成 `.xcodeproj`,与 SPM 包并存

## 调试与取证(Debug & Forensics)

### 症状 → 排查命令 → 根因映射

| 症状 | 排查命令 | 可能根因 |
|------|---------|---------|
| 改 `Package.swift` 后 Xcode 不识别新 target | `rm -rf ~/Library/Developer/Xcode/DerivedData/*` 后重启 Xcode,执行 File → Packages → Resolve Package Versions | DerivedData 缓存陈旧;Xcode 的 SPM 状态机未刷新 |
| `swift build` 报 `cyclic dependency` | `swift package show-dependencies --format json \| python3 -m json.tool` 观察依赖树;或 `swift package show-dependencies` 文本输出 | 两个或多个模块互相依赖;解法:把共享类型下移到两者共同依赖的最近底层(通常是 Protocols 层) |
| `error: no such module 'Foo'` | `swift build --target App --verbose 2>&1 \| grep "warning\|no such module"` | `path:` 字段错误 / target `dependencies` 数组漏配该模块 |
| 增量构建慢得离谱(>15 秒) | `time swift build -Xswiftc -driver-show-incremental --build-tests 2>&1 \| grep "^Compiling" \| wc -l` | "上帝模块"——单个 target 文件数 > 40,触发全量重编 |
| submodule 漂移(本地与 CI 版本不一致) | `git submodule status` 查看 SHA 是否有 `+`(已修改但未提交);`git submodule update --init --recursive` 对齐 | gitlink SHA 与子仓库 HEAD 不一致;应先在子仓库 push 再 bump 主仓库 gitlink |
| Apps 层意外看到不该看到的 internal type | SwiftLint 自定义规则检查 import;或 `swift build 2>&1 \| grep "is internal"` | `@_exported import` 在实现层滥用,导致 internal 符号泄漏到消费方 |
| SPM 解析卡住 / Xcode Package 菊花转 | `swift package clean && swift package reset` 清除本地 checkouts 和 build artifacts | `.build/` 或 `~/.swiftpm/` 缓存损坏 |
| Xcode 工程与 SPM 包中同名 target 冲突 | `swift package describe --type json \| python3 -m json.tool \| grep '"name"'` 列出所有 target 名;检查 `.xcodeproj` 中的 target 名是否重复 | xcworkspace 中同时有 Xcode target 和 SPM target 同名 |

### 关键工具详解

**1. 查看 SPM 依赖图**

```bash
# 文本模式:层次缩进展示完整依赖树
swift package show-dependencies

# JSON 模式:可用 jq/python3 过滤
swift package show-dependencies --format json \
  | python3 -m json.tool \
  | grep -A3 '"name"'
```

**2. 列出所有 target 及其类型**

```bash
swift package describe --type json \
  | python3 -c "import sys,json; [print(t['name'], t['type']) for t in json.load(sys.stdin)['targets']]"
```

**3. 清缓存(从轻到重)**

```bash
# 轻量:只清 build 产物
swift package clean

# 中量:清 build 产物 + 重置所有 checkouts(SPM 会重新 resolve)
swift package reset

# 重量:清 DerivedData(Xcode 用)
rm -rf ~/Library/Developer/Xcode/DerivedData/*

# 核弹:清 SPM 全局缓存(影响所有项目!)
rm -rf ~/.swiftpm/cache
```

**4. 验证循环依赖**

```bash
# SPM 会在 resolve 阶段直接报错,但可以提前检查
swift package show-dependencies 2>&1 | grep -i "cycl\|circular"

# 如果 json 输出包含某个包名出现两次(在不同深度),说明存在菱形依赖(非错误但需注意版本冲突)
swift package show-dependencies --format json | python3 -c "
import sys, json, collections
data = json.load(sys.stdin)
def collect(d, names):
    names[d['name']] += 1
    for dep in d.get('dependencies', []):
        collect(dep, names)
names = collections.Counter()
collect(data, names)
print({k: v for k, v in names.items() if v > 1})
"
```

**5. 增量构建诊断**

```bash
# 显示哪些文件被重新编译
swift build -Xswiftc -driver-show-incremental 2>&1 | grep "^Compiling"

# 统计本次增量重编文件数
swift build -Xswiftc -driver-show-incremental 2>&1 | grep "^Compiling" | wc -l

# 找出编译最慢的表达式(需 debug build)
swift build -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=50 2>&1 | grep "warning:"
```

**6. 验证 submodule 状态**

```bash
# 查看所有 submodule 当前 SHA;前缀 '+' 表示本地已改动但未 commit
git submodule status

# 对齐到主仓库记录的 SHA
git submodule update --init --recursive

# 查看某个 submodule 的远端最新 vs 本地 gitlink
cd AXorcist && git log --oneline origin/main..HEAD
```

**7. Xcode Build Diagnostics**

在 Xcode 中:`Product → Perform Action → Generate Build Diagnostics`。生成的 `.xcbuilddata` 包含完整的依赖图、编译时间、警告统计。可以用 Instruments 的 Build Timing template 分析。

## 常见陷阱(Pitfalls)

### 陷阱 1 · "上帝模块"引发的雪崩重编

**症状**:增量构建时间超过 15 秒,`-driver-show-incremental` 输出显示超过 40 个文件被重编。

**可观测信号**:修改某个服务实现文件后,`Compiling` 行数超过模块实际文件数的 3 倍——说明 SPM 认为有大量文件依赖链被"污染"。

```bash
swift build -Xswiftc -driver-show-incremental 2>&1 | grep "^Compiling" | wc -l
# 如果输出 >> 单模块文件数,说明依赖边界太宽
```

**处理**:拆分期间用 `@_exported` 保持向后兼容(`Core/PeekabooCore/Package.swift` 的做法),分阶段迁移而非一次性大重构。

**来源**:`docs/module-architecture-refactoring.md:13-21` 记录了 Peekaboo 真实的 700+ 文件重编案例。

---

### 陷阱 2 · 循环依赖

**症状**:SPM 报 `error: cyclic dependency` 并终止 resolve。

**可观测信号**:报错消息形如 `package 'A' depends on 'B' which depends on 'A'`。

**检查命令**:

```bash
swift build 2>&1 | grep -i "cycl\|circular"
swift package show-dependencies 2>&1 | grep -i "cycl"
```

**处理**:将触发环路的共享类型下移到两者共同依赖的最近底层(通常是 `PeekabooProtocols` 或 `PeekabooFoundation`),而不是用 `@_spi` 绕过。`docs/module-architecture-refactoring.md:20` 记录了真实案例:`PeekabooCore → Tachikoma → TachikomaMCP → 回调 PeekabooCore 类型`。

---

### 陷阱 3 · submodule 漂移

**症状**:本地 `swift build` 通过,CI 报"找不到 symbol"或类型不兼容错误;或反之。

**可观测信号**:`git submodule status` 输出中某行以 `+` 开头(本地 SHA 与 gitlink 不一致);或 CI 与本地拉到的 submodule 版本不同。

**检查命令**:

```bash
git submodule status
# 输出前缀含义: ' ' = 正确, '+' = 已修改, '-' = 未初始化, 'U' = 有冲突
```

**处理**:先在 home repo 改动并 push,再 bump 主仓库 gitlink(`git add AXorcist && git commit -m "chore: bump AXorcist"`);不要用 `git submodule update --remote --merge` 在主仓库中批量推进,这会脱离版本锁定语义。

---

### 陷阱 4 · 上游模块改 API 时下游测试不跑

**症状**:CI 全部绿,但运行时出现 `EXC_BAD_ACCESS` 或协议方法缺失崩溃。

**可观测信号**:`swift build` 和所有测试通过,但 `swift build --target App` 时出现警告:`warning: expression implicitly coerced from 'any FooProtocol' to 'Any'`——说明协议接口已变更但调用方隐式 cast 了。

**处理**:在 Protocols target 的测试目录中加"契约测试"(contract test)——用一个 mock 实现来断言协议的所有方法签名和行为约束。上游改 API 时,contract test 先失败,强制同步修改下游。

---

### 陷阱 5 · `@_exported import` 滥用导致跨模块名字泄漏

**症状**:Apps 层能够访问某个不在 `MyAppCore` 公共 API 中的 `internal` struct,且 Xcode 的代码补全中出现了不该出现的符号。

**可观测信号**:`swift build` 出现 `warning: using '@_exported' to export 'internal' type 'Foo' is deprecated`;或在 Apps 层文件中能 `import` 到底层实现模块(如 `MyAutomationKit`)而不报错——说明 `@_exported` 已把该模块的所有 `public` 符号传递给消费方。

**处理**:只在 umbrella 组装层(如 `MyAppCore`)使用 `@_exported`,实现层之间禁止互相 `@_exported`。定期运行 `swift build --target MyAppCore 2>&1 | grep "@_exported"` 检查有无非预期的重导出。

## 延伸阅读

- Peekaboo 内部文档:`docs/module-architecture-refactoring.md`、`docs/ARCHITECTURE.md`、`docs/swift-module-plan.md`
- Apple 官方:
  - [Swift Package Manager](https://www.swift.org/package-manager/)
  - [Organizing Your Code with Local Packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages)
  - [Improving the Speed of Incremental Builds](https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds)
  - WWDC 2022 [Session 110359 — Swift Package plugins](https://developer.apple.com/videos/play/wwdc2022/110359/)
  - WWDC 2024 [Session 10138 — Consume noncopyable types in Swift](https://developer.apple.com/videos/play/wwdc2024/10138/) (Swift 6 concurrency + modular design 相关)
- 其它 playbook:
  - [02 · Swift 6 严格并发](./02-swift6-concurrency.md) — 模块分层后 `@MainActor`、`Sendable` 边界如何设置
  - [11 · SwiftPM + Xcode workspace + Poltergeist](./11-swiftpm-xcode-poltergeist.md) — 混合工程(SPM 包 + xcodeproj)的目标依赖配置与增量构建工具

---
*Last verified against Peekaboo @ `548989f7299888e25444f15dcf7cab28b876f227`*
