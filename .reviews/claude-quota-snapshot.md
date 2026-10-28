# Code Review — feature/claude-quota-snapshot

Reviewer: 评审员-第1轮 + 评审员-第2轮(均为 dynamic-workflow 独立子代理;未参与本分支任何实现——judge ≠ author)
Date: 2026-10-28(第 2 轮同日)
Reviewed-Head: 3dee6d3
Verdict: APPROVED
Scope:  第 1 轮 @ 85d16d9 — 12 files changed, 390 insertions(+), 238 deletions(-);第 2 轮 @ 3dee6d3 — 修复 4 commits 后回归(见第 2 轮小节)

```
AGENTS.md
NemoNotch/Models/UsageQuota.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/UsageQuotaService+Claude.swift
NemoNotch/Services/UsageQuotaService+Codex.swift
NemoNotch/Services/UsageQuotaService+Keychain.swift
NemoNotch/Services/UsageQuotaService.swift
NemoNotch/Tabs/UsageQuotaCardView.swift
NemoNotchTests/UsageQuotaTests.swift
README.md
README_CN.md
docs/superpowers/plans/2026-10-28-claude-quota-snapshot.md
```

## 第 1 轮(Reviewed-Head 85d16d9)

### 结论先行

核心交付是对的且我亲跑验证了:`fetchClaude()` 只读 `~/.claude/usage-snapshot.json`,零凭证、零网络(`UsageQuotaService+Claude.swift:11-19`);parser 对 missing/stale/毫秒 ISO/单窗/双窗缺失的处理与 plan 接口规则逐条一致并有鉴别力测试;两次变异都变红;QuotaAlert 的 `.valid` 门(`Models/QuotaAlert.swift:58`)挡住新状态伪造「恢复」卡。**挡住 APPROVED 的只有一条 P1**:一截专为 Claude 写的 Keychain 明文读取函数(`security find-generic-password -w`)成了孤儿死码留在仓库里,与 plan Goal「删除全部 Claude 凭证读取路径」直接相悖,且 plan Task 5 Step 1 的 grep 词表本应抓到它。修法 5 分钟、在范围内、零行为变化。修完 + 复审即可 APPROVED。

### Findings

**[P1] `UsageQuotaService+Codex.swift:91-141` — security-CLI Keychain 读取器成为孤儿死码,带 Claude 叙事,未删未说明**
- 事实链(均为本会话亲查):
  - develop 上 `readKeychainCredentialViaSecurityCLI` 的**唯一**调用方是 `UsageQuotaService+Claude.swift:115`(`git grep -n readKeychainCredentialViaSecurityCLI develop -- NemoNotch/ NemoNotchTests/` → 仅 Claude.swift:115 调用 + Codex.swift:100 定义)。Codex 自己的 Keychain 读走 `readKeychainCredential(provider:service:)`(Codex.swift:86),从未走 CLI 路径。
  - 本分支删了调用方和开关常量 `useSecurityCLIForClaudeKeychain`(UsageQuotaService.swift),**没删被调用方**:`readKeychainCredentialViaSecurityCLI`(:101)+ `securityCLICredentialBlob`(:123,spawn `/usr/bin/security find-generic-password -s <service> -w`)。本分支 grep:`rg -n "readKeychainCredentialViaSecurityCLI|securityCLICredentialBlob" NemoNotch/ NemoNotchTests/` → 只有定义与自调用,零外部调用。
  - 它的 doc comment(:91-99)写明"this is the same path Claude Usage take … returns the plaintext blob for the ACL-less `Claude Code-credentials` item";日志/消息文本 :107/:110/:115 为 "no Claude keychain blob" / "Claude keychain item not found" / "Claude keychain blob unparseable"。
- 为什么是 P1 而非卫生债:plan Goal 原文「删除 NemoNotch 全部 Claude 凭证读取路径」;plan Task 5 Step 1 要求 grep `Claude Code-credentials` 并「逐一改写或确认保留理由」——`rg -n "Claude Code-credentials" NemoNotch/` 命中 Codex.swift:94,commit 85d16d9 与交接都未提及、未给保留理由。安全团队的诉求起点是审计 NemoNotch 对 Claude 凭证的接触;合并后仓库仍带着一个标注为 Claude 用的 Keychain 明文读取实现,只是没人调它——运行时 EDR 归零成立,审计口径不成立,且是最容易被下一个人"顺手复活"的形状。
- 修法:删 `+Codex.swift:91-141` 整段(两个函数)。它不在 Codex 配额路径上(上条证据),删除对 zcode/Codex/Gemini 行为零影响,不违反「配额路径一行不动」的拍板;编译器会证明无调用方。若 owner 坚持该文件冻结,最低限度也要在提交信息里记录保留决定并把 Claude 叙事注释/消息改掉——但"留着不提"不可接受。补一个 commit(建议 `refactor(quota): drop orphaned security-CLI keychain reader`),跑 `sh scripts/affected-tests.sh`,更新本记录 Reviewed-Head 后复审。

**[P3] `UsageQuota.swift:190-199, 446-460` — `parseClaudeCodeQuota` + `ClaudeUsageResponse/ClaudeUsageTier` 为生产死码(实现者已自报)**
- `rg -n parseClaudeCodeQuota NemoNotch/` → 仅定义(:190),零生产调用;两个测试 `parseQuotaRealPayload`/`parseQuotaMalformedThrows`(UsageQuotaTests.swift:18/:30)在测死码。`QuotaWindow.sevenDayOpus/.sevenDaySonnet`(:45-46)也已无 producer,但 5 个 UI 文件的 switch 仍处理它们。
- 不接触凭证、plan 删除清单未列,未删合规。建议后续 feature 一并清理(删 enum case 会牵动 EdgeBarUsage/EdgeBarUsageCard/UsageQuotaCardView/QuotaAlert,独立成一张小 plan 更干净);若 owner 愿意并入 P1 的修复 commit 也行。

**[P3] `NemoNotchTests/UsageQuotaTests.swift:264-265, 285, 318-319` — 下标 `quota.tiers[0]/[1]` 在 count 期望之后,失败时 trap 而非干净变红**
- 我额外注入变异 `<= claudeSnapshotFreshInterval` → `<`(边界翻转):套件变红(exit 0,失败 2),但 xcresult 显示 `snapshotFreshAtExactlyFiveHours` 是 **"Test crashed with signal trap"**——`#expect(count == 1)` 记录失败后 `quota.tiers[0]` 对空数组下标越界,整个测试进程被 kill,并发中的 `snapshotHappyPathBothWindows` 被连带标为 crash。守卫有牙,但红的方式丢失断言信息、殃及旁观测试。
- 修法:`let tier = try #require(quota.tiers.first)` / `try #require(quota.tiers.count == 2)` 替代裸下标。另 `#expect(quota.tiers[0].resetsAt != nil)`(:264-265)可钉字面 Date(`2026-09-21T14:13:20Z`)——对 Review Focus 3「毫秒 ISO 解析」更有鉴别力。可选。

**[P3] 状态语义的两处模糊(不要求改,记录供日后判读 bug 报告)**
- `UsageQuota.swift:412-415`:`updated_at` **存在但格式坏** → `.snapshotStale`(UI「等待 Claude 会话刷新」)而非 `.parseError`。plan 文字「缺失或超龄」可宽读覆盖;但真遇到 claude-hud 换时间格式时,用户看到的是"等会话"而不是"坏了"。
- `UsageQuotaService+Claude.swift:15`:`try? Data(contentsOf:)` 任何失败(含 EACCES)→ nil → `.snapshotMissing`(「需配置 claude-hud 快照」)。文件在但读不到会被当成没配置。

**[P3] `UsageQuotaService+Codex.swift:72` — 越出 plan Task 3 Files 清单的改动,提交信息未说明**
- 注释从 "see readClaudeCredential for the rationale" 改为独立解释。明显必要(所指函数已删,否则悬空)且零行为变化;但 plan Task 3 Files 未列 Codex.swift,commit d7bc976 message 只写 "zcode/Codex/Gemini quota paths untouched",未提这一处——与交接里的「偏差 5」不一致。按本仓规则记一笔,不阻塞。

### plan 忠实度核验

- 提交结构:`git log --oneline develop..HEAD` = 1 plan 提交(2ed4a39)+ 5 任务提交(f55a13f/995ac6e/d7bc976/03ebabc/85d16d9),每条 message 引用 "Task N of docs/superpowers/plans/…",与 plan 各 Task 的 Commit 文案逐字一致;checkbox 随任务勾(`grep -c '^\s*- \[ \]'` → 0 裸框)。
- 接口对照 plan Task 1「Interfaces」:`enum ClaudeUsageSnapshotParser { static func parse(data:now:) -> ProviderUsageQuota }`(UsageQuota.swift:393-429)✓;`data==nil → .snapshotMissing`(:402)✓;非对象 → `.parseError`(:405-409)✓;`updated_at` 缺/超龄 → `.snapshotStale` 空 tiers(:412-416)✓;单/双窗 → `.valid`,window 映射(:417-420)✓;`resets_at` 解析失败 → nil 不丢窗(:433-440)✓;两窗都缺 → `.parseError`(:421-426)✓;`provider: .claude, fetchedAt: now` ✓。常量 `claudeSnapshotFreshInterval = 5 * 3600` 带理由注释(:394-398)✓。
- 已声明偏差 7 条逐条看:(1) statusKey 两 case 提前到 Task 1——穷举 switch 的编译必要性成立,commit f55a13f message 已说明 ✓;(2) 新测试并入 `UsageQuotaTests` 而非新 suite——理由(affected-tests 按文件名选类)成立,且本轮实证了这个坑(见教训候选 L1)✓;(3) ISO 复用 `UsageQuotaParser.parseResetDate`(:285-297):带小数 → 截断到毫秒 → 不带小数三段尝试,满足 plan「两个 formatter 先后尝试」✓;(4) `authorize()` 对 `.claude` 也 guard、`keychainService(.claude)` 返空串(Keychain.swift:69/:130)——防御性,最小 ✓;(5) 见上 P3;(6) 带日期 specs/archive 与 playbook 战例保留——历史记录非现状断言,合理 ✓;(7) 全树 lint --fix 的 HookInstaller.swift 漂移已还原——我在 develop 复核 `swiftformat --config ./.swiftformat --lint NemoNotch NemoNotchTests` → EXIT=70,唯一命中 `HookInstaller.swift`,确属 develop 既存 ✓。
- **未声明的遗漏**:上面 P1(plan Goal + Task 5 Step 1 词表 `Claude Code-credentials` 的命中未处理)。

### 亲跑证据(全部在 worktree `.worktree/claude-quota-snapshot`,HEAD 85d16d9)

| 检查 | 命令 | 结果 |
|---|---|---|
| 影响面测试 | `sh scripts/affected-tests.sh` | **EXIT=0**;选 EdgeBarUsageCardTests,EdgeBarUsageTests,QuotaAlertTests,UsageQuotaTests;脚本摘要「通过 60 · 失败 0」,build/test.log 实数 **61 passed / 0 failed**(摘要少 1 系 `parseCodexQuotaFreeTier() passe2026-10-28…` 一行被 xcodebuild stdout 插断);10 个 `snapshot*` 用例逐个 `passed` 可见 |
| QuotaAlert 门禁套件(affected-tests 静默漏跑,见 L1) | `sh scripts/test.sh --only QuotaAlertDetectorTests,QuotaAlertsTests,EdgeBarUsageFittingTests` | **EXIT=0**,14/0(7+5+2) |
| plan 指定变异(阈值 ×10) | `sh scripts/mutate.sh NemoNotch/Models/UsageQuota.swift "5 * 3600" "5 * 36000" --only UsageQuotaTests` | **EXIT=0** 变异被抓住(失败 1 `snapshotStaleWhenOlderThanFiveHours`/通过 39);文件已恢复(`git status` 仅 `?? .reviews/…`) |
| 额外变异(边界 `<=`→`<`) | `sh scripts/mutate.sh NemoNotch/Models/UsageQuota.swift "<= claudeSnapshotFreshInterval" "< claudeSnapshotFreshInterval" --only UsageQuotaTests` | **EXIT=0** 变异被抓住(失败 2/通过 38;xcresult:两者均 "Test crashed with signal trap",见 P3);文件已恢复 |
| 零网络 | `rg -n "URLSession\|api\.anthropic" NemoNotch/Services/UsageQuotaService+Claude.swift` | 零命中(rg EXIT=1) |
| Review Focus 5 残留 | `rg -n "claude-cred\|\.credentials\.json\|useSecurityCLI\|claudeKeychainService\|parseClaudeCredentials\|claudeUsageURL" NemoNotch/ NemoNotchTests/` | 仅 `UsageQuotaService.swift:66,69`(init 迁移清理,plan 允许) |
| 扩词残留 | `rg -n "api\.anthropic\|oauth/usage\|Claude Code-credentials\|claudeAiOauth" NemoNotch/ NemoNotchTests/` | **命中 `UsageQuotaService+Codex.swift:94`** → P1 |
| 死码 | `rg -n parseClaudeCodeQuota NemoNotch/`;`git grep -n readKeychainCredentialViaSecurityCLI develop -- NemoNotch/` | 前者仅定义;后者 develop 唯一调用方 Claude.swift:115(已删) |
| String Catalog | `python3 scripts/xcstrings.py check` | **EXIT=0** canonical |
| 文档对账 | `sh scripts/doc-audit.sh` | **EXIT=0**(6 项全过) |
| 架构围栏 | `sh scripts/check-arch.sh` | **EXIT=0** |
| Lint | `sh scripts/lint.sh`(check-only) | **EXIT=1**——SwiftFormat 报不一致;定位:`swiftformat --config ./.swiftformat --lint <本分支 7 个 .swift>` → **0/7 需格式化**;全树唯一命中 `NemoNotch/Services/HookInstaller.swift`(本分支未触及),develop 同命令 **EXIT=70** → develop 既存漂移,**不计入本分支**;SwiftLint 仅存量 warning、无 error |
| 工作树 | `git status --porcelain` | 全程仅 `?? .reviews/claude-quota-snapshot.md`;我未改任何其它文件 |

未做:真机 GUI 验证(起 app 看 AI tab/边栏 Claude 行)——需部署后按 plan「部署后机器侧步骤」执行,不在 worktree 评审范围;本判断只基于代码阅读 + 上表脚本证据。

### 审查清单

- [x] **判别剃刀**:10 个新测试均以字面 JSON 输入调 `parse(data:now:)`,断言具体 status/window 序列/utilization 值/`tiers.isEmpty`/`fetchedAt`;parser 全返默认值过不了任何一条。两次变异均变红(上表)。弱点见 P3(`resetsAt != nil` 未钉值;裸下标)。
- [x] **证据纪律**:各 commit message 与交接引用了 affected-tests/mutate/xcstrings/doc-audit 的退出码(第 4 级);我已全部复跑,与自述一致(61/0 对 61/0;变异抓住;check 0;audit 0)。交接坦白了管道尾退出码误读并改法——好。
- [x] **Swift 6 并发**:`ClaudeUsageSnapshotParser` 纯 static enum、无状态;`fetchClaude()` 在 `@MainActor` 类上,`lastClaudeQuotaLogState` 只在 actor 内写(Claude.swift:24-32);`CredentialStatus: Sendable` 加 case 无风险;`Data(contentsOf:)` 主线程内联读 ~200B 为 plan 明示并注释(Claude.swift:13-14)。无新 `nonisolated`/`@unchecked`。
- [x] **最小改动**:7 个 .swift 全部可追溯到任务;Codex.swift:72 注释为必要衍生(P3 记一笔);**例外**:删除面没删干净(P1)——是少删不是多改。
- [x] **错误路径**:坏 JSON/非对象/两窗缺 → `.parseError` 带 errorMessage(UsageQuota.swift:405-409/421-426);缺文件 → `.snapshotMissing`;超龄 → `.snapshotStale` 空 tiers;UI 三者皆落 `statusKey` 文案分支(UsageQuotaCardView.swift:115-119/:213-214);`backfilled()` 对空 tiers 直接返回不混旧值(UsageQuotaService.swift:142);QuotaAlert 只吃 `.valid` 非空(QuotaAlert.swift:58,套件 12/12 过)。init 的遗留缓存删除 best-effort 且只在存在时打一次 .info(UsageQuotaService.swift:68-73)。两处语义模糊记 P3。
- [x] **坑总目录对照**:「轮询循环里记状态迁移不记每次失败 tick」→ `logClaudeQuotaState` 状态串比较、变化才 .info(Claude.swift:24-32)✓;「Keychain 凭据绝不自动弹窗」→ Claude 路径整体移除,`authorize(.claude)` 被 guard(Keychain.swift:69)✓;「推翻旧口径 ⇒ 全仓 grep 残留」→ AGENTS/README/README_CN 已改;代码注释残留见 P1。
- [x] **教训候选**:见下节。
- [x] **文档同步**:AGENTS.md:81 整条重写(路径、绝对路径要求、5h、日志纪律、遗留清理、其它 provider 不动的拍板);README.md:50 / README_CN.md:50 同步;doc-audit 0。

### 教训候选(供 reflect 分流)

- **L1(可门禁化,建议进 guardrail-backlog)** `scripts/affected-tests.sh` 「文件名即类名」在 suite 名 ≠ 文件名时**静默选中 0 个测试并报成功**:本轮 `-only-testing:NemoNotchTests/QuotaAlertTests` 实际执行 0 例(该文件的 suite 是 `QuotaAlertDetectorTests`/`QuotaAlertsTests`,`NemoNotchTests/QuotaAlertTests.swift:9,88`);`EdgeBarUsageTests.swift:71` 的第二 suite `EdgeBarUsageFittingTests` 同样漏跑。这正是脚本要防的假绿形状——本次 plan 设计事实 4 倚赖的 QuotaAlert 门禁其实没被影响面测试覆盖(我手动补跑才闭合)。判据/修法:从选中的测试文件里抽 `struct|final class (\w+)` / `@Suite` 名全部传给 `--only`;或 test.sh 对每个请求的类核对 ≥1 例执行、0 例即非零。实现者的偏差 (2) 说明他们知道这个坑并为自己的测试规避了——该硬化了。
- **L2(小)** `scripts/test.sh` 摘要计数被 xcodebuild stdout 插断(`…passe2026-10-28…`)少算 1:本轮 60 vs 实 61。从 xcresult 取数或容忍插断。
- **L3(develop 一次性修)** develop 的 `NemoNotch/Services/HookInstaller.swift` 不过 `.swiftformat`(全树 `--lint` EXIT=70),任何人跑全树 `--fix` 都会把它拖进无关分支。在 develop 上单独修一次。
- **L4(AGENTS 坑候选)** 「编译器引导清干净」对**被调用方**失效:删开关常量 + 删调用点,未被调用的实现不会报错(本轮 P1 即此形状)。判据:删掉一个 feature-flag/选择开关时,grep 它选择的那条分支的函数名(这里 `ViaSecurityCLI`),不是只 grep 开关名(`useSecurityCLI`——plan 词表恰好只覆盖了开关)。
- **L5(测试写法)** Swift Testing 里 `#expect(count == N)` 后紧跟裸下标 `[i]`,失败即 trap 杀进程、殃及并发用例;用 `try #require(…first)`。见 P3。

### 复审指引

修 P1 后在 worktree:`sh scripts/affected-tests.sh`(引退出码)+ `rg -n "readKeychainCredentialViaSecurityCLI|securityCLICredentialBlob|Claude Code-credentials|Claude keychain" NemoNotch/ NemoNotchTests/` 零命中。然后把本记录的 `Reviewed-Head:` 更新为新 head,在下方追加「第 2 轮」小节(**不要重跑 review.sh 覆盖本文**)。P3 项可选处理,不阻塞。

## 第 2 轮(Reviewed-Head 3dee6d3)—— 2026-10-28

> Reviewed-Head 写 `3dee6d3`(最近一次非 .reviews 提交,feat-done 门禁的比对目标);`git rev-parse --short HEAD` 此时输出 `965ff80`(第 1 轮记录的 docs commit,非代码)。

### 结论先行

第 1 轮唯一阻塞项(P1 security-CLI Keychain 死码)已删干净;两条 P2(rolled-window stale、api.anthropic wire 死码)均已修且有鉴别力守卫;P3 全部处理或按建议记录在案。回归全绿(下表全部亲跑)。新发现仅 1 条 P3(注释/AGENTS 对新鲜度双信号的主从表述与代码行为在罕见场景分歧——行为正确,仅措辞)。**Verdict: APPROVED**。

### 上轮意见逐条核验

| 上轮 | 修复 commit / 状态 | 本轮证据 |
|---|---|---|
| P1 security-CLI reader 死码(+Codex.swift:91-141) | `aa2094a` 删除 52 行 | `rg -n "readKeychainCredentialViaSecurityCLI\|securityCLICredentialBlob\|Claude Code-credentials\|Claude keychain\|api\.anthropic\|claudeAiOauth\|useSecurityCLI\|readClaudeCredential\|writeClaudeCache\|invalidateClaudeCache" NemoNotch/ NemoNotchTests/` → **零命中**(EXIT=1);commit message 补记了偏差 5(Codex.swift:72 注释越界)——上轮 P3 的「记一笔」落实 |
| P2 resets_at 已过 → stale | `31c44c7` 双信号:任一 tier `resetsAt < now` → `.snapshotStale`(UsageQuota.swift rolled 检查);守卫测试 `snapshotRolledWindowIsStaleDespiteFreshUpdatedAt`(用第 1 轮实捕数据形状:updated_at 11:40 / 5h reset 12:00 / 读于 12:20) | 变异 `$0 < now` → `_ in false`(禁用 rolled 规则)→ EXIT=0 变异被抓住,失败正是该测试,干净断言失败 |
| P2 wire decoder 死码 | `6ff0c7f` 删 `parseClaudeCodeQuota` + 私有 `tier(_:_:)` + `ClaudeUsageResponse/ClaudeUsageTier`(−65 行,含 2 个死码测试);`parseResetDate` 保留(Gemini/Codex/快照共用),其测试移至重命名 MARK | 上方 grep 零命中;`.sevenDayOpus/.sevenDaySonnet` 及 UI 分支 **deferred with record**(commit message 明示"touch four UI files — a follow-up cleanup feature")——符合上轮「允许拆开但要有记录」 |
| P3 测试裸下标 / resetsAt 不钉值 | `31c44c7` 改 `try #require(...first/last)` + 钉字面 Date;`snapshotStaleWhenOlderThanFiveHours` 重构为「resets_at 在未来、只有 updated_at 能判」(护住阈值变异的鉴别力) | 边界变异 `<=`→`<`:EXIT=0 被抓住,失败 `snapshotFreshAtExactlyFiveHours`,**0 crash/0 trap**(上轮同变异是 trap 杀进程);阈值变异 `5*3600`→`5*36000`:失败 `snapshotStaleWhenOlderThanFiveHours`——重构后的特异性别丢了 |
| P3 读失败吞成 missing | `31c44c7` `fetchClaude()` 先 `fileExists`,读错误 catch → `.parseError` 带 errorMessage + `.warn`(与「未配置」区分) | `+Claude.swift:8-27` 亲读;AGENTS.md 同步该语义 |
| P3 注释审判 MUST KILL ①-⑥ | ①②③ 于 `31c44c7`、④⑤⑥ 于 `3dee6d3` 全删 | 亲读:fetchClaude/logClaudeQuotaState/claudeSnapshotURL/lastClaudeQuotaLogState 均无 doc,"ONLY quota source" 句已删;白名单项(外部格式契约 4 行、5h 理由、枚举 case doc、init 迁移 why、Keychain 行内注释)**全部保留未误删** |
| P3 updated_at 坏格式 → stale(不要求改) | 未改(维持上轮决定) | — |

### Findings(第 2 轮新发现)

**[P3] `NemoNotch/Models/UsageQuota.swift` rolled 规则注释末句 + `AGENTS.md` Usage quota 条目 — 「updated_at 只作兜底」的表述与代码行为在罕见场景分歧(行为正确,仅措辞)**
- 代码事实(亲读):updated_at 超 5h 是**无条件第一道闸**(在 tier 解析之前,UsageQuota.swift parse 前段),rolled 检查是第二道;注释末句 "updated_at is only the fallback freshness signal for tiers without a resets_at" 与 AGENTS「`updated_at` 超 5h 只作 resets_at 为 nil 的兜底」都把它说成从属兜底。
- 分歧场景(罕见但存在):快照只有 7d 窗、其 resets 在未来、updated_at 超 5h → 代码判 `.snapshotStale`(正确:5h 没会话就该等刷新,plan 原语义),按「兜底」读法则是 `.valid`。两窗齐全时两者等价(5h 窗 resets_at ≤ updated_at+5h,updated_at 超 5h ⇒ 该窗必已滚动)。
- 顺带:`snapshotStale` 枚举 doc 仍只列 updated_at 一个成因,没提 rolled 来源。日后有人按注释/手册「优化」会把上述场景改坏——建议改为「updated_at 超 5h、或任一 tier 的 resets_at 已过,任一即 stale」。不阻塞。

**[观察,不计 finding] `fetchClaude` 的 `fileExists` + `try Data` 两步间存在 TOCTOU**:文件恰在两步之间被删 → 一拍 `.parseError`(而非 missing),下一拍自愈。原子 rename 写不删文件,仅用户手删可触发;为修复上轮「读失败归并」而引入的形状,代价可接受。

### 亲跑证据(全部在 worktree,输入文件先经 `git status` + 与 HEAD diff 验证干净)

| 检查 | 命令 | 结果 |
|---|---|---|
| **作废声明** | 首轮 `affected-tests.sh` | 首跑 60/0 **作废**:跑后发现工作树 UsageQuota.swift 曾处变异态(`$0 < now`→`_ in false`,20:27 出现 `nemonotch-mutate.bak`、20:28 消失)——实现侧会话与本次评审**并发**使用同一 worktree,编译时刻无法确证在变异窗口外。文件恢复、与 HEAD 逐字节一致后**重跑** |
| 影响面测试(重跑) | `sh scripts/affected-tests.sh` | **EXIT=0**;60 passed / 0 failed(test.log 实数);账目吻合:61 − 删 2 死码测试 + 1 新 rolled 测试 = 60 |
| QuotaAlert 门禁套件(上轮 L1,affected-tests 仍漏选) | `sh scripts/test.sh --only QuotaAlertDetectorTests,QuotaAlertsTests,EdgeBarUsageFittingTests` | **EXIT=0**,14/0 |
| 变异①(rolled 规则禁用) | `sh scripts/mutate.sh NemoNotch/Models/UsageQuota.swift '$0 < now' '_ in false' --only UsageQuotaTests` | **EXIT=0** 被抓住(失败 1 = `snapshotRolledWindowIsStaleDespiteFreshUpdatedAt` / 通过 38);文件 trap 恢复 |
| 变异②(阈值 ×10) | 同脚本 `"5 * 3600"` → `"5 * 36000"` | **EXIT=0** 被抓住(失败 1 = `snapshotStaleWhenOlderThanFiveHours` / 通过 38)——重构后特异性别未丢 |
| 变异③(边界 `<=`→`<`) | 同脚本 | **EXIT=0** 被抓住(失败 1 = `snapshotFreshAtExactlyFiveHours`);**0 crash/0 trap**(上轮同变异双 trap) |
| 死码/凭证残留(扩词) | `rg` 见上表 P1 行 | **零命中** |
| String Catalog | `python3 scripts/xcstrings.py check` | **EXIT=0**;两个新 key 的 zh-Hans 文案在位 |
| 文档对账 | `sh scripts/doc-audit.sh` | **EXIT=0** |
| 架构围栏 | `sh scripts/check-arch.sh` | **EXIT=0**(A+B 档全过) |
| Lint(全树 check) | `sh scripts/lint.sh` | **EXIT=1,但不计入本分支**:本分支 7 个改动 .swift `swiftformat --lint` **0/7 需格式化**;全树唯一命中 `HookInstaller.swift` 系分叉点(7405ba2)旧 develop 漂移——develop 侧已修(9db7171),本分支对该文件零改动,`--no-ff` 合并自取 develop 版;SwiftLint 0 error(27 存量 warning) |
| plan checkbox | `grep -c '^\s*- \[ \]'` / `'- \[x\]'` | 0 裸框 / 20 勾 |
| 工作树 | `git status --porcelain`(每步后) | 除本文件外全程干净;3 次变异后均恢复 |

未做:真机 GUI 验证(与第 1 轮相同,按 plan「部署后机器侧步骤」在合并部署后执行);claude-hud 机器侧配置不在 worktree 范围。

### 教训候选(第 2 轮追加)

- **L6(guardrail-backlog 候选)评审与实现侧验证并发共享 worktree 会互相污染**:本轮首跑 affected-tests 期间,实现侧的 mutate.sh 恰好把 UsageQuota.swift 置于变异态(20:27 注入 .bak、20:28 恢复),测试结果的编译输入无法确证——只能作废重跑。判据/修法候选:mutate.sh 跑时落锁文件(如 `.nemonotch-mutate.lock`),affected-tests/test.sh 见锁即拒跑或等待;或评审期间约定 worktree 独占。同一 DerivedData 的并发 xcodebuild 同理。
- L1(affected-tests 漏选)本轮复现依旧:摘要仍列出 `QuotaAlertTests`(0 例的类名),门禁套件靠手动补跑——硬化优先级应提高。

### Verdict(第 2 轮)

**APPROVED** — P1/P2 全修、P3 处置得当、回归全绿、两条变异守卫(rolled + 阈值)经本轮独立变异实证有牙且红得干净。唯一新 finding 为 P3 措辞项(不阻塞,建议随手改或并入后续 opus/sonnet 清理 feature)。合并部署后仍须走 plan「部署后机器侧步骤」(claude-hud `externalUsageWritePath` 绝对路径 + 真机 5h/7d 显示验证)。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 7405ba277b720cfc2fbf506b52148e2083d6c712...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
