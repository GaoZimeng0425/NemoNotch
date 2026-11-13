# 防休眠双开关 + 「谁在阻止休眠」面板 — 设计

2026-11-13,脑暴定案(同日调查:租约/IOPMAssertion 与 disablesleep 两层机制对比,见会话记录)。

## 意图与为什么

用户要「开着 app 就防休眠、退出即停、下次启动自动恢复」的**零弹窗**体验。调查确认:

- 租约(`IOPMAssertionCreateWithName`)完整覆盖该体验,但**管不了纯合盖**(不接外接屏合盖照睡,内核 clamshell 路径无视一切断言);
- 现有 disablesleep 路线是唯一能纯合盖防睡的,代价是开/关各一次管理员授权框,这个价格去不掉(除非换特权模型,已否)。

拍板:**两种都做,两个独立 toggle,用户按场景自选**。另加「谁在阻止休眠」面板,把两层状态如实展示。

## 目标

1. **开关 A「空闲不休眠」(新,租约版,零弹窗)**
   - 开 = 创建 `PreventUserIdleSystemSleep` 断言(与 caffeinate 默认同族:系统不空闲睡,屏幕可正常熄灭);
   - 状态持久化:`AppSettings` 新键(默认关,**用户拍板**),didSet 落 UserDefaults;
   - **状态保留**:启动时设置为止开 → 自动重建断言;`refresh()` 对账自愈(意图开而断言缺 → 重建,powerd 重启等丢失场景);
   - 退出无需任何还原代码(断言随进程由系统自动回收);
   - 断言名 `"NemoNotch Idle Keep Awake"`,与第二层的 `"NemoNotch Keep Awake"` 在 `pmset -g assertions` 里可区分。
2. **面板「谁在阻止休眠」(设置页防休眠区块下方,两层)**
   - 空闲层:`IOPMAssertionCopyMatching` 枚举用户态断言,每条 = 进程名 + 持续时长 + 剩余时间(有 timeout 才显示);`Created for PID` 归因的(如 coreaudiod 挂给 octok)显示归因目标;
   - 合盖层:一行 = `SleepDisabled` 开/关 + 归属(我们 / 未知来源)——数据全用现有 `isEnabled`/`isOwned`,零新读;
   - 刷新:区块可见时 onAppear + 10s 定时,离屏即停(枚举是 µs 级 IOKit 调用,不添常驻轮询)。

## 非目标 / 反目标

- **开关 B(合盖不休眠)机制、设置、行为一行不动**(用户拍板「B 不动」):不加启动自动重开,不改还原/对账/标记。B 的「状态保持」由已有「退出时还原」开关(默认开)表达,关掉它即跨退出保持。
- 不做「关闭其他 app 的断言」:powerd 按创建进程记账,外进程 ID 释放返回 `NotPermitted`,root 也不行(2026-11-13 定案)。
- 不换特权模型(不上 sudoers helper / LaunchDaemon)。
- display 保活族断言(`NoDisplaySleepAssertion` 等)v1 不进列表——语义是「屏幕不灭」非「系统不睡」,混列误导。
- A 不进 notch / 菜单栏露出,设置页唯一入口(v1)。

## 约束

- A 断言与第二层断言**分开持有**(各自 ID):第二层跟随系统真相(补篡改窗口),A 是用户意图,语义不同不共用;两 toggle 同开时两份断言并存,powerd 自行聚合。
- UITestMode 下 A 不创建真断言(测试宿主安静),设置持久化照常。
- 断言创建失败:`lastError` 同款样式显示,状态行如实「开启(未生效)」;不弹窗不重试(对账自愈已覆盖恢复路径)。
- 纯逻辑抽函数可测:断言字典数组解析 → 过滤/聚合/时长格式化,Swift Testing 造 fixture 字典;判别剃刀——字段真解析(类型/时长/剩余/归因),不是恒真。
- 本地化:新 UI key 进 `Localizable.xcstrings`(en + zh-Hans)。

## 方案取舍(Approaches)

1. **换租约版、删 disablesleep** —— 否:纯合盖场景能力丢失(用户要保留)。
2. **维持单开关 B + 启动自动重开(每次启动一弹窗)** —— 否:弹窗体验差;B 的跨启动保持已有「退出时还原」开关表达。
3. **双开关 + 两层面板(选定)**:A 零弹窗覆盖开盖/外接屏场景,B 保留纯合盖能力,面板如实展示两层现状。

## 归属

- 用户拍板:双开关;A 默认关;B 一行不动;A 状态保留(启动重建);面板两层、带剩余时间。
- 我的裁量(实现层):
  - A 断言类型选 `PreventUserIdleSystemSleep`(不是 display 保活变体——任务跑着不需要屏幕亮,省电);
  - A 并入 `KeepAwakeService` 管理(同域,复用日志/UITestMode/refresh 周期),不另起服务;
  - 面板噪音过滤名单:`powerd` / `WindowServer` / `runningboardd` / `bluetoothd` + 无 owner pid 的内核项(常驻噪音,列出来等于没列);`coreaudiod` 保留(带归因,是有价值信号);
  - 面板只列「系统不睡」族类型:`PreventUserIdleSystemSleep` / `NoIdleSleepAssertion` / `PreventSystemSleep`;
  - 列表排除本进程(两份自家断言都不列)。

## 剩给实现的

- AppSettings 键与 UI copy 命名;
- 面板行布局(SwiftUI Form 内,参照现有 statusRow 风格);
- 断言字段 key 常量(IOKit 头文件核对,不凭记忆)。
