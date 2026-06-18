---
summary: 'NemoNotch never-auto-prompt 模式：启动时不请求权限，PermissionCard "Grant" 按钮统一处理 Calendar / Location / Automation / Notification；AX 只能跳系统设置。'
read_when:
  - '在 macOS app 中决定何时以及如何请求 TCC 权限'
  - '需要实现"权限未授权时显示卡片、授权后显示正常内容"的 UI 模式'
  - '理解为什么 AX 没有 Grant 按钮只有 Open Settings 按钮'
sources: ['N §11', 'N §11.6']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# Permission Card UX：Never-Auto-Prompt 模式

## TL;DR

NemoNotch 的权限 UI 原则：**启动时不主动请求任何 TCC 权限**。用户首次进入相关 Tab / Settings 页面时，看到的是 `PermissionCard`——一张包含图标、说明文字和 CTA 按钮的小卡片，取代正常功能内容。用户点击 **Grant** 按钮后，app 调用系统 API 请求权限（或跳转系统设置），卡片在权限授予后自动消失、功能内容随即显示。

AX（辅助功能）是特例：macOS 没有编程方式请求 AX 权限（`AXIsProcessTrustedWithOptions` 只弹一次，首次拒绝后不再弹），所以 AX 卡片没有 Grant 按钮，只有"Open Settings"直接跳 `Privacy_Accessibility` 深链。

---

## 可复用模式

### PermissionCard 组件结构

`NemoNotch/Helpers/PermissionCard.swift`：

```swift
/// 三态：notDetermined / denied / restricted
/// .authorized 故意省略——上层用 if-else 控制卡片可见性：
///   有权限 → 正常内容；无权限 → PermissionCard
enum PermissionStatus: Equatable {
    case notDetermined
    case denied
    case restricted
}

/// notDetermined 时 CTA 的行为
enum PermissionRequestability {
    case programmatic(() -> Void)  // 有 API 可调用 → 显示 Grant 按钮
    case settingsOnly              // 只能跳系统设置 → 不显示 Grant 按钮
}

struct PermissionCard: View {
    let icon: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
    let status: PermissionStatus
    let primary: PermissionRequestability
    let openSettings: () -> Void
    // ...
}
```

**CTA 按钮逻辑**（`PermissionCard.swift:52-63`）：

| `status` | `primary` | 显示 |
|----------|-----------|------|
| `.notDetermined` | `.programmatic(action)` | **Grant** + Settings（双按钮） |
| `.notDetermined` | `.settingsOnly` | **Open Settings**（单按钮） |
| `.denied` / `.restricted` | 任何 | **Open Settings**（强制跳设置，系统无法重新触发 prompt） |

### 四类权限的卡片配置

#### Calendar（EventKit）

`NemoNotch/Tabs/OverviewTab.swift:57-66`

```swift
PermissionCard(
    icon: "calendar.badge.lock",
    titleKey: "permission.calendar.title",
    detailKey: "permission.calendar.detail",
    status: calendarService.authorizationStatus == .denied ? .denied : .notDetermined,
    primary: .programmatic { calendarService.requestAccess() },   // EKEventStore.requestFullAccessToEvents
    openSettings: { calendarService.openSystemSettings() }
)
```

权限授予后，`calendarService.authorizationStatus` 变为 `.fullAccess`，父 `Group` switch 自动渲染正常内容（`@Observable` 驱动）。

#### Location（CoreLocation，天气 Tab）

`NemoNotch/Tabs/OverviewTab.swift:439-448`

```swift
PermissionCard(
    icon: "location.slash",
    titleKey: "permission.location.title",
    detailKey: "permission.location.detail",
    status: weatherService.locationAuthorizationStatus == .denied ? .denied : .notDetermined,
    primary: .programmatic { weatherService.requestLocationAccess() },
    openSettings: { weatherService.openLocationSettings() }
)
```

#### Automation（AppleEvents，媒体控制）

`NemoNotch/Tabs/OverviewTab.swift:222-233`

```swift
PermissionCard(
    icon: "lock.shield",
    titleKey: "permission.automation.title",
    detailKey: "permission.automation.detail",
    status: automationMonitor.state(for: player.rawValue) == .denied ? .denied : .notDetermined,
    primary: .programmatic { mediaService.requestAutomationAccess(for: player) },
    openSettings: { mediaService.openAutomationSettings() }
)
```

**注意**：Automation 卡片仅在当前播放的媒体 app 需要 ScriptingBridge（`KnownPlayer`：Music / Spotify）时显示，对其它 player 透明。

#### Accessibility（AX，Settings → Notification 列表）

`NemoNotch/Settings/SettingsView.swift:416-424`

```swift
PermissionCard(
    icon: "exclamationmark.triangle.fill",
    titleKey: "permission.accessibility.title",
    detailKey: "permission.accessibility.detail",
    status: .notDetermined,       // 首次拒绝后 AXIsProcessTrustedWithOptions 不弹，固定 notDetermined
    primary: .settingsOnly,       // 没有 Grant 按钮，只跳系统设置
    openSettings: { notificationService.openAccessibilitySettings() }
)
```

AX 没有 `programmatic` 入口：`AXIsProcessTrustedWithOptions(prompt: true)` 只在**首次**弹窗，之后沉默。所以这里用 `.settingsOnly`，引导用户手动在 `Privacy_Accessibility` 勾选。

#### Notifications（Pomodoro Settings）

`NemoNotch/Settings/PomodoroSettingsView.swift:83`

由 `NotificationPermissionMonitor`（`UNUserNotificationCenter` 轮询）驱动，`primary: .programmatic` 调用 `UNUserNotificationCenter.requestAuthorization`。

### @Observable 驱动卡片消失

权限状态存储在 `@Observable` Service 的属性上；SwiftUI 注入 via `@Environment`。当 Service 属性从"未授权"跳变为"已授权"时，父 `Group` / `if` 语句自动重渲染——卡片消失，功能内容出现，无需额外通知机制。

```swift
// CalendarService.swift — EventKit 授权成功后写属性
func requestAccess() {
    Task { @MainActor in
        let granted = try await eventStore.requestFullAccessToEvents()
        authorizationStatus = granted ? .fullAccess : .denied  // 写 @Observable 属性
        if granted { fetchEvents() }
    }
}

// OverviewTab — 纯声明式，无回调
Group {
    switch calendarService.authorizationStatus {
    case .fullAccess: calendarContent       // 授权后渲染这个
    default:          PermissionCard(...)   // 未授权渲染卡片
    }
}
```

per-permission 响应延迟（见 `macos-cookbook.md §11.6`）：

| 权限 | 写属性的机制 | 延迟 |
|------|-------------|------|
| Calendar | `.EKEventStoreChanged` → `authorizationStatus` | ~立即 |
| Accessibility | 2 s Timer → `isAXTrusted` | ≤ 2 s |
| Automation | `SBApplicationDelegate.eventDidFail(-1743)` → `notifyPermissionDenied()` | 下次 AS 调用时 |
| Location | `CLLocationManagerDelegate.didChangeAuthorization` → `locationAuthorizationStatus` | ~立即 |
| Notification | `UNUserNotificationCenter.getNotificationSettings` 轮询 | ≤ 轮询周期 |

---

## 锚点（file:line）

| 符号 | 文件:行 | 说明 |
|------|---------|------|
| `PermissionCard` | `NemoNotch/Helpers/PermissionCard.swift:22` | 组件定义 |
| `PermissionStatus` | `NemoNotch/Helpers/PermissionCard.swift:7` | 三态枚举 |
| `PermissionRequestability` | `NemoNotch/Helpers/PermissionCard.swift:17` | programmatic vs settingsOnly |
| Calendar 卡片 | `NemoNotch/Tabs/OverviewTab.swift:57-66` | EKEventStore |
| Automation 卡片 | `NemoNotch/Tabs/OverviewTab.swift:222-233` | ScriptingBridge per-player |
| Location 卡片 | `NemoNotch/Tabs/OverviewTab.swift:439-448` | CoreLocation |
| AX 卡片（settingsOnly） | `NemoNotch/Settings/SettingsView.swift:416-424` | 无 Grant 按钮 |
| Notification 卡片 | `NemoNotch/Settings/PomodoroSettingsView.swift:83` | UNUserNotificationCenter |
| Reactive bridge（§11.6） | `NemoNotch/Services/CalendarService.swift:9, 37-42` | EKEventStoreChanged |
| AX 轮询 | `NemoNotch/Services/NotificationService.swift:14, 84` | 2 s Timer |
| AE 拒绝回调 | `NemoNotch/Services/MediaBridge.swift:35-43` | `-1743` |

---

## Pitfalls

### 陷阱 1 · 不要在 AppDelegate / didFinishLaunching 里请求权限

**问题**：启动时立即弹多个 TCC 对话框，用户通常不看说明就全部拒绝，且拒绝后 `denied_sticky` 使后续 prompt 无法再弹（AX）。
**处理**：延迟到用户主动进入对应 Tab / 点击 Grant 按钮时才请求。

### 陷阱 2 · AX 的 `denied` 和 `notDetermined` 外观相同

**问题**：用户第一次拒绝 AX 后，App 仍显示 Grant 按钮（实际无效）。
**处理**：AX 卡片固定用 `.settingsOnly`；`AXIsProcessTrusted()` 返回 false 不管原因是"从未授权"还是"已拒绝"，处理路径相同——引导去系统设置。

### 陷阱 3 · 不要把 `authorized` 状态放进 `PermissionCard`

**设计意图**：父 view 用 `if-else` / `switch` 判断——有权限渲染功能，无权限渲染卡片。`PermissionCard` 本身不持有"已授权"状态，三态枚举没有 `.authorized`。这让调用点读起来清晰，不会在卡片里写隐式的"what to show when granted"逻辑。

### 陷阱 4 · Automation 卡片逻辑：仅对 KnownPlayer 显示

**问题**：Automation 卡片不是"全局有没有 ScriptingBridge 权限"，而是"当前播放 app 是否需要 ScriptingBridge"。浏览器播放音乐时不会显示卡片（浏览器不是 `KnownPlayer`）。
**处理**：`automationCardPlayer` computed property 先检查 `KnownPlayer(bundleID:)`，nil 则不渲染卡片。

---

## 落地 checklist

- [ ] 确认所有 TCC 权限不在启动时自动请求
- [ ] 每类权限：Service 用 `@Observable` 暴露授权状态属性
- [ ] 父 View 用 `switch` / `if` 控制 PermissionCard vs 正常内容
- [ ] Calendar / Location / Automation / Notification：`primary: .programmatic { service.request() }`
- [ ] AX：`primary: .settingsOnly`，`openSettings` 打开 `Privacy_Accessibility` 深链
- [ ] 已授权后，`@Observable` 属性变化 → SwiftUI 自动重渲染卡片消失
- [ ] `denied` 状态下 CTA 自动降级为 Open Settings（`PermissionCard` ctaRow 逻辑已处理）

---

## 延伸阅读

- [tcc-state-machine.md](tcc-state-machine.md) — TCC 七态状态机、三类权限生效时机、`in_effect` / `denied_sticky`
- [infoplist-pitfall.md](infoplist-pitfall.md) — GENERATE_INFOPLIST_FILE 陷阱（缺 UsageDescription 导致 PermissionCard 的 Grant 按钮永远不弹窗）
- [../keychain/](../keychain/) — Keychain `needsAuthorization` / Authorize 按钮（与本文 TCC PermissionCard 模式平行）
- [../accessibility/](../accessibility/) — AX 深度使用（Dock badge 读取、AXorcist）
