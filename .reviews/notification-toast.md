# Code Review — feature/notification-toast

Reviewer: 独立评审子代理(Claude,未参与本分支开发;只读 diff + AGENTS.md)
Date: 2026-10-30
Reviewed-Head: c4e77b6
Verdict: APPROVED
Scope:  38 files changed, 1535 insertions(+), 479 deletions(-)

```
AGENTS.md
NemoNotch/Helpers/AppDependencies.swift
NemoNotch/Models/AppSettings.swift
NemoNotch/NemoNotchApp.swift
NemoNotch/Notch/Badge/BadgeGrouping.swift
NemoNotch/Notch/Badge/BadgeIconView.swift
NemoNotch/Notch/Badge/BadgeItem.swift
NemoNotch/Notch/Badge/BadgeViewModel.swift
NemoNotch/Notch/CompletionToastLayout.swift
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Notch/CompletionToastWindow.swift
NemoNotch/Notch/NotchView.swift
NemoNotch/PermissionFlow/PermissionPane.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/AppActivator.swift
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/CompletionToastQueue.swift
NemoNotch/Services/NotificationCenterReader.swift
NemoNotch/Services/NotificationInbox.swift
NemoNotch/Services/NotificationRecord.swift
NemoNotch/Services/NotificationService.swift
NemoNotch/Services/NotificationToastService.swift
NemoNotch/Settings/Pages/NotificationListSettingsPage.swift
NemoNotch/Settings/SettingsSearchIndex.swift
NemoNotch/Settings/SettingsView.swift
NemoNotchTests/AppSettingsNotificationToastTests.swift
NemoNotchTests/BadgeDebounceTests.swift
NemoNotchTests/BadgeParsingTests.swift
NemoNotchTests/CompletionToastClickTests.swift
NemoNotchTests/CompletionToastQueueTests.swift
NemoNotchTests/NotificationInboxTests.swift
NemoNotchTests/NotificationRecordTests.swift
README.md
README_CN.md
docs/superpowers/plans/2026-10-30-notification-toast.md
docs/superpowers/specs/2026-10-30-notification-toast-design.md
docs/superpowers/specs/2026-10-30-notification-toast-mockup.html
```

## Findings

无 P1。以下均不阻断合并,建议后续跟进。

证据完备度:以下判断基于代码阅读 + 受影响单测实跑 + 一次变异验证;**未**在运行中的 app 复现(本机无法构造「无完全磁盘访问权限」的进程,也未验证通知中心「预览:从不」时库里是否仍存正文)。

实跑证据(第 4 级):
- `sh scripts/affected-tests.sh` → 选 15 类,通过 134 · 失败 0,退出码 0,日志 `build/test.log`。
- `sh scripts/mutate.sh NemoNotch/Services/NotificationInbox.swift 'seen.formIntersection(present)' 'seen = []' --only NotificationInboxTests` → 变异被抓(失败 3 / 通过 8,exit 0),文件已恢复。
- `sh scripts/check-arch.sh` 退出 0;`sh scripts/doc-audit.sh` 退出 0;`scripts/xcstrings.py check` → canonical。

逐条:
- [P2] NemoNotch/Services/NotificationToastService.swift:123-138 + NemoNotch/Notch/CompletionToastView.swift:96 — 卡片直接渲染库里的 title/body,绕过了系统通知设置里的「显示预览:从不/解锁时」以及「镜像或共享屏幕时允许通知」(默认关)。共享屏幕/演示时消息正文会出现在每块屏的刘海下。第 2 级推断(未实测库在预览关闭时是否仍存正文);建议至少在共享屏幕时压制通知卡,或在设置页说明。产品取舍,留给用户拍板。
- [P2] NemoNotch/Models/AppSettings.swift:289 — `notificationToastEnabled` 默认开。已为别的功能授过完全磁盘访问权限的用户升级后会**不经任何操作**开始读通知中心并把正文显示到屏上;「授 FDA 才是真正的 opt-in」这一前提对这类用户不成立。与 AGENTS「提醒天生烦人,严格 opt-in」(WaitingReminder/QuotaAlert 都默认关)口径不一致。建议默认关或首次启用时提示。
- [P3] NemoNotch/Services/NotificationCenterReader.swift:26-34 — TCC 拒绝(EPERM)映射到 `CocoaError.fileReadNoPermission` 未实测(第 2 级)。若映射不同,状态会落到 `.unavailable("Operation not permitted")`,设置页只显示「不可用」文字而不是完全磁盘访问权限卡——降级可见但引导缺失。建议用一次真实的无 FDA 运行确认。
- [P3] NemoNotch/Services/NotificationToastService.swift:179-192 — 读失败时每 2s 都重开一次文件(`lastReadSucceeded=false` 永不走 fingerprint 短路)。功能默认开 + 多数用户不授 FDA ⇒ 永久 2s 一次被 TCC 拒绝的 open(tccd 侧日志噪声,app 日志已按状态迁移去重,OK)。可考虑失败时退避(如 30s)。另「授权后免重启生效」(AGENTS 新增段)未到第 4 级。
- [P3] NemoNotch/Services/NotificationToastService.swift:32-35, 75-97 — 服务层胶水(×/点击/到期 → `markHandled`;被挤出**不**算已处理;`previous.subtracting(arrivals)` 就地缩减)没有测试。纯 `NotificationInbox`/`CompletionToastQueue` 有牙,但「关闭的消息永不再现」这条用户契约的最后一跳只靠阅读保证。若后续改动 `onToastRemoved` 语义,无红灯。
- [P3] NemoNotch/Services/NotificationInbox.swift:27 — 多发件人分隔符硬编码中文「、」,英文界面会显示 `Alice、Bob`。建议走本地化或按 locale 选 ", "。
- [P3] NemoNotch/Services/NotificationToastService.swift:132 — `String(localized: "notification.toast.latest")` 跟系统 locale 而非应用内语言(AGENTS 本地化节已列此坑);全仓 124 处同款,属存量口径,不单独阻断。
- [P3] 新增私有系统集成(usernoted sqlite)与 `@unchecked Sendable`(NotificationToastService.swift:150)——AGENTS 要求同一提交在 macos-playbook cookbook 加条目;本机未检出 cookbook(`docs/macos` 链接不解析),无法核实是否已加。

已核对、无问题:
- **不会写系统库**:只有 `FileHandle(forReadingFrom:)` 探针 + `sqlite3_open_v2(..., SQLITE_OPEN_READONLY)` + 单条 `SELECT`;无 exec/写语句。WAL 模式下只读连接仍会映射/写 `-shm` 共享内存索引(sqlite 标准读者行为,不改库页、不做 checkpoint),可接受。
- **Swift 6 并发**:poller 的可变状态(timer/lastFingerprint/lastReadSucceeded)全部只在私有串行 queue 上读写,`@unchecked Sendable` 成立;timer handler `[weak self]`;`deliver` 为 `@Sendable`,经 `Task { @MainActor [weak self] }` hop;`NotificationCenterReadResult`/`NotificationRecord` 为内部值类型,隐式 Sendable;`LogService.*` 为 nonisolated。关闭后在途结果由 `apply` 的 `poller != nil` 守卫丢弃;快速关→开时旧 poller 的在途结果会被新会话当作种子基线——良性(只会少报不会重放)。
- **状态机**:首次成功读才种基线且覆盖全部 app;读失败不碰 inbox;`seen ∩ present` 保证已处理/已见 id 不复现;小写键与库里 `xinwechat` 对齐;移出监听列表即 `markHandled` + 撤卡;关开关 `reset` 后重新种基线,不重放关闭期间的消息。
- **卡片/计时**:同 app 新到达走 `add` 合并(`merge` 以新 item 为底,`notice` 取新值)并重置 5 分钟;只缩减走 `replace` 不重计时;被挤出不回调 `onToastRemoved`;不触发辉光,不受 `completionFlashEnabled` 门禁。点击 → `AppActivator.openApp`(已运行则 activate,与既有 `activateBundle` 同法;未运行则 openApplication)→ 关卡 → 回调已处理。
- **设置页**:开关 onChange、删 app、加 app 三处都调 `settingsChanged()`;FDA 卡走拖拽引导,无自动请求;日志不含消息正文。
- 旧 Dock 红点 `NotificationService`(含每 2s AX 轮询)整删,残留引用已清(grep 无 `monitoredApps`/`NotificationService` 残留)。

### 教训候选

- NemoNotch/Services/NotificationToastService.swift:123 — 把**其他 app 的私有内容**投到屏上的功能,判据:必须尊重系统的「共享屏幕时隐藏通知 / 预览设置」,或在 spec 里显式写明为何不尊重。可门禁化程度低,适合进坑总目录。
- NemoNotch/Services/NotificationCenterReader.swift:26 — TCC 拒绝的错误映射(EPERM → 哪个 CocoaError)是「状态卡显示哪张」的承重件却只能在真机无授权进程里验证;判据:凡按错误码分流 UI 的 TCC 探针,合并前需一次无授权实跑记录(梯级 4)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [x] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [x] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [x] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿
- [x] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [x] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗?

## 评审方法提示(给评审会话)

在 worktree 里:`git diff b344e9d49449b9884938da351343ddbac912a4b4...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
