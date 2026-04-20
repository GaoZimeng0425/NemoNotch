# NemoNotch 体验升级设计

> 定位：保持"轻量闭合 + 丰富展开"架构，全面升级交互、功能和视觉。

## 一、交互体验升级

### 1.1 三态动画系统（Closed → Breathing → Opened）

现有二态（closed/opened）升级为三态：

| 状态   | 尺寸              | 触发条件                        | 动画                                                      |
|--------|-------------------|---------------------------------|-----------------------------------------------------------|
| Closed | 200×32            | 默认状态                        | —                                                         |
| Breathing | 200×38 + 内容模糊预览 | 鼠标进入刘海周围 20px 范围   | `interactiveSpring(duration: 0.3, extraBounce: 0.15)` + 触觉反馈 |
| Opened | 500×280           | 鼠标继续靠近进入刘海区域，或点击 | `interactiveSpring(duration: 0.35)`                       |

- Closed → Breathing 可逆：鼠标离开范围自动缩回
- Breathing 态显示当前活跃 Tab 的缩略内容（歌名、温度等），提供发现感
- 参考实现：NotchDrop 的三态系统 + Combine 鼠标位置监听

### 1.2 滑动手势切换 Tab

展开态下新增：
- **左右滑动**：切换相邻 Tab，page-style 过渡动画
- **底部滑动指示器**：点状指示当前 Tab 位置
- 滑动手势与 Tab 栏点击并存，不互相干扰

参考：NotchNook / Dynamic Island 的横向滑动交互。

---

## 二、新增 Widget

### 2.1 天气 Tab

利用 macOS WeatherKit 获取数据（无需第三方 API Key）。

**紧凑态徽章**：当前温度 + 小天气图标（如 `23° ☀️`）

**展开态内容**：
- 当前天气图标 + 温度 + 体感温度 + 城市名
- 今日最高/最低温
- 未来 3 小时简要预报（横排 3 个时段）
- 风速、湿度一行简报

**定位**：CoreLocation 获取当前位置，首次请求系统授权。

**Service 设计**：`WeatherService`
- `@Observable` 类
- 属性：`currentTemp`, `condition`, `highLow`, `hourlyForecast`, `humidity`, `windSpeed`
- 每 10 分钟刷新一次，位置变化时触发更新
- 无网络时显示上次缓存数据

### 2.2 系统信息 Tab

用 `sysctl` / `IOReport` / `IOKit` 获取本机数据。

**紧凑态徽章**：CPU 使用率百分比 或 电池电量（用户可配置）

**展开态内容**：
- CPU 使用率（迷你折线图，保留最近 60 秒数据）
- 内存使用量 / 总量（进度条）
- 电池电量 + 充电状态 + 剩余时间
- 磁盘可用空间

**刷新频率**：每 2 秒采样，低开销。

**Service 设计**：`SystemService`
- `@Observable` 类
- 属性：`cpuUsage`, `cpuHistory: [Double]`, `memoryUsed`, `memoryTotal`, `batteryLevel`, `isCharging`, `timeRemaining`, `diskFree`
- Timer 驱动采样，历史数据环形缓冲区（60 个采样点）

### 2.3 Tab 布局调整

新增后共 7 个 Tab：媒体、日历、Claude、OpenClaw、启动器、天气、系统。

默认启用：媒体、天气、系统（最常用）。其余在设置中由用户开启。

---

## 三、视觉设计升级

### 3.1 深色实心面板

展开态采用深色背景，与硬件刘海融为一体：

- **背景色**：`#1C1C1E`（systemGray6 暗色），非纯黑以保留层次感
- **圆角**：闭合态 8px，展开态 24px
- **投影**：展开时 `radius: 12, opacity: 0.4` 柔和阴影
- **内容区卡片**：`#2C2C2E` 底色 + 8px 圆角做层次分隔

### 3.2 动画细节打磨

- **Badge 出现**：`scaleEffect` 从 0.5 弹出到 1.0 + spring 动画
- **Tab 切换**：`slideTransition`（新内容右滑入、旧内容左滑出）
- **闭合动画**：内容先 fade-out（0.1s），再收起尺寸（0.2s），避免内容被挤压
- **Breathing 态**：背景略微提亮到 `#252528`，暗示可交互

### 3.3 紧凑态多 Badge 排列

现有左/右各一个 Badge 升级为：
- 多个 Badge 横排显示（音乐图标 + 天气温度 + CPU 百分比）
- Badge 间距 4px，超出空间自动省略低优先级
- 每个 Badge 点击可快速展开到对应 Tab

---

## 四、参考实现资源

| 功能点 | 参考项目 | 关键文件 |
|--------|---------|---------|
| 三态动画 | NotchDrop | `NotchViewModel.swift`, `NotchViewModel+Events.swift` |
| 鼠标接近检测 | NotchDrop | Combine 鼠标位置监听 |
| 滑动手势 | NotchNook (闭源) | 自行实现 DragGesture |
| Spring 动画 | DynamicNotchKit | `DynamicNotch.swift` `.bouncy(duration: 0.4)` |
| 天气 API | WeatherKit | Apple 原生框架 |
| 系统监控 | eul / menubar_runcat | sysctl + IOKit 采样 |

---

## 五、实施建议（分阶段）

### Phase 1：交互基础
- 三态动画系统（Closed/Breathing/Opened）
- 触觉反馈集成

### Phase 2：新 Widget
- SystemService + 系统信息 Tab
- WeatherService + 天气 Tab

### Phase 3：手势 + 视觉
- 滑动手势 Tab 切换
- 动画细节打磨（Badge 弹出、Tab 滑动过渡、闭合序列）
- 多 Badge 横排排列
