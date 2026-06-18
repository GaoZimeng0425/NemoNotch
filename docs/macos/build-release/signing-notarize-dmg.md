---
summary: '从 xcarchive 到 DMG 的完整签名/公证流程，含 ad-hoc、Developer ID、entitlements、INFOPLIST_KEY_* 陷阱与 GitHub Actions 发布。'
read_when:
  - '打包 .app 或 DMG 发布（本地或 CI）'
  - '调试签名失效、Gatekeeper 拦截、自动化权限对话框不出现'
  - '设置 GitHub Actions 标签触发发布流水线'
  - '理解 ad-hoc cdhash 每次重签变化对 Keychain 授权的影响'
sources: ['N §3', 'I-17']
last_verified: { peekaboo: 'n/a', nemonotch: 'fe4e9e5' }
---

# 签名 / 公证 / DMG

## TL;DR

NemoNotch 目前走 **ad-hoc 签名**（`CODE_SIGN_IDENTITY="-"`）+ `hdiutil` DMG，本地一键 `./build.sh`，CI 走 tag 触发的 GitHub Actions。Ad-hoc 每次重签都会改变 cdhash，这直接影响 Keychain 授权门控逻辑（见 [../keychain/cdhash-gated-read.md](../keychain/cdhash-gated-read.md)）。官方分发需要 Developer ID + 公证，尚未配置。

---

## 可复用模式

### 模式 1 · INFOPLIST_KEY_* 写入 pbxproj（非 Info.plist）

`GENERATE_INFOPLIST_FILE = YES` 时，源文件 `NemoNotch/Info.plist` **被完全忽略**；所有 Info.plist 键必须以 `INFOPLIST_KEY_*` 形式写入 `project.pbxproj`，且 Debug 和 Release 两个配置块都要改。

```
# 需要同时改 Debug（:301-306）和 Release（:355-360）两处
GENERATE_INFOPLIST_FILE = YES;
INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
INFOPLIST_KEY_LSUIElement = YES;
INFOPLIST_KEY_NSAppleEventsUsageDescription = "...";
INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = "...";
INFOPLIST_KEY_NSHumanReadableCopyright = "";
```

验证：`/usr/libexec/PlistBuddy -c "Print" "$APP/Contents/Info.plist"`

### 模式 2 · LSUIElement = YES 隐藏 Dock 图标

菜单栏专属 app 必须设此标志，否则点击 Dock 图标会弹出空窗口。

```
INFOPLIST_KEY_LSUIElement = YES;
```

### 模式 3 · 沙箱禁用 entitlements

NemoNotch 运行在非沙箱模式下，因为 MediaRemote dlopen、`~/.claude/settings.json` hook 安装、NowPlayingCLI 子进程控制均不能在 App Sandbox 下工作。

```xml
<!-- NemoNotch/NemoNotch.entitlements:1-8 -->
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
```

沙箱迁移是多周级别工程，不是一个标志位的翻转。

### 模式 4 · build.sh：archive → ad-hoc 签名 → DMG

```bash
# build.sh:14-44
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  | tail -1

# ad-hoc 签名
codesign --force --deep --sign - "$BUILD_DIR/export/$APP_NAME.app"

# 打 DMG
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$BUILD_DIR/$DMG_NAME.dmg"
```

### 模式 5 · AI 生成工程的 staged bundle 构建（通用模板）

来自 Ironsmith/`ToolAppBundleClient.swift`，适用于任何程序化构建 `.app` 的场景：

1. Release 构建（`swift build -c release`）验证成功
2. `--show-bin-path` 取可执行文件路径
3. 建临时 staged bundle（`.{base}.staged.{UUID}.app`），创建 `Contents/{MacOS,Resources}`
4. 复制可执行文件，权限 `0o755`
5. 复制图标到 `Contents/Resources/AppIcon.icns`（可选）
6. 写 Info.plist（`PropertyListSerialization`，`.xml`，原子写）
7. 写 entitlements（沙箱启用时）
8. Ad-hoc 签名 + 验证（staged）
9. 原子替换（带备份回滚）
10. 再次验证签名（final）
11. strip quarantine：`xattr -d com.apple.quarantine <binary>`

**Info.plist 必有键**：`CFBundleDevelopmentRegion`、`CFBundleDisplayName`、`CFBundleExecutable`、`CFBundleIdentifier`、`CFBundleInfoDictionaryVersion=6.0`、`CFBundleName`、`CFBundlePackageType=APPL`、`CFBundleShortVersionString`、`CFBundleVersion`、`LSApplicationCategoryType`、`LSMinimumSystemVersion`。

**条件键**：`CFBundleIconFile`（有图标）、`LSUIElement=true`（菜单栏 app；导出到 /Applications 时不设，以便显示在 Dock）、usage description 键（NSCameraUsageDescription 等）。

```bash
# 签名三件套
/usr/bin/codesign --force --sign - --options runtime [--entitlements <file>] <App>
/usr/bin/codesign --verify --deep --strict <App>
/usr/bin/xattr -d com.apple.quarantine <binary>   # 失败不致命
```

**沙箱 entitlements（按需）**：`com.apple.security.app-sandbox = true`；`network.client`；`files.user-selected.read-write`；`device.audio-input`；`device.camera`；`personal-information.*`；`automation.apple-events`。

**Bundle Identifier 生成规则**（参考 Ironsmith）：`com.{vendor}.generated.{component}.{uuid}`，component = 显示名 ASCII 折叠 + 小写 + 非字母数字切词 + `-` 连接，截断 48 字符。

**导出到 /Applications 的 staged replacement**：首选 `{name}.app`；若已存在且 `CFBundleIdentifier` 匹配 → 覆写；否则递增后缀（`{name} 2.app` …）。替换前移旧 bundle 到备份名，失败则移回。

### 模式 6 · GitHub Actions tag 触发发布

```yaml
# .github/workflows/release.yml:12-57
jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode 26.3
        run: sudo xcode-select -s /Applications/Xcode_26.3.app
      - name: Build archive
        run: |
          xcodebuild archive \
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

### 模式 7 · SwiftFormat build phase（降级为 warning）

```bash
# NemoNotch.xcodeproj/project.pbxproj:148 (Run Script phase)
if which swiftformat >/dev/null;
  then swiftformat "$SRCROOT" --cache quiet 2>/dev/null || true
else
  echo "warning: swiftformat not installed, run: brew install swiftformat"
fi
```

---

## 锚点（file:line）

| 锚点 | 路径 |
|------|------|
| Debug `INFOPLIST_KEY_*` | `NemoNotch.xcodeproj/project.pbxproj:301-306` |
| Release `INFOPLIST_KEY_*` | `NemoNotch.xcodeproj/project.pbxproj:355-360` |
| `LSUIElement` | `project.pbxproj:303,357` |
| Entitlements 文件 | `NemoNotch/NemoNotch.entitlements:1-8` |
| `build.sh` archive + DMG | `build.sh:14-44` |
| SwiftFormat Run Script | `project.pbxproj:148` |
| GitHub Actions workflow | `.github/workflows/release.yml:12-57` |
| Ironsmith staged bundle | `ToolAppBundleClient.swift`（Ironsmith 仓库） |

---

## Pitfalls

**P1：GENERATE_INFOPLIST_FILE = YES 导致源 Info.plist 被忽略**
编辑了 `NemoNotch/Info.plist` 但 build product 里没有变化。原因：`GENERATE_INFOPLIST_FILE = YES` 时此文件完全无效。必须改 `project.pbxproj`，Debug 和 Release 两处均须更新。

**P2：缺 `NSAppleEventsUsageDescription` 导致授权对话框静默消失**
Automation 权限弹窗不出现，System Settings → Privacy → Automation 面板也无法手动添加该 app，表现为"app 不需要 automation"。实际是 Info.plist 缺此键，macOS 静默拒绝。参见 `../permissions/` 目录。

**P3：只改 Debug 忘改 Release**
Debug 测试正常，归档后 Release build 缺权限描述键。双配置必须同步修改。

**P4：ad-hoc cdhash 每次重签变化**
`CODE_SIGN_IDENTITY="-"` 每次重签都产生新 cdhash，导致基于 cdhash 的 Keychain 门控授权失效——上次授权的 cdhash 不匹配新签名，需要重新授权。开发期间预期行为；稳定签名（Developer ID）可做到真正一次性授权。详见 [../keychain/cdhash-gated-read.md](../keychain/cdhash-gated-read.md)。

**P5：ENABLE_HARDENED_RUNTIME=NO 是 dlopen 的必要条件**
启用 Hardened Runtime 后，MediaRemote.framework 的 dlopen 会被阻断，除非同时添加 `com.apple.security.cs.allow-dyld-environment-variables` entitlement。

**P6：Gatekeeper "app is damaged"**
Ad-hoc 签名的 .app 首次运行被 Gatekeeper 拦截。用户需要右键 → Open，或运行 `xattr -dr com.apple.quarantine NemoNotch.app`。

**P7：`xcodebuild` Xcode 版本浮动**
CI 用 `macos-latest` 时 runner 镜像更新会带入新 Xcode，破坏 Swift 6 strict-concurrency 编译。必须 pin `macos-15` + 显式 `xcode-select -s /Applications/Xcode_26.3.app`。

**P8：MACOSX_DEPLOYMENT_TARGET 与项目不一致**
workflow 里的 `MACOSX_DEPLOYMENT_TARGET` 低于项目设定时，archive 链接了更新 SDK 的符号，在 target OS 上运行时崩溃。

**P9：SwiftFormat stderr 被 Xcode 解析为 build error**
`2>/dev/null` 是必须的；没有它 Xcode 会把 SwiftFormat 的正常进度输出当作错误，产生误导性的红色 build banner。

---

## 落地 Checklist

- [ ] 新增权限：在 `project.pbxproj` Debug **和** Release 配置块各加一行 `INFOPLIST_KEY_NS*UsageDescription`
- [ ] 验证 build product：`/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$APP/Contents/Info.plist"`
- [ ] 菜单栏 app：确认 `INFOPLIST_KEY_LSUIElement = YES` 两处都有
- [ ] 本地打包：`./build.sh`，检查 `build/NemoNotch.dmg` 非空
- [ ] 首次运行测试：右键 → Open 绕过 Gatekeeper，或 `xattr -dr com.apple.quarantine`
- [ ] CI 发布：推 `vX.Y.Z` tag → Actions 页确认 workflow 通过 → GitHub Releases 出现 DMG
- [ ] Developer ID 分发（未配置）：需要申请 Developer ID Application 证书 + 配置公证 (`notarytool`) + 移除 `CODE_SIGNING_REQUIRED=NO`

---

## 延伸阅读

- [../keychain/cdhash-gated-read.md](../keychain/cdhash-gated-read.md) — cdhash 门控 Keychain 读取，ad-hoc 签名对授权的影响
- [../permissions/](../permissions/) — 权限请求模式（PermissionCard，自动化权限陷阱）
- [../project-layout/](../project-layout/) — pbxproj 文件同步规则（不手动编辑添加源文件）
- [Apple · Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — Developer ID + 公证官方文档
- [Apple · Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) — entitlements 与 `--options runtime`
