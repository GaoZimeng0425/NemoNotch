---
summary: 'Structure a macOS app into unidirectional SPM layers to keep incremental builds under five seconds.'
read_when:
  - 'setting up module boundaries and dependency graph for a new macOS project'
  - 'slow incremental builds or circular-dependency errors in SPM'
---

# 01 · 模块划分与依赖方向

## TL;DR

把 macOS 应用拆成单向层次模块：Foundation（零依赖的基础类型）→ Protocols（接口层）→ 功能模块（Visualizer / AutomationKit）→ PeekabooCore（组装层）→ Apps（消费层）。每层只能向下依赖，SPM 的编译隔离会把一次改动的重编文件数从 700+ 降到几十个。把可独立发布、有明确领域边界的第三方库封装成一个 `PeekabooExternalDependencies` 模块统一管理，其余 submodule（AXorcist、Tachikoma 等）只在自己的仓库演进，主仓库通过 gitlink 锁版本。CLI / Mac.app / Inspector 三态共用同一套 Core 库，靠 `PeekabooProtocols` 的协议边界而非具体类型来对接，从根本上避免循环引用。这套模式能让增量构建从 43 秒降到 5 秒以内，且让不同 App 目标共享逻辑而无横向耦合。

## Peekaboo 在哪里实现

- 模块：`Core/PeekabooFoundation`、`Core/PeekabooProtocols`、`Core/PeekabooAutomationKit`、`Core/PeekabooVisualizer`、`Core/PeekabooExternalDependencies`、`Core/PeekabooCore`、`Apps/CLI`
- 关键文件：`Core/PeekabooFoundation/Package.swift:25` — `dependencies: []`，零依赖声明，是整个依赖图的绝对底层
- 关键文件：`Core/PeekabooCore/Package.swift:44-50` — PeekabooCore 同时引用 AutomationKit、Foundation、Protocols、ExternalDependencies、Visualizer、Tachikoma，是唯一允许横跨多层的"组装点"
- 关键文件：`Core/PeekabooExternalDependencies/Package.swift:23-46` — 把 AXorcist、AsyncAlgorithms、Commander、swift-log 等全部第三方包聚合到单一 target 并统一 re-export
- 相关 docs：`docs/module-architecture-refactoring.md`、`docs/swift-module-plan.md`、`docs/ARCHITECTURE.md`

## 设计动机(Why)

Peekaboo 的初始架构是一个"上帝模块"：132 个 Swift 文件全部塞进 `PeekabooCore`，任意一个文件改动都触发 700+ 文件重编（占全仓 96%），增量构建耗时 43 秒（见 `docs/module-architecture-refactoring.md:14-21`）。

根因不是文件数量，而是三个结构性问题：
1. **无接口边界**：具体类型直接跨层引用，导致任何叶子改动都会"传染"到所有依赖方；
2. **循环依赖**：`PeekabooCore → Tachikoma → TachikomaMCP → 回调 PeekabooCore 的类型`，SPM 直接报错，只能用 workaround 绕开；
3. **第三方依赖散落**：AXorcist、Commander、swift-log 等分布在各个模块的 `Package.swift` 里，版本升级需要逐一追查。

拆模块的核心收益是让 SPM 编译图变窄：每个 target 只编译变化的依赖闭包，目标增量构建 < 5 秒。同层模块无横向依赖，SPM 自动并行构建。

## 核心模式(Pattern)

### 依赖方向图

```
┌─────────────────────────────────────────────────────────────────┐
│  Apps 层                                                         │
│  peekaboo(CLI) · Peekaboo.app · PeekabooInspector               │
└───────────────────────┬─────────────────────────────────────────┘
                        │ 只能向下依赖
┌───────────────────────▼─────────────────────────────────────────┐
│  组装层   PeekabooCore (umbrella: @_exported re-export)          │
│           PeekabooAutomation / PeekabooAgentRuntime              │
└──────┬──────────────────────┬────────────────────────┬──────────┘
       │                      │                        │
┌──────▼──────┐  ┌────────────▼──────────┐  ┌─────────▼──────────┐
│PeekabooVis- │  │ PeekabooAutomationKit │  │ PeekabooExternal-  │
│  ualizer    │  │ (AX 自动化低层实现)    │  │ Dependencies       │
└──────┬──────┘  └──────────┬────────────┘  │ (第三方依赖聚合)    │
       │                    │               └────────────────────┘
       └──────────┬─────────┘
                  │
┌─────────────────▼─────────────────────────────────────────────┐
│  接口层   PeekabooProtocols                                    │
│  (ApplicationServiceProtocol, ClickServiceProtocol, ...)       │
└─────────────────────────────┬──────────────────────────────────┘
                              │
┌─────────────────────────────▼──────────────────────────────────┐
│  基础层   PeekabooFoundation   (零外部依赖)                     │
│  (ElementType, ClickType, ScrollDirection, 基础 DTO)           │
└────────────────────────────────────────────────────────────────┘

  ────────────────────── git submodules ──────────────────────────
  AXorcist · Tachikoma · Commander · TauTUI · Swiftdansi
  (独立仓库独立演进，主仓库只锁 gitlink SHA)
```

### PeekabooProtocols 作为接口层

`PeekabooProtocols` 只依赖 `PeekabooFoundation`，暴露所有服务协议（`ApplicationServiceProtocol`、`ClickServiceProtocol` 等）。上层依赖协议而非具体实现，实现替换不触发调用方重编（见 `Core/PeekabooProtocols/Package.swift:13-16`）。

```swift
// Core/PeekabooProtocols — 只声明协议，不依赖任何实现
public protocol ApplicationServiceProtocol {
    func listApplications() async throws -> [AppInfo]
}

// Core/PeekabooAutomationKit — 依赖协议实现具体逻辑
public final class ApplicationService: ApplicationServiceProtocol { ... }
```

### PeekabooExternalDependencies 隔离第三方

所有第三方包集中到单一 target，统一 `@_exported` 暴露；版本升级只改这一个 `Package.swift`（见 `Core/PeekabooExternalDependencies/Package.swift:23-46`）。

### CLI / Mac / Inspector 三态共享 Core

三个 App target 均 `import PeekabooCore`（见 `Apps/CLI/Package.swift:34`），PeekabooCore 用 `@_exported` 重导出子模块作为 umbrella。App 层只通过协议接口使用 Core 提供的能力，不直接引用底层具体类型，避免横向耦合。

## 新项目落地步骤(How to apply)

1. **建 Foundation 模块**：创建 `Core/YourFoundation/Package.swift`，`dependencies: []`，放入项目中最稳定的基础类型（枚举、DTO、错误层次）；确保它能单独 `swift build` 通过。
2. **建 Protocols 模块**：创建 `Core/YourProtocols/Package.swift`，只依赖 Foundation；把所有服务接口定义为 `public protocol`，不引入任何 AppKit/ScreenCaptureKit 等平台框架。
3. **建 ExternalDependencies 模块**：创建 `Core/YourExternalDependencies/Package.swift`，把所有第三方包（AXorcist、swift-log 等）集中在此，用 `@_exported import` 统一暴露；其他模块只依赖这一个 target 即可获得所有第三方符号。
4. **拆分实现模块按功能域**（Visualizer、AutomationKit 等）：判定边界的原则是"能否在不修改其他模块的情况下独立替换这个模块"——能则说明边界清晰。每个模块只依赖 Foundation + Protocols + ExternalDependencies；同一层的模块之间不互相依赖，用构造函数注入协议代替直接引用具体类型：

```swift
// 错误：AutomationKit 直接引用 Visualizer 具体类型
// 正确：构造时注入 Visualizer 遵守的协议
public final class AutomationRunner {
    private let feedback: VisualizerProtocol
    public init(feedback: VisualizerProtocol) { self.feedback = feedback }
}
```
5. **建组装层 Core**：在 `Core/YourCore/Package.swift` 中汇聚所有实现模块，用 `@_exported import` 提供单一入口；Core 是唯一允许同时引用多个实现模块的地方。
6. **收拢 Apps 层依赖到 Core**：CLI、Mac.app、扩展等各自的 `Package.swift` 只 `import YourCore`，不直接引用底层模块；App 层与实现模块完全解耦，替换实现不改 App 代码。
7. **评估 submodule 切割条件**：满足以下全部条件才切 git submodule：① 能独立 release（有自己的语义版本）；② 其他项目也可能用到它；③ 心智负担清晰（单一职责，不依赖主仓库私有 API）。否则保持在 Core 目录内，过早拆 submodule 会增加 gitlink 漂移的维护成本。

## 常见陷阱(Pitfalls)

- **"上帝模块"引发的雪崩重编**：（见上文设计动机）可观测信号：当单个模块文件数超过 40 个，或增量构建时间超过 15 秒时，应评估是否需要拆分。拆分期间用 `@_exported` 保持向后兼容，否则所有调用方须同步改 import。

- **循环依赖**：`docs/module-architecture-refactoring.md:20` 记录真实案例：`PeekabooCore → Tachikoma → TachikomaMCP → PeekabooCore`，SPM 报 circular dependency。解法是将触发环路的共享类型移到两个模块共同依赖的最近底层（通常是 Protocols 层），而非用 `@_spi` 绕过。

- **submodule 漂移**：上游有 breaking change 而主仓库 gitlink 未同步（或反之）会导致本地与 CI 不一致。用 `git submodule status` 核对 SHA；先在 home repo 改动，再 bump 主仓库 gitlink。

## 延伸阅读

- Peekaboo：`docs/module-architecture-refactoring.md`、`docs/ARCHITECTURE.md`、`docs/swift-module-plan.md`
- Apple：[Swift Package Manager](https://www.swift.org/package-manager/)
- 其它 playbook：[02 · Swift 6 并发](./02-swift6-concurrency.md)、[11 · SwiftPM + Xcode + Poltergeist](./11-swiftpm-xcode-poltergeist.md)

---
*Last verified against Peekaboo @ `f9ac01fd`*
