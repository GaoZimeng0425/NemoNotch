# NotchApp - All-in-One Notch 信息中枢

## 概述

一个 macOS notch 应用，在刘海区域集中展示媒体播放、日历事件、Claude Code 运行状态，并提供快速应用启动功能。

## 技术栈

- **UI 框架**: SwiftUI + DynamicNotchKit
- **窗口管理**: NSPanel, level = `.mainMenu + 3`
- **应用驻留**: MenuBarExtra
- **最低版本**: macOS 14.0+

## 整体架构

```
┌─────────────────────────────────────────────┐
│                  NotchApp                    │
├──────────────┬──────────────┬───────────────┤
│  NotchShell  │  FeatureTabs │  Services     │
│  (UI 层)     │  (功能模块)   │  (数据层)     │
│              │              │               │
│ DynamicNotch │ MediaTab     │ MediaService  │
│ Kit 扩展     │ LauncherTab  │ CalendarSvc   │
│              │ CalendarTab  │ ClaudeCodeSvc │
│ TabBarView   │ ClaudeTab    │ LauncherSvc   │
│              │              │               │
├──────────────┴──────────────┴───────────────┤
│              NSPanel (window level)          │
│              .mainMenu + 3                   │
└─────────────────────────────────────────────┘
```

## Notch UI 层

### 收起状态（默认）

- notch 旁边显示紧凑徽章（DynamicNotchInfo）
- 优先级：Claude Code 工作中 > 正在播放音乐 > 即将日程
- 悬停预览，点击展开

### 展开状态

- 顶部 Tab 栏：`music.note` | `calendar` | `terminal` | `rocket`
- 下方显示当前 Tab 内容（约 300x200pt）
- 展开动画复用 DynamicNotchKit 的 spring 动画
- 失焦自动收起

## 功能模块

### 1. MediaTab（媒体播放）

- **框架**: MediaPlayer（MPNowPlayingCenter + MPRemoteCommandCenter）
- **显示**: 专辑封面缩略图、歌曲名、艺术家、播放进度条
- **控制**: 播放/暂停、上一首/下一首
- **支持**: 所有系统媒体播放器

### 2. CalendarTab（日历）

- **框架**: EventKit（EKEventStore）
- **显示**: 今日事件列表（标题、时间、日历颜色）
- **顶部**: 下一个事件倒计时
- **实时更新**: EKEventStoreChangedNotification 监听

### 3. ClaudeTab（Claude Code 状态）

- **通信**: NWListener HTTP 服务 + Claude Code hooks
- **安装**: 自动修改 `~/.claude/settings.json` 注册 hooks
- **状态机**: idle → working → waiting
- **显示**: 状态指示器、当前工具名称、会话耗时
- **收起提示**: 工作中时徽章动画

### 4. LauncherTab（快速启动）

- **API**: NSWorkspace
- **布局**: 3-4 列网格，应用图标 + 名称
- **搜索**: Spotlight 风格过滤
- **配置**: 用户可编辑应用列表

## 项目结构

```
NotchApp/
├── NotchApp.swift              # App 入口，MenuBarExtra
├── Notch/
│   ├── NotchCoordinator.swift  # DynamicNotch 生命周期管理
│   ├── CompactBadge.swift      # 收起状态徽章
│   └── TabBarView.swift        # Tab 切换栏
├── Tabs/
│   ├── MediaTab.swift
│   ├── CalendarTab.swift
│   ├── ClaudeTab.swift
│   └── LauncherTab.swift
├── Services/
│   ├── MediaService.swift      # MPRemoteCommandCenter
│   ├── CalendarService.swift   # EventKit
│   ├── ClaudeCodeService.swift # NWListener + hooks
│   └── LauncherService.swift   # NSWorkspace
├── Models/
│   ├── PlaybackState.swift
│   ├── CalendarEvent.swift
│   └── ClaudeState.swift
└── Helpers/
    └── HookInstaller.swift     # Claude Code hooks 注册
```

## 数据流

```
Service (ObservableObject)
    ↓ @Published 属性变化
Tab View (@ObservedObject)
    ↓ 用户交互
Service 方法 → 系统 API / HTTP 回调
```

## 技术决策

| 决策 | 选择 | 原因 |
|------|------|------|
| Notch 框架 | DynamicNotchKit | 成熟、纯 SwiftUI、无私有 API |
| 窗口层级 | `.mainMenu + 3` | 和 Peninsula 一致，不被普通窗口遮挡 |
| 媒体 API | MediaPlayer.framework | 系统原生，支持所有播放器 |
| 日历 API | EventKit | 官方 API，无需权限 hack |
| CC 监控 | Hooks + NWListener | 参考 masko-code，状态信息完整 |
| 应用驻留 | MenuBarExtra | 轻量，不占 Dock 位置 |
