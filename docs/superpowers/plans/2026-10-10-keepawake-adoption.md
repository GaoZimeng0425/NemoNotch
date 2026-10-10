# 防休眠借鉴 MacMiniMode(2026-10-10)

对比 [Pama-Lee/MacMiniMode](https://github.com/Pama-Lee/MacMiniMode)(插电合盖不休眠的菜单栏应用,root LaunchDaemon 架构)后,按 NemoNotch 的现实约束(osascript 提权、无 root 常驻、ad-hoc 签名)吸收其四项能力。

## 范围(做)

1. **直读 IOPMrootDomain 的 `SleepDisabled`**(`PMSet.readSleepDisabledLive()`)替代 `pmset -g` 子进程作为对账真相源——开销从"起一个进程"降到一次注册表属性读取,轮询因此做得起。`pmset -g` 保留为 root domain 拿不到时的回退。
2. **外部改动发现**:`com.apple.system.powermanagement.prefschange` Darwin 通知(`CFNotificationCenterAddObserver`,observer 指针当回调上下文)+ 10s 轮询兜底。通知先到、内核后写 → 0/0.2/1/2.5s 四点复查。只发现+如实上报+记 `KeepAwakeEventLog`,**不自动纠回**(纠回要弹授权框,不能无人值守静默做)。`isBusy` 期间整体抑制——我们自己的写同样触发该通知。
3. **`PreventSystemSleep` 断言第二道保险**(免 root,随进程退出自动释放):补"被清掉到发现之间"的空闲睡眠窗口;跟随系统真相源 `isEnabled` 而非用户意图;挡不住合盖睡眠(没有断言能挡);`UITestMode.isTestHost` 下不持。
4. **关闭后已合盖 → `pmset sleepnow`**(免 root):纯决策 `KeepAwakeSleepNowDecision`(`systemSleepDisabled == false && lidClosed == true && clamshellCausesSleep == true`,任一 nil 不睡);`AppleClamshellCausesSleep` 为内核对合盖工作模式(外接显示器)的权威判断,不会误睡 clamshell 工作站。开关路径延迟 2s 复核(反悔窗口),退出路径立即(延迟任务活不过退出)。

## 不做(及理由)

- **root LaunchDaemon 架构**:ad-hoc 签名下 `register()`/`status()` 假成功、launchd 不拉 helper(已实测,见 AGENTS.md)。MacMiniMode 可用是因其 pkg 有 Apple 签名+公证。
- **auto 模式(插电自动开)**:每次插电弹密码框,osascript 路线做不到可接受 UX。
- **防拉锯限速**:只在能自动纠回时才有意义。
- **低电量保护 / 温度留痕**:电池+电量检测免费但静默动作做不到,本次不做,需要时再议。

## 附带修复

- `refresh()` 周期化后 `turnDisplayOffIfNeeded` 改为**上升沿触发**(`isEnabled && !wasEnabled`),否则每轮轮询都会对已合盖的盖子重发 `displaysleepnow`。
- `NemoNotchTests/KeepAwakeTests.swift` 补上 `@Suite("KeepAwakeTests")` 包裹——原先裸的自由 `@Test` 不隶属命名套件,`scripts/test.sh --only KeepAwakeTests` 匹配不到任何用例(脚本的假绿检查会报出来)。

## 验证

- 新增 5 个 `KeepAwakeSleepNowDecision` 用例(全条件 / 拨回 / 盖开 / clamshell 工作站 / 各 nil 位),加上原有 18 个 KeepAwake 用例,`sh scripts/test.sh --only KeepAwakeTests` 23/23。
- 全量 `sh scripts/test.sh` 333/333(退出码 0,日志 `build/test.log`)。
