---
summary: 'Combine SwiftPM packages and an Xcode workspace with Poltergeist watch-builds and lipo universal binaries for fast iteration.'
read_when:
  - 'setting up a mixed SwiftPM and Xcode project with a shared workspace'
  - 'speeding up iterative builds or creating a Universal Binary release artifact'
---

# 11 · SwiftPM + Xcode workspace + Poltergeist 增量构建

## TL;DR

混合 macOS 工程通常同时包含纯 SwiftPM 包（库和 CLI）与 Xcode 工程（带 entitlements 的 .app），二者放进同一 `.xcworkspace` 以便 Xcode 看到所有目标。Poltergeist 在后台监听文件变化、按 debounce 触发增量构建，前台通过 `polter` 命令直接调用最新产物，消除手工 build 等待。发布阶段用 `lipo` 把 arm64 与 x86_64 产物合成 Universal Binary，再统一签名。整套流程以 pnpm 作为任务运行器对外暴露统一入口，降低记忆负担。

## Peekaboo 在哪里实现

- 配置文件：`Package.swift`、`poltergeist.config.json`、`scripts/build-swift-*.sh`、`Apps/Peekaboo.xcworkspace`
- 关键文件：`Package.swift:32-88` — 顶层 SwiftPM 包声明，四个 library 目标形成线性依赖链（Foundation → Protocols → AutomationKit → Bridge）
- 关键文件：`poltergeist.config.json:4-101` — 多目标监听配置，`Peekaboo` 目标对 `Core/**/*.swift` 等六条 glob 增量触发 `build-swift-debug.sh`
- 关键文件：`scripts/build-swift-universal.sh:129-146` — arm64 + x86_64 分别编译后执行 `lipo -create` 合成 Universal Binary
- 关键文件：`Apps/Peekaboo.xcworkspace/contents.xcworkspacedata:1-16` — workspace 把 `Mac/Peekaboo.xcodeproj`、`CLI`（SwiftPM）、`Playground.xcodeproj`、`Inspector.xcodeproj` 聚合为单一 Xcode 工作区
- 关键文件：`scripts/poltergeist-wrapper.sh:26-68` — 统一入口，区分 daemon 子命令与 `polter peekaboo` 前台调用路径
- 相关 docs：`docs/poltergeist.md`、`docs/building.md`

## 设计动机（Why）

CLI 适合纯 SwiftPM：`swift build` 快、CI 友好。但 macOS .app 需要 entitlements、自定义 Run Script Phase、代码签名等 Xcode 专属能力。把二者放进同一 `.xcworkspace`，Xcode 共享索引与补全，构建流程仍各自独立。

开发痛点在于"改完等编译"。Poltergeist（基于 Watchman）在后台监听，文件落定后自动增量构建；`polter peekaboo` 只在 CLI target 完成后执行，前台始终拿到最新产物。

分发时需要同时支持 Apple Silicon 与 Intel，因此两次 `swift build --arch` 编译后用 `lipo -create` 合成 Universal Binary，统一签名一次。

## 核心模式（Pattern）

### 1. 混合工作区目标组织

```
Apps/Peekaboo.xcworkspace
├── Mac/Peekaboo.xcodeproj      # 菜单栏 .app（Xcode scheme）
├── CLI/                         # SwiftPM 包（swift build）
├── Playground/Playground.xcodeproj
└── PeekabooInspector/Inspector.xcodeproj
```

SwiftPM 包内的 library 目标被 xcodeproj 通过 `package` 依赖引用；workspace 层只负责聚合，不重复声明依赖。

### 2. SwiftPM target 依赖链

```
PeekabooFoundation
  └── PeekabooProtocols
        └── PeekabooAutomationKit   (+ AXorcist, swift-algorithms)
              └── PeekabooBridge
```

每层仅对直接上游依赖；`Package.swift:55-87` 通过 `path:` 指向 `Core/` 子目录，与 Xcode 工程代码严格分离。

### 3. Poltergeist 监听与增量构建

`poltergeist.config.json` 的核心字段：

```jsonc
{
  "targets": [{
    "name": "Peekaboo",
    "type": "executable",
    "buildCommand": "./scripts/build-swift-debug.sh",
    "outputPath": "./peekaboo",
    "debounceInterval": 5000,      // 5 s 防抖，批量保存只触发一次
    "settlingDelay": 1000,         // 文件系统稳定等待
    "watchPaths": [
      "Core/**/*.swift",
      "AXorcist/**/*.swift",
      "Apps/CLI/**/*.swift"
      // ...其余 submodule 路径
    ]
  }],
  "buildScheduling": { "parallelization": 1 }  // 串行队列
}
```

`parallelization: 1` 确保 CLI target 完成后 mac target 才启动，避免共享 `.build` 目录竞争写入。

### 4. Universal Binary 合成（lipo）

`scripts/build-swift-universal.sh` 的关键流程（第 129-146 行）：

```bash
swift build --arch arm64   -c release ...
swift build --arch x86_64  -c release ...
lipo -create -output "$FINAL_BINARY_PATH.tmp" \
     "$ARM64_BINARY_TEMP" "$X86_64_BINARY_TEMP"
strip -Sxu "$FINAL_BINARY_PATH.tmp"
codesign --force --sign "$SIGN_IDENTITY" ...
```

arm64 slice 路径：`.build/arm64-apple-macosx/release/peekaboo`；x86_64 slice：`.build/x86_64-apple-macosx/release/peekaboo`。两个 slice **必须来自独立的 `--arch` 调用**，不能重用同一 `.build` 目录。

### 5. 开发循环

```bash
pnpm run poltergeist:haunt   # 启动后台守护，开始监听
# 正常编辑 Swift 文件 → Poltergeist 自动增量构建
pnpm run poltergeist:status  # 确认构建成功
pnpm run poltergeist:rest    # 收工时停止守护

# 前台直接调用 CLI（等待当前构建完成后执行）
pnpm run peekaboo -- screenshot --app Safari
```

`package.json:47` 中 `peekaboo` 脚本通过 `poltergeist-wrapper.sh peekaboo` 路由到 Poltergeist 的 `polter` 入口，保证每次调用都拿到最新产物。

### 6. pnpm 作为统一任务运行器

| 场景 | 命令 |
|------|------|
| 调试构建 | `pnpm run build:cli` |
| arm64 发布 | `pnpm run build:swift` |
| Universal 发布 | `pnpm run build:swift:all` |
| 启动监听 | `pnpm run poltergeist:haunt` |
| 查看状态 | `pnpm run poltergeist:status` |
| 运行测试 | `pnpm run test:safe` |

所有构建入口集中在 `package.json:18-56`，团队成员无需记忆 Swift 命令行细节。

## 新项目落地步骤（How to apply）

1. 用 `swift package init` 创建 SwiftPM 包作为共享库；将 .xcodeproj 放在同级目录，通过 `Package.swift` 的 `.package(path:)` 依赖本地 SwiftPM 包。
2. 创建 `YourProject.xcworkspace`，在 `contents.xcworkspacedata` 中用 `<FileRef location="group:...">` 同时引用 `.xcodeproj` 和 SwiftPM 目录；用 Xcode 菜单 File → Add Package Dependencies 添加本地包验证引用正确。
3. 编写 `poltergeist.config.json`：为 CLI target 配置 `watchPaths`（仅覆盖该 target 实际需要的 Swift 文件），设置 `debounceInterval`（建议 3000-5000 ms），`buildScheduling.parallelization` 设为 `1`。
4. 编写 `scripts/build-swift-debug.sh`（调试）和 `scripts/build-swift-universal.sh`（发布）；Universal 脚本中先后执行 `--arch arm64` 和 `--arch x86_64`，最后 `lipo -create` 合成，再统一 `codesign`。
5. 在 `package.json` 的 `scripts` 中注册 `poltergeist:haunt`、`poltergeist:status`、`poltergeist:rest`、`build:cli`、`build:swift:all` 等入口，通过包装脚本屏蔽路径细节。

## 常见陷阱（Pitfalls）

**陷阱 1：Xcode 工程缓存导致 Package.swift 改动不生效**

- 可观测信号：修改了 `Package.swift`（新增目标或改依赖版本），`swift build` 命令行已能看到变化，但 Xcode 中代码补全/构建仍报旧错误，或新 target 不出现在 scheme 列表里。
- 原因：Xcode 把 SwiftPM 解析结果缓存在 `DerivedData` 下；工程文件哈希未变时不会重新 resolve。
- 处理：在 Xcode 中执行 File → Packages → Reset Package Caches，或删除 `~/Library/Developer/Xcode/DerivedData/<项目名>-*/SourcePackages/` 目录后重新打开 workspace；命令行侧无此问题，仅影响 Xcode GUI。
- 来源：`Apps/Peekaboo.xcworkspace` 实际开发中反复触发，尤其在升级 AXorcist 等 git submodule 版本时。

**陷阱 2：Poltergeist 监听漏掉某些文件类型导致构建不触发**

- 可观测信号：修改了 `.plist`、`.entitlements`、`.storyboard` 等非 `.swift` 文件后，`poltergeist:status` 显示 idle，构建未启动，但手动 `pnpm run build:cli` 能正常生效。
- 原因：`watchPaths` 的 glob 仅覆盖 `**/*.swift`；Poltergeist 不感知其他扩展名。
- 处理：在对应 target 的 `watchPaths` 中追加所需 glob（如 `"Apps/Mac/**/*.storyboard"`），参考 `poltergeist.config.json:91-100` 中 `Peekaboo.app` target 的做法。
- 来源：`poltergeist.config.json:14-21` CLI target 目前仅覆盖 `.swift`，有意为之；app target 则额外覆盖 `.storyboard`、`.xib`、`.plist` 等。

**陷阱 3：lipo 报 "file is the same architecture" 构建失败**

- 可观测信号：`lipo: ... file is the same architecture (arm64) as ...`，Universal 产物未生成。
- 原因：两次 `swift build` 共享 `.build` 目录，第二次因缓存复用了 arm64 产物，两个 slice 架构相同。
- 处理：每次编译均显式传 `--arch arm64` / `--arch x86_64`（见 `scripts/build-swift-universal.sh:132-143`）；默认省略 `--arch` 时 Swift 用宿主架构，本地 arm64 机器上不会暴露，只在 CI 或手工测试时才发现。

**陷阱 4：双重构建产物路径混淆**

- 可观测信号：`pnpm run build:cli` 产物在 `Apps/CLI/.build/debug/peekaboo`，`build:swift:all` 输出到根目录 `./peekaboo`；`polter peekaboo` 可能调用旧调试产物，版本号未更新。
- 处理：统一用 `pnpm run peekaboo -- <args>` 调用，经 `poltergeist-wrapper.sh` 路由，始终使用 `outputPath: ./peekaboo`（`poltergeist.config.json:10`）。

## 延伸阅读

- Peekaboo：`docs/poltergeist.md`、`docs/building.md`、`poltergeist.config.json`
- Apple：[Swift Package Manager](https://www.swift.org/package-manager/)、[Xcode Workspace](https://developer.apple.com/documentation/xcode/creating-a-workspace)
- 其它 playbook：[01 · 模块划分](./01-module-layout.md)、[09 · SwiftUI + AppKit](./09-swiftui-appkit-liquid-glass.md)、[12 · 测试策略](./12-testing-permission-gated.md)

---
*Last verified against Peekaboo @ `7b163cb0`*
