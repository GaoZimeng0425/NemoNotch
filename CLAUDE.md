# NemoNotch — CLAUDE.md

## 项目简介

NemoNotch 是一个 macOS 刘海工具，在 MacBook 刘海区域提供可交互的浮动面板，集成媒体控制、日历事件、Claude Code 监控和应用启动器。

## 技术栈

- Swift 5 + SwiftUI，仅 macOS，无第三方依赖
- 关键框架：AppKit（NSWindow）、MediaPlayer、EventKit

## 项目结构

```
NemoNotch/
├── NemoNotchApp.swift           # 入口，MenuBarExtra，全局快捷键
├── Models/                      # 数据模型（Tab, AppSettings, PlaybackState 等）
├── Notch/                       # 刘海 UI 核心（窗口、动画、事件监听）
├── Tabs/                        # 各标签页内容视图
├── Services/                    # 后台服务（媒体、日历、Claude Code、启动器）
├── Settings/                    # 设置界面
└── Helpers/                     # 工具类
```

## 参考项目指南

所有参考项目位于 `/Users/gaozimeng/Learn/macOS/`，遇到实现问题时优先查看这些项目的做法。

### 刘海窗口与交互

| 需求 | 参考项目 | 要点 |
|------|---------|------|
| 刘海窗口定位、多屏幕支持 | **NotchDrop** | `NotchWindow` 子类，`screen.notchSize` 检测，每屏独立 WindowController |
| 刘海动画、自动收起、内容切换 | **DynamicNotchKit** | Spring 动画 `.bouncy(duration: 0.4)`，Timer 自动消失，鼠标悬停延迟关闭 |
| 多视图状态机、Cmd-Tab 替代 | **Peninsula** | 复杂状态管理，Accessibility API 获取窗口/应用信息 |

### 媒体与播放控制

| 需求 | 参考项目 | 要点 |
|------|---------|------|
| Now Playing 信息获取 | **PlayStatus** / **Tuneful** | MediaPlayer 框架，MPNowPlayingInfoCenter 轮询 |
| 媒体键拦截 | **PlayStatus** | `sendEvent` override 拦截 `NX_KEYTYPE_PLAY` 等系统按键 |
| 命令行获取播放信息 | **nowplaying-cli** | 纯 CLI 方案，可参考其输出格式 |

### 窗口管理与快捷键

| 需求 | 参考项目 | 要点 |
|------|---------|------|
| 全局快捷键、窗口操作 | **Loop** | `WindowEngine` 架构，径向菜单，键盘事件处理 |
| Spotlight 风格搜索栏 | **DSFQuickActionBar** | NSPanel 浮窗，异步搜索，键盘导航（方向键/Enter/ESC） |
| Dock 悬停预览 | **DockDoor** | SCWindow 截图，窗口缩略图缓存，AXUIElement 控制窗口 |

### 菜单栏与系统工具

| 需求 | 参考项目 | 要点 |
|------|---------|------|
| 菜单栏架构、组件化 | **eul** | StatusBarManager，Combine 响应式，深色/浅色模式适配 |
| 菜单栏 B 站播放器 | **Bili.Mac.MenuBar** | 菜单栏内嵌复杂 UI |
| 菜单栏番茄钟 | **TomatoBar** | 轻量菜单栏应用模板 |
| 系统负载动画 | **menubar_runcat** | 动画帧驱动，反映系统状态 |

### 启动器与搜索

| 需求 | 参考项目 | 要点 |
|------|---------|------|
| 应用启动器 | **sol** / **Verve** | sol（原生 Swift）、Verve（Rust+Tauri）启动器架构 |
| 文件搜索、剪贴板 | **Snap** | Spotlight 替代方案，搜索与索引实现 |

### 通用参考

| 需求 | 参考项目 | 要点 |
|------|---------|------|
| SwiftUI + SwiftData | **NotesApp** | 现代 SwiftUI 数据持久化模式 |
| 代码片段管理 | **Snippets** | 数据管理 + 搜索 UI |
| 自定义 UI 组件 | **Luminare** / **CustomWindowStyle** | SwiftUI 组件库，窗口样式定制 |
| 全局语音输入 | **QuickSpeech** | 全局快捷键 + 系统集成 |
| 屏幕录制 | **Recorder** | ScreenCaptureKit 用法 |

## 开发约定

- 所有 Service 使用 `@Observable` 宏，通过 SwiftUI 响应式更新 UI
- 刘海窗口 level 固定为 `.statusBar + 8`，属性为 `fullScreenAuxiliary` + `stationary` + `canJoinAllSpaces`
- 优先查阅参考项目中的现成实现，避免从零造轮子
