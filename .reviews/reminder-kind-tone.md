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
