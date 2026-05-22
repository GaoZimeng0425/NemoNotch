---
summary: 'Combine SwiftPM packages and Xcode workspace with Poltergeist watch-builds, pnpm script orchestration, and lipo-based universal binary assembly.'
read_when:
  - 'setting up a new macOS project that needs SwiftPM modularity plus an app bundle'
  - 'speeding up the edit-build cycle with incremental file watching'
---

<!-- Baseline: macOS 14+  ·  pnpm 11 (Corepack)  ·  Xcode 16 / Swift 6.2  ·  Poltergeist 1.x (Watchman-backed) -->

# 11 · SwiftPM + Xcode workspace + Poltergeist 增量构建

## TL;DR

混合 macOS 工程把 SwiftPM 包（可复用库 + CLI）与 Xcode 工程（带 entitlements 的 `.app`）放进同一 `.xcworkspace`，共享 Swift 索引与代码补全，构建流程各自独立。Poltergeist 在后台基于 Watchman 监听文件变化，按 debounce 触发增量构建，前台用 `polter peekaboo` 始终拿到最新产物，消除手工 build 等待。发布阶段分别以 `--arch arm64` 和 `--arch x86_64` 编译，再用 `lipo -create` 合成 Universal Binary、`strip -Sxu` 精简符号、`codesign` 统一签名一次。pnpm 作为任务运行器将上述所有入口统一到 `package.json scripts` 段，团队成员无需记忆任何 Swift 命令细节。当前 ReplayD 等系统进程在 `.app` 调试构建完成后由 `autoRelaunch: true` 自动触发重启，消除手工操作。

## Peekaboo 在哪里实现

- **顶层 Package.swift**：`Package.swift:32-88` — 完整包声明；4 个 library 目标（`PeekabooFoundation → PeekabooProtocols → PeekabooAutomationKit → PeekabooBridge`）线性依赖，SwiftPM 外部依赖仅 `AXorcist` 和 `swift-algorithms` 两条。
- **Workspace 聚合文件**：`Apps/Peekaboo.xcworkspace/contents.xcworkspacedata:1-16` — 4 行 `<FileRef>` 把 `Mac/Peekaboo.xcodeproj`、`CLI/`（SwiftPM 包）、`Playground/Playground.xcodeproj`、`PeekabooInspector/Inspector.xcodeproj` 聚合为单一工作区；workspace 本身不重新声明依赖。
- **Poltergeist 配置**：`poltergeist.config.json:4-101` — 8 个目标，`Peekaboo`（CLI executable）对 6 条 glob 增量触发 `build-swift-debug.sh`；`Peekaboo.app`（app-bundle）设 `settlingDelay: 4000`（vs CLI 的 1000）和 `autoRelaunch: true`；`buildScheduling.parallelization: 1` 强制串行队列。
- **Universal Binary 脚本**：`scripts/build-swift-universal.sh:129-153` — arm64 build → x86_64 build → `lipo -create` → `strip -Sxu` → `codesign --force`；临时 slice 命名为 `peekaboo-arm64` / `peekaboo-x86_64`，最终合并到根目录 `./peekaboo`。
- **arm64-only 脚本**：`scripts/build-swift-arm.sh:126-164` — 与 universal 版共用 `resolve_signing_identity` / `resolve_timestamp_arg` / `generate_info_plist` 三个辅助函数；直接复制 `.build/arm64-apple-macosx/release/peekaboo` 至根目录。
- **Wrapper 脚本**：`scripts/poltergeist-wrapper.sh:24-68` — 通过 `case` 分支区分 poltergeist 守护命令（haunt/status/logs 等）和前台 `polter` 调用；`peekaboo` 目标强制启 PTY（`script -q /dev/null`）以兼容 ANSI 输出。
- **pnpm 入口**：`package.json:18-56` — 所有构建/测试/poltergeist 操作集中于此；`poltergeist:haunt` / `poltergeist:status` / `poltergeist:rest` / `build:swift:all` 是最常用的 4 个脚本。
- **相关 docs**：`docs/poltergeist.md`（tuning 指南）、`docs/building.md`（快速入门）

## 设计动机（Why）

### 为何不纯 SwiftPM

`swift build` 快、CI 友好，但 SwiftPM 没有对应的 `.app` target 类型。macOS 应用需要：

- **entitlements 文件** — Screen Recording、Accessibility、Hardened Runtime 等权限由 `.entitlements` 声明，`codesign` 在打包时嵌入；SwiftPM 无法指定 entitlements。
- **自定义 Run Script Phase** — 生成 `Info.plist`、注入 git 版本号、运行 SwiftGen 等构建期任务在 Xcode 以 Phase 管理，SPM 无等价机制。
- **Assets.xcassets / storyboard / xib** — Xcode 构建系统负责编译资源、生成 `Assets.car`；SwiftPM 不处理这些资源类型。
- **应用签名与公证** — `.app` bundle 需要 `ProductBundleIdentifier`、签名 entitlements、`--options runtime`；xcodebuild 原生支持，SPM 不支持。

结论：CLI 工具用纯 SwiftPM 即可；`.app` 必须走 Xcode。

### 为何不纯 Xcode xcodeproj

Xcode 工程文件（`project.pbxproj`）是 PList 序列化格式，多人协作时 merge conflict 极重。SwiftPM 依赖管理（`Package.swift`）对比 Xcode SPM 集成：

- **`Package.swift` 在 CLI target 中**：可直接 `swift build`，CI 不依赖 Xcode；依赖图版本通过 `.package(url:exact:)` 锁定，diff 干净。
- **Xcode SPM 解析**：Xcode 的 `XCRemoteSwiftPackageReference` 条目生成到 `project.pbxproj`，每次 resolve 都可能改写文件（Peekaboo 实测：升级 AXorcist 时 pbxproj 噪音 diff 超过 50 行）。
- **共享库的边界**：Core 层（`PeekabooFoundation/Protocols/AutomationKit/Bridge`）用 SwiftPM 管理；`.app` 通过 `package(path: "../../")` 或 workspace 层引用本地 SPM 包，避免重复声明。

结论：混合方案——库/CLI 走 SwiftPM，`.app` 走 xcodeproj，`xcworkspace` 聚合共享索引。

### 为何需要 Poltergeist

Xcode 增量构建慢有结构性原因：

1. **全 target 依赖分析** — 每次构建 Xcode 必须扫描整个 workspace 的目标图。
2. **跨 target 信号弱** — 修改 `Core/` 下一个 Swift 文件，Xcode 要重新验证所有依赖该模块的目标。
3. **GUI 焦点切换** — 在编辑器与 Xcode 之间切换时构建才开始，打断了编辑 → 验证的节奏。

Poltergeist 解决方式：在后台常驻，文件落地即触发，`debounceInterval: 5000` 批量收集连续改动，`settlingDelay: 1000` 等文件系统稳定，然后直接调用 `swift build --package-path Apps/CLI`（CLI target）或 `xcodebuild`（app target）的轻量脚本路径，完全绕过 Xcode GUI。

### 为何 pnpm 而非 make

| 维度 | pnpm scripts | Makefile |
|------|-------------|---------|
| 语法 | JSON，对 JS/TS 开发者熟悉 | 历史语法，tab 严格 |
| 跨平台 | Node.js 运行，darwin/linux 相同 | 需 GNU make，macOS 附带版本旧 |
| 依赖管理 | `package.json devDependencies` 集中管理工具版本 | 手工管理 |
| Corepack | `corepack enable pnpm` 后 pnpm 版本锁定 | 无等价机制 |
| 条件执行 | `pnpm run --if-present` | 复杂条件语法冗长 |
| 缺点 | 需要 Node.js 环境 | 原生，无额外依赖 |

Peekaboo 已依赖 Node（`docs/building.md:13`），额外成本为零。

## 核心模式（Pattern）

### Pattern 1 · 混合工作区目录布局

```
MyProject/
├── Package.swift                    # 顶层 SPM 包（库 + CLI targets）
├── poltergeist.config.json          # Poltergeist 监听配置
├── package.json                     # pnpm 任务入口
├── Apps/
│   ├── MyProject.xcworkspace/
│   │   └── contents.xcworkspacedata  # 聚合 xcodeproj + SPM 包目录
│   ├── Mac/
│   │   └── MyProject.xcodeproj      # .app target（含 entitlements）
│   └── CLI/
│       ├── Package.swift            # CLI-specific SPM 包（依赖根 Package.swift）
│       └── Sources/...
├── Core/
│   ├── Foundation/Sources/...       # PeekabooFoundation-equivalent
│   ├── Protocols/Sources/...
│   └── AutomationKit/Sources/...
└── scripts/
    ├── build-swift-arm.sh           # arm64-only release
    ├── build-swift-universal.sh     # lipo universal release
    └── poltergeist-wrapper.sh       # Poltergeist 统一入口
```

workspace 层只负责聚合 `<FileRef>`，不重复声明依赖。xcodeproj 通过 Xcode 的 "Add Package Dependencies" 引用本地 SPM 包（`Package.swift` 在工作区根目录或相对路径）。

### Pattern 2 · SwiftPM target 依赖链（4 层）

```
PeekabooFoundation       ← 零依赖基础类型
  └── PeekabooProtocols  ← 协议定义（@MainActor 隔离）
        └── PeekabooAutomationKit  ← AXorcist + swift-algorithms
              └── PeekabooBridge   ← CLI/App 共享胶水层
```

`Package.swift:55-87` 关键字段：每层只声明**直接上游**依赖；`path:` 指向 `Core/` 子目录；`swiftLanguageModes: [.v6]` 全局启用 Swift 6 严格并发。

外部依赖（`Package.swift:51-54`）只有两条：
```swift
.package(url: "https://github.com/steipete/AXorcist.git", exact: "0.1.2"),
.package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
```

### Pattern 3 · Poltergeist 核心字段解析

`poltergeist.config.json` 三类关键配置：

**Target 级别**（以 `Peekaboo` CLI target 为例，第 5-31 行）：
```jsonc
{
  "name": "Peekaboo",
  "type": "executable",        // executable | test | app-bundle
  "enabled": true,             // false = 不触发该 target（专注 CLI 时关掉 app）
  "buildCommand": "./scripts/build-swift-debug.sh",
  "outputPath": "./peekaboo",  // polter 等待此文件刷新后再执行
  "settlingDelay": 1000,       // 文件系统稳定等待（ms）
  "debounceInterval": 5000,    // 合并连续改动，5 s 内只触发一次
  "watchPaths": [
    "Core/**/*.swift",         // 共享库
    "AXorcist/**/*.swift",     // git submodule
    "Apps/CLI/**/*.swift"      // CLI 自身
  ],
  "postBuild": [{              // 构建成功后自动执行测试
    "command": "./scripts/status-swifttests.sh",
    "runOn": "success",
    "timeoutSeconds": 1800
  }]
}
```

**App-bundle target 额外字段**（`Peekaboo.app` target，第 81-101 行）：
```jsonc
{
  "type": "app-bundle",
  "bundleId": "boo.peekaboo.mac.debug",
  "autoRelaunch": true,        // 构建成功后自动重启 .app（ReplayD 模式）
  "settlingDelay": 4000,       // 比 CLI 高，避免 Core 改动误触频繁 app build
  "watchPaths": [
    "Apps/Mac/Peekaboo/**/*.swift",
    "Apps/Mac/Peekaboo/**/*.storyboard",
    "Apps/Mac/Peekaboo/**/*.xib",
    "Core/**/*.swift"
  ]
}
```

**全局调度**（第 199-207 行）：
```jsonc
"buildScheduling": {
  "parallelization": 1,        // 强制串行队列，防止 .build 目录竞争写入
  "prioritization": {
    "enabled": true,           // 若关闭，队列退化为并行 Promise.all
    "focusDetectionWindow": 300000
  }
}
```

### Pattern 4 · Universal Binary 合成工作流

完整流程（对应 `scripts/build-swift-universal.sh`）：

```
┌─────────────────────────────────────────────────────────┐
│ 1. swift package reset + rm -rf .build                   │
│    (确保两次编译互不污染)                                  │
├─────────────────────────────────────────────────────────┤
│ 2. swift build --arch arm64  -c release -Osize           │
│    → .build/arm64-apple-macosx/release/myapp             │
│    cp → ./myapp-arm64                                     │
├─────────────────────────────────────────────────────────┤
│ 3. swift build --arch x86_64 -c release -Osize           │
│    → .build/x86_64-apple-macosx/release/myapp            │
│    cp → ./myapp-x86_64                                    │
├─────────────────────────────────────────────────────────┤
│ 4. lipo -create -output ./myapp.tmp                      │
│         ./myapp-arm64 ./myapp-x86_64                     │
├─────────────────────────────────────────────────────────┤
│ 5. strip -Sxu ./myapp.tmp                                │
│    (-S: debug symbols, -x: non-global, -u: keep undef)   │
├─────────────────────────────────────────────────────────┤
│ 6. codesign --force --sign "$SIGN_IDENTITY"              │
│             --options runtime                            │
│             --entitlements myapp.entitlements            │
│             ./myapp.tmp                                   │
├─────────────────────────────────────────────────────────┤
│ 7. mv ./myapp.tmp ./myapp                                │
│    rm ./myapp-arm64 ./myapp-x86_64                       │
│    lipo -info ./myapp  ← 验证                            │
└─────────────────────────────────────────────────────────┘
```

关键：步骤 2/3 **必须显式传 `--arch`**，不能依赖宿主机默认架构。本地 arm64 机器省略 `--arch` 时两次都会生成 arm64 slice，`lipo` 报 "same architecture" 错误（陷阱 3）。

### Pattern 5 · pnpm scripts 入口映射

`package.json:18-56` 完整 scripts 段：

| 场景 | pnpm 命令 | 底层调用 |
|------|----------|--------|
| 调试构建（swift build debug） | `pnpm run build:cli` | `swift build --package-path Apps/CLI` |
| arm64 release | `pnpm run build:swift` | `./scripts/build-swift-arm.sh` |
| Universal release | `pnpm run build:swift:all` | `./scripts/build-swift-universal.sh` |
| 启动 Poltergeist 守护 | `pnpm run poltergeist:haunt` | `poltergeist-wrapper.sh haunt` |
| 查看构建状态 | `pnpm run poltergeist:status` | `poltergeist-wrapper.sh status` |
| 查看日志 | `pnpm run poltergeist:logs` | `poltergeist-wrapper.sh logs` |
| 停止守护 | `pnpm run poltergeist:rest` | `poltergeist-wrapper.sh rest` |
| 调用最新产物 | `pnpm run peekaboo -- <args>` | `poltergeist-wrapper.sh peekaboo` |
| 安全测试 | `pnpm run test:safe` | `swift test -DPEEKABOO_SKIP_AUTOMATION --no-parallel` |

### Pattern 6 · 开发循环

```bash
# 启动 Poltergeist 守护（只需一次，常驻终端标签）
pnpm run poltergeist:haunt

# 编辑 Swift 文件 → Poltergeist 在后台自动增量构建
# 5 s debounce：连续保存只触发一次
# 构建完成后 status-swifttests.sh 自动验证（postBuild hook）

# 确认构建状态（无需等 Xcode GUI）
pnpm run poltergeist:status

# 前台直接调用最新 CLI 产物
pnpm run peekaboo -- screenshot --app Safari

# 收工
pnpm run poltergeist:rest
```

`poltergeist-wrapper.sh:34-38` 对 `peekaboo` 目标强制 PTY（`script -q /dev/null`），确保颜色输出正确，即使在 CI 或 pipe 中调用。

### Pattern 7 · ProcessWatcher / autoRelaunch 模式

对于 `.app` 目标，Poltergeist 的 `autoRelaunch: true` 会在每次成功构建后自动重启进程。这一"ProcessWatcher 模式"适用于：

- **ReplayD / 辅助进程**：构建完成 → `autoRelaunch` 触发 `kill`（graceful）+ 重启，无需手动 `killall MyApp`。
- **菜单栏 app debug 循环**：修改菜单栏代码 → Poltergeist 重建 → 自动弹出新版 app，前台始终是最新版本。
- **系统进程注意**：`autoRelaunch` 调用的是 `buildCommand` 产出的 `bundleId` 对应进程；若进程由 launchd 管理（如系统扩展），直接重启可能绕过 launchctl，导致进程僵尸（陷阱 5）。

可观测信号：`autoRelaunch` 触发时 `.poltergeist.log` 会记录 `Relaunching <bundleId>`；若重启静默失败（新进程未出现），先 `ps aux | grep <bundleId>` 确认旧进程是否已退出。

### Pattern 8 · xcworkspace 同时引用 xcodeproj + SPM 包

`Apps/Peekaboo.xcworkspace/contents.xcworkspacedata` 的完整结构模式：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <FileRef location="group:Mac/Peekaboo.xcodeproj" />   <!-- .app -->
  <FileRef location="group:CLI" />                        <!-- SPM 包目录 -->
  <FileRef location="group:Playground/Playground.xcodeproj" />
  <FileRef location="group:PeekabooInspector/Inspector.xcodeproj" />
</Workspace>
```

规则：
- `group:` 前缀表示相对于 `.xcworkspace` 所在目录（`Apps/`）的路径。
- 指向目录（`group:CLI`）等价于告诉 Xcode "这是一个 SPM 包根目录"，Xcode 自动解析其 `Package.swift`。
- 指向 `.xcodeproj` 文件（`group:Mac/Peekaboo.xcodeproj`）引入完整 Xcode 工程。
- workspace 本身不声明任何目标依赖，依赖关系由各 `.xcodeproj` 内的 `XCSwiftPackageProductDependency` 声明。

### Pattern 9 · Watchman 排除规则优化

`poltergeist.config.json:156-190` 的 `watchman` 段对性能至关重要：

```jsonc
"watchman": {
  "useDefaultExclusions": true,      // 默认排除 .build / DerivedData / node_modules
  "excludeDirs": [
    "coverage", "*.log",
    "tmp_screenshots", "test_output"
  ],
  "rules": [
    { "pattern": "**/*.xcuserstate", "action": "ignore" },  // Xcode 用户状态
    { "pattern": "**/Version.swift",  "action": "ignore" }  // 自动生成文件（构建时写入，否则循环触发）
  ]
}
```

`Version.swift` 规则至关重要：构建脚本会在每次 build 时写入 `Version.swift`，若不排除会形成"构建 → 文件变更 → 触发构建 → ..."死循环。

## 完整代码示例（Starter Code）

以下 7 个文件构成一个最小可运行的混合工程骨架，可直接拷进新项目。

### 1 · Package.swift（顶层 SwiftPM 包）

```swift
// swift-tools-version: 6.2
// 基线：macOS 14+，Xcode 16，pnpm 11，Poltergeist 1.x
// 依赖：AXorcist 0.1.2，swift-algorithms 1.2.x（可按需替换）

import PackageDescription

// ─── Swift 设置组（各层独立调优）───────────────────────────────────────────
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let foundationSettings = strictConcurrency + [
    .unsafeFlags(["-parse-as-library"]),
]

let protocolSettings = strictConcurrency + [
    .defaultIsolation(MainActor.self),
    // 调试阶段警告慢函数（>50ms 编译体检）
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=50",
        "-Xfrontend", "-warn-long-expression-type-checking=50",
    ], .when(configuration: .debug)),
]

let kitSettings = strictConcurrency + [
    .enableExperimentalFeature("SwiftTesting"),
    .unsafeFlags(["-parse-as-library"]),
]

let coreSettings = strictConcurrency + [
    .unsafeFlags(["-parse-as-library"]),
]

// ─── 包声明 ────────────────────────────────────────────────────────────────
let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v14)],

    products: [
        .library(name: "MyFoundation",     targets: ["MyFoundation"]),
        .library(name: "MyProtocols",      targets: ["MyProtocols"]),
        .library(name: "MyAutomationKit",  targets: ["MyAutomationKit"]),
        .library(name: "MyCore",           targets: ["MyCore"]),
    ],

    dependencies: [
        // 锁定版本以确保 CI 可复现构建
        .package(url: "https://github.com/steipete/AXorcist.git", exact: "0.1.2"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
    ],

    targets: [
        // 层 1：零依赖基础类型
        .target(
            name: "MyFoundation",
            dependencies: [],
            path: "Core/Foundation/Sources/MyFoundation",
            swiftSettings: foundationSettings),

        // 层 2：协议层（默认 @MainActor 隔离）
        .target(
            name: "MyProtocols",
            dependencies: ["MyFoundation"],
            path: "Core/Protocols/Sources/MyProtocols",
            swiftSettings: protocolSettings),

        // 层 3：自动化工具包（含外部依赖）
        .target(
            name: "MyAutomationKit",
            dependencies: [
                "MyFoundation",
                "MyProtocols",
                .product(name: "AXorcist",   package: "AXorcist"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            path: "Core/AutomationKit/Sources/MyAutomationKit",
            swiftSettings: kitSettings),

        // 层 4：CLI/App 共享胶水层
        .target(
            name: "MyCore",
            dependencies: ["MyAutomationKit", "MyFoundation"],
            path: "Core/MyCore/Sources/MyCore",
            swiftSettings: coreSettings),

        // 单元测试（不依赖系统权限）
        .testTarget(
            name: "MyFoundationTests",
            dependencies: ["MyFoundation"],
            path: "Core/Foundation/Tests"),
    ],
    swiftLanguageModes: [.v6]
)
```

### 2 · poltergeist.config.json（完整骨架）

```jsonc
{
  "version": "1.0",
  "projectType": "mixed",

  "targets": [
    // ── CLI 可执行 target ──────────────────────────────────────────────────
    {
      "name": "MyApp",
      "type": "executable",
      "enabled": true,
      "buildCommand": "./scripts/build-swift-debug.sh",
      "outputPath": "./myapp",
      "settlingDelay": 1000,
      "debounceInterval": 5000,
      "watchPaths": [
        "Core/**/*.swift",
        "Apps/CLI/**/*.swift"
        // 若有 git submodule：添加 "Submodules/AXorcist/**/*.swift" 等
      ],
      "postBuild": [
        {
          "name": "Swift tests",
          "command": "./scripts/run-safe-tests.sh",
          "runOn": "success",
          "timeoutSeconds": 900,
          "maxLines": 10
        }
      ]
    },

    // ── macOS .app target（Xcode 构建）────────────────────────────────────
    {
      "name": "MyApp.app",
      "type": "app-bundle",
      "platform": "macos",
      "enabled": true,
      "buildCommand": "./scripts/build-mac-debug.sh",
      "bundleId": "com.example.myapp.debug",
      "autoRelaunch": true,      // 成功后自动重启 .app（ProcessWatcher 模式）
      "settlingDelay": 4000,     // 比 CLI 高：Core 改动不立即触发 app rebuild
      "debounceInterval": 5000,
      "watchPaths": [
        "Apps/Mac/**/*.swift",
        "Apps/Mac/**/*.storyboard",
        "Apps/Mac/**/*.xib",
        "Apps/Mac/**/*.xcassets",
        "Apps/Mac/**/*.entitlements",
        "Apps/Mac/**/*.plist",
        "Core/**/*.swift"
      ]
    }
  ],

  // ── Watchman 全局排除（防止 .build / DerivedData 触发循环）────────────
  "watchman": {
    "useDefaultExclusions": true,
    "excludeDirs": ["coverage", "tmp_screenshots", "test_output"],
    "rules": [
      { "pattern": "**/*.xcuserstate",  "action": "ignore",
        "reason": "Xcode user state" },
      { "pattern": "**/Version.swift",  "action": "ignore",
        "reason": "Auto-generated; changes on every build → prevents loop" }
    ]
  },

  // ── 性能 ──────────────────────────────────────────────────────────────
  "performance": {
    "profile": "balanced",
    "autoOptimize": true
  },

  // ── 构建调度（串行队列，防 .build 目录竞争）───────────────────────────
  "buildScheduling": {
    "parallelization": 1,
    "prioritization": { "enabled": true }
  },

  "notifications": { "enabled": true },
  "logging": { "file": ".poltergeist.log", "level": "debug" }
}
```

### 3 · Apps/MyApp.xcworkspace/contents.xcworkspacedata

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <!-- .app Xcode 工程（含 entitlements / Run Script Phase / assets） -->
  <FileRef location="group:Mac/MyApp.xcodeproj" />
  <!-- SwiftPM CLI 包目录（Xcode 自动解析其 Package.swift） -->
  <FileRef location="group:CLI" />
</Workspace>
```

创建方式：在 Finder 新建目录 `Apps/MyApp.xcworkspace`，手写或用 Xcode File → New → Workspace 后添加引用。

### 4 · scripts/build-universal.sh（完整 bash）

```bash
#!/usr/bin/env bash
# build-universal.sh — 基线：macOS 14+，Xcode 16，Swift 6.2
# 产出：项目根目录 ./myapp（Universal Binary，signed，stripped）
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_PATH="$PROJECT_ROOT/Apps/CLI"
BINARY_NAME="myapp"
FINAL="$PROJECT_ROOT/$BINARY_NAME"
ARM64="$PROJECT_ROOT/${BINARY_NAME}-arm64"
X86="$PROJECT_ROOT/${BINARY_NAME}-x86_64"
ENTITLEMENTS="$CLI_PATH/Sources/Resources/myapp.entitlements"

# 可通过环境变量覆盖（CI 场景）
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
# -Osize: 大小优先，WMO 默认关闭（Swift 6.3.x 偶发 release build 挂起）
OPT_FLAGS="${SWIFT_OPTIMIZATION_FLAGS:--Xswiftc -Osize -Xlinker -dead_strip}"

# ── 1. 解析签名证书 ────────────────────────────────────────────────────────
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
    if [[ -z "$SIGN_IDENTITY" ]]; then
        # 回退：取第一个有效证书
        SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
            | sed -n 's/.*"\(.*\)"/\1/p' | head -n1)"
    fi
    [[ -n "$SIGN_IDENTITY" ]] || { echo "ERROR: No codesigning identity found" >&2; exit 1; }
fi

# Developer ID Application → 生产分发（需公证），否则用 none（本地测试）
TIMESTAMP_ARG="--timestamp=none"
[[ "$SIGN_IDENTITY" == *"Developer ID Application"* ]] && TIMESTAMP_ARG="--timestamp"

# ── 2. 清理（两次 swift build 必须干净起步，否则 lipo 报 same-arch）───────
echo "==> Cleaning..."
(cd "$CLI_PATH" && swift package reset) || rm -rf "$CLI_PATH/.build"
rm -f "$ARM64" "$X86" "${FINAL}.tmp"

# ── 3. 读取版本（可选，按需保留）─────────────────────────────────────────
VERSION="$(node -p "require('$PROJECT_ROOT/version.json').version" 2>/dev/null || echo "dev")"
echo "==> Version: $VERSION"

# ── 4. 编译 arm64 ────────────────────────────────────────────────────────
echo "==> Building arm64..."
(cd "$CLI_PATH" && swift build --arch arm64 -c release $OPT_FLAGS)
cp "$CLI_PATH/.build/arm64-apple-macosx/release/$BINARY_NAME" "$ARM64"

# ── 5. 编译 x86_64 ───────────────────────────────────────────────────────
echo "==> Building x86_64..."
(cd "$CLI_PATH" && swift build --arch x86_64 -c release $OPT_FLAGS)
cp "$CLI_PATH/.build/x86_64-apple-macosx/release/$BINARY_NAME" "$X86"

# ── 6. lipo 合成 ─────────────────────────────────────────────────────────
echo "==> Merging with lipo..."
lipo -create -output "${FINAL}.tmp" "$ARM64" "$X86"

# ── 7. strip（调试符号 + 非全局符号，保留未定义符号引用）─────────────────
echo "==> Stripping symbols..."
strip -Sxu "${FINAL}.tmp"

# ── 8. codesign ──────────────────────────────────────────────────────────
echo "==> Signing with: $SIGN_IDENTITY"
codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    $TIMESTAMP_ARG \
    --identifier "com.example.myapp" \
    --entitlements "$ENTITLEMENTS" \
    "${FINAL}.tmp"

# ── 9. 验证 + 替换 ────────────────────────────────────────────────────────
codesign --verify --strict "${FINAL}.tmp" && echo "==> Signature OK"
mv "${FINAL}.tmp" "$FINAL"
rm -f "$ARM64" "$X86"

echo "==> Done:"
lipo -info "$FINAL"
ls -lh  "$FINAL"
```

### 5 · scripts/poltergeist-wrapper.sh（完整 bash）

```bash
#!/usr/bin/env bash
# poltergeist-wrapper.sh — 统一 Poltergeist 入口
# 区分守护命令（haunt/status/logs）与前台 polter 调用（peekaboo/myapp）
# 基线：Poltergeist 1.x（与 Peekaboo 同仓库的 ../poltergeist 目录）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

POLTER_DIR="$(cd "$PROJECT_DIR/../poltergeist" && pwd)"
CLI_TS="$POLTER_DIR/src/cli.ts"
POLTER_TS="$POLTER_DIR/src/polter.ts"

export NODE_PATH="${NODE_PATH:-$POLTER_DIR/node_modules}"

COMMAND="${1:-}"
IS_DAEMON_CMD=false

case "$COMMAND" in
  daemon|start|haunt|stop|rest|restart|pause|resume|\
  status|logs|wait|panel|project|init|list|clean|version|polter|-h|--help|"")
    IS_DAEMON_CMD=true
    ;;
esac

# 前台 target 调用：强制 PTY（确保 ANSI/颜色输出正确）
if ! $IS_DAEMON_CMD && [[ "$COMMAND" == "myapp" ]] && [[ -z "$WRAPPER_PTY" ]]; then
    if command -v script >/dev/null 2>&1; then
        export WRAPPER_PTY=1
        exec script -q /dev/null "$0" "$@"
    fi
fi

if $IS_DAEMON_CMD; then
    # 自动注入 --config（允许从任意 cwd 调用）
    ADD_CONFIG=true
    for arg in "$@"; do
        case "$arg" in -c|--config|--config=*) ADD_CONFIG=false ;; esac
    done
    $ADD_CONFIG && set -- "$@" --config "$PROJECT_DIR/poltergeist.config.json"

    # panel 子命令使用 --watch 模式（tsx --watch）
    if [[ "$1" == "panel" ]] || { [[ "$1" == "status" ]] && [[ "$2" == "panel" ]]; }; then
        exec pnpm --dir "$POLTER_DIR" exec tsx --watch "$CLI_TS" "$@"
    else
        exec pnpm --dir "$POLTER_DIR" exec tsx "$CLI_TS" "$@"
    fi
else
    # 前台 polter 调用（等待构建完成后执行 outputPath 中的产物）
    TSX="$POLTER_DIR/node_modules/.bin/tsx"
    if [[ -x "$TSX" ]]; then
        exec "$TSX" "$POLTER_TS" "$@"
    else
        exec pnpm --dir "$POLTER_DIR" exec tsx "$POLTER_TS" "$@"
    fi
fi
```

### 6 · package.json scripts 段（完整）

```jsonc
{
  "name": "my-macos-app",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22.0.0" },
  "scripts": {
    // ── Swift 构建 ─────────────────────────────────────────────────────
    "build:cli":         "swift build --package-path Apps/CLI",
    "build:cli:release": "swift build --configuration release --package-path Apps/CLI",
    "build:swift":       "./scripts/build-swift-arm.sh",
    "build:swift:all":   "./scripts/build-universal.sh",
    "build":             "pnpm run build:cli",

    // ── 测试（分级 gating，详见 playbook 12）───────────────────────────
    "test:safe":          "swift test --package-path Apps/CLI -Xswiftc -DMYAPP_SKIP_AUTOMATION --no-parallel",
    "test:automation":    "MYAPP_INCLUDE_AUTOMATION_TESTS=true swift test --package-path Apps/CLI --no-parallel",
    "test":               "pnpm run test:safe",

    // ── Lint / Format ──────────────────────────────────────────────────
    "lint:swift":  "swiftlint lint --config .swiftlint.yml",
    "lint":        "pnpm run lint:swift",
    "format:swift":"swiftformat .",
    "format":      "pnpm run format:swift",

    // ── Poltergeist 守护 ───────────────────────────────────────────────
    "poltergeist:haunt":  "./scripts/poltergeist-wrapper.sh haunt",
    "poltergeist:status": "./scripts/poltergeist-wrapper.sh status",
    "poltergeist:logs":   "./scripts/poltergeist-wrapper.sh logs",
    "poltergeist:rest":   "./scripts/poltergeist-wrapper.sh rest",

    // ── 前台调用最新产物 ───────────────────────────────────────────────
    "myapp": "FORCE_COLOR=1 CLICOLOR_FORCE=1 script -q /dev/null ./scripts/poltergeist-wrapper.sh myapp",

    // ── 其他 ───────────────────────────────────────────────────────────
    "postinstall": "chmod +x myapp 2>/dev/null || true"
  }
}
```

### 7 · scripts/build-swift-debug.sh（调试构建，供 Poltergeist 调用）

```bash
#!/usr/bin/env bash
# build-swift-debug.sh — Poltergeist buildCommand 入口（调试构建）
# 不做 strip/codesign，只求速度；outputPath = 项目根 ./myapp
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_PATH="$PROJECT_ROOT/Apps/CLI"
BINARY_NAME="myapp"

echo "==> Debug build (arm64, debug config)..."
(cd "$CLI_PATH" && swift build --arch arm64)
cp "$CLI_PATH/.build/arm64-apple-macosx/debug/$BINARY_NAME" \
   "$PROJECT_ROOT/$BINARY_NAME"
echo "==> Done: $PROJECT_ROOT/$BINARY_NAME"
```

> **Starter Code 行数合计：约 290 行**（7 个文件，含注释）

## 新项目落地步骤（How to apply）

**前置条件**：macOS 14+，Xcode 16，Swift 6.2，pnpm 11（`corepack enable pnpm`），Watchman（`brew install watchman`）。

1. **初始化 SPM 包**：`swift package init --type library --name MyApp` 在项目根目录创建顶层 `Package.swift`；按 Pattern 2 的四层结构在 `Core/` 下建立子目录，修改 `Package.swift` 的 `path:` 字段指向各子目录。

2. **创建 Xcode 工程**：在 Xcode 中 File → New → Project 创建 macOS App 工程，保存到 `Apps/Mac/MyApp.xcodeproj`；在 Project Settings → Signing & Capabilities 中添加所需 entitlements（Screen Recording、Accessibility 等）。

3. **创建 workspace 并聚合**：新建目录 `Apps/MyApp.xcworkspace`，写入 `contents.xcworkspacedata`（参考 Pattern 8 / Starter Code 第 3 节）；在 Xcode 中打开 workspace，验证 `.xcodeproj` 和 SPM 包目录均可见；通过 File → Add Package Dependencies 将根目录 `Package.swift` 作为本地包添加到 Xcode 工程。

4. **安装并配置 Poltergeist**：Clone Poltergeist 到 `../poltergeist`（与项目同级目录）；`cd ../poltergeist && pnpm install`；将 Starter Code 第 2 节的 `poltergeist.config.json` 复制到项目根目录并调整 `watchPaths` 和 `buildCommand`。

5. **编写构建脚本**：复制 Starter Code 第 4 节（`build-universal.sh`）、第 7 节（`build-swift-debug.sh`）到 `scripts/` 目录；`chmod +x scripts/*.sh`；调整 `BINARY_NAME`、`ENTITLEMENTS` 路径、`bundleId`；本地测试 `./scripts/build-swift-debug.sh` 能产出 `./myapp`。

6. **配置 pnpm scripts**：复制 Starter Code 第 6 节的 `package.json scripts` 段；`pnpm install` 确认 devDependencies 安装；运行 `pnpm run build:cli` 验证调试构建通过；`pnpm run test:safe` 验证单元测试通过。

7. **启动 Poltergeist 并验证增量构建**：`pnpm run poltergeist:haunt`；修改任一 Swift 文件；等待 5 s debounce 后观察 `pnpm run poltergeist:status` 输出；确认 `./myapp` 时间戳刷新；`pnpm run myapp -- --version` 验证能调用最新产物。

8. **验证 Universal Binary**：运行 `pnpm run build:swift:all`；`lipo -info ./myapp` 输出应包含 `arm64 x86_64`；`lipo -verify_arch arm64 ./myapp && lipo -verify_arch x86_64 ./myapp`（无输出 = 通过）；`codesign --verify --strict -vvvv ./myapp` 确认签名有效。

9. **收紧 watchPaths**：根据实际改动频率，确认 `poltergeist.config.json` 的 `watchPaths` 仅覆盖**该 target 真正关心的文件**（Core 修改影响所有 target → 全部监听；仅 app UI 文件 → 只有 app target 监听）；参考 `docs/poltergeist.md` 的 "Rebuild Triggers & Watch Paths" 段调优。

10. **CI 集成**：CI 环境不运行 Poltergeist（无守护需求），直接调用 `pnpm run build:swift:all`（Universal）或 `pnpm run build:swift`（arm64 only）；测试用 `pnpm run test:safe`（不需要系统权限）；权限敏感测试用 `MYAPP_INCLUDE_AUTOMATION_TESTS=true pnpm run test:automation`（macOS runner 且已授权）；详见 [12 · 测试策略](./12-testing-permission-gated.md)。

## 替代方案对比（When NOT to use）

| 方案 | 适用场景 | 优势 | 劣势 | 本方案 fail 时降级到 |
|------|---------|-----|------|---------------------|
| **本方案** SwiftPM + xcodeproj + Poltergeist + pnpm | 混合 CLI + .app；需 Universal Binary；团队多人 | 增量快、依赖管理干净、pnpm 统一入口 | 需要 Poltergeist（Node + Watchman）；上手成本略高 | — |
| **纯 swift build** | CLI/library only；无 GUI；CI 简洁 | 零额外工具；`swift build` 单命令；SwiftPM 依赖管理原生 | 无法构建 `.app`（无 entitlements/assets/Run Script）；无 Poltergeist 监听 | 若项目无 `.app` target 改用此方案 |
| **纯 xcodebuild** | 完整 Apple 生态；App Store 提交；复杂 scheme | Apple 官方支持；Xcode Organizer 集成；证书/entitlements/notarize 原生 | `project.pbxproj` diff 噪音重；增量构建依赖 Xcode GUI；CI 命令繁琐（需传大量 `-destination`）；SPM 依赖管理弱 | 若必须走 App Store，保留 xcodeproj，移除 Poltergeist，用 xcodebuild + fastlane |
| **Bazel** | 大型多语言 monorepo（Swift + ObjC + C++）；严格 hermetic build | 完全 hermetic；可复现；跨语言共享缓存；远程缓存 | 学习成本极高；Bazel Swift rules 支持落后（`rules_swift` 常滞后 swift-tools-version）；macOS .app 构建配置复杂；社区小 | 若仓库超过 10 个 Swift 模块且有 C++/Rust 混合，考虑 Bazel（但预留 2-4 周迁移） |
| **Tuist** | 中型 iOS/macOS 工程；团队觉得 `project.pbxproj` 维护难 | 用 Swift DSL 生成 `.xcodeproj`，diff 干净；内置依赖图可视化；`tuist generate` 一键重建 | 需要额外学习 Tuist DSL（与 SwiftPM 不同语法）；Xcode 升级时 Tuist 可能滞后；与 SPM 包的本地引用配合有时需要 workaround | 若 `project.pbxproj` merge conflict 成常见痛点，且不想引入 Poltergeist/Node，用 Tuist 替代混合方案 |
| **Buck2** | Meta 内部 / 多语言 monorepo | 速度极快；Meta 维护 | Swift 一等支持弱；macOS app bundle 构建规则不成熟；社区极小；文档少 | 基本不推荐 macOS app 场景 |

**决策树**：

```
需要 .app bundle（entitlements/assets/签名）？
├── 否 → 纯 swift build（最简单）
└── 是
    ├── 需要 Universal Binary（支持 Intel Mac）？
    │   └── 是 → 本方案（build-universal.sh + lipo）
    │       否 → 本方案但跳过 build-swift:all
    ├── 团队 > 5 人 且 pbxproj 冲突频繁？
    │   └── 考虑 Tuist 生成 xcodeproj
    └── 多语言 monorepo（Swift + C++ + Rust）？
        └── 考虑 Bazel（接受 2-4 周上手成本）
```

## 调试与取证（Debug & Forensics）

| 症状 | 命令 | 根因 |
|------|------|------|
| Xcode 看不到 Package.swift 改动（新 target 不出现、补全仍报旧错） | `rm -rf ~/Library/Developer/Xcode/DerivedData/<ProjectName>-*/SourcePackages/` 后重新打开 workspace；或 Xcode → File → Packages → Reset Package Caches | Xcode 把 SPM 解析结果缓存在 DerivedData；`.xcworkspace` 哈希未变时不重新 resolve |
| `swift build` 报循环依赖 | `swift package show-dependencies --format json \| python3 -m json.tool` | 依赖图中存在循环；逐层检查 `Package.swift` 的 `dependencies:` 字段 |
| `swift package resolve` 失败 / 网络超时 | `swift package reset && swift package resolve` 重新拉取；或 `swift package show-dependencies` 确认 exact 版本存在 | 本地 `.build/checkouts` 缓存损坏；版本号不存在 |
| Poltergeist 不触发构建（修改文件后 status 仍 idle） | `pnpm run poltergeist:status` 查看 Watchman 状态；`watchman watch-list` 确认项目目录已注册；`watchman shutdown-server && pnpm run poltergeist:haunt` 重启 | Watchman 进程崩溃 / socket 丢失；或 glob 模式不匹配修改的文件扩展名 |
| Poltergeist 频繁误触发（每隔几秒就重新构建） | `pnpm run poltergeist:logs \| grep "ChangedFile"` 查看触发文件；检查 `poltergeist.config.json` 的 `rules` 是否排除了 `Version.swift` / `.xcuserstate` | settleDelay 太短；或 glob 覆盖了构建产物（如未排除 `.build/**`） |
| `lipo` 报 "file is the same architecture (arm64) as ..." | `file .build/arm64-apple-macosx/release/myapp`（确认两个 slice 确实都是 arm64）；检查 `build-universal.sh` 是否两次都传了 `--arch` | 两次 `swift build` 未清理 `.build` 目录，第二次复用了 arm64 缓存；本地 arm64 机器省略 `--arch` 时两次都生成 arm64 |
| Universal Binary 无法在目标机器运行 | `codesign --verify --strict -vvvv ./myapp`；`codesign -d --entitlements - ./myapp` 查看嵌入的 entitlements | codesign 缺少 `--entitlements` 或 entitlements 文件路径错误；`--options runtime` 缺失（公证要求 Hardened Runtime） |
| `codesign -d --entitlements -` 显示 entitlements 不完整 | `security find-identity -p codesigning -v` 确认证书有效；`cat Apps/CLI/Sources/Resources/myapp.entitlements` 检查文件内容 | entitlements 文件路径在 build script 中配置错误；或证书已过期 |
| Xcode 提示 entitlements 不匹配 bundle ID | `defaults read com.apple.dt.xcode` 查看 Xcode 设置；检查 xcodeproj 的 `PRODUCT_BUNDLE_IDENTIFIER` 与 entitlements 文件名是否一致 | `code signing entitlements` 文件路径 Build Setting 配置错误 |
| CI 中 `swift test` 卡住不退出 | 检查是否设置了 `MYAPP_SKIP_AUTOMATION` 环境变量；改用 `pnpm run test:safe`；参见 `package.json:26` | 自动化测试尝试使用 Screen Recording / Accessibility，CI 无权限时挂起等待授权弹窗 |
| Poltergeist `haunt` 后没有 `rest`，Watchman 留 zombie | `ps aux \| grep watchman`（出现多个独立进程而非单一 daemon） → `watchman shutdown-server`；再 `pnpm run poltergeist:haunt` 重新启动 | 每次 `haunt` 若前一个 daemon 未正确退出，Watchman 进程会叠加；多个 daemon 会重复触发构建 |
| `strip -Sxu` 漏跑导致 debug symbols 泄漏到发布包 | `nm ./myapp \| grep " d " \| head -20`（有输出 = 含 debug 符号）；`otool -l ./myapp \| grep -A3 LC_UUID` 查看 UUID | `build-universal.sh` 中 `strip` 步骤在 `codesign` 之后运行（顺序错误会导致签名失效）；或 `strip` 命令缺少 `-Sxu` 参数 |
| `xcodebuild` 构建失败但错误信息不清晰 | `xcodebuild -showBuildSettings -workspace Apps/MyApp.xcworkspace -scheme MyApp` 查看所有 Build Settings；`xcodebuild ... 2>&1 \| xcbeautify` 格式化输出 | xcodeproj 的 SPM 依赖未正确 resolve；或 scheme 名称拼写不一致 |

**调试工具速查**：

```bash
# SPM 依赖图
swift package show-dependencies                # 树形视图
swift package show-dependencies --format json  # JSON（机器可读）
swift package describe --type json             # 包描述（含 target 列表）

# 清理 SPM 缓存
swift package clean    # 清理 .build（保留 checkouts）
swift package reset    # 清理 .build + checkouts（重新 resolve 所有依赖）

# Poltergeist 状态
pnpm run poltergeist:status         # 当前构建状态
pnpm run poltergeist:logs           # 实时日志流
pnpm run poltergeist:logs -- --filter "error"  # 过滤错误

# Watchman 诊断
watchman watch-list                  # 已注册的 watch 目录
watchman shutdown-server             # 强制重启 Watchman daemon
watchman clock <project-path>        # 当前 clock（用于 debug 订阅延迟）
watchman log-level debug             # 开启 debug 日志

# Binary 验证
file ./myapp                         # 基本架构检查
lipo -info ./myapp                   # Universal Binary slice 列表
lipo -verify_arch arm64 ./myapp      # 验证 arm64 slice 存在（无输出 = OK）
lipo -verify_arch x86_64 ./myapp     # 验证 x86_64 slice 存在
nm ./myapp | grep " d " | head -20   # 检查 debug 符号

# 代码签名验证
codesign --verify --strict -vvvv ./myapp          # 完整签名验证
codesign -d --entitlements - ./myapp              # 查看嵌入的 entitlements
codesign -dv --verbose=4 ./myapp                  # 详细签名信息
spctl --assess --type execute -vvvv ./myapp       # Gatekeeper 评估（需 Developer ID）

# Xcode 构建信息
xcodebuild -showBuildSettings -workspace Apps/MyApp.xcworkspace -scheme MyApp
xcodebuild -list -workspace Apps/MyApp.xcworkspace  # 列出所有 scheme
```

## 常见陷阱（Pitfalls）

**陷阱 1：Xcode DerivedData 缓存导致 Package.swift 改动不生效**

- **可观测信号**：修改了 `Package.swift`（新增 target 或改依赖版本），命令行 `swift build` 已看到变化，但 Xcode 补全/构建仍报旧错误，或新 target 不出现在 scheme 列表。
- **原因**：Xcode 把 SPM 解析结果缓存在 `DerivedData/<项目名>-*/SourcePackages/`；`.xcworkspace` 哈希未变时不重新 resolve（与命令行 `swift build` 独立的缓存路径）。
- **处理**：`rm -rf ~/Library/Developer/Xcode/DerivedData/<项目名>-*/SourcePackages/` 后重新打开 workspace；或 Xcode → File → Packages → Reset Package Caches。CLI 路径不受影响。
- **来源**：`Apps/Peekaboo.xcworkspace` 实际开发中反复触发，尤其升级 AXorcist 等 git submodule 版本时。

**陷阱 2：Poltergeist watchPaths 漏掉非 `.swift` 文件**

- **可观测信号**：修改 `.plist`、`.entitlements`、`.storyboard` 后 `poltergeist:status` 显示 idle，构建未触发，但手动 `pnpm run build:cli` 能正常生效。
- **原因**：`watchPaths` 的 glob 仅覆盖 `**/*.swift`；Poltergeist 不感知其他扩展名（`poltergeist.config.json:14-21` CLI target 有意只覆盖 `.swift`）。
- **处理**：在对应 target 的 `watchPaths` 中追加所需 glob；参考 `poltergeist.config.json:91-100` 中 `Peekaboo.app` target 额外覆盖 `*.storyboard`、`*.xib`、`*.plist`、`*.xcassets`、`*.entitlements` 的做法。

**陷阱 3：lipo 报 "file is the same architecture" 导致 Universal 构建失败**

- **可观测信号**：`lipo: ./myapp-arm64 file is the same architecture (arm64) as ./myapp-x86_64`。
- **原因**：两次 `swift build` 共享 `.build` 目录，第二次因缓存复用了 arm64 产物，两个 slice 架构相同。本地 arm64 机器省略 `--arch` 时两次都生成 arm64，只在 CI 或显式测试时才暴露（`scripts/build-swift-universal.sh:131-143` 每次都传 `--arch`，规避此问题）。
- **处理**：确保 `build-universal.sh` 在每次调用时先执行 `swift package reset && rm -rf .build`，然后分别显式传 `--arch arm64` / `--arch x86_64`。

**陷阱 4：双重产物路径混淆**

- **可观测信号**：`pnpm run build:cli` 产物在 `Apps/CLI/.build/debug/myapp`，`build:swift:all` 输出到根目录 `./myapp`；`polter myapp` 可能调用到旧的调试产物，版本号未更新但没有错误提示。
- **处理**：统一通过 `pnpm run myapp -- <args>` 调用（经 `poltergeist-wrapper.sh` 路由），始终使用 `poltergeist.config.json` 中 `outputPath: ./myapp` 指定的产物；不要直接 `./Apps/CLI/.build/debug/myapp <args>`。

**陷阱 5：`poltergeist haunt` 后忘记 `rest`，Watchman 留 zombie**

- **可观测信号**：`ps aux | grep watchman` 输出多个独立 watchman 进程（正常应只有一个 daemon）；或 `poltergeist:status` 报告同一文件变更触发了两次构建。
- **原因**：每次 `haunt` 若前一个 daemon 未正确退出（如强制 Ctrl+C），Watchman 订阅会叠加；多个订阅相同路径导致每次文件变更触发多次 build。
- **处理**：`watchman shutdown-server` 强制停止所有 Watchman 进程，然后 `pnpm run poltergeist:haunt` 重新启动；养成收工执行 `pnpm run poltergeist:rest` 的习惯（等价于 `poltergeist-wrapper.sh rest`）。

**陷阱 6：`strip -Sxu` 漏跑或顺序错误导致 debug symbols 泄漏 / 签名失效**

- **可观测信号（符号泄漏）**：`nm ./myapp | grep " d " | head -20` 有输出（`d` = debug 符号）；`ls -lh ./myapp` 显示文件体积异常大（含 dwarf debug info 时可达正常的 3-5 倍）。
- **可观测信号（签名失效）**：`codesign --verify ./myapp` 报 "code object is not signed at all" 或 "modified/invalid"；通常因为在 `codesign` 之后运行了 `strip`，strip 改写了 binary 导致签名失效。
- **正确顺序**：`lipo -create` → `strip -Sxu` → `codesign`（必须在 strip 之后签名，不能反过来）。参见 `scripts/build-swift-universal.sh:145-165`。

## 延伸阅读

- **Peekaboo 文档**：`docs/poltergeist.md`（tuning 指南，含 watch path 优化建议）、`docs/building.md`（构建快速入门）、`poltergeist.config.json`（完整生产配置）
- **本 playbook 集**：[01 · 模块划分与依赖方向](./01-module-layout.md)（SwiftPM 多模块边界）、[09 · SwiftUI + AppKit + Liquid Glass](./09-swiftui-appkit-liquid-glass.md)（workspace 里如何混 xcodeproj app 与 SwiftPM 包）、[12 · 测试策略 + 权限敏感测试 gating](./12-testing-permission-gated.md)（`test:safe` / `test:automation` 分级）
- **Apple 官方**：
  - [Swift Package Manager](https://www.swift.org/package-manager/) — 官方文档
  - [Xcode Workspace](https://developer.apple.com/documentation/xcode/creating-a-workspace) — workspace 创建指南
  - [Distributing your app outside the Mac App Store](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — Developer ID 公证流程
  - [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) — entitlements 与 codesign `--options runtime`
- **工具**：
  - [Poltergeist GitHub](https://github.com/steipete/poltergeist) — Peekaboo 作者写的 Watchman-backed 增量构建工具
  - [Watchman](https://facebook.github.io/watchman/) — Facebook 出品，Poltergeist 的底层文件监听引擎
  - [xcbeautify](https://github.com/tuist/xcbeautify) — xcodebuild 输出格式化（`scripts/build-swift-universal.sh` 可选依赖）

---
*Last verified against Peekaboo @ `14c09283`*
