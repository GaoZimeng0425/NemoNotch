---
summary: 'GENERATE_INFOPLIST_FILE=YES 时源 Info.plist 被忽略，所有 key 必须写 INFOPLIST_KEY_* 进 pbxproj；缺 NSAppleEventsUsageDescription 导致自动化授权对话框静默不弹。'
read_when:
  - '新增权限描述 key（NSAppleEventsUsageDescription、NSCalendarsFullAccessUsageDescription 等）'
  - '调试"系统设置自动化列表里找不到我的 app"或"Automation 权限 prompt 永远不弹"'
  - '验证 build 产物的 Info.plist 是否包含期望的 key'
sources: ['N §2', 'N §3']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# Info.plist 陷阱：GENERATE_INFOPLIST_FILE 与 INFOPLIST_KEY_*

## TL;DR

NemoNotch（以及任何开启了 `GENERATE_INFOPLIST_FILE = YES` 的项目）**不从源文件 `NemoNotch/Info.plist` 读取任何 key**。Xcode 在构建时完全忽略该文件，改为从 `project.pbxproj` 的 build settings 里读取 `INFOPLIST_KEY_*` 前缀的条目来生成最终的 `Info.plist`。

漏掉这一点的代价极高：缺少 `NSAppleEventsUsageDescription` 会导致 macOS **静默拒绝**显示 Automation 授权对话框，且 System Settings → Privacy & Security → Automation **列表里不会出现你的 app**——调试起来极其耗时，因为没有任何报错。

---

## 可复用模式

### 如何添加新的权限描述 key

1. **编辑 `project.pbxproj`**，找到所有现有的 `INFOPLIST_KEY_NS*UsageDescription` 行，紧邻它们各添加一行：

   ```
   INFOPLIST_KEY_NSAppleEventsUsageDescription = "NemoNotch 需要控制音乐播放器以实现快进、快退等播放控制功能。";
   INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = "NemoNotch 需要访问您的日历，以便在灵动岛中显示今日日程和下一个事件提醒。";
   ```

   **关键**：Debug 和 Release configuration 各有一个 block，**两处都要改**，否则 Release build 会缺 key：
   - Debug block：`NemoNotch.xcodeproj/project.pbxproj:301-306`
   - Release block：`NemoNotch.xcodeproj/project.pbxproj:355-360`

2. **不要**修改 `NemoNotch/Info.plist`——在 `GENERATE_INFOPLIST_FILE = YES` 模式下该文件不参与构建。

3. **验证**：构建后用 PlistBuddy 检查 build 产物：

   ```bash
   APP="build/Release/NemoNotch.app"
   /usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" \
       "$APP/Contents/Info.plist"
   # 期望输出 key 的值；如果输出 "Does Not Exist" 说明 pbxproj 漏改
   ```

   也可以一次性打印全部 key 做完整验证：

   ```bash
   /usr/libexec/PlistBuddy -c "Print" "$APP/Contents/Info.plist"
   ```

### 现有 INFOPLIST_KEY 完整列表（NemoNotch Debug config）

`NemoNotch.xcodeproj/project.pbxproj:301-306`：

```
GENERATE_INFOPLIST_FILE = YES;
INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
INFOPLIST_KEY_LSUIElement = YES;
INFOPLIST_KEY_NSAppleEventsUsageDescription = "NemoNotch 需要控制音乐播放器以实现快进、快退等播放控制功能。";
INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription = "NemoNotch 需要访问您的日历，以便在灵动岛中显示今日日程和下一个事件提醒。";
INFOPLIST_KEY_NSHumanReadableCopyright = "";
```

---

## 锚点（file:line）

| 条目 | 文件:行 | 说明 |
|------|---------|------|
| Debug config INFOPLIST_KEY block | `NemoNotch.xcodeproj/project.pbxproj:301-306` | Debug build settings |
| Release config INFOPLIST_KEY block | `NemoNotch.xcodeproj/project.pbxproj:355-360` | Release build settings；与 Debug 重复，两处都要改 |
| `GENERATE_INFOPLIST_FILE = YES` | `NemoNotch.xcodeproj/project.pbxproj:84` | 源 Info.plist 被忽略的根因 |
| 源 Info.plist（不被使用） | `NemoNotch/Info.plist` | 文件存在但 build 时不读取 |

---

## Pitfalls

### 陷阱 1 · 缺 NSAppleEventsUsageDescription → Automation 授权对话框静默不弹

**症状**：
- App 对 Music / Spotify 发送 AppleEvent，什么对话框都没有弹出
- System Settings → Privacy & Security → Automation 列表里找不到你的 app
- `SBApplicationDelegate.eventDidFail` 回调收到 `-1743`（`errAEEventNotPermitted`）
- `MediaBridge.hasAutomationAccess` 永远返回 false

**根因**：macOS 在允许显示 Automation 授权对话框之前，会检查 built app 的 `Info.plist` 是否包含 `NSAppleEventsUsageDescription`。没有这个 key，系统**静默拒绝**，不给任何反馈。

**处理**：
1. 按"如何添加新的权限描述 key"步骤，在 pbxproj 两个 config block 都加上这行
2. 重新构建，用 PlistBuddy 验证 key 存在
3. 首次运行触发 SB 调用，Automation 对话框出现

**NemoNotch 实证**：这个问题曾导致整整一天的调试时间（`macos-cookbook.md §11.2`）。

### 陷阱 2 · 只改了 Debug config，Release build 仍缺 key

**症状**：Debug 运行一切正常，Archive / Release build 失去权限功能，用户报告问题。
**处理**：每次添加新 key 时，在 pbxproj 中同时找到 Debug 和 Release 两处 `INFOPLIST_KEY_*` block 都修改。

### 陷阱 3 · 修改源 Info.plist 无效

**症状**：在 `NemoNotch/Info.plist` 添加了 key，但构建产物的 Info.plist 里看不到。
**原因**：`GENERATE_INFOPLIST_FILE = YES` 告诉 Xcode 完全忽略源 Info.plist，从 pbxproj 的 build settings 生成。
**处理**：只改 `project.pbxproj`，不改源 Info.plist。

### 陷阱 4 · 项目使用 Xcode 16 自动同步（auto-sync root groups）

NemoNotch 使用 auto-sync root groups（见 `memory/project_xcode-file-sync.md`）：**永远不要手动编辑 pbxproj 来添加源文件**，Xcode 会自动同步文件引用。但 build settings（包括 `INFOPLIST_KEY_*`）不在自动同步范围内，仍需手工编辑 pbxproj。

---

## 落地 checklist

- [ ] 确认项目是否开启 `GENERATE_INFOPLIST_FILE = YES`（在 Xcode → Build Settings 搜索 `GENERATE_INFOPLIST`）
- [ ] 新增权限时，修改 pbxproj 的 **Debug 和 Release** 两个 config block
- [ ] 构建后用 `PlistBuddy -c "Print :NSAppleEventsUsageDescription"` 验证 key 存在
- [ ] 如果 Automation prompt 不弹：先检查 built Info.plist，再检查 entitlements（`codesign -d --entitlements - App.app`）
- [ ] 沙盒 app 还需要在 entitlements 中添加 `com.apple.security.automation.apple-events = true`

---

## 延伸阅读

- [tcc-state-machine.md](tcc-state-machine.md) — AppleEvents TCC 状态机与 `-1743` 错误码
- [permission-card-ux.md](permission-card-ux.md) — PermissionCard Grant 按钮（依赖 UsageDescription key 才能触发系统对话框）
- [../build-release/](../build-release/) — 完整 build 配置参考（Archive、Export、DMG）
- `macos-cookbook.md §3` — NemoNotch build settings 完整参考（包含 `LSUIElement`、`LSApplicationCategoryType` 等）
