# Code Review — feature/toast-click-jump

Reviewer: 独立评审子代理(Claude Opus 5.5,未参与开发,只读 worktree)
Date: 2026-10-29
Reviewed-Head: 55526b0
Verdict: APPROVED
Scope:  9 files changed, 168 insertions(+), 9 deletions(-)

```
AGENTS.md
NemoNotch/Notch/CompletionToastLayout.swift
NemoNotch/Notch/CompletionToastWindow.swift
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotchTests/CompletionToastClickTests.swift
README.md
README_CN.md
docs/superpowers/specs/2026-10-29-toast-click-jump-design.md
```

## Findings

第 2 轮(head 55526b0,复审 7110558..55526b0):无 P1 / P2。P3-1、P3-2 已修并经评审员复验(见文末「第 2 轮运行证据」);P3-3、P3-4 按作者说明保留,接受。

第 1 轮(head 7110558)原始记录如下:

- `NemoNotch/Services/CompletionDetector.swift:12-16` — 新 `CompletionJump` 插在 `CompletionItem` 的文档注释与 struct 之间,"A finished unit of work…" 三行现在挂在 `CompletionJump` 上,`CompletionItem` 失去文档注释。把那三行挪回 `struct CompletionItem` 之上即可。[P3] **已修(d4fc0ff)**:注释回到 `CompletionDetector.swift:26-28` 的 `struct CompletionItem` 之上,`CompletionJump` 保留自己的两行注释。
- `NemoNotch/Services/CompletionDetector.swift:24` — `CompletionJump.make` 的「只有 tab 链接也算可跳」分支无测试守护:变异 `|| tabLink != nil else` → `else` **存活**(mutate.sh exit 1,20 例全绿)。边栏 `EdgeBarModel.swift:159-161` 明确把「只有 tab link」当可跳,两处语义一致性目前只靠代码自觉。建议在 `makeRequiresSomeField` 加一行 tabLink-only 断言。[P3] **已修(55526b0)**:`CompletionToastClickTests.swift:47-49` 新增 tab-link-only 断言;评审员复跑同一变异 → 被抓住(exit 0,1 失败)。
- `NemoNotch/Services/CompletionFlashService.swift:74-78` — 会话字段 → `CompletionJump` 的映射无测试:变异 `hostBundleId: session.launchingAppBundleId` → `nil` 全量 579 例**存活**(exit 1)。这是 private 服务方法,测它要起 store+service,属"无廉价测试目标",可接受;但要明说:接线正确性目前只有梯级 2(读代码)。[P3]
- 快照 vs 点击时回查(设计选择,判定为对):`AICLIMonitorService.swift:170-178` 在 dispatch **之后**另起一次 `store.mutate` 记录宿主,但两次突变都在 `routeEvent` 同一同步段内,而 `CompletionFlashService.observe` 的 onChange 经 `Task { @MainActor }` 跳一拍才 `evaluate()`(`CompletionFlashService.swift:105-113`),所以快照时宿主已落地;`ClaudeCodeService.swift:133` 的 record 路径在同一 mutate 里记录。残余盲区只有"宿主在完成**之后**才首次解析出来"(例如此前每次进程树上溯都没找到 GUI 祖先),这种情况点击时回查也大概率同样拿不到;反过来快照能熬过 stale 回收,回查不能。若想两全可点击时先查 store、缺了再用快照——非必要。[P3 观察]
- 与边栏 Go 的激活路径对比:同一个 `AppActivator.activate`、同样从 never-active app 的非激活面板里由真实 mouseDown 触发(边栏经 `press` 的 asyncAfter 延迟,toast 同步执行),激活条件等价。顺序上边栏先 `hover.closeNow()` 再 activate,这里先 activate 再 `dismissToast`;`dismissToast` 只动 `toastQueue`/`toasts`,与激活无耦合,两种顺序在同一 runloop turn 内结果相同,不存在先收卡导致点击上下文丢失的问题(卡在面板里收起不 orderOut 面板,最后一张卡的 orderOut 还有 `hudAppearDuration+0.1s` 延迟)。梯级 2–3(读代码推断),未在运行中的 app 复现(梯级 5 未达)。[P3 观察]
- `CompletionToastWindow.swift:350` — 点击按 `host.layout`(apply 时异步同步)的索引去取 `service.toasts[index]`;若卡片在 apply 的那一拍之间到期移除,索引可能错位到相邻卡。存量问题(× 早就如此),但后果从"关错卡"升级为"跳错 app"。窗口仅一个 main-queue turn,实际概率极低。[P3]

### 教训候选

- `CompletionDetector.swift:12` — 在已有 `///` 文档注释与声明之间插入新类型会把注释"偷"走;swiftlint/swiftformat 都不拦。判据:新增顶层类型时看它上方紧邻的 `///` 是不是原本属于下一个声明。(可能可门禁化:相邻两个顶层声明之间若注释首句明显描述后者……难机械化,大概率只能留作评审清单项。)
- 「同一个"可不可跳"判据在两处各写一遍」(`EdgeBarModel.content` 的 `hasHost` 与 `CompletionJump.make`)——三字段非空判断重复,将来加第四种跳转源(如 IDE deep link)容易只改一处。判据:新增跳转源时 grep `tabLinkURL != nil`。

## 运行证据(梯级 4)

- `sh scripts/affected-tests.sh` → exit 0;选中 CompletionDetectorTests/CompletionPathTests/CompletionToastClickTests/CompletionToastLayoutTests/CompletionToastQueueTests,44 通过 0 失败(`build/test.log`)。
- `scripts/mutate.sh`(`--only CompletionDetectorTests,CompletionToastClickTests`,M5 全量):
  - M1 merge 去掉 `?? older.jump` → 红,exit 0 ✓
  - M2 detector `jump: candidate.jump` → `nil` → 红,exit 0 ✓
  - M3 无宿主卡 `.dismiss` → `nil` → 红,exit 0 ✓
  - M4 make 去掉 `|| tabLink != nil` → **存活**,exit 1(见上 P3)
  - M5 服务映射 `hostBundleId` → `nil` → **存活**,exit 1,全量 579 例(见上 P3)
- `sh scripts/check-arch.sh` exit 0;`sh scripts/doc-audit.sh` exit 0;`sh scripts/lint.sh` exit 0。
- 每次跑后 `grep -E '^# port' ~/.NemoNotch/hooks/hook-sender.sh` → `# port: 45831`(未被测试宿主改写)。

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

在 worktree 里:`git diff 8189b0bb05da63a9e2324d373c0f7ac32d28544f...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

## 第 2 轮运行证据(head 55526b0,梯级 4)

- `sh scripts/affected-tests.sh` → exit 0;同 5 个测试类,44 通过 0 失败。
- `scripts/mutate.sh NemoNotch/Services/CompletionDetector.swift '|| tabLink != nil else' 'else' --only CompletionDetectorTests,CompletionToastClickTests` → **变异被抓住**,exit 0(测试 exit 65,1 失败 19 通过)。由评审员复跑,不采信作者自述。
- `check-arch.sh` exit 0;`doc-audit.sh` exit 0;`lint.sh` exit 0。
- 跑后 `grep -E '^# port' ~/.NemoNotch/hooks/hook-sender.sh` → `# port: 45831`。
