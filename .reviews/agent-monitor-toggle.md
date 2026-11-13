# Code Review — feature/agent-monitor-toggle

Reviewer: zcode 独立评审会话(GLM-5.3 judge 会话，未参与开发)
Date: 2026-11-13
Reviewed-Head: a893c91
Verdict: CHANGES_NEEDED
Scope:  24 files changed, 616 insertions(+), 280 deletions(-)

```
AGENTS.md
NemoNotch/Helpers/AppDependencies.swift
NemoNotch/Models/AppSettings.swift
NemoNotch/NemoNotchApp.swift
NemoNotch/Badge/BadgeItem.swift
NemoNotch/Notch/Badge/BadgeViewModel.swift
NemoNotch/MenuBar/HooksSection.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/AICLIMonitorService.swift
NemoNotch/Services/AISessionStore.swift
NemoNotch/Services/ClaudeCodeService.swift
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/GeminiProvider.swift
NemoNotch/Settings/Pages/AIAgentsSettingsPage.swift
NemoNotch/Settings/SettingsComponents.swift
NemoNotch/Settings/SettingsSearchIndex.swift
NemoNotch/Tabs/AIChatTab+EmptyState.swift
NemoNotchTests/AISourceRoutingTests.swift
NemoNotchTests/BadgeSessionItemsTests.swift
NemoNotchTests/CompletionDetectorTests.swift
README.md
README_CN.md
docs/superpowers/plans/2026-11-13-agent-monitor-toggle.md
```

## Findings

- **[P2] hermes 启动路径漏装总闸，五源语义不一致，边缘条件下可破「关闭不弹卡」红线** — `NemoNotch/Helpers/AppDependencies.swift:87-89`:`hermes.connect()` 只看 `!UITestMode.isActive`,不看 `hermesEnabled`。正常 toggle-off 路径闭环(卸钩后 `isInstalled=false` → `connect()` 的 guard 让它 no-op),但当「hermesEnabled=false 且磁盘 hook 仍在」时(卸载抛错被 provider 吞 / 用户手动把 hook 装回 Hermes 配置——正是本次 bug 起因的同构场景：用户手动管理 hook 配置)，重启即复活 FSEvents + 3s 轮询，agent 状态经 registry 直达 `CompletionFlashService.currentCandidates()`(CompletionFlashService.swift:105-115),**完全绕过 routeEvent 的 hermesGate** → agent 完成弹卡。对照 claude 同场景:`startSessionDiscovery`(AICLIMonitorService.swift:93)与 routeEvent 双闸挡死，彻底安静。修法一行:`if !UITestMode.isActive, settings.hermesEnabled { hermes.connect() }`(settings 在 build() 首行已定义，AppDependencies.swift:68)。
- **[P3] stopDiscovery 后 in-flight 回写复活窗口(UI 僵尸，不弹卡)** — `NemoNotch/Services/ClaudeCodeService.swift:101-110`(pollRecords 的 detached 回调)与 ：46-57(scanExistingSessions 的 detached 回调)在 `stopDiscovery()` 之后仍会写 store。两个子路径后果不同:(a) 启动扫描(秒级窗口)复活的会话 phase=.idle、无 recordPID → `cleanupStaleSessions` 最长 30 分钟后移除(ClaudeCodeService.swift:604-610),detector 对「已 idle 后消失」不报，无卡，仅列表残留;(b) record 轮询(毫秒窗口)复活的会话 recordStatusKnown=true → `StaleDemotion` 豁免(SessionPhase.swift:315-317)+ `removeStaleThreshold` 路径要求 `recordPID == nil`(ClaudeCodeService.swift:605)→ **永久 working 僵尸**(占 activeSession 与 AIChatTab),直到用户再次开 toggle。注释(ClaudeCodeService.swift:79-81)只论证了「不会错误结束会话」，未覆盖「复活后无人回收」。两路都不破弹卡红线(detector 语义兜底)，但违背「彻底安静」。修法:provider 加 `discoverySuspended` 标志，setMonitoring 翻转，两个回调写 store 前 guard。Gemini 的 scanExistingSessions 同构。
- **[P3] HermesService.connect 不幂等** — `NemoNotch/Services/HermesService.swift:58-71`:`pollTimer = Timer.scheduledTimer(...)` 无 `pollTimer == nil` 守卫，二次 connect 泄漏旧 3s timer。当前调用图(启动一次 + toggle on,之间必有 disconnect)不可达双 connect,记脆弱点；若采纳 P2 修法，建议顺手加守卫。
- **[P3] toggle off 不撤 HookServer 里挂起的审批** — `forgetSessions`(CompletionFlashService.swift:97-101)走 `store.removeSessions`,不像 `endSession`(ClaudeCodeService.swift:185-191)调 `hookServer.cancelPendingPermissions`。关 toggle 时恰有挂起审批的会话，CLI 侧要等各自超时(claude 120s fail-close / opencode 600s 无决定)。既有超时语义兜底、可接受，记提示。
- **[P3] setMonitoring/forgetSessions 服务层串联无测试覆盖** — 「detector.forget 必须先于 store.removeSessions」的顺序契约只存在于注释(CompletionFlashService.swift:86-90)，测试只覆盖了 detector.forget 纯函数(有牙，已 mutate 验证)。集成链受「uninstallHooks 碰真磁盘」约束跳过可以理解，但 forgetSessions 本身(store 读 + forget + remove 顺序)可注入测。属补强项，不阻塞。

## 审查清单(评审者逐项过，不适用项标 N/A)

- [x] **判别剃刀**：新测试有鉴别力。AISourceGateTests 四个测试全部经 `hookServer.onEventReceived` 真 routeEvent、断言 store 终态(双向：拦截断 nil、放行断 source);CompletionDetectorTests 的 forget 测试带对照组(不 forget 的同形消失报 sessionLost)。mutate 亲验两次：routeEvent gate 反转 → 7 败/exit 65;detector.forget 无效化(`prior.removeValue(forKey: key)` → `_ = key`)→ 2 败/exit 65。守卫有牙。
- [x] **证据纪律**：门禁我亲跑——`sh scripts/lint.sh` exit 0(仅 scripts/index-affected.swift 存量 warning,非本分支文件);`sh scripts/doc-audit.sh` exit 0;`sh scripts/check-arch.sh` exit 0;`sh scripts/plan-audit.sh` exit 0;`sh scripts/affected-tests.sh` exit 0(索引闭包选 39 类，260 通过 0 失败);`python3 scripts/xcstrings.py check` canonical。提交信息含具体证据(「测试宿主两次 connection 前崩溃实锤」)，与 diff 相符。
- [x] **Swift 6 并发**：sourceGate/hermesGate 是 @MainActor service 的实例属性闭包，routeEvent/setMonitoring 全在 MainActor;stopDiscovery 同步 invalidate timer;无新的 Sendable 边界。CompletionFlashService.forgetSessions 的 forget+remove 同 MainActor 同步段，onChange 回调(Task 异步)不会插进中间读到半态。未见问题。
- [x] **最小改动**：diff 可逐条对到 plan 任务；xcstrings 删 8 个死 key 是口径清理(plan T6 声明)；SettingsSearchIndex 是文案 key 连带；无顺手改邻近代码。UsageQuotaCardView(Tabs/UsageQuotaCardView.swift:14-27)按源过滤确认保留且零改动，约束满足。
- [x] **错误路径**：uninstallHooks 抛错经 provider 记 .error(既有)；gate 拦截记 .info 带 "disabled, dropped",可区分「事件没到」vs「到了被拦」(对齐日志纪律)。
- [x] **坑总目录对照**：事件归属坑(ses_/sess_ 前缀归属保留在 gate 之前且有测试 disabledZcodeDropsSessButNotSes);「门禁在发射不在快照」不违反——本分支的闸比发射更上游(事件根本不进 store);AGENTS.md 已新增「按源监控开关是服务层总闸」不变量条目，与实现一致(UI 过滤层删除、handleServerReady 自愈按源、静默清源顺序均如实记载)。
- [x] **教训候选**：见下。
- [x] **文档同步**：AGENTS.md(+1 不变量)、README/README_CN 各改两处(功能描述 + herdr mod 双卡指引改为「关开关」)，与行为一致。

## bug 专项镜头

- **修复与根因因果对应**：是。根因(五开关只有 UI 消费者、路由/轮询/自愈服务层无消费者)逐点封堵:routeEvent 统一 gate(AICLIMonitorService.swift:231-272)、record 轮询/watcher 可停(ClaudeCodeService.swift:82-96)、handleServerReady 按源自愈(:285-306,原缺陷 a)。不是绕症状(UI 过滤反而删除，职责归服务层)。用户实报的链路(卸钩 → record 轮询仍发现 → 消失弹红卡)两端都断：轮询停 + store 清空走 detector.forget(消失不读作 sessionLost)。
- **失败测试红→绿可重放**：部分满足。本分支测试与实现同 commit 系列交付(4521be8/08d205e 各自带上测试)，非独立的先红 commit——plan 声明的「失败测试先红」未以可重放形式落档；但 gate 与 forget 两条守卫经我 mutate 验证有牙(变异即红)，鉴别力等价成立。按「新功能不强制 TDD」口径，可接受。
- **推翻旧口径全仓 grep 清场**：已跑。`settings.install_hooks`/`uninstall_hooks`/`reinstall`/`status.not_installed`/`menu.install_*_hooks`/`onInstall`/`onUninstall` 在代码、AGENTS.md、README、docs/superpowers/plans/(非 archive)均无现在时残留；命中仅在 `docs/superpowers/plans/archive/`(历史归档，刻意不追)与两份旧 plan(zcode-provider/unified-service-enablement)的过程性描述。AGENTS.md 新条目与 README 口径一致。

## 门禁亲跑结果(引用真实退出码)

| 脚本 | 退出码 | 结果 |
|---|---|---|
| `sh scripts/lint.sh` | 0 | 通过 |
| `sh scripts/doc-audit.sh` | 0 | 通过 |
| `sh scripts/check-arch.sh` | 0 | 通过 |
| `sh scripts/plan-audit.sh` | 0 | 通过 |
| `sh scripts/affected-tests.sh` | 0 | 260 通过 / 0 失败(39 类) |
| `sh scripts/mutate.sh`(gate 反转) | 0 | 变异被抓，套件 exit 65 |
| `sh scripts/mutate.sh`(forget 无效化) | 0 | 变异被抓，套件 exit 65 |

## 教训候选

- **绕过路由闸的后门清单化**(AICLIMonitorService.swift:231-234 的注释已点 watcher,但不完整)：「关掉一个源」时要枚举所有仍能向 store 写入的路径——路由(事件)、发现轮询、transcript watcher、**in-flight 异步回调的迟到落地**、以及不经 store 的旁路(agent registry / FSEvents)。本次 hermes 启动 connect(P2)与 in-flight 回写(P3)就是清单漏项。判据：给一个数据面加总闸时，grep 该数据面的**全部写入者**并在闸上逐个核对，而不是只封事件入口。
- **「guard isInstalled」与用户意图是两个开关**：磁盘事实(isHookInstalled)只回答「数据能不能流」，不回答「用户要不要」。启动路径的条件必须读用户意图开关，读磁盘事实当开关的启动代码会在「外部把磁盘状态改回去」时复活监控(与 handleServerReady 曾无条件复活 claude hook 同族)。

## 结论

CHANGES_NEEDED:修 P2 一行(AppDependencies.swift:88 加 `settings.hermesEnabled` 条件)，其余 P3 记录在案可另行处理。修后请更新 Reviewed-Head 增量复审。实现主体(routeEvent 统一 gate、静默清源顺序契约、自愈按源、UI toggle 化、文档同步、测试鉴别力)质量扎实，证据链完整；除 hermes 启动缺口与竞态窗口外，我未发现其他破「关闭不弹卡」红线的路径。

---

# Code Review — feature/agent-monitor-toggle(增量复审段，附于首轮记录之后)

Reviewer: zcode 独立评审会话(GLM-5.3 judge 会话，未参与开发)
Date: 2026-11-13
Reviewed-Head: b8d4316
Verdict: APPROVED
Scope(增量): a893c91..b8d4316 — 2 files changed(AppDependencies.swift +3/-1, HermesService.swift +1/-1),1 个修复提交(06f9224 为 .reviews 落盘，按排除项不计)

## 零代码漂移检查

`git diff a893c91..HEAD -- . ':!.reviews'` 仅含两个声明修复文件(AppDependencies.swift、HermesService.swift),无其他任何改动。✓

## 上轮 Findings 处置核对

- **[P2] hermes 启动路径漏闸 → 已修，正确**。`NemoNotch/Helpers/AppDependencies.swift:87-90`:`if !UITestMode.isActive, settings.hermesEnabled { hermes.connect() }`,与上轮给定修法一致；why 注释点明「磁盘事实(isInstalled)会在手动重装/卸载失败时复活监控」的正确理由(呼应上轮教训候选「isInstalled 与用户意图是两个开关」)。`settings.hermesEnabled` 缺省 true(AppSettings init),全新用户行为不变；settings 在 build() 首行定义(AppDependencies.swift:68),时序可用。
- **[P3] connect 不幂等 → 已修，正确**。`NemoNotch/Services/HermesService.swift:59`:`guard isInstalled, pollTimer == nil else { return }`。on/off/on 循环不受影响——`disconnect()`(HermesService.swift:73-82)已置 `pollTimer = nil`,重新 connect 可通过守卫；重复 connect 现在是干净 no-op(不重装 FSEvents、不重复 refreshSessions)。
- **[P3] in-flight 回写僵尸窗口 / [P3] 挂起审批不撤 / [P3] forgetSessions 集成测试 → 按仓库「P3 默认不修」口径记录在案**，零代码漂移确认未顺手改动。✓

## 门禁亲跑(引用真实退出码)

| 脚本 | 退出码 | 结果 |
|---|---|---|
| `sh scripts/lint.sh` | 0 | 通过 |
| `sh scripts/doc-audit.sh` | 0 | 通过 |
| `sh scripts/check-arch.sh` | 0 | 通过 |
| `sh scripts/affected-tests.sh`(当前 HEAD 重跑) | 0 | 263 通过 / 0 失败(索引闭包 40 类，含 HermesReparseGateTests) |

关于派发方声明的全量 test.sh exit 0:build/test.log(18:33:57)早于修复提交(18:34:08)11 秒——时序上属「跑完测试即提交」的正常顺序，日志中 697 条 passed、唯一含 "failed" 字样的行是用例名 `failedToolThenSilenceStillDemotes`(passed);为消除工件对应关系疑虑，我针对当前 HEAD 亲跑 affected-tests(exit 0,263/0),修复后的代码已由我直接验证。

## 结论

APPROVED。上轮唯一阻塞项(P2)修复正确且无漂移，P3 处置符合仓库口径，门禁与测试我亲跑全绿。我愿意为这个合并背书。
