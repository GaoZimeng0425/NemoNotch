---
summary: '混合 SwiftPM + xcodeproj 工程统一进 .xcworkspace，Poltergeist 基于 Watchman 监听文件变化触发增量构建，pnpm 统一任务入口，lipo 合成 Universal Binary。'
read_when:
  - '搭建 CLI + .app 混合工程（SwiftPM 管库、xcodeproj 管 .app）'
  - '用 Poltergeist 实现后台增量构建、消除手工 build 等待'
  - '为 CLI 工具构建 arm64 + x86_64 Universal Binary'
  - '用 pnpm 统一 Swift 项目的构建/测试/格式化入口'
sources: ['P11']
last_verified: { peekaboo: 'n/a', nemonotch: 'fe4e9e5' }
---

# Poltergeist 增量构建 + 混合工程

## TL;DR

混合 macOS 工程把 SwiftPM 包（可复用库 + CLI）与 Xcode 工程（带 entitlements 的 `.app`）放进同一 `.xcworkspace`，共享 Swift 索引与代码补全，构建流程各自独立。Poltergeist 在后台基于 Watchman 监听文件变化，按 debounce 触发增量构建，前台用 `polter peekaboo` 始终拿到最新产物，消除手工 build 等待。发布阶段分别以 `--arch arm64` 和 `--arch x86_64` 编译，再用 `lipo -create` 合成 Universal Binary、`strip -Sxu` 精简符号、`codesign` 统一签名一次。pnpm 作为任务运行器将所有入口统一到 `package.json scripts`。

---

## 可复用模式

### 模式 1 · 混合工作区目录布局

```
MyProject/
├── Package.swift                      # 顶层 SPM 包（库 + CLI targets）
├── poltergeist.config.json            # Poltergeist 监听配置
├── package.json                       # pnpm 任务入口
├── Apps/
│   ├── MyProject.xcworkspace/
│   │   └── contents.xcworkspacedata  # 聚合 xcodeproj + SPM 包目录
│   ├── Mac/
│   │   └── MyProject.xcodeproj       # .app target（含 entitlements）
│   └── CLI/
│       ├── Package.swift             # CLI-specific SPM 包
│       └── Sources/...
├── Core/
│   ├── Foundation/Sources/...
│   ├── Protocols/Sources/...
│   └── AutomationKit/Sources/...
└── scripts/
    ├── build-swift-arm.sh
    ├── build-swift-universal.sh
    └── poltergeist-wrapper.sh
```

workspace 层只负责聚合 `<FileRef>`，不重复声明依赖。

### 模式 2 · xcworkspace 同时引用 xcodeproj + SPM 包

```xml
<!-- Apps/MyApp.xcworkspace/contents.xcworkspacedata -->
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
  <FileRef location="group:Mac/MyApp.xcodeproj" />   <!-- .app -->
  <FileRef location="group:CLI" />                    <!-- SPM 包目录 -->
</Workspace>
```

`group:` 前缀表示相对于 `.xcworkspace` 所在目录的路径。指向目录（`group:CLI`）等价于告诉 Xcode "这是一个 SPM 包根目录"，Xcode 自动解析其 `Package.swift`。workspace 本身不声明目标依赖。

**为何不纯 SwiftPM**：`swift build` 无法产出 `.app`（无 entitlements、Run Script Phase、Assets.xcassets 编译、bundle 签名）。  
**为何不纯 xcodeproj**：`project.pbxproj` 多人协作 merge conflict 极重；SwiftPM 依赖管理更干净。  
混合方案：库/CLI 走 SwiftPM，`.app` 走 xcodeproj，`xcworkspace` 聚合共享 Swift 索引。

### 模式 3 · SwiftPM 四层依赖链

```
Foundation  ← 零依赖基础类型
  └── Protocols  ← 协议定义（@MainActor 隔离）
        └── AutomationKit  ← 外部依赖（AXorcist / swift-algorithms）
              └── Core/Bridge  ← CLI/App 共享胶水层
```

每层只声明**直接上游**依赖；`swiftLanguageModes: [.v6]` 全局启用 Swift 6 严格并发。

外部依赖锁定版本（`Package.swift:51-54`）：
```swift
.package(url: "https://github.com/steipete/AXorcist.git", exact: "0.1.2"),
.package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
```

### 模式 4 · Poltergeist 核心配置字段

**CLI executable target**（`poltergeist.config.json:5-31`）：
```jsonc
{
  "name": "MyApp",
  "type": "executable",
  "buildCommand": "./scripts/build-swift-debug.sh",
  "outputPath": "./myapp",         // polter 等待此文件刷新后执行
  "settlingDelay": 1000,           // 文件系统稳定等待（ms）
  "debounceInterval": 5000,        // 合并连续改动，5s 内只触发一次
  "watchPaths": [
    "Core/**/*.swift",
    "Apps/CLI/**/*.swift"
  ],
  "postBuild": [{
    "command": "./scripts/run-safe-tests.sh",
    "runOn": "success",
    "timeoutSeconds": 900
  }]
}
```

**App-bundle target 额外字段**（`poltergeist.config.json:81-101`）：
```jsonc
{
  "type": "app-bundle",
  "bundleId": "boo.peekaboo.mac.debug",
  "autoRelaunch": true,            // 构建成功后自动重启 .app
  "settlingDelay": 4000,           // 比 CLI 高，避免 Core 改动频繁触发 app build
  "watchPaths": [
    "Apps/Mac/**/*.swift",
    "Apps/Mac/**/*.storyboard",
    "Apps/Mac/**/*.xib",
    "Core/**/*.swift"
  ]
}
```

**全局调度**（`poltergeist.config.json:199-207`）：
```jsonc
"buildScheduling": {
  "parallelization": 1,            // 强制串行队列，防 .build 目录竞争写入
  "prioritization": { "enabled": true }
}
```

**Watchman 排除规则**（`poltergeist.config.json:156-190`）：
```jsonc
"watchman": {
  "useDefaultExclusions": true,    // 默认排除 .build / DerivedData / node_modules
  "rules": [
    { "pattern": "**/*.xcuserstate", "action": "ignore" },
    { "pattern": "**/Version.swift",  "action": "ignore" }  // ← 关键，防构建循环
  ]
}
```

### 模式 5 · Universal Binary 合成流程

```
1. swift package reset + rm -rf .build    # 两次编译必须干净起步
2. swift build --arch arm64  -c release -Osize  → cp → ./myapp-arm64
3. swift build --arch x86_64 -c release -Osize  → cp → ./myapp-x86_64
4. lipo -create -output ./myapp.tmp ./myapp-arm64 ./myapp-x86_64
5. strip -Sxu ./myapp.tmp                 # 先 strip 后 sign（顺序关键）
6. codesign --force --sign "$SIGN_IDENTITY" --options runtime \
            --entitlements myapp.entitlements ./myapp.tmp
7. mv ./myapp.tmp ./myapp && rm ./myapp-arm64 ./myapp-x86_64
8. lipo -info ./myapp                     # 验证
```

完整脚本参见 `scripts/build-swift-universal.sh:129-153`（Peekaboo 仓库）。

### 模式 6 · pnpm scripts 入口映射

| 场景 | pnpm 命令 | 底层调用 |
|------|----------|---------|
| 调试构建 | `pnpm run build:cli` | `swift build --package-path Apps/CLI` |
| arm64 release | `pnpm run build:swift` | `./scripts/build-swift-arm.sh` |
| Universal release | `pnpm run build:swift:all` | `./scripts/build-swift-universal.sh` |
| 启动 Poltergeist | `pnpm run poltergeist:haunt` | `poltergeist-wrapper.sh haunt` |
| 查看构建状态 | `pnpm run poltergeist:status` | `poltergeist-wrapper.sh status` |
| 查看日志 | `pnpm run poltergeist:logs` | `poltergeist-wrapper.sh logs` |
| 停止守护 | `pnpm run poltergeist:rest` | `poltergeist-wrapper.sh rest` |
| 调用最新产物 | `pnpm run myapp -- <args>` | `poltergeist-wrapper.sh myapp` |
| 安全测试 | `pnpm run test:safe` | `swift test ... --no-parallel` |

pnpm vs make 的选择：JSON 语法对 TS/JS 开发者更友好；`corepack enable pnpm` 锁定版本；项目已依赖 Node，额外成本为零。

### 模式 7 · ProcessWatcher / autoRelaunch 开发循环

```bash
pnpm run poltergeist:haunt      # 启动守护（常驻终端标签）
# 编辑 Swift 文件 → 5s debounce 后自动增量构建
pnpm run poltergeist:status     # 确认构建状态
pnpm run myapp -- <args>        # 调用最新产物
pnpm run poltergeist:rest       # 收工
```

`autoRelaunch: true` 适用于菜单栏 app debug 循环（修改代码 → 重建 → 自动弹出新版）和辅助进程（ReplayD 等）。注意：若进程由 launchd 管理，直接 `autoRelaunch` 可能绕过 `launchctl` 导致进程僵尸。

---

## 锚点（file:line）

| 锚点 | 路径 |
|------|------|
| 顶层 Package.swift 完整声明 | `Package.swift:32-88`（Peekaboo） |
| xcworkspace 聚合文件 | `Apps/Peekaboo.xcworkspace/contents.xcworkspacedata:1-16` |
| Poltergeist 配置 | `poltergeist.config.json:4-101` |
| Universal Binary 脚本 | `scripts/build-swift-universal.sh:129-153` |
| Wrapper 脚本 | `scripts/poltergeist-wrapper.sh:24-68` |
| pnpm scripts | `package.json:18-56` |
| Watchman 排除规则 | `poltergeist.config.json:156-190` |
| 全局构建调度 | `poltergeist.config.json:199-207` |

---

## Pitfalls

**P1：Xcode DerivedData 缓存导致 Package.swift 改动不生效**
命令行 `swift build` 已看到新 target，但 Xcode 补全/构建仍报旧错误。原因：`DerivedData/<项目名>-*/SourcePackages/` 缓存未刷新。处理：`rm -rf ~/Library/Developer/Xcode/DerivedData/<项目名>-*/SourcePackages/` 或 Xcode → File → Packages → Reset Package Caches。

**P2：watchPaths 漏掉非 .swift 文件**
修改 `.plist`、`.entitlements`、`.storyboard` 后 Poltergeist idle，构建未触发。在对应 target 的 `watchPaths` 中追加所需 glob。

**P3：lipo 报 "file is the same architecture (arm64)"**
两次 `swift build` 共享 `.build` 目录，第二次因缓存复用了 arm64 产物。必须在 `build-universal.sh` 中先 `swift package reset && rm -rf .build`，然后分别显式传 `--arch arm64` / `--arch x86_64`（`scripts/build-swift-universal.sh:131-143`）。

**P4：双重产物路径混淆**
`pnpm run build:cli` 产物在 `Apps/CLI/.build/debug/myapp`，`build:swift:all` 输出到根目录 `./myapp`。统一通过 `pnpm run myapp -- <args>` 调用，始终走 `poltergeist.config.json` 的 `outputPath`。

**P5：poltergeist haunt 后忘记 rest，Watchman 留 zombie**
`ps aux | grep watchman` 出现多个独立进程 → 每次文件变更触发多次构建。`watchman shutdown-server` 强制停止，再 `pnpm run poltergeist:haunt` 重启。养成收工执行 `pnpm run poltergeist:rest` 的习惯。

**P6：strip 在 codesign 之后运行导致签名失效**
`nm ./myapp | grep " d "` 有输出（debug 符号泄漏）或 `codesign --verify` 报 "modified/invalid"。正确顺序：`lipo -create` → `strip -Sxu` → `codesign`（`scripts/build-swift-universal.sh:145-165`）。

**P7：Version.swift 未排除导致构建死循环**
构建脚本每次 build 时写入 `Version.swift` → Poltergeist 感知文件变更 → 触发构建 → 循环。必须在 `watchman.rules` 中 ignore `**/Version.swift`（`poltergeist.config.json:156-190`）。

---

## 落地 Checklist

- [ ] 初始化 SPM 包：`swift package init --type library`，按四层结构建 `Core/` 子目录
- [ ] 创建 Xcode 工程：保存到 `Apps/Mac/`，添加所需 entitlements
- [ ] 创建 workspace：写入 `contents.xcworkspacedata`，引用 xcodeproj + CLI 目录
- [ ] 安装 Poltergeist：clone 到 `../poltergeist`，`cd ../poltergeist && pnpm install`
- [ ] 配置 `poltergeist.config.json`：`watchPaths` 覆盖 .swift + 非 swift 资源；`Version.swift` 加 ignore；`buildScheduling.parallelization: 1`
- [ ] 编写构建脚本：`build-swift-debug.sh`（Poltergeist buildCommand），`build-universal.sh`（发布）
- [ ] 验证开发循环：`pnpm run poltergeist:haunt` → 改文件 → 5s 后 `poltergeist:status` 显示构建完成
- [ ] 验证 Universal Binary：`lipo -info ./myapp` 输出含 `arm64 x86_64`
- [ ] CI：直接调用 `pnpm run build:swift:all`，不运行 Poltergeist

---

## 延伸阅读

- [Poltergeist GitHub](https://github.com/steipete/poltergeist) — Watchman-backed 增量构建工具
- [Watchman](https://facebook.github.io/watchman/) — Poltergeist 的底层文件监听引擎
- [./signing-notarize-dmg.md](./signing-notarize-dmg.md) — .app 签名、DMG 打包、GitHub Actions 发布
- [../project-layout/](../project-layout/) — 模块划分与 SPM 依赖方向
- [../testing/](../testing/) — `test:safe` / `test:automation` 分级策略
- [Apple · Swift Package Manager](https://www.swift.org/package-manager/)
- [Apple · Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
