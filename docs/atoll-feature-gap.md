# Atoll 功能对照 — NemoNotch 缺失清单

> 对照仓库：`/Users/gaozimeng/Learn/macOS/Atoll`（Ebullioscopic/Atoll，GPL v3）。
> 生成日期：2026-07-12。已完成的借鉴：天气双源 + 数字码图标映射（2e00c53）。
> ⚠️ Atoll 是 GPL v3 —— 只能参考思路重新实现，不能抄代码。

## 锁屏层（NemoNotch 完全没有的能力面）

| 功能 | Atoll 实现 | 说明 |
|------|-----------|------|
| 锁屏小组件 | `LockScreenWeatherManager` / `LockScreenTimerWidgetManager` / `LockScreenReminderWidgetManager` + SkyLightWindow | 天气/计时器/充电/蓝牙/提醒事项渲染到锁屏层，私有 API 窗口，无需付费开发者账号 |
| 锁屏媒体面板 | `LockScreenPanelManager` / `LockScreenLiveActivityWindowManager` | 锁屏上的正在播放卡片 |
| 锁屏外观定制 | `LockScreenWidgetPreviewManager` | 组件位置/样式可调，设置里带实时预览 |

## Live Activities（iOS 风格实况状态）

| 功能 | Atoll 实现 | 说明 |
|------|-----------|------|
| 隐私指示器 | `PrivacyIndicatorManager` + `CameraMonitor` / `MicrophoneMonitor` | 摄像头/麦克风被占用时刘海旁亮点 + 占用 App 名 |
| 屏幕录制指示 | `ScreenRecordingManager` | 录屏进行中的刘海提示 |
| 专注模式 | `DoNotDisturbManager`（57K） | Focus 开关状态展示与切换 |
| 充电/低电量事件 | `BatteryActivityManager` + `MacBatteryManager` | 插电动画、充满倒计时、低电量音效提醒 |
| 下载进度（beta） | `DownloadManager` | 监控下载文件夹进度 |
| 提醒事项 | `ReminderLiveActivityManager`（26K） | EventKit Reminders 到点在刘海弹实况 |
| Caps Lock 指示 | `CapsLockManager` | 大小写切换的刘海提示 |

## 效率工具

| 功能 | Atoll 实现 | 说明 |
|------|-----------|------|
| 剪贴板历史 | `ClipboardManager`（20K）+ 面板/浮窗 | 历史记录、搜索、固定 |
| 取色器 | `ColorPickerManager` | 屏幕取色 + 历史 |
| Shelf 文件架 | `Shelf` 组件 + LocalSend 集成 | 拖文件暂存、AirDrop、`open -a Atoll <file>` 从终端投递、LocalSend 跨设备互传 |
| 内嵌终端 | `TerminalManager`（28K，SwiftTerm） | 刘海面板里的终端 tab |
| 系统时钟计时器桥接 | `SystemTimerBridge`（40K，读 `com.apple.mobiletimerd`） | 与系统"时钟"App 的计时器双向同步展示 |
| Apple Notes 同步 | `AppleNotesSyncManager`（15K） | 便签速览 |
| Screen Assistant | `ScreenAssistantManager`（51K） | 截屏 + LLM 对话（Gemini 等）问答屏幕内容 |

## 媒体增强（NemoNotch 已有基础媒体控制）

| 功能 | Atoll 实现 | 说明 |
|------|-----------|------|
| 音乐可视化 | rtaudio（C++ 移植） | 实时频谱动画 |
| 全屏封面窗口 | `FullScreenArtworkWindowManager`（67K） | 封面铺满屏幕的沉浸视图 |
| 动态封面 | `AnimatedArtworkManager` | Apple Music 动态封面 |
| 手势控制 | ReadMe「Gesture Controls」 | 双指下滑开刘海/上滑关；音乐区横滑切歌或 ±10s，手势与按钮行为独立配置 |
| 媒体键拦截 | `MediaKeyInterceptor` | 接管 F7-F9 |
| Spotify OAuth | `SpotifyAuthManager` | 点赞/歌单等 Web API 能力 |
| AirPlay / 音频路由 | `AppleMusicAirPlayManager` + `AudioRouteManager` | 输出设备切换 |

## 系统监控 / HUD 增强

| 功能 | Atoll 实现 | 说明 |
|------|-----------|------|
| 系统 OSD 替换 | `SystemOSDManager` + `SystemHUDManager` | **压掉**系统原生音量/亮度 OSD，用自绘 HUD 替代（NemoNotch 是叠加，不抑制系统 OSD） |
| GPU / 网络 / 温度监控 | `StatsManager`（58K，SMC + IOReport） | CPU 温度、频率、per-core、GPU、网速——NemoNotch SystemTab 只有 CPU/内存/磁盘 |
| 蓝牙设备电量 | `BluetoothAudioManager`（98K） | AirPods 等电量展示 + 连接动画 |
| 外接显示器亮度 | `LunarManager` + `BetterDisplayManager` | 与 Lunar/BetterDisplay 联动调外屏 |
| 键盘背光 | `KeyboardBrightnessSensor` + `SystemKeyboardBacklightController` | 背光 HUD 与控制 |
| 摄像头预览 | `WebcamManager` | 刘海当镜子 |

## 产品化基建

| 功能 | Atoll 实现 | 说明 |
|------|-----------|------|
| 自动更新 | Sparkle（`Updates/appcast.xml`） | NemoNotch 目前手动下 DMG |
| Onboarding / What's New / Tips | `Onboarding`、`WhatsNewView`、`Tips` 组件 | 首启引导与版本亮点 |
| Shortcuts 集成 | `Shortcuts/ShortcutConstants.swift` | 快捷指令动作 |
| 空闲动画 | `IdleAnimationManager` + Lottie | 无事发生时刘海小动画 |
| Minimalistic 极简模式 | Alcove 风格布局 | 整体紧凑形态切换 |
| LLM 本地用量成本 | `JSONLUsageParser` + `ModelPricing`（已分析，见前次对话） | token 数 + 美元成本统计；NemoNotch 只有配额百分比。另有 Cursor 支持 |

## 反向对照（NemoNotch 有、Atoll 没有）

AI CLI 会话监控（Claude/Gemini/opencode/zcode 的 hook 管线 + 会话卡片）、多智能体监控（OpenClaw/Hermes）、完成闪光 + 全屏 toast、番茄钟 + TODO、App 启动器、Dock 通知徽标、Gemini 配额、徽章折叠扇形布局。核心差异：Atoll 走"系统全能面板"路线，NemoNotch 走"AI 工作流指挥台"路线。

## 如果要借鉴，个人建议优先级

1. **隐私指示器**（摄像头/麦克风占用）— 与现有 badge/Live 状态体系天然契合，实现小
2. **剪贴板历史** — 日常价值高，独立性强
3. **系统 OSD 替换** — 现有 HUDService 的自然升级
4. **蓝牙设备电量** — Overview/badge 顺手位
5. **Sparkle 自动更新** — 发版体验（需要稳定签名，与 Keychain 授权问题同根）
