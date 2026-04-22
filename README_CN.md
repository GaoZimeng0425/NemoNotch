# NemoNotch

macOS 刘海区域的交互式浮动面板，将 MacBook 的 Notch 变成一块多功能信息中心。

<p align="center">
  <img src="docs/images/screenshot.png" alt="NemoNotch 截图" width="700">
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

## 功能

### 7 个功能标签页

| 标签 | 功能 |
|------|------|
| **媒体控制** | 实时播放控制（播放/暂停/上下曲）、专辑封面、进度条，支持 Spotify 和 Apple Music |
| **日历** | 15 天日期选择器、当日事件列表、日历颜色标识、权限引导 |
| **Claude Code** | 会话列表、对话详情、权限审批、Context 用量进度条、子代理监控、模型显示 |
| **OpenClaw** | 多代理系统状态监控、WebSocket 实时连接、代理工作状态追踪 |
| **启动器** | 应用图标网格、搜索过滤、快速启动自定义应用列表 |
| **天气** | 当前温度/体感温度、高低温、湿度风速、3 小时逐时预报 |
| **系统** | CPU/内存/电池/磁盘监控、历史趋势图、颜色阈值警告 |

### 核心特性

- **Notch 浮动面板** — 窗口悬浮在刘海区域，自动检测屏幕 Notch 尺寸
- **全局快捷键** — `⌥⌘N` 切换面板开关，`⌥⌘1-7` 快速切换标签页
- **自动切换** — 智能检测活跃服务（Claude 工作中、音乐播放中）自动切到对应标签
- **菜单栏入口** — 通过菜单栏图标控制面板展开和 Claude Code Hooks 安装
- **Claude Code 深度集成** — Hook 事件监听、会话追踪、权限拦截、终端检测、中断感知

## 技术栈

- **Swift 5** + **SwiftUI**，纯 macOS 原生应用
- **AppKit** — 自定义 NSWindow，点击穿透，多屏幕定位
- **MediaPlayer / MediaRemote** — 媒体播放控制
- **EventKit** — 日历事件读取
- **IOKit** — 系统状态监控（CPU、内存、电池、磁盘）
- **CocoaLumberjack** — 日志系统（`~/.NemoNotch/logs/`，7 天轮转）
- **WebSocket / Unix Socket** — Claude Code Hooks 和 OpenClaw 通信

## 项目结构

```
NemoNotch/
├── NemoNotchApp.swift           # 入口，MenuBarExtra，全局快捷键
├── Models/                      # 数据模型（Tab, AppSettings, PlaybackState 等）
├── Notch/                       # 刘海 UI 核心（窗口、动画、事件监听）
├── Tabs/                        # 各标签页内容视图
├── Services/                    # 后台服务（媒体、日历、Claude Code、启动器等）
├── Settings/                    # 偏好设置界面
└── Helpers/                     # 工具类
```

## 构建

1. 使用 Xcode 打开 `NemoNotch.xcodeproj`
2. 选择 `NemoNotch` target
3. Build & Run（需要 macOS 14+）

## 鸣谢

NemoNotch 的开发借鉴了以下优秀开源项目的设计与实现：

### 刘海窗口与交互

- [**NotchDrop**](https://github.com/Lakr233/NotchDrop) — Notch 窗口定位、多屏幕支持、点击穿透
- [**DynamicNotchKit**](https://github.com/Lakr233/DynamicNotchKit) — Spring 动画、自动收起、内容切换
- [**Peninsula**](https://github.com/yufan8414/Peninsula) — 刘海区域多视图状态管理

### 媒体与播放控制

- [**PlayStatus**](https://github.com/nicklama/PlayStatus) — MediaRemote 框架集成、媒体键拦截
- [**Tuneful**](https://github.com/Dimillian/Tuneful) — 播放信息获取与 UI 展示
- [**nowplaying-cli**](https://github.com/kirtan-shah/nowplaying-cli) — 命令行获取播放信息

### 窗口管理与快捷键

- [**Loop**](https://github.com/MrKai77/Loop) — 全局快捷键注册、窗口操作引擎
- [**DSFQuickActionBar**](https://github.com/dagronf/DSFQuickActionBar) — 浮动搜索栏组件

### 显示器与系统监控

- [**MonitorControl**](https://github.com/MonitorControl/MonitorControl) — 通过 DisplayServices API 读取屏幕亮度

### 菜单栏与系统工具

- [**eul**](https://github.com/gao-sun/eul) — 菜单栏架构设计、Combine 响应式模式
- [**menubar_runcat**](https://github.com/Kyle-Ye/menubar_runcat) — 菜单栏状态动画

### 启动器与 UI 组件

- [**sol**](https://github.com/ospfranco/sol) — 应用启动器架构
- [**Luminare**](https://github.com/Dimillian/Luminare) — SwiftUI 组件库与设计语言

### AI 与桌面集成

- [**Vibe Notch**](https://github.com/farouqaldori/vibe-notch) — Claude Code 刘海通知、会话监控、权限审批交互
- [**masko-code**](https://github.com/nicepkg/masko-code) — Claude Code 状态监控与桌面覆盖层概念

## License

MIT
