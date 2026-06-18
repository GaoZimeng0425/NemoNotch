---
summary: 'SPM 编译隔离策略:如何通过模块边界、Swift 设置和构建命令让增量构建时间可控;以及 AI 生成代码场景下的包生成与构建流程。'
read_when:
  - '增量构建变慢,需要诊断和优化'
  - '需要用命令行(不开 Xcode)构建、测试、打包'
  - '构建 AI 生成代码管线,需要动态生成 Package.swift 并编译验证'
  - '调试 SPM cache 损坏或 DerivedData 陈旧问题'
sources: ['P01', 'I-16', 'N §3']
last_verified:
  peekaboo: '548989f7299888e25444f15dcf7cab28b876f227'
  nemonotch: 'fe4e9e5'
---

# 增量构建隔离与构建流程

## TL;DR

SPM 的增量构建隔离依赖**模块边界**:每个 package/target 独立维护编译缓存,改动只污染直接依赖方。"上帝模块"场景下单次改动触发 700+ 文件重编(43s);拆成四层模块后降至几十个文件(< 5s)。构建流程本身用纯命令行工具,不依赖 Xcode GUI:`swift build` / `xcodebuild` + shell 脚本;AI 生成代码管线同样用 `swift build --package-path <root>` 在隔离目录中编译临时包,以编译器错误数作为客观质量信号。

---

## 可复用模式

### 1. 编译隔离的工作原理

SPM 增量构建以 **target** 为粒度维护 `.build/` 缓存。当某个 target 的源文件或接口发生变化时,只有直接或间接依赖该 target 的模块才触发重编。

关键推论:
- **接口层(Protocols)稳定** → 改实现层(AutomationKit)只重编 AutomationKit + 直接依赖它的模块,不触发全仓
- **Foundation 稳定** → 它永远不被重编
- **同层模块不互相依赖** → 改 ImplA 不触发 ImplB 重编

**增量构建数据(Peekaboo 真实案例)**:`docs/module-architecture-refactoring.md:13-21`

| 阶段 | 架构 | 重编文件数 | 耗时 |
|---|---|---|---|
| 重构前 | 单"上帝模块"(132 文件塞进 PeekabooCore) | 700+(96%) | ~43s |
| 重构后 | 四层单向 SPM 模块 | 几十个 | < 5s |

---

### 2. Swift 设置对编译速度的影响

在接口层开启编译耗时警告,提前暴露"胖"类型推断(`PeekabooProtocols/Package.swift:12-17`):

```swift
.unsafeFlags([
    "-Xfrontend", "-warn-long-function-bodies=50",
    "-Xfrontend", "-warn-long-expression-type-checking=50",
], .when(configuration: .debug))   // 只在 debug build 开启
```

阈值 50ms:超出则 warning,帮助定位编译瓶颈。

---

### 3. 构建命令参考(命令行,不开 Xcode)

#### SPM 项目(纯命令行)

```bash
# 独立验证各层边界
swift build --target MyFoundation
swift build --target MyProtocols
swift build --target MyAutomationKit
swift build --target MyAppCore
swift build --target MyCLI

# Debug / Release
swift build --package-path <root>
swift build -c release --package-path <root>

# 取二进制目录
swift build -c release --show-bin-path --package-path <root>

# 验证 Package.swift 语法和依赖图
swift package describe
swift package show-dependencies
```

成功判据:`terminationStatus == 0`。

#### Xcode 工程(xcodebuild)

```bash
# Archive
xcodebuild archive \
  -project "YourApp.xcodeproj" \
  -scheme "YourApp" \
  -configuration Release \
  -archivePath "build/YourApp.xcarchive" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO

# Ad-hoc 签名
codesign --force --deep --sign - "build/export/YourApp.app"

# 打 DMG
hdiutil create -volname "YourApp" \
  -srcfolder "build/dmg-staging" \
  -ov -format UDZO \
  "build/YourApp.dmg"
```

> `CODE_SIGN_IDENTITY="-"` 产生 ad-hoc 签名。Gatekeeper 会在首次启动时拦截("app is damaged");终端用户需 `xattr -dr com.apple.quarantine YourApp.app`。官方分发需 Developer ID + notarization。
>
> `ENABLE_HARDENED_RUNTIME=NO` 是 dlopen 私有框架的必要条件(`build.sh:14-44`)。启用 hardened runtime 需要额外的 entitlement。

---

### 4. AI 生成代码场景:动态包生成与构建

当 AI 为每次生成输出一个独立的 Swift 包时(`AgentArtifacts.swift`),构建流程如下:

#### Package.swift 模板(最小可构建包)

```swift
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "{executableName}",
    platforms: [.macOS(.v26)],
    targets: [ .executableTarget(name: "{executableName}") ],
    swiftLanguageModes: [.v6]
)
```

#### 固定 `@main` 入口

```swift
// Sources/{name}/{name}.swift
import SwiftUI
@main
struct {executableName}: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
```

#### 构建与验证循环

1. 写入 `Package.swift` + 源文件到隔离目录(`/tmp/ironsmith/{uuid}/`)
2. `swift build --package-path <root>` — debug 构建
3. 解析 `stderr` 的编译器诊断(error / warning / note),按文件/行号分组、去重、排优先级
4. 用编译器错误数作为客观质量信号:0 error = 通过;> 0 = 触发修复循环
5. 修复层级:确定性规则(免费)→ 受限模型调用(便宜)→ 整体重生(贵)
6. 记录历史最优错误数;失败恢复原状;绝不留半成品

---

### 5. 增量构建诊断工具

```bash
# 显示本次哪些文件被重新编译
swift build -Xswiftc -driver-show-incremental 2>&1 | grep "^Compiling"

# 统计重编文件数
swift build -Xswiftc -driver-show-incremental 2>&1 | grep "^Compiling" | wc -l

# 找出编译最慢的表达式(需 debug build)
swift build -Xswiftc -Xfrontend -Xswiftc -warn-long-expression-type-checking=50 2>&1 | grep "warning:"

# 查看完整依赖树
swift package show-dependencies

# 列出所有 target 及类型
swift package describe --type json \
  | python3 -c "import sys,json; [print(t['name'], t['type']) for t in json.load(sys.stdin)['targets']]"
```

---

### 6. SPM Cache 清理(从轻到重)

```bash
# 轻量:只清 build 产物
swift package clean

# 中量:清 build 产物 + 重置所有 checkouts(SPM 重新 resolve)
swift package reset

# 重量:清 DerivedData(Xcode 用)
rm -rf ~/Library/Developer/Xcode/DerivedData/*

# 核弹:清 SPM 全局缓存(影响所有项目!)
rm -rf ~/.swiftpm/cache
```

**触发场景**:改 `Package.swift` 后 Xcode 不识别新 target → 先 `rm -rf ~/Library/Developer/Xcode/DerivedData/*` 再重启 Xcode，执行 File → Packages → Resolve Package Versions。

---

### 7. GitHub Actions 发布流程(tag 触发)

```yaml
# .github/workflows/release.yml:12-57
jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.3.app
      - name: Build archive
        run: |
          xcodebuild archive \
            -project "$PROJECT" -scheme "$SCHEME" \
            -configuration Release \
            -archivePath "build/$SCHEME.xcarchive" \
            -destination 'platform=macOS' \
            MACOSX_DEPLOYMENT_TARGET=26.2 \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            ENABLE_HARDENED_RUNTIME=NO
      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: build/NemoNotch.dmg
          generate_release_notes: true
```

触发条件:推送 `v*` 格式 tag(`git tag v0.1.0 && git push origin v0.1.0`)。

---

## 锚点

| 锚点 | 位置 | 内容 |
|---|---|---|
| 雪崩重编案例数据 | `docs/module-architecture-refactoring.md:13-21` | 700+ 文件 / 43s → 几十个 / < 5s |
| 编译耗时警告配置 | `Core/PeekabooProtocols/Package.swift:12-17` | `.when(configuration: .debug)` |
| 动态包生成模板 | `AgentArtifacts.swift` | `swift-tools-version: 6.2` 最小可构建包 |
| 构建命令封装 | `SwiftPackageProcessClient.swift` | `swift build --package-path <root>` |
| 主仓工具链配置 | `Package.swift` (Ironsmith root) | `swift-tools-version: 6.3`, `.macOS("26.0")`, `swiftLanguageMode(.v5)` |
| ad-hoc 签名脚本 | `build.sh:14-44` | Archive → export → codesign → DMG |
| Info.plist 陷阱 | `NemoNotch.xcodeproj/project.pbxproj:301-306` | `GENERATE_INFOPLIST_FILE = YES` 导致 Info.plist 被忽略 |
| CI workflow | `.github/workflows/release.yml:12-57` | tag 触发,macos-15 runner |

---

## Pitfalls

### 1. 改 Package.swift 后 Xcode 不识别新 target

**原因**:DerivedData 缓存陈旧;Xcode SPM 状态机未刷新。

**处理**:`rm -rf ~/Library/Developer/Xcode/DerivedData/*` 后重启 Xcode → File → Packages → Resolve Package Versions。

---

### 2. 增量构建慢(> 15s)

**可观测信号**:`-driver-show-incremental` 输出 >> 单模块文件数。

**根因**:单个 target 文件数 > 40(经验阈值),或接口层被频繁改动导致全仓重编。

**处理**:按四层拆分(见 `./module-and-spm-layout.md`);提取稳定的 Protocols 层作为"防火墙"。

---

### 3. `GENERATE_INFOPLIST_FILE = YES` 导致权限 key 丢失

**症状**:缺少 `NSAppleEventsUsageDescription` → macOS **静默拒绝**弹出 automation 授权对话框;System Settings → Privacy → Automation 也无法手动添加该 app。

**处理**:所有 Info.plist key 必须在 `project.pbxproj` 中以 `INFOPLIST_KEY_*` 形式声明,**Debug 和 Release 配置都要写**。

```bash
# 验证 key 是否真正进入 build 产物
/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" \
  "$APP/Contents/Info.plist"
```

---

### 4. Hardened Runtime 与 dlopen 冲突

**症状**:启用 Hardened Runtime 后,`dlopen` 私有框架(如 MediaRemote.framework)失败。

**处理**:本地 / CI 构建用 `ENABLE_HARDENED_RUNTIME=NO`。若需要 Developer ID 公证,需添加 `com.apple.security.cs.allow-dyld-environment-variables` entitlement 并充分测试。

---

### 5. Ad-hoc 签名被 Gatekeeper 拦截

**症状**:用户双击 app 显示"已损坏,无法打开"。

**处理**:
```bash
xattr -dr com.apple.quarantine YourApp.app
```
或指导用户右键 → 打开。**正式分发**需 Developer ID + notarization。

---

### 6. SPM cache 损坏导致 Xcode "菊花转"

**症状**:Xcode Package 解析卡住。

**处理**:
```bash
swift package clean && swift package reset
```

---

## 落地 checklist

- [ ] 各层有独立 `swift build --target Layer` 验证,确保边界不依赖 Xcode
- [ ] CI pipeline 逐层运行 `swift build --target Layer`(不只跑顶层 target)
- [ ] 接口层(Protocols)开启 debug-only 编译耗时警告(50ms 阈值)
- [ ] `project.pbxproj` 中 `INFOPLIST_KEY_*` 同时在 Debug 和 Release 配置中声明
- [ ] `build.sh` 包含:archive → export → ad-hoc sign → DMG 完整流程
- [ ] GitHub Actions workflow 锁定 Xcode 版本 + 运行器版本
- [ ] 有 AI 生成代码管线时:隔离目录 + 编译器错误数作为质量信号 + 修复循环 + 历史最优回滚

---

## 延伸阅读

- 四层模块划分与 Package.swift 骨架 → `./module-and-spm-layout.md`
- App bundle 打包、签名、沙箱、entitlements 完整步骤 → `../build-release/`
- Swift 6 严格并发 + 模块边界 `@MainActor`/`Sendable` → `../concurrency/`
