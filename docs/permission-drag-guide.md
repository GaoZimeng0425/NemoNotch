# 权限拖拽引导（Drag-to-Authorize Guide）

在「系统设置 → 隐私与安全性」里，把 NemoNotch 自己拖进权限列表来完成授权。
本文件说明实现位置、机制原理、手动验证步骤与已知边界。

## 1. 它长什么样

用户点击设置里的权限卡片 CTA 后：

1. 系统设置自动打开到对应隐私面板；
2. 一个悬浮引导窗停在系统设置窗口**下方**（放不下时退到侧边/底部）；
3. 引导窗里是 NemoNotch 的应用图标，带呼吸光环 + 手型光标；
4. 用户把图标拖到系统设置的权限列表里松手；
5. 勾选开关 → 引导窗检测到授权，显示「已授权」约 1.6s 后自动收起。

全程不抢焦点（`.nonactivatingPanel`），用户可继续操作系统设置。

## 2. 代码位置

| 文件 | 职责 |
|---|---|
| `NemoNotch/PermissionFlow/PermissionPane.swift` | 8 个支持拖拽的隐私面板 + 深链 + 授权检测闭包 |
| `NemoNotch/PermissionFlow/SystemSettingsWindowTracker.swift` | 无权限获取系统设置窗口位置 |
| `NemoNotch/PermissionFlow/DraggableAppIconView.swift` | AppKit 拖拽源（提供 `.app` 的 file URL） |
| `NemoNotch/PermissionFlow/PermissionDragPanel.swift` | 悬浮 NSPanel |
| `NemoNotch/PermissionFlow/PermissionDragPanelView.swift` | 引导窗 SwiftUI 内容 |
| `NemoNotch/PermissionFlow/PermissionFlowController.swift` | 编排：打开 / 定位 / 跟随 / 轮询 / 收起 |

入口：`SettingsView` 的辅助功能 `PermissionCard` →
`PermissionFlowController.shared.start(pane: .accessibility)`。

## 3. 两个关键机制

### 3.1 为什么用 Window Server 而不是 Accessibility API

要跟随系统设置窗口，就得读它的 frame。但**通过 AX API 读别的 App 的窗口位置，
本身就要求辅助功能授权** —— 而辅助功能正是我们要拿的那个权限。死锁。

解法：`CGWindowListCopyWindowInfo` 是窗口服务器查询，不需要任何 TCC 授权。
已在 macOS 26.6 Tahoe 实测确认：无需屏幕录制权限即可拿到 PID / 层级 / bounds。

> 注意：`kCGWindowOwnerName` 返回的是**本地化**应用名（中文系统是「系统设置」）。
> 代码因此用 bundle id `com.apple.systempreferences` 反查 PID 来匹配，不能匹配名字。

坐标系换算（已实测校准）：

```
AppKit y = 主屏高度 - CG y - CG 高度     // x 不变
```

### 3.2 拖拽只是「引导」，不是绕过

真正写入 TCC 数据库的仍是用户在系统设置里的那次 drop。本应用只提供拖拽源
（把 `Bundle.main.bundleURL` 以 `.fileURL` 放进 pasteboard）。没有、也无法绕过
macOS 的安全机制。

## 4. 支持拖拽的面板（仅这 8 个）

Accessibility、Full Disk Access、Input Monitoring、Screen Recording、
App Management、Developer Tools、Bluetooth、Media & Apple Music。

其余隐私面板（相机、麦克风、照片、日历、通讯录……）是「首次使用时系统弹窗」
模式，没有可拖入的列表，**不应**显示引导窗。

## 5. 手动验证清单

> 说明：本次改动未能在命令行完成整机编译验证（环境里 `xcodebuild` 的 SwiftPM
> 包解析被沙箱阻断）。新模块已单独通过 `swiftc -typecheck -swift-version 6`
> 严格并发检查，零 warning，但请在 Xcode 里跑一次真机验证。

1. Xcode ⌘B 编译通过。
2. 取消辅助功能授权（若已授权，在设置里把 NemoNotch 的开关关掉或移除条目）。
3. NemoNotch 设置 → 通知列表 → 点击权限卡片按钮。
4. 预期：系统设置打开到「辅助功能」，引导窗停在其下方。
5. 从引导窗把图标拖进列表 → 勾选开关 → 引导窗变绿显示「已授权」并自动收起。
6. 回到设置，权限卡片应已消失（`refreshAXTrust()` 每 1.5s 轮询一次）。
7. 边界：
   - 拖动系统设置窗口 → 引导窗应跟随；
   - 关闭系统设置 → 引导窗自动收起；
   - 按 ESC 或点右上角 × → 立即收起；
   - 引导窗不抢焦点，可继续点击系统设置。

## 6. 已知取舍

- **仅限非沙盒应用**。当前 entitlements 里 `com.apple.security.app-sandbox = false`，
  方案成立；若将来上架 Mac App Store 开启沙盒，悬浮窗覆盖其他应用将不可用。
- **无法自动检测所有面板的授权结果**。只有 Accessibility 与 Screen Recording 有公开
  的 preflight API；其余面板没有，引导窗会一直显示到系统设置关闭或用户手动关掉。
- **窗口位置为轮询跟随**（10Hz）。这是无 AX 权限下的代价；C 层比 AX 观察器略耗，
  但引导窗生命周期只有几秒到几分钟。
- **3 分钟硬超时**，避免被遗忘的引导窗常驻屏幕。
