# NemoNotch

macOS 刘海区域的交互式浮动面板，将 MacBook 的 Notch 变成一块多功能信息中心。

<p align="center">
  <img src="docs/images/Notch.png" alt="收起状态的刘海 — 一眼掌握 AI CLI 活动" width="720">
</p>

<p align="center"><em>实时展示 AI 会话与智能体状态。</em></p>

<p align="center">
  <img src="docs/images/tab-overview.png" alt="概览 — 媒体、日历与天气" width="720">
</p>

<p align="center">
  <img src="docs/images/tab-claude.png" alt="AI Chat" width="380">
  <img src="docs/images/tab-agents.png" alt="智能体" width="380">
</p>

<p align="center">
  <img src="docs/images/tab-pomodoro.png" alt="番茄钟" width="380">
  <img src="docs/images/tab-system.png" alt="系统" width="380">
</p>

<p align="center">
  <img src="docs/images/tab-launcher.png" alt="启动器" width="380">
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

## 功能

### 6 个功能标签页

| 标签 | 功能 |
|------|------|
| **概览 (Overview)** | 一个标签页里三块速览信息 —— **媒体**：实时播放控制（播放/暂停/上下曲/拖动进度）、专辑封面、进度条 —— 通过 Perl 桥接系统媒体控制，支持任何上报 Now Playing 的播放器（Apple Music、Spotify、浏览器、Podcasts、网易云音乐……）；**日历**：15 天日期选择器、当日事件列表、日历颜色标识、可点击会议链接；**天气**：当前温度/体感温度、高低温、湿度风速、可滚动 7 日预报、昼夜天气图标（Open-Meteo 数据源，wttr.in 兜底） |
| **AI Chat** | 统一 Claude Code、Gemini CLI、opencode 与 zcode 监控 — 会话列表、子代理追踪、模型显示；对话详情、权限审批与 Context 用量进度条仅限 Claude Code 与 Gemini CLI |
| **智能体** | 多代理系统状态监控，支持 OpenClaw（WebSocket）和 Hermes-agent（HTTP API），实时代理工作状态追踪 |
| **启动器** | 应用图标网格、搜索过滤、快速启动自定义应用列表 |
| **番茄钟** | 经典 25/5/15 周期（每 4 个工作长休息），快捷键呼出居中浮窗一键启动，notch 折叠态显示 🍅 + 饼图剩余时间；TODO 列表持久化，每个任务累计番茄钟数；结束时播放声音 + 系统通知 |
| **系统** | Top 5 进程资源排行（CPU 和内存）、应用图标、系统概览底栏（CPU / 内存 / 电池 / 网络） |

### 核心特性

- **Notch 浮动面板** — 窗口悬浮在刘海区域，自动检测屏幕 Notch 尺寸
- **多 AI 提供商** — 统一界面支持 Claude Code、Gemini CLI、opencode 与 zcode，集成 Hook 事件监听和会话追踪；权限拦截仅限 Claude Code 与 Gemini CLI。opencode 通过 NemoNotch 编写的插件（`~/.config/opencode/plugin/nemonotch-notify.ts`）集成，将生命周期事件 POST 到 NemoNotch 的 Hook 服务器 —— 刘海 badge、完成闪光、Toast 与 AI 标签页状态卡片均自动生效。zcode（基于 GLM、与 Claude Code 兼容）直接复用 Claude 的 Hook 管线（无需插件）—— 仅提供通知与实时状态，不解析对话/Token，也不支持刘海内审批
- **AI 用量配额** —— 在 AI 标签页以卡片展示 Claude Code、Codex 与 Gemini 的用量配额（使用率 % + 重置倒计时），数据来自各 CLI 的 OAuth 凭证。检测到 Codex / Gemini CLI 已登录时自动显示对应段。
- **全局快捷键** — 切换面板开关：在设置 → 快捷键里自行配置（默认无）。切换标签页默认 `⌥⌘1-5`。所有快捷键均可自定义，基于 [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- **自动切换** — 智能检测活跃服务（AI 工作中、音乐播放中）自动切到对应标签
- **活动光晕** — AI/Agent 忙碌时（运行中或等待审批），展开的刘海下半内边缘会泛起一层应用主题橘色的柔和模糊光晕，到中部渐隐消失（不遮挡正文）
- **完成闪光** — 当 AI 会话或 Agent 完成一轮任务（working→idle）时，NemoNotch 在所有屏幕边缘播放一次全屏橘色边缘光晕，并在屏幕下方居中显示一个更大的 Toast 胶囊（宽度随文字自适应），列出完成的项目/Agent 名称。番茄钟阶段结束提醒也复用同一个统一 Toast。短时间内的多次完成会节流合并，仅更新 Toast 而不重复播放闪光。可在设置中开关。

  <p align="center">
    <img src="docs/images/completion-flash.png" alt="完成闪光 — 全屏橘色边缘光晕 + 刘海旁完成提示 Toast" width="720">
  </p>
- **菜单栏入口** — 固定刘海图标（状态从刘海面板查看）；媒体播放时菜单显示正在播放控制区（上一曲 / 播放暂停 / 下一曲）
- **HUD 叠加层** — 音量、亮度、电池电量的分段条指示器
- **国际化** — 支持中文和英文，可在设置中切换
- **显式权限请求。** NemoNotch 启动时不会自动申请系统权限。每个需要权限的功能会在对应 Tab 中显示「授权」按钮(Overview 的日历、Weather 卡片的定位)— 点击触发系统弹窗。媒体控制完全不需要权限——走 Perl 桥实现。
- **ESC 关闭 Notch。** notch 打开时按 ESC 即可关闭。

## 技术栈

- **Swift 6** + **SwiftUI**，纯 macOS 原生应用
- **AppKit** — 自定义 NSWindow，点击穿透，多屏幕定位
- **MediaPlayer / MediaRemote** — 媒体播放控制
- **EventKit** — 日历事件读取
- **IOKit** — 系统状态监控（CPU、内存、电池、磁盘）
- **libproc** — 通过内核 API 实现进程级资源追踪
- **CocoaLumberjack** — 日志系统（`~/.NemoNotch/logs/`，7 天轮转）
- **KeyboardShortcuts** — 用户可自定义全局快捷键（替代 Carbon `RegisterEventHotKey`）
- **WebSocket / Unix Socket** — AI CLI Hooks 和 OpenClaw 通信
- **HTTP API** — 通过 localhost:8787 监控 Hermes-agent

## 项目结构

```
NemoNotch/
├── NemoNotchApp.swift           # 入口，MenuBarExtra，全局快捷键
├── Models/                      # 数据模型（Tab, AppSettings, AIProvider, PlaybackState 等）
├── Notch/                       # 刘海 UI 核心（窗口、动画、事件监听、TabBar、HUD）
├── Tabs/                        # 各标签页内容视图（AIChatTab 统一 AI 会话）
├── Services/                    # 后台服务（媒体、日历、AI CLI 监控、启动器等）
├── Settings/                    # 偏好设置界面
└── Helpers/                     # 工具类（MarkdownRenderer, ClaudeCrabIcon, ToolStyles）
```

## 构建

1. 使用 Xcode 打开 `NemoNotch.xcodeproj`
2. 选择 `NemoNotch` target
3. Build & Run（需要 macOS 14+）

> **注意：** 首次启动时如果 macOS 阻止打开应用，请执行以下命令移除隔离属性：
>
> ```bash
> sudo xattr -d com.apple.quarantine /Applications/NemoNotch.app
> ```

## 鸣谢

NemoNotch 的开发借鉴了以下优秀开源项目的设计与实现：

### 刘海窗口与交互

- [**NotchDrop**](https://github.com/Lakr233/NotchDrop) — Notch 窗口定位、多屏幕支持、点击穿透
- [**DynamicNotchKit**](https://github.com/MrKai77/DynamicNotchKit) — Spring 动画、自动收起、内容切换
- [**Peninsula**](https://github.com/celve/Peninsula) — 刘海区域多视图状态管理

### 媒体与播放控制

- [**mediaremote-adapter**](https://github.com/ejbills/mediaremote-adapter) — macOS 15.4+ 媒体控制的 Perl 桥（绕过私有 API 签名限制）

### 窗口管理与快捷键

- [**Loop**](https://github.com/MrKai77/Loop) — 全局快捷键注册、窗口操作引擎

### 显示器与系统监控

- [**MonitorControl**](https://github.com/MonitorControl/MonitorControl) — 通过 DisplayServices API 读取屏幕亮度

### 系统工具

- [**eul**](https://github.com/gao-sun/eul) — 菜单栏架构设计、Combine 响应式模式

### UI 组件

- [**Luminare**](https://github.com/MrKai77/Luminare) — SwiftUI 组件库与设计语言

### AI 与桌面集成

- [**Vibe Notch**](https://github.com/farouqaldori/vibe-notch) — Claude Code 刘海通知、会话监控、权限审批交互
- [**masko-code**](https://github.com/RousselPaul/masko-code) — Claude Code 状态监控与桌面覆盖层概念

### UI 与设计

- [**Notch Pilot**](https://notchpilot.app/) — 刘海面板布局、Tab 结构、控制台风格头部的视觉参考

## License

MIT
