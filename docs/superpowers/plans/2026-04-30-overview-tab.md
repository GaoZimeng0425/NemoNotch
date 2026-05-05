# Overview Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Media、Calendar、Weather 三个独立 Tab 合并为横向三列的 Overview Tab，各列为独立圆角卡片，无媒体时媒体卡折叠消失。

**Architecture:** 新建 `OverviewTab.swift` 含三个 private section view；更新 `Tab` enum 移除三旧 case、加入 `.overview`；更新 `NotchView`、`AppSettings`、`NemoNotchApp` 中的引用；删除旧三个 Tab 文件。

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, `GeometryReader` 比例布局，`withAnimation(.spring)` 折叠动画。

---

## File Map

| 操作 | 文件 |
|------|------|
| **Create** | `NemoNotch/Tabs/OverviewTab.swift` |
| **Modify** | `NemoNotch/Models/Tab.swift` |
| **Modify** | `NemoNotch/Models/AppSettings.swift` |
| **Modify** | `NemoNotch/Notch/NotchView.swift` |
| **Modify** | `NemoNotch/NemoNotchApp.swift` |
| **Modify** | `NemoNotch/Resources/Localizable.xcstrings` |
| **Delete** | `NemoNotch/Tabs/MediaTab.swift` |
| **Delete** | `NemoNotch/Tabs/CalendarTab.swift` |
| **Delete** | `NemoNotch/Tabs/WeatherTab.swift` |

---

### Task 1: 更新本地化文件，新增 overview key，移除三旧 key

**Files:**
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

- [ ] **Step 1: 在 `Localizable.xcstrings` 中找到 `models.tab.launcher` 块（约第 568 行），在其前面插入 `models.tab.overview` 块**

在 `"models.tab.launcher"` 的 `{` 之前插入：

```json
    "models.tab.overview" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Overview"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "概览"
          }
        }
      }
    },
```

- [ ] **Step 2: 删除 `models.tab.media`、`models.tab.calendar`、`models.tab.weather` 三个完整 JSON 块**

删除以下三段（含末尾逗号）：
- `"models.tab.calendar" : { ... }` （约第 552–567 行）
- `"models.tab.media" : { ... }` （约第 584–599 行）
- `"models.tab.weather" : { ... }` （约第 632–647 行）

- [ ] **Step 3: 构建确认无编译错误**

```bash
cd /Users/gaozimeng/Learn/macOS/NemoNotch
xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | grep -E "error:|warning:|BUILD"
```

预期：出现 `BUILD SUCCEEDED`（此时因 Tab.swift 还有旧 case 会有 warning，无 error 即可继续）

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Resources/Localizable.xcstrings
git commit -m "i18n: add overview tab key, remove media/calendar/weather tab keys"
```

---

### Task 2: 更新 Tab enum

**Files:**
- Modify: `NemoNotch/Models/Tab.swift`

- [ ] **Step 1: 将 `Tab.swift` 全部替换为新内容**

```swift
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview
    case claude
    case openclaw
    case launcher
    case system

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .claude: "cpu"
        case .openclaw: "ladybug"
        case .launcher: "square.grid.2x2"
        case .system: "gearshape.2"
        }
    }

    var title: String {
        switch self {
        case .overview: String(localized: "models.tab.overview")
        case .claude: String(localized: "models.tab.ai")
        case .openclaw: String(localized: "models.tab.openclaw")
        case .launcher: String(localized: "models.tab.launcher")
        case .system: String(localized: "models.tab.system")
        }
    }
}

extension Tab {
    static func sorted(_ tabs: Set<Tab>) -> [Tab] {
        tabs.sorted { allCases.firstIndex(of: $0)! < allCases.firstIndex(of: $1)! }
    }
}
```

- [ ] **Step 2: 构建，记录所有因移除旧 case 导致的编译错误（后续 Task 修复）**

```bash
xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | grep "error:" | head -30
```

预期：出现若干 `error: type 'Tab' has no member 'media'` 等错误，属正常，记录位置供后续修复。

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Models/Tab.swift
git commit -m "feat(tab): add .overview case, remove .media/.calendar/.weather"
```

---

### Task 3: 更新 AppSettings 默认值

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift`

- [ ] **Step 1: 将 `init()` 中 `defaultTab` 回退值从 `.media` 改为 `.overview`**

找到（约第 65 行）：
```swift
self.defaultTab = storedTab ?? .media
```
替换为：
```swift
self.defaultTab = storedTab ?? .overview
```

- [ ] **Step 2: 构建确认 AppSettings.swift 无错误**

```bash
xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | grep "AppSettings" | grep "error:"
```

预期：无输出（无 AppSettings 相关 error）

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Models/AppSettings.swift
git commit -m "feat(settings): change default tab to .overview"
```

---

### Task 4: 创建 OverviewTab.swift

**Files:**
- Create: `NemoNotch/Tabs/OverviewTab.swift`

- [ ] **Step 1: 创建文件，写入完整内容**

```swift
import EventKit
import SwiftUI

// MARK: - OverviewTab

struct OverviewTab: View {
    @Environment(MediaService.self) var mediaService

    private var isPlaying: Bool { !mediaService.playbackState.isEmpty }

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 6
            let numGaps: CGFloat = isPlaying ? 2 : 1
            let totalCardWidth = geo.size.width - gap * numGaps

            let calendarWidth = totalCardWidth * (isPlaying ? 2.0 / 5.0 : 2.0 / 3.0)
            let mediaWidth = totalCardWidth * 2.0 / 5.0
            let weatherWidth = totalCardWidth * (isPlaying ? 1.0 / 5.0 : 1.0 / 3.0)

            HStack(alignment: .top, spacing: gap) {
                OverviewCalendarSection()
                    .frame(width: calendarWidth)

                if isPlaying {
                    OverviewMediaSection()
                        .frame(width: mediaWidth)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .trailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .trailing))
                        ))
                }

                OverviewWeatherSection()
                    .frame(width: weatherWidth)
            }
            .animation(.spring(duration: 0.3, bounce: 0.05), value: isPlaying)
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Calendar Section

private struct OverviewCalendarSection: View {
    @Environment(CalendarService.self) var calendarService
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        Group {
            switch calendarService.authorizationStatus {
            case .fullAccess:
                calendarContent
            default:
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.lock")
                        .font(.system(size: 20))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("calendar.permission_required")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }

    private var calendarContent: some View {
        VStack(spacing: 0) {
            Text(calendarService.monthLabel(locale: appSettings.currentLocale))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 6)

            DateStripView(
                dates: calendarService.dateRange,
                selectedDate: calendarService.selectedDate,
                hasEvents: { calendarService.hasEvents(on: $0) },
                onSelect: { calendarService.selectedDate = $0 },
                locale: appSettings.currentLocale
            )
            .padding(.vertical, 2)
            .padding(.horizontal, 4)

            Divider()
                .background(NotchTheme.stroke)
                .padding(.vertical, 2)

            eventList
        }
    }

    private var eventList: some View {
        let events = calendarService.eventsForSelectedDate
        return Group {
            if events.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 18))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Text("calendar.no_events")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(events) { event in
                            CalendarEventRow(event: event)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .notchScrollEdgeShadow(.vertical, thickness: 10, intensity: 0.36)
            }
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(cgColor: event.calendarColor))
                .frame(width: 3, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(event.isPast ? NotchTheme.textMuted : NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(eventTimeRange)
                    .font(.system(size: 9))
                    .foregroundStyle(event.isPast ? NotchTheme.textMuted.opacity(0.75) : NotchTheme.textSecondary)
            }

            Spacer(minLength: 0)

            if event.meetingURL != nil {
                CalendarMeetingIcon(platform: event.meetingPlatform)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered && event.meetingURL != nil ? NotchTheme.surfaceEmphasis : NotchTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isHovered && event.meetingURL != nil ? NotchTheme.accent.opacity(0.4) : NotchTheme.stroke,
                            lineWidth: 0.6
                        )
                )
        )
        .opacity(event.meetingURL != nil ? 1 : event.isPast ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            if event.meetingURL != nil { isHovered = hovering }
        }
        .onTapGesture {
            if let url = event.meetingURL { NSWorkspace.shared.open(url) }
        }
    }

    private var eventTimeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if event.isAllDay { return String(localized: "calendar.all_day") }
        return "\(formatter.string(from: event.startDate)) - \(formatter.string(from: event.endDate))"
    }
}

private struct CalendarMeetingIcon: View {
    let platform: MeetingPlatform

    var body: some View {
        Circle()
            .fill(platform.iconColor.opacity(0.2))
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: platform.iconName)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(platform.iconColor)
            )
    }
}

// MARK: - Media Section

private struct OverviewMediaSection: View {
    @Environment(MediaService.self) var mediaService

    private var state: PlaybackState { mediaService.playbackState }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                artwork
                trackInfo
                Spacer(minLength: 0)
            }
            progressBar
            controls
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .center)
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let data = state.artworkData, let nsImage = NSImage(data: data) {
                    GeometryReader { geo in
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.08))
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(.white.opacity(0.3))
                        }
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)

            if let appIcon = mediaService.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 13, height: 13)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
        }
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
            Text(state.artist)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NotchTheme.surfaceEmphasis)
                Capsule()
                    .fill(NotchTheme.accent.opacity(0.75))
                    .frame(width: state.duration > 0 ? geo.size.width * CGFloat(state.position / state.duration) : 0)
            }
        }
        .frame(height: 2)
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button(action: { mediaService.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchTheme.textSecondary)
            }
            .buttonStyle(.plain)

            Button(action: { mediaService.togglePlayPause() }) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(NotchTheme.accent))
            }
            .buttonStyle(.plain)

            Button(action: { mediaService.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Weather Section

private struct OverviewWeatherSection: View {
    @Environment(WeatherService.self) var weatherService

    var body: some View {
        Group {
            if !weatherService.isLoaded {
                ProgressView()
                    .controlSize(.small)
                    .tint(NotchTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                weatherContent
            }
        }
        .notchCard(radius: 8, fill: NotchTheme.surface)
    }

    private var weatherContent: some View {
        VStack(spacing: 4) {
            Text(weatherService.cityName)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)

            HStack(spacing: 2) {
                Image(systemName: conditionIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(NotchTheme.textSecondary)
                Text("\(Int(weatherService.temperature))°")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(NotchTheme.textPrimary)
            }

            Text(weatherService.condition)
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
                .multilineTextAlignment(.center)

            Divider()
                .background(NotchTheme.stroke)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)

            VStack(spacing: 4) {
                statItem(label: String(localized: "weather.feels_like"), value: "\(Int(weatherService.feelsLike))°")
                statItem(label: String(localized: "weather.humidity"), value: "\(weatherService.humidity)%")
                statItem(label: String(localized: "weather.wind_speed"), value: "\(Int(weatherService.windSpeed))")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private func statItem(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
        }
    }

    private var conditionIcon: String {
        let lower = weatherService.condition.lowercased()
        if lower.contains("sunny") || lower.contains("clear") { return "sun.max.fill" }
        if lower.contains("partly cloudy") { return "cloud.sun.fill" }
        if lower.contains("cloudy") || lower.contains("overcast") { return "cloud.fill" }
        if lower.contains("rain") || lower.contains("drizzle") { return "cloud.rain.fill" }
        if lower.contains("snow") { return "snowflake" }
        if lower.contains("thunder") { return "cloud.bolt.fill" }
        if lower.contains("fog") || lower.contains("mist") { return "cloud.fog.fill" }
        return "cloud.sun.fill"
    }
}
```

- [ ] **Step 2: 构建，确认 OverviewTab.swift 本身无编译错误**

```bash
xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | grep "OverviewTab" | grep "error:"
```

预期：无 OverviewTab 相关 error（其他文件引用旧 Tab case 的 error 仍存在，Task 5 修复）

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Tabs/OverviewTab.swift
git commit -m "feat(tab): add OverviewTab with calendar/media/weather sections"
```

---

### Task 5: 更新 NotchView.swift

**Files:**
- Modify: `NemoNotch/Notch/NotchView.swift`

- [ ] **Step 1: 将 `BadgeItem.tab` 属性中 `.media` 和 `.calendar` 两个 case 改为 `.overview`**

找到（约第 49–57 行）：
```swift
var tab: Tab {
    switch self {
    case .notification: .media
    case .media: .media
    case .ai: .claude
    case .openclaw: .openclaw
    case .calendar: .calendar
    }
}
```
替换为：
```swift
var tab: Tab {
    switch self {
    case .notification: .overview
    case .media: .overview
    case .ai: .claude
    case .openclaw: .openclaw
    case .calendar: .overview
    }
}
```

- [ ] **Step 2: 将 `tabContent` computed property 中旧三个 case 替换为 `.overview`**

找到（约第 312–332 行）：
```swift
@ViewBuilder
private var tabContent: some View {
    switch coordinator.selectedTab {
    case .media:
        MediaTab()
    case .calendar:
        CalendarTab()
    case .claude:
        AIChatTab()
    case .openclaw:
        OpenClawTab()
    case .launcher:
        LauncherTab {
            coordinator.notchClose()
        }
    case .weather:
        WeatherTab()
    case .system:
        SystemTab()
    }
}
```
替换为：
```swift
@ViewBuilder
private var tabContent: some View {
    switch coordinator.selectedTab {
    case .overview:
        OverviewTab()
    case .claude:
        AIChatTab()
    case .openclaw:
        OpenClawTab()
    case .launcher:
        LauncherTab {
            coordinator.notchClose()
        }
    case .system:
        SystemTab()
    }
}
```

- [ ] **Step 3: 构建，确认 NotchView.swift 无编译错误**

```bash
xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | grep "NotchView" | grep "error:"
```

预期：无 NotchView 相关 error

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Notch/NotchView.swift
git commit -m "feat(notch): wire OverviewTab in NotchView, update badge tab routing"
```

---

### Task 6: 更新 NemoNotchApp.swift 中的 autoSelectTab

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift`

- [ ] **Step 1: 将 `autoSelectTab` 闭包中 `.media` 改为 `.overview`**

找到（约第 162 行）：
```swift
if self.mediaService?.playbackState.isPlaying == true { return .media }
```
替换为：
```swift
if self.mediaService?.playbackState.isPlaying == true { return .overview }
```

- [ ] **Step 2: 构建，确认整个项目无编译错误**

```bash
xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | grep -E "^.*error:" | head -20
```

预期：无 error，只有零星 warning

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift
git commit -m "feat(app): auto-select .overview when media is playing"
```

---

### Task 7: 删除旧三个 Tab 文件，全量构建验证

**Files:**
- Delete: `NemoNotch/Tabs/MediaTab.swift`
- Delete: `NemoNotch/Tabs/CalendarTab.swift`
- Delete: `NemoNotch/Tabs/WeatherTab.swift`

- [ ] **Step 1: 删除旧文件**

```bash
rm /Users/gaozimeng/Learn/macOS/NemoNotch/NemoNotch/Tabs/MediaTab.swift
rm /Users/gaozimeng/Learn/macOS/NemoNotch/NemoNotch/Tabs/CalendarTab.swift
rm /Users/gaozimeng/Learn/macOS/NemoNotch/NemoNotch/Tabs/WeatherTab.swift
```

- [ ] **Step 2: 确认文件已删除（项目使用目录引用，无需 Xcode 手动移除）**

在命令行确认文件不存在：
```bash
ls /Users/gaozimeng/Learn/macOS/NemoNotch/NemoNotch/Tabs/
```
预期：只有 `AIChatTab.swift`、`ChatMessageView.swift`、`DateStripView.swift`、`LauncherTab.swift`、`OpenClawTab.swift`、`OverviewTab.swift`、`SystemTab.swift`、`WeatherTab.swift` 不存在。

- [ ] **Step 3: 全量构建，确认 BUILD SUCCEEDED**

```bash
xcodebuild -scheme NemoNotch -destination 'platform=macOS' build 2>&1 | tail -5
```

预期输出包含：
```
** BUILD SUCCEEDED **
```

- [ ] **Step 4: Commit**

```bash
git add -u NemoNotch/Tabs/
git commit -m "refactor(tab): delete MediaTab, CalendarTab, WeatherTab (merged into OverviewTab)"
```

---

### Task 8: 运行应用，验证 UI

- [ ] **Step 1: 在 Xcode 中 Run（或命令行启动）**

```bash
open /Users/gaozimeng/Learn/macOS/NemoNotch/build/NemoNotch.app 2>/dev/null \
  || xcodebuild -scheme NemoNotch -destination 'platform=macOS' -derivedDataPath /tmp/NemoNotchBuild build && \
     open /tmp/NemoNotchBuild/Build/Products/Debug/NemoNotch.app
```

- [ ] **Step 2: 验证以下场景**

1. **有媒体播放时**：刘海展开后显示三列（日历 / 媒体 / 天气），比例约 2:2:1
2. **无媒体播放时**：媒体卡以 spring 动画折叠消失，日历和天气按 2:1 撑满
3. **TabBar**：只有 5 个图标（overview / claude / openclaw / launcher / system），overview 显示 `rectangle.3.group` 图标
4. **媒体 badge**：播放时刘海两侧出现封面缩略图 badge，点击后跳到 overview tab
5. **日历 badge**：临近事件时 badge 显示日历图标，点击后跳到 overview tab
6. **Settings**：Tab 管理列表中不再显示 media/calendar/weather，只有 overview 等 5 项

- [ ] **Step 3: 若发现布局问题，调整 OverviewTab.swift 中 padding/spacing 后重新构建**

- [ ] **Step 4: 最终 Commit（如有微调）**

```bash
git add NemoNotch/Tabs/OverviewTab.swift
git commit -m "fix(overview): adjust card spacing/padding for visual balance"
```
