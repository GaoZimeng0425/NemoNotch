全部验证完毕，证据链闭合。汇总并返回填好的评审记录全文。

**验证摘要(均为本人实跑，引用真实退出码)**
- 门禁：`lint.sh` exit=0(告警全为存量，AppActivator 无新告警)、`doc-audit.sh` exit=0、`check-arch.sh` exit=0、`affected-tests.sh` exit=0(确定性映射选中 `AppActivatorTests`,10 过 0 败；`build/test-head.txt` 仍为 d678367,子集未顶替全量锚点)
- 派发方全量测试复核:`build/test-head.txt`=d678367=HEAD，原 `build/test.log:807` `** TEST SUCCEEDED **`(17:03;我的子集运行覆盖了该文件，已快照到 `/tmp/nn-review-fulltest-snapshot.log`)
- 机制验证(第 5 级，不抢前台)：Mail 处于 bug 现场(pid 73285 活着、9 个 layer-0 全为辅助窗、零 viewer 窗)时，用**与修复相同的 API**(`NSWorkspace.openApplication(at:configuration:)`、`activates=false`)调用 → completion `app.pid=73285 err=nil`(复用实例、无新实例)，随后新出现 layer-0 窗 `#2432 onscreen=true 1512×948`(viewer 主窗重建)，前台未被夺走；callback 线程实测 `onMain=false queue=com.apple.launchservices.open-queue`,印证 SDK 头文件「concurrent queue」——修复在 handler 里只调 nonisolated `LogService` + `DispatchQueue.main.asyncAfter`,并发处理正确
- 日志核对(只读)：今日 Mail 通知卡激活 23 次全部 `accepted=true`;「8/8、无 did-not-take」对应 16:30 前前 8 次(与作者/派发方口径吻合)；18:08:51 有 1 条 `did not take — frontmost is dev.herdr.app`(旧路径、修复后两路径仍保留 `verifyFrontmost` 诊断)；**今日 0 条 `Opening … via Launch Services`**——新代码路径未在真实 app 跑过(见 P3-2)
- 副作用披露：我的探针使 Mail 在后台出现了一个 viewer 主窗(1512×948,未激活、未抢前台)——恰好是用户期望的状态

---

# Code Review — feature/fix-toast-open-reopen

Reviewer: 独立评审子代理(ZCode / GLM-5.3,未参与开发)
Date: 2026-11-02
Reviewed-Head: d678367
Verdict: APPROVED
Scope:  2 files changed, 36 insertions(+), 12 deletions(-)

```
AGENTS.md
NemoNotch/Services/AppActivator.swift
```

## Findings

- **[P3]** AGENTS.md:119 — 完成闪光段「激活统一走 `bringForward`」在本分支后不再成立(`.open` 路径已改走 Launch Services,「统一」变假)。一句话修法:改成「`.jump` 的激活走 `bringForward`(通知卡 `.open` 走 LS,见下条)」。
- **[P3]** d678367 提交信息「确认探针 = 关 Mail 主窗 → 点通知卡 → viewer 窗出现且日志无 did not take」— 该端到端确认**没有留下任何工件**：今日日志 0 条 `Opening … via Launch Services`(新代码路径从未在真实 app 里执行过)，新日志行是无条件的，不可能漏记。一句话修法：代码无需改；在合并后的 PR/汇报里附一行勘误，部署后用真实点击日志补上(评审记录已把此失真固化进证据链)。机制本身已被评审员独立复现到第 5 级(见证据摘要)，不影响合并。

## 审查清单(评审者逐项过，不适用项标 N/A)

- [x] **判别剃刀**：N/A — 无新增测试；跳过成立。被测行为是「Launch Services 对运行中实例投递 reopen → Mail 重建主窗」，属系统/Mail 的集成行为，无纯逻辑缝可抽(`openApp` 直接调 `NSWorkspace`/`NSRunningApplication`,为它造注入 seam 的重构量超过修复本身)；既有 `AppActivatorTests` 覆盖的 hostAppPID/recordHost 逻辑未动且仍绿。
- [x] **证据纪律**：提交信息里的 `open -g -b` 探针真实可复现——评审员用**同一 API**(activates=false)在 bug 现场独立复现：viewer 窗 1512×948 重建、completion 复用 pid 73285、err=nil(作者报 win#1884,我复现 win#2432,尺寸一致)。但「确认探针 = 点通知卡 → …」一条零工件(P3-2),系把未跑过的端到端确认写成完成时——梯级 1 冒充梯级 4,扣此项。
- [x] **Swift 6 并发**：✓ — completion handler 线程实测 `onMain=false, queue=com.apple.launchservices.open-queue`(与 SDK 头文件「concurrent queue」一致)；handler 内只调 nonisolated `LogService`、文档标注线程安全的 `NSRunningApplication.processIdentifier`,`verifyFrontmost` 经 `DispatchQueue.main.asyncAfter` 回主线程;捕获仅 Sendable 值(bundleId/pid)。Swift 6 严格并发编译通过(affected-tests 构建)。
- [x] **最小改动**：✓ — 2 文件 36+/12-,每行可追溯(统一走 LS open、`verifyFrontmost` 抽取共享、not-running 路径补错误日志、AGENTS.md 坑条目)；`.jump` 路径(bringForward/activate)刻意不动。
- [x] **错误路径**：✓ — LS 打开失败 → `.warn` 带 localizedDescription;无已装 app → `.warn`;旧版 not-running 分支的 fire-and-forget 吞错已补上;`verifyFrontmost` 0.5s 前台回查两路径共用。
- [x] **坑总目录对照**：✓ — AGENTS.md:120 新增的正是本坑条目(activate 只切前台不发 reopen / LS open = Dock 语义)，事实与日志、探针逐条核对一致；残留一处旧口径(P3-1)。
- [x] **教训候选**：见尾部小节(3 条)。
- [x] **文档同步**：✓ — AGENTS.md:120 已更新且口径准确；README 无此粒度细节，不需要。

## bug 专项镜头

1. **失败测试红→绿**：无测试，跳过成立(理由同判别剃刀；修 bug 测试规则明确留了此出口)。
2. **修复与根因因果对应**：✓，非绕症状 — 三环全部有实证:(a) 旧路径 `activate` 被系统接受且 Mail 成前台(今日 23 次 accepted=true)但探针证明零 viewer 窗 → 「切了前台、没窗」;(b) LS open 对运行实例投递 Apple 事件给该实例(SDK NSWorkspace.h:381-385/402-403,Launch Services 语义);(c) 同 API 探针在 bug 现场使 viewer 窗重建(评审员第 5 级复现)。`OpenConfiguration` 默认 `activates=YES`、`createsNewApplicationInstance=NO`(NSWorkspace.h:163-176)→ 激活 + 复用实例 = Dock 点击语义,与用户期望「等同点 Dock 图标」精确对齐;`running?.bundleURL` 优先还避免了「注册 URL 指向另一份拷贝时开出第二实例」。
3. **旧口径清场**：全仓 grep docs/、README、注释 — 残留 1 处(P3-1);`CompletionToastClick`/`CompletionToastLayout` 注释无过时表述。

## 证据完备度披露

- 已验证：机制(第 5 级，真机真 Mail)、门禁四脚本本人实跑退出码、派发方全量测试工件核对、并发线程假设实测。
- **未直接验证**:`activates=true` 下我们代码的完整点击路径(需部署后真实点击——跑它会抢用户前台，铁律禁止)。该残余由 SDK 文档(`activates` 默认 YES)+ 旧路径日志(22/23 次激活生效)背书；合并部署后用户点一次即可闭环。
- 评审副作用：探针使 Mail 后台出现一个 viewer 主窗(未激活)，恰为用户期望状态，无需处理。

## 教训候选

- AppActivator.swift:245 — `verifyFrontmost` 只看「是否前台」，看不见「前台了但没窗」；本次 8 连 accepted=true 的“成功”日志正是盲区本体。判据：凡「点了没反应」类报告，先用 CGWindowList 只读探针分诊“没前台”vs“没窗口”；候选增强 = 回查时顺带记目标 pid 的 layer-0 可见窗数(不宜门禁化，排 guardrail-backlog 或 playbook)。
- AGENTS.md:120 — 判据已入册(「打开某 app」类交互 = LS `openApplication` 带 reopen;`NSRunningApplication.activate` 只切前台)。不建议门禁化:`.jump` 路径合法用 `activate`,形状规则必假红。
- scripts/review.sh:43 — `grep -q '^Verdict:'` 会被模板自带占位行 `Verdict: (填 …)` 命中，重跑即误报「已有已填 Verdict 的记录」(本次实遇)。修法：匹配 `^Verdict: (APPROVED|CHANGES_NEEDED)`。门禁脚本自身坑，可硬化。

---

**Verdict: APPROVED**——修复与根因因果闭合、机制经评审员第 5 级独立复现、四项门禁本人实跑全绿(退出码 0)、Swift 6 并发线程假设实测印证、改动最小；两条 P3 皆为文档/提交信息层面的口径问题，不阻塞合并。评审对象绑定 `d678367`;diff 变了本结论作废。

相关文件(worktree 只读，未做任何改动):`/Users/aa00930/Documents/Learn/macos/NemoNotch/.worktree/fix-toast-open-reopen/NemoNotch/Services/AppActivator.swift`、`/Users/aa00930/Documents/Learn/macos/NemoNotch/.worktree/fix-toast-open-reopen/NemoNotch/Notch/CompletionToastWindow.swift`(.open 唯一调用点 ：362)、`/Users/aa00930/Documents/Learn/macos/NemoNotch/.worktree/fix-toast-open-reopen/AGENTS.md`(:119-120)。快照:`/tmp/nn-review-fulltest-snapshot.log`(派发方全量测试日志)、探针 `/tmp/nn-review-probe/reopen-probe.swift`。
