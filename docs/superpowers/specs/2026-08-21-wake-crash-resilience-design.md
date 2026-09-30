# 设计:唤醒崩溃韧性(wake-crash resilience)

- **日期**:2026-08-21
- **分支**:`feature/crash-resilience`(基于 develop)
- **状态**:已通过设计评审,待实现计划

## 目标

修复 2026-08-19 暴露的唤醒崩溃问题的工程韧性,分三层:

1. **L1 唤醒退避**:屏幕参数变化通知触发的窗口重建,不再在 AppKit 唤醒重配的同步路径上执行 —— 消除我们这一侧的已知诱因。
2. **L2 崩溃自愈**:平台层 bug 无法归零,保证致命信号后 ≤3s 自动恢复,带熔断防崩溃循环。
3. **L3 唤醒可观测**:每次唤醒留一份窗口/屏幕快照,让下次复发有崩溃前后对照。

## 背景

### 根因摘要

2026-08-19 19:08 唤醒后 1 秒,主线程在 `-[NSApplication run]` 排干 autorelease pool 时对一个已释放的
`NSStatusBarWindow` 再次 `objc_release` → SIGSEGV → 进程死亡。崩溃栈无任何本应用代码帧,定性为
macOS 26 唤醒路径上 AppKit 的过度释放(JetBrains JBR-9859、MonitorControl #1737、BetterDisplay、
boring.notch #336/#420/#370 均为同类先例)。证据链见崩溃报告
`~/Library/Logs/DiagnosticReports/NemoNotch-2026-08-19-190843.ips` 与应用日志
`~/.NemoNotch/logs/com.nemo.BrightnessApp.NemoNotch 2026-08-19--09-44-44-268.log`(行 8724–8789)。

### 我们这一侧的诱因

- `NotchCoordinator.screenParametersChanged`(`Notch/NotchCoordinator.swift:283`)与
  `CompletionFlashWindowController` 的 observer(`Notch/CompletionFlashWindow.swift:41`)在
  `didChangeScreenParametersNotification` 回调里**同步**销毁/重建/挪动 NSPanel;该通知在唤醒时于
  AppKit 自身重配中途发出、可能连发多次 —— 我们的窗口 churn 与 AppKit 的状态栏重建交错。
- 全仓没有任何 `didWake` 处理器:应用对"唤醒"这个高危时段与"插拔显示器"一视同仁。
- 本次崩溃实测:开盖 IOKit 消息后 ~1.4s 崩溃,唤醒重配窗口内主 runloop 曾出现 198.6ms 慢转。

## 非目标(YAGNI)

- 不迁移 MenuBarExtra → 手动 NSStatusItem(macOS 26 另一类已知故障,独立后续任务)。
- 不修 KeepAwakeService 启动即 deinit 异常(独立缺陷,另开任务;证据:2026-08-19 各启动窗口的
  `[KeepAwake] KeepAwakeService init/deinit` 日志对)。
- 不做冷/热事件分类仲裁服务(去抖 + 唤醒静默期已覆盖其 90% 价值)。
- 不追求"彻底不崩" —— 平台层概率只能压低,目标改为恢复速度。
- 不改任何重建逻辑本身(rebuildSlots / rebuild 的 diff 算法零改动,只改触发时机)。

## 决策回顾

| 项 | 决策 | 备选与否决理由 |
|---|---|---|
| 自愈机制 | 信号处理器 + posix_spawn 重启脚本 | LaunchAgent KeepAlive:ad-hoc 签名下 SMAppService 有"register 成功但不跑"实测前科,需 PoC;仅手动入口:常驻体验打折 |
| MenuBarExtra | 保留,不迁移 | 迁移与本次故障不同源,改动面翻倍 |
| L1 策略 | 去抖 0.5s + 唤醒静默期 2.5s | 仅 next-runloop 异步:仍落在 ~1.4s 重配窗口内且不去抖;仲裁服务:过度设计 |
| 信号集 | SIGSEGV / SIGBUS / SIGILL / SIGABRT | 观测崩溃为 SIGSEGV;其余为同族内存错误与 Swift 运行时陷阱,熔断兜底防循环 |

## 设计

### L1:WakeObserver + 去抖调度

**新组件 `WakeObserver`**(`NemoNotch/Notch/WakeObserver.swift`,`@MainActor`,单例,`AppDelegate` 创建):

- 订阅 `NSWorkspace.didWakeNotification`;唤醒时:
  1. `quietAfter = Date().addingTimeInterval(NotchConstants.wakeBackoff)` —— 屏幕重建不得早于该时刻;
  2. 输出 L3 诊断快照(见下)。
- 暴露 `var quietAfter: Date`(读时取 `max(now, 已设值)` 语义即可,唤醒前为 distantPast)。

**两个调用点改造**(重建逻辑零改动,只改触发时机,统一"取消-重调度"模式):

- `NotchCoordinator.screenParametersChanged`:取消在途重建 Task → 以
  `delay = max(screenRebuildDebounce, quietAfter - now)` 调度唯一的 `rebuildSlots()` + 活动屏失效检查。
- `CompletionFlashWindowController` 的 screen-params observer:同模式包住 `rebuild()`。
- 连发 N 次通知只产生 1 次重建(去抖合并)。
- **例外**:两者 `init` 里的首次构建保持同步 —— 冷路径,窗口必须先于首帧存在,且启动不在唤醒窗口内。

**常量**(进 `NotchConstants`):`screenRebuildDebounce = 0.5s`、`wakeBackoff = 2.5s`。
依据:崩溃发生在开盖后 ~1.4s,2.5s 留余量;插拔显示器场景 notch 晚 0.5s 出现,无感。

### L2:CrashRelaunch(信号处理器自愈 + 熔断)

**新组件 `CrashRelaunch`**(`NemoNotch/Services/CrashRelaunch.swift`,~120 行):

**启动时**(`applicationDidFinishLaunching` 最前置;`UITestMode.isActive` 或 `P_TRACED`(sysctl 检测调试器)时整体跳过):

1. 读熔断标记 `~/.NemoNotch/crash-relaunch.count`(纯文本数字;**时间戳用文件 mtime** —— 信号处理器内无需格式化)。
2. 熔断判定(纯函数,可单测):
   - mtime 距今 < `crashLoopWindow = 10min` 且 count ≥ `crashLoopLimit = 3` → **不装处理器**,打 `.warn`,重置计数;
   - mtime 距今 < 窗口且 count < 3 → 装处理器,预格式化 count+1 载荷供处理器写入;
   - mtime 距今 ≥ 窗口(过期)→ 装处理器,计数从 1 起。
3. 稳定运行 `stableRun = 5min` 后删除标记 —— 健康运行清零,下周再崩仍自愈。
4. 启动发现近期崩溃标记 → 打 `.warn`("上次运行因致命信号退出,count=N,已自愈")—— 即自愈的溯源日志。

**信号处理器**(SIGSEGV/SIGBUS/SIGILL/SIGABRT,`sigaction` 安装;**只做 async-signal-safe 操作**):

1. `open`+`write`+`close` 写入**启动时预格式化**的 count 载荷(路径、内容均预构建;处理器内零格式化、零 ObjC、零 malloc、无锁);
2. `posix_spawn` 重启:`/bin/sh -c "sleep 1; open -b com.nemo.BrightnessApp.NemoNotch"`(argv 启动时预构建;spawn attrs 带 `POSIX_SPAWN_SETSIGDEF` 复位致命信号,防子进程继承处理器);
3. `signal(sig, SIG_DFL)` + `raise(sig)` —— 进程以真实信号死亡,**macOS 崩溃报告照常生成**,诊断不丢。

**与 KeepAwake 的交互**:崩溃路径不走 `restoreForQuit`,残留 `SleepDisabled=1` 由下次启动的既有对账逻辑处理(现有设计已覆盖,零改动)。

**菜单顺风车**:`AppSection` 增加"重启 NemoNotch"项 —— 先 spawn
`/bin/sh -c "for i in $(seq 1 60); do pgrep -x NemoNotch >/dev/null || break; sleep 0.5; done; open -b com.nemo.BrightnessApp.NemoNotch"`
(pgrep 等待消化 KeepAwake 退出还原可能造成的延迟,60 次上限),再 `NSApp.terminate(nil)`。~15 行,boring.notch 同款。

### L3:唤醒诊断快照(并入 WakeObserver)

唤醒时以 `.info` 记录(约 8–10 行/次,唤醒低频,不违反日志量规则):

- `NSApp.windows` 清单 —— 直接复用 `MainThreadProbe` 现成的窗口快照格式(title/frame/visible);
- 屏幕列表(displayID + frame);
- 本地时间戳,可与 `keep-awake.log` 对齐。

## 测试与验收

### 单测(Swift Testing,纯函数)

- 熔断判定 `CrashRelaunchDecision`:无标记→装/计数 1;近期 count=2→装/计数 3;近期 count≥3→熔断+重置;过期 count≥3→装/计数 1;UITestMode/debugged→不装。
- 去抖调度策略:连发合并为一次;`quietAfter` 生效时延迟取 `max`;`quietAfter` 已过取 0.5s。

### 手动验收

1. `kill -SEGV <pid>` → ≤3s 恢复;启动日志含 `.warn` 溯源行;`~/Library/Logs/DiagnosticReports/` 崩溃报告仍在。
2. 10 分钟内连续 `kill -SEGV`:前 3 次崩溃各触发自愈(第 3 次崩溃后仍会重启);第 4 次启动读到 count≥3 → 熔断不再自愈,有 `.warn`。
3. 稳定运行 5 分钟后标记被清除(下次 `kill -SEGV` 仍自愈)。
4. 外接显示器在位:合盖→10s→开盖 ×10;系统菜单睡眠→唤醒 ×10:无崩溃,窗口无丢失。
5. 热插拔显示器 ×5:notch 窗口 ≤1.5s 出现在新屏(去抖无感)。
6. `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'` 全绿。

### 文档与流程义务

- README.md / README_CN.md / CLAUDE.md 增补(自愈与唤醒退避行为)。
- macos-cookbook.md 新增条目:信号处理器自愈模式(async-signal-safety 纪律、mtime 当时间戳、POSIX_SPAWN_SETSIGDEF、P_TRACED 检测)。
- Git Flow:`feature/crash-resilience` 基于 develop,合并回 develop。

## 风险与对策

| 风险 | 对策 |
|---|---|
| 处理器内越界操作使崩溃更糟 | 载荷全部启动时预构建;处理器体仅 open/write/close/posix_spawn/signal/raise;代码评审重点盯 |
| 熔断标记写失败(磁盘级故障)→ 熔断失效 | 接受 —— 磁盘写失败时机器已有更大问题 |
| `open -b` 失败(app 被移动) | 静默失败,用户可见,接受 |
| SIGABRT 自愈掩盖开发期断言 | P_TRACED 检测调试器时跳过安装;熔断 3 次上限兜底 |
| 去抖引入的重建延迟 | 冷路径 0.5s、唤醒后 2.5s,均有常量可调;验收第 5 条覆盖 |

## 后续任务(不在本次范围)

1. MenuBarExtra → 手动 NSStatusItem 迁移(规避 macOS 26 "隐藏图标→scene 静默退出"风险;可先做 10 分钟 PoC:系统设置隐藏图标,观察应用是否存活)。
2. KeepAwakeService 启动即 deinit 异常排查(持有链 / `?? KeepAwakeService()` 兜底实例身份混用)。
