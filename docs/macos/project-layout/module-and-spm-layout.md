---
summary: '把 macOS 应用拆成单向四层 SPM 模块(Foundation → Protocols → Impl → Core/Apps),用协议边界隔离变化,SPM 编译隔离将增量构建从 43s 降至 5s 以内。'
read_when:
  - '新建 macOS 项目,规划 SwiftPM 模块边界'
  - '增量构建超过 15s,怀疑存在"上帝模块"'
  - '评估是否把某个模块切成 git submodule'
  - '协议层与实现层的依赖反转如何落地'
sources: ['P01', 'I-2']
last_verified:
  peekaboo: '548989f7299888e25444f15dcf7cab28b876f227'
  nemonotch: 'fe4e9e5'
---

# 模块划分与依赖方向

## TL;DR

把 macOS 应用拆成单向四层模块:Foundation(零依赖)→ Protocols(只依赖 Foundation)→ 实现层(依赖 Foundation + Protocols)→ Core 组装层(唯一横跨多层的汇聚点)→ Apps(只 import Core)。SPM 的 package 边界比 target 边界强制力更高——一次改动只污染直接依赖方,增量重编文件数可从 700+ 降到几十个。把可独立发布、有外部消费者的模块切成 git submodule;其余实现模块用 `path:` 方式留在主仓库 `Core/` 目录。

日志后端的选型见 `../logging/`。

---

## 可复用模式

### 1. 四层单向依赖图

```
┌──────────────────────────────────────────────────────────────────┐
│  Apps 层                                                          │
│  CLI / Mac.app / Inspector / …                                   │
│  只 import Core(组装层),不直接引用底层具体类型                   │
└─────────────────────────────┬────────────────────────────────────┘
                              │ 单向向下
┌─────────────────────────────▼────────────────────────────────────┐
│  组装层   Core/YourCore                                           │
│  umbrella package:@_exported import 重导出所有子模块              │
│  唯一允许同时引用多个实现模块的地方                               │
└──────────┬──────────────────┬────────────────────┬───────────────┘
           │                  │                    │
┌──────────▼───────┐  ┌───────▼──────────┐  ┌─────▼─────────────┐
│ ImplA            │  │ ImplB            │  │ ExternalDeps      │
│ (功能域 A 实现)  │  │ (功能域 B 实现)  │  │ 第三方依赖聚合    │
│                  │  │                  │  │ @_exported re-exp │
└──────────┬───────┘  └───────┬──────────┘  └───────────────────┘
           └──────────┬───────┘
                      │
┌─────────────────────▼────────────────────────────────────────────┐
│  接口层   Core/YourProtocols                                      │
│  只声明 public protocol,不引任何平台框架(无 AppKit / ScreenCapture)│
└─────────────────────────────┬────────────────────────────────────┘
                              │
┌─────────────────────────────▼────────────────────────────────────┐
│  基础层   Core/YourFoundation   (dependencies: [])               │
│  稳定基础类型、枚举、DTO、Error 层次                              │
└──────────────────────────────────────────────────────────────────┘

  ─────── git submodules(独立仓库,独立演进) ──────────────────────
  AXorcist · Tachikoma · Commander · …
  (主仓库只锁 gitlink SHA;见 .gitmodules)
```

**同层规则**:ImplA 与 ImplB **不互相依赖**;共享逻辑下沉到 Protocols 或 Foundation。

---

### 2. Package.swift 骨架(四层分离 + Swift 6 严格模式)

可直接拷入新项目作为起点:

```swift
// swift-tools-version: 6.2
import PackageDescription

// ── 共享 Swift 设置 ─────────────────────────────────────
let foundationSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let protocolSettings: [SwiftSetting] = foundationSettings + [
    .defaultIsolation(MainActor.self),
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=50",
        "-Xfrontend", "-warn-long-expression-type-checking=50",
    ], .when(configuration: .debug)),   // 只在 debug build 开启编译耗时警告
]

let kitSettings: [SwiftSetting] = foundationSettings + [
    .enableExperimentalFeature("SwiftTesting"),
]

let coreSettings: [SwiftSetting] = foundationSettings

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MyFoundation",    targets: ["MyFoundation"]),
        .library(name: "MyProtocols",     targets: ["MyProtocols"]),
        .library(name: "MyAutomationKit", targets: ["MyAutomationKit"]),
        .library(name: "MyAppCore",       targets: ["MyAppCore"]),
        .executable(name: "my-cli",       targets: ["MyCLI"]),
    ],
    // 外部依赖集中在根 Package.swift 或 ExternalDependencies 模块统一管理
    dependencies: [
        // 日志后端见 ../logging/
        // .package(url: "https://github.com/apple/swift-log", from: "1.6.4"),
    ],
    targets: [
        // ── Layer 1: Foundation(零依赖)─────────────────
        .target(
            name: "MyFoundation",
            dependencies: [],
            path: "Core/MyFoundation/Sources/MyFoundation",
            swiftSettings: foundationSettings
        ),

        // ── Layer 2: Protocols(只依赖 Foundation)───────
        .target(
            name: "MyProtocols",
            dependencies: ["MyFoundation"],
            path: "Core/MyProtocols/Sources/MyProtocols",
            swiftSettings: protocolSettings
        ),

        // ── Layer 3: Implementation(同层不互相依赖)─────
        .target(
            name: "MyAutomationKit",
            dependencies: ["MyFoundation", "MyProtocols"],
            path: "Core/MyAutomationKit/Sources/MyAutomationKit",
            swiftSettings: kitSettings
        ),

        // ── Layer 4a: Core(唯一横跨多层的汇聚点)───────
        .target(
            name: "MyAppCore",
            dependencies: ["MyFoundation", "MyProtocols", "MyAutomationKit"],
            path: "Core/MyApp/Sources/MyApp",
            swiftSettings: coreSettings
        ),

        // ── Layer 4b: Apps(只 import Core)─────────────
        .executableTarget(
            name: "MyCLI",
            dependencies: ["MyAppCore"],
            path: "Apps/CLI/Sources/CLI",
            swiftSettings: coreSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

---

### 3. `path:` 引用同仓库兄弟目录

```swift
// Core/PeekabooCore/Package.swift:44-50
dependencies: [
    .package(path: "../PeekabooAutomationKit"),   // 兄弟目录
    .package(path: "../PeekabooFoundation"),
    .package(path: "../PeekabooProtocols"),
    .package(path: "../PeekabooExternalDependencies"),
    .package(path: "../../Tachikoma"),            // submodule 在仓库根
]
```

`path:` 依赖由 SPM 本地解析,无需 push/tag,改动即时生效;但**不能被外部项目直接消费**。

---

### 4. `@_exported import` 做 umbrella 重导出

```swift
// Core/PeekabooCore/Sources/PeekabooCore/PeekabooCore.swift
@_exported import PeekabooAutomation
@_exported import PeekabooAgentRuntime
@_exported import PeekabooFoundation
@_exported import PeekabooProtocols
```

Apps 层只写 `import PeekabooCore` 即可获得所有公共符号。

**限制**:`@_exported` 是 Swift 私有 SPI。**只在 umbrella 组装层使用**,实现层之间禁止互相 `@_exported`(否则 internal 符号泄漏到消费方,边界检查失效)。

---

### 5. 协议注入(依赖反转)

```swift
// Core/YourProtocols — 只声明协议,不依赖任何实现
// ServiceProtocols.swift:14
public protocol ApplicationServiceProtocol: Sendable {
    func listApplications() async throws -> [String]
}

// Core/YourAutomationKit — 依赖协议,实现具体逻辑
public final class ApplicationService: ApplicationServiceProtocol { … }

// 正确:构造时注入遵守协议的实例
public final class AutomationRunner {
    private let feedback: VisualizerProtocol
    public init(feedback: VisualizerProtocol) { self.feedback = feedback }
}
// 错误:AutomationKit 直接引用 Visualizer 具体类型
```

---

### 6. ExternalDependencies 聚合模块(可选,多第三方依赖时强烈推荐)

把所有第三方包集中在 `Core/YourExternalDependencies/Package.swift`(对应 `Core/PeekabooExternalDependencies/Package.swift:22-46`)。用 `@_exported import` 统一暴露。其他模块只依赖这一个 target 即可获得所有第三方符号,**版本升级只改这一个文件**。

---

### 7. git submodule 切割临界点

满足**全部**三个条件才切 git submodule:
1. **能独立 release** — 有自己的语义版本 tag
2. **有外部消费者** — 其他项目也在用
3. **单一职责** — 不依赖主仓库私有 API

Peekaboo 示例:AXorcist 满足三条,切为 submodule;PeekabooVisualizer 仅内部使用,保持 `path:`。

---

### 8. Ironsmith 式逻辑分层(小型 macOS app)

对于不需要多 Package 分层、单仓库的应用(< 100 文件),可用目录约定代替 SPM 分层:

```
YourApp/
  App/          入口、菜单栏/窗口控制器、Settings 场景
  Core/
    Models/        稳定基础类型(@Model / DTO)
    Persistence/   持久化访问(Repository)
    Inference/     Provider、凭证、模型发现
    SomeDomain/    业务管线
  Features/
    FeatureA/      UI + Store(局部状态)
    Settings/
```

四层职责与禁止事项:

| 层 | 职责 | 明确禁止 |
|---|---|---|
| View | 渲染状态、发出意图 | 不直接碰网络/文件/进程/Keychain |
| Store(`@Observable`) | 协调工作流、持有状态 | 局部 UI 状态不要塞进共享 store |
| Repository | 包装持久化访问 | 不发网络、不碰 Keychain、不起进程 |
| Closure Client | 包装一切副作用 | — |

拆分单元要"命名一个真实职责",而不是为了减少行数(`AGENTS.md:136`)。

---

## 锚点

| 锚点 | 位置 | 内容 |
|---|---|---|
| Foundation 零依赖声明 | `Core/PeekabooFoundation/Package.swift:25,29` | `dependencies: []`(Package 级 + target 级) |
| Core 组装层 `path:` 依赖 | `Core/PeekabooCore/Package.swift:44-50` | 横跨所有子模块的唯一汇聚点 |
| ExternalDeps 聚合 | `Core/PeekabooExternalDependencies/Package.swift:22-46` | 统一管理第三方依赖 |
| Protocols 只向下依赖 | `Core/PeekabooProtocols/Package.swift:30-31` | `dependencies: [.package(path: "../PeekabooFoundation")]` |
| CLI 消费 Core | `Apps/CLI/Package.swift:34` | `dependencies: ["PeekabooCore"]` |
| 编译耗时警告开关 | `PeekabooProtocols/Package.swift:12-17` | `.when(configuration: .debug)` |
| 四层职责契约 | `AGENTS.md:31` | views/stores/repositories/closure clients |
| 目录结构按职责 | `AGENTS.md:136` | "命名一个真实职责,而非减少行数" |
| 700+ 文件雪崩案例 | `docs/module-architecture-refactoring.md:13-21` | 初始"上帝模块"的增量构建耗时 43s |

---

## Pitfalls

### 1. "上帝模块"引发的雪崩重编

**症状**:增量构建 > 15s;`-driver-show-incremental` 输出显示 > 40 个文件被重编(实为 700+/96% 全仓)。

**检测**:
```bash
swift build -Xswiftc -driver-show-incremental 2>&1 | grep "^Compiling" | wc -l
# 输出 >> 单模块文件数 → 依赖边界太宽
```

**处理**:拆分期间用 `@_exported` 保持向后兼容,分阶段迁移;不要一次性大重构。

---

### 2. 循环依赖

**症状**:SPM 报 `error: cyclic dependency`。

**真实案例**:`PeekabooCore → Tachikoma → TachikomaMCP → 回调 PeekabooCore 类型`(`docs/module-architecture-refactoring.md:20`)。

**处理**:把触发环路的共享类型下移到两者共同依赖的最近底层(通常是 Protocols 或 Foundation),不要用 `@_spi` 绕过。

```bash
swift build 2>&1 | grep -i "cycl\|circular"
swift package show-dependencies 2>&1 | grep -i "cycl"
```

---

### 3. git submodule 漂移

**症状**:本地 `swift build` 通过,CI 报"找不到 symbol"或类型不兼容。

**检测**:`git submodule status` 输出中某行以 `+` 开头。

**处理**:先在子仓库 push,再 bump 主仓库 gitlink(`git add AXorcist && git commit -m "chore: bump AXorcist"`)。**不要**用 `--remote --merge` 批量推进。

---

### 4. `@_exported import` 在实现层滥用

**症状**:Apps 层能访问不该暴露的 `internal` struct;代码补全出现底层符号。

**处理**:只在 umbrella 组装层使用 `@_exported`;定期检查:

```bash
swift build --target MyAppCore 2>&1 | grep "@_exported"
```

---

### 5. 上游改 API 时下游测试不跑

**症状**:CI 全绿,运行时崩溃(`EXC_BAD_ACCESS` 或协议方法缺失)。

**处理**:在 Protocols target 的测试目录加"契约测试"(contract test)——用 mock 实现断言所有方法签名和行为约束。上游 API 变更时,契约测试先失败,强制同步修改下游。

---

### 6. 过早切 git submodule

**成本**:每次跨 repo 改动需要 ping-pong 式提交;PR review 散乱;gitlink 漂移导致 CI 失败;循环依赖检测延迟到本地 resolve 时才报错。

**原则**:满足三个条件之前,保持 `path:` 引用。

---

## 落地 checklist

- [ ] 建 Foundation 模块:`dependencies: []`,放稳定基础类型。`swift build --target YourFoundation` 验证零依赖通过
- [ ] 建 Protocols 模块:只依赖 Foundation;所有服务接口定义为 `public protocol`;不 import AppKit 等平台框架
- [ ] 建 ExternalDependencies 聚合模块(可选,但多第三方依赖时强烈推荐):集中第三方包,`@_exported import` 统一暴露
- [ ] 按功能域拆分实现模块:判定边界——"能否在不修改其他模块的情况下独立替换?"。**同层不互相依赖**
- [ ] 建 Core 组装层:用 `@_exported import` 提供单一入口;是唯一允许引用多个实现模块的地方
- [ ] Apps 层依赖只写 Core:通过协议消费,不直接引用底层具体类型
- [ ] 配置 CI 逐层验证:`swift build --target Layer` 确保边界在 CI 有守护
- [ ] SwiftLint 自定义规则:禁止 Apps 层文件直接 `import` 底层实现模块(如 `import PeekabooAutomationKit`)而非通过 Core
- [ ] 评估 submodule 切割:全部满足三个条件(独立 release / 外部消费者 / 单一职责)才切

---

## 延伸阅读

- 增量构建隔离细节 → `./build-isolation.md`
- 构建脚本与发布 → `../build-release/`
- Swift 6 并发边界(模块分层后 `@MainActor`/`Sendable` 如何设置) → `../concurrency/`
- 日志后端选型 → `../logging/`
