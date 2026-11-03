# Code Review — feature/reminder-kind-tone

Reviewer: ZCode 独立评审会话(judge ≠ author,未参与开发)
Date: 2026-11-03
Reviewed-Head: fb3d90f
Verdict: CHANGES_NEEDED
Scope:  28 files changed, 1611 insertions(+), 140 deletions(-)

```
AGENTS.md
NemoNotch/Models/AIProvider.swift
NemoNotch/Models/ApiErrorMarker.swift
NemoNotch/Models/AppSettings.swift
NemoNotch/Models/ReminderKind.swift
NemoNotch/Models/SessionPhase.swift
NemoNotch/Notch/CompletionFlashView.swift
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/ClaudeCodeService.swift
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/CompletionToastQueue.swift
NemoNotch/Services/ConversationParser.swift
NemoNotch/Services/GeminiProvider.swift
NemoNotch/Services/OpencodeProvider.swift
NemoNotch/Services/ZcodeProvider.swift
NemoNotch/Settings/Pages/AlertsSettingsPage.swift
NemoNotchTests/ApiErrorMarkerTests.swift
NemoNotchTests/CompletionDetectorTests.swift
NemoNotchTests/CompletionToastQueueTests.swift
NemoNotchTests/ReminderKindTests.swift
NemoNotchTests/ReminderSnapshotTests.swift
NemoNotchTests/SessionPhaseTests.swift
README.md
README_CN.md
docs/superpowers/plans/2026-11-03-reminder-kind-tone.md
docs/superpowers/specs/2026-11-03-reminder-kind-tone-design.md
```

## Findings

- **[P1]** `NemoNotchTests/AppSettingsReminderToneTests.swift`(untracked,不在上述任何提交里):plan T9 声称新建该测试并已勾框,但 commit 6f55eaf 只含 xcstrings + AlertsSettingsPage(`git show 6f55eaf --stat` 亲验),`git status` 显示该文件 `??`。它现在能跑(affected-tests 270 全过里含它)纯粹因为还在磁盘上——feat-done 拆 worktree 即丢失,仓库里的开关默认值/持久化守卫随之消失,plan 勾框与提交链不符。修法:`git add NemoNotchTests/AppSettingsReminderToneTests.swift` 单独提交(内容已读过,四个用例有效),补交后 head 变化须按流程 `--prompt --prev fb3d90f` 增量复审更新 Reviewed-Head。
- **[P2]** `NemoNotch/Services/CompletionFlashService.swift:348`(handle 的 `pick(... ?? .green)`):kind==nil 的日历/蓝牙批次(唯一仍走 showCompletionFlash→handle 的非 agent 源)辉光从旧 `NotchTheme.accent` 变成 green。环保留了彩虹(spec 反目标达成),但辉光没保留——非 agent 卡的视觉通道被动上了 tone 色系,与 spec「日历/通知/外部不上色系」的原则有张力,且这是用户可见的颜色漂移(spec 非目标只承诺「通道与开关不动」,颜色属视觉通道)。修法:二选一——(a) glowTone 设为 Optional,kind==nil 批次回落 `NotchTheme.accent/accentHot`;(b) 在 spec/AGENTS.md 补一句拍板「日历辉光统一 green(=回来看)」。不修文档就必须修代码。
- **[P2]** plan `docs/superpowers/plans/2026-11-03-reminder-kind-tone.md:181-183`:T10 Step 2(门禁全套含 `sh scripts/test.sh` 全量与 plan-audit)与 Step 3(真机四条验证:AskUserQuestion→amber、Bash→blue、正常完成→green、kill CLI→red,截图留证)未完成未勾。feat-done 的 plan-audit 门禁会拦裸框,且 spec 的验证方式一节要求真机四条——合并前必须做完(本轮我已代跑 lint/doc-audit/check-arch/affected-tests 全绿,但全量 test.sh 与真机验证不可代)。
- **[P3]** `NemoNotch/Services/CompletionFlashService.swift:3`:头注释仍写「work-completion edges (working→idle / active→idle)」——旧口径残留(isActive 已改 phase 谓词,边沿语义是 active→inactive + kind)。修法:注释改为 phase 口径。
- **[P3]** `NemoNotch/Settings/SettingsSearchIndex.swift:22-23`:设置搜索索引未收录新条目 `settings.attention_toast.*`、`settings.failure_toast.*`(以及新加的 `settings.completion_flash.hint`——既有惯例 hint 也入索引,见 external_toast.hint)。用户搜「提醒/决定/出错」找不到新开关。修法:三条 key 补进 alerts 页清单,SettingsSearchTests 相应补断言。
- **[P3]** `NemoNotch/Services/CompletionToastQueue.swift` demote(约 :138):先 `toasts.removeAll` → `refill` → 再扫 `waiting`——若同会话的 ask: 卡恰在此拍从等待堆递补进行上,它躲过本次 demote(靠 AttentionDetector 的 retract 兜底撤,最终一致但有一拍误差)。修法:demote 里两集合先总移除、后一次性 refill。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增测试全部以具体输入调被测单元、断言字面输出(ReminderSnapshotTests 的 waitingForApproval isActive / ApiErrorMarkerTests 的样本字面量 / 队列 sticky/demote 计时断言);变异亲验两处有牙——`isActive: session.phase.isActive`→`session.status == .working` 红失败 1 过 4(exit 0);sticky 到期豁免剥除 红失败 1 过 27(exit 0),文件均已恢复(trap)。
- [x] **证据纪律**:门禁全部亲跑——`sh scripts/lint.sh` exit 0(仅存量 warning);`sh scripts/doc-audit.sh` exit 0;`sh scripts/check-arch.sh` exit 0;`sh scripts/affected-tests.sh` 270 过 0 败 exit 0;`python3 scripts/xcstrings.py check` = canonical;apiError 样本核准声明亲验——`grep` 本机 `~/.claude/projects` 命中 `"isApiErrorMessage":true` 真实条目(样本存在,非凭记忆)。
- [x] **Swift 6 并发**:新增 ReminderKind/ReminderTone/ApiErrorMarker/StaleDemotion/AttentionDetector/ReminderSnapshot 均纯值类型无隔离;服务改动在既有 @MainActor 类内;无新 Sendable 边界、无回调线程假设。
- [x] **最小改动**:色值与 plan Global Constraints 逐项核对一致(16 个 RGB 字面量全对);CA 环结构未动(仅参数化 colors,`self.colors.map(\.cgColor)` 的 Optional.map 陷阱有注释);唯一越界点是 P2 的非 agent 辉光颜色漂移;外部/通知卡走 showExternalToast/showNotificationToast 直接 addToasts,未被新 tone 门禁波及(亲读全文确认)。
- [x] **错误路径**:开关 gate off 有 debug 日志;迟到红卡 info 日志;demote 无匹配静默返回 [];askItem 找不到 session 返 nil 跳过。
- [x] **坑总目录对照**:具文窗口(同窗换色不重建,注释点明)、RingKind arrival-gesture 幂等哲学(EdgeBarRing.swift:110 引用)、CA 环禁 TimelineView、本地化经 xcstrings.py、bluetooth/hook 端点区未触碰;zcode Stop→waitingForInput 路径亲验存在(ZcodeProvider.swift:112,绿卡通道未断)。
- [x] **教训候选**:见下节。
- [x] **文档同步**:AGENTS.md 新增两条(四色原则/边沿规则,与实现逐点核对一致——含「hitApiError 非粘性、latest wins」与 ConversationParser 实现吻合);README×2 同步;本地化 11 个新 key 逐一在 xcstrings 命中。

## 教训候选

- **测试文件写完忘了 add,plan 勾框照勾**:plan-audit 只核勾框不核工件入库。可门禁化——feat-done 探针加一条:worktree 存在 untracked 的 `*.swift` 时响亮警告(位置:本分支实案 NemoNotchTests/AppSettingsReminderToneTests.swift)。
- **队列「移除+递补」原语要一次成型**:demote 先移除行上卡、refill 递补、再扫等待堆的两段式,让恰好递补进行的卡躲过匹配(见 P3)。判据:任何「按谓词移除 + refill」的组合,移除判定必须覆盖 refill 可能引入的卡(CompletionToastQueue.demote)。

## 增量复审(第 2 轮)

Reviewer: ZCode 独立评审会话(增量复审,未参与开发)
Date: 2026-11-03
Reviewed-Head: 67e355e
Verdict: APPROVED
Scope: fb3d90f...67e355e — 4 commits(564f747 / 1052c09 / 85409d1 / 67e355e),8 files changed, +148/−22

### 上轮 Findings 处置核对

- **P1(漏交测试)→ 已解决**:564f747 补交 `NemoNotchTests/AppSettingsReminderToneTests.swift` 入库(git show 亲验,new file 45 行,4 用例:两开关各默认开 + 关掉持久化,UserDefaults 键有保存/恢复与 `removeObject` 清场,`@Suite(.serialized)` 防串扰)。affected-tests 选择列表含该类,269 用例全绿。
- **P2(日历辉光漂移)→ 已解决(修法 b 拍板)**:1052c09 在 AGENTS.md 四色条目补「日历/蓝牙批次辉光随 green(到点=该行动了,最接近『回来看』档;旧 accent 橙弃用,拍板 2026-11-03 评审口径 6)」+ spec 审计口径第 6 条;代码 handle 的 `$0.kind?.tone ?? .green` 与文档口径一致(亲读 CompletionFlashService.swift:352-357)。代码、spec、手册三者同一提交,符合 doc-audit 强迫同行原则。
- **P2(T10 未完)→ 已解决**:67e355e 勾 Step 2/3。门禁本轮亲跑(见下);真机四色截图存在 `/private/tmp/nn-{green,amber,blue,red}.png`(2026-11-03 17:17),抽查判读 2/4 张:nn-green.png 场景 = 多张绿环「完成了」卡 + 顶部琥珀橙辉光同屏(两 CLI 会话一完成一提问,恰为 85409d1「attention 到达也闪辉光」的真机实证);nn-amber.png 因 CDN 判读通道 400 未读成,blue/red 未抽查——四色判读以作者声明为主、抽查 2/4 相符(梯级:抽查=5、未抽 2 张=1)。
- **P3(注释旧口径)→ 已解决**:1052c09 头注释改为「active→inactive edges (each completion carries its ReminderKind — done, or lost) and for arrivals into "parked on the user"」,与现行为一致。
- **P3(搜索索引)→ 已解决(断言豁免合理)**:1052c09 补 6 条 key(completion_flash.hint / attention_toast.header·enabled·hint / failure_toast.header·enabled),逐一在 Localizable.xcstrings 命中(grep 计数各 1);上轮建议的「SettingsSearchTests 补断言」未做——亲读该测试为纯匹配语义固定语料(不锁任何页的 key 清单,无断言位可锁),stringsByPage 语言解析已有判别断言,不补合理。
- **P3(demote 两段式)→ 修复落地、守卫无牙(降级本轮新 P3,见下)**:1052c09 改为先 `toasts`+`waiting` 总移除、后 `refill`(带注释引用 review round-1 P3);行为正确性亲验——`refill` 用 `waiting.popLast()` 递补,旧顺序确实会让恰被递补的匹配卡躲过 demote,新顺序消除该窗口。

### 85409d1(attention 辉光)重点核对

spec 63/65/85 行确证「三处视觉同一语义」「amber 环卡 + amber 辉光」是既有要求——第 1 轮评审与实现确都漏了,85409d1 方向正确。`flashIfNeeded` 重构对 handle 原语义三项均保留(亲读 :341-365):(1) **节流**——`guard !inCooldown` 只出卡 + debug log,与旧 mid-window 分支等价;(2) **开关门禁**——`toneAllowed` 过滤仍在发射处,attention 路径 `where settings.attentionToastEnabled` 与出卡同闸,开关关时既不闪也不出卡;(3) **同批仲裁**——`pick(enabled.map…)` 仍在已过滤批次上。移除 `?? .green` 无行为差异:`guard !enabled.isEmpty` 早退在前,`pick`(`tones.max`)对非空数组必非 nil,空批次不可达闪辉光分支。新仲裁面(同拍 attention 先于完成处理、attention 闪后 2s 内的完成只出卡)与注释「being blocked on the user outranks being done」及 spec 口径 5 节流语义一致。ask 卡 `tokenDisplay: nil`(去 token 噪音)为 UI 微调,e2e 已验。`holdForUITest` 不经 handle/flashIfNeeded,截图模式不受影响。

### 本轮亲跑门禁(退出码)

- `sh scripts/lint.sh` → **exit 0**(仅存量 warning,均不在本分支 diff 文件内)
- `sh scripts/doc-audit.sh` → **exit 0**
- `sh scripts/check-arch.sh` → **exit 0**
- `sh scripts/affected-tests.sh` → **exit 0**(269 过 0 败,含 AppSettingsReminderToneTests)
- 变异验证(下条)→ **exit 1**(变异存活),文件经 trap 恢复,`git status` 干净

### 本轮新发现

- **[P3]** `NemoNotch/Services/CompletionToastQueue.swift` demote 一次成型修复**无守卫用例**:变异回旧顺序(两集合移除夹 refill),`sh scripts/mutate.sh … --only CompletionToastQueueTests` → exit 1(变异存活,28 用例全绿)。现有 demoteSameSessionOnly(toasts 全非匹配)与 demoteWaitingPile(toasts 无匹配卡 → refill 不触发)都不构造「toasts 与 waiting 同时有同会话卡」的时序差场景。修复本身正确但无牙——下次被"优化"回两段式不会红。修法:补一用例(toasts=[ai:s1,x,y] 满 capacity、waiting=[ask:s1],断言 demote 后行上无 s1 卡且 removed 含两张)。按 P3 默认不修,主对话拍板(≤10 行可顺手)。
- **[披露]** 作者声明全量 test.sh 665/665,但 worktree 与主检出均无 `build/test-head.txt` 锚点工件可证(梯级 1 自述);本轮代跑 affected 269 全绿(梯级 4)。feat-done 测试门禁会强制全量重跑,不阻塞本 verdict。
- **[提示]** plan 仅剩 Step 4(评审+合并)未勾——时序正确(APPROVED 后才能勾),feat-done 前须补勾,否则 plan-audit 拦裸框。

### 教训候选(增补)

- **"修复+守卫"成对交付的缺口在增量回修里更高发**:评审回修的 P3(非用户报 bug)最容易只改代码不补用例——demote 时序差修复即实案(变异存活 exit 1)。判据:凡注释里写着「review round-N P3」的防御性修复,必须有对应用例或明说为何不测。
