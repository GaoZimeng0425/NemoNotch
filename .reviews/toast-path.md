# Code Review — feature/toast-path

Reviewer: independent review subagent (Claude, fresh context; did not author this branch)
Date: 2026-10-28
Reviewed-Head: 47342fb
Verdict: APPROVED
Scope:  9 files changed, 115 insertions(+), 12 deletions(-)

```
NemoNotch/Notch/CompletionToastLayout.swift
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotchTests/CompletionPathTests.swift
NemoNotchTests/CompletionToastLayoutTests.swift
README.md
README_CN.md
docs/images/completion-flash.png
```

## Findings

无 P1/P2。P3 备注:

- NemoNotch/Services/ClaudeCodeService.swift:199-201 — 磁盘扫描恢复的 Claude 会话 cwd 由项目目录名把 `-` 全换成 `/` 还原,有损(`.worktree/toast-path` → `//worktree/toast/path`)。本分支首次把完整 cwd 展示给用户;但 ClaudeCodeService.swift:392 `applyContext` 每个 hook 事件都用 `event.cwd` 覆盖,而触发 toast 需要 working→idle 边沿(必有 hook 事件),实际展示到错误路径的窗口很窄。存量问题,不阻塞。[P3]
- NemoNotch/Services/CompletionDetector.swift:186 + CompletionFlashService.swift:64 — toast 按 `name`(= projectFolder,最后一级目录)同名合并;两个不同父目录下同名项目(如主检出与另一机位的同名 repo)完成时并成一张卡,path 取较新者。合并语义是存量设计,新 path 行只是让"哪一个"可见,记录即可。[P3]
- 提交序列:aaa083a 把 cardHeight 52→66,但 CompletionToastLayoutTests.swift:42 的 `y: 60`「卡片下方」探针直到 88c06cf 才改成 `y: 70`——aaa083a 单独检出时该用例应为红(未实跑该中间提交,推断自 diff),违反「序列可验证单元」,bisect 时会误报。不重写历史,记录。[P3]
- 提交信息无任何验证声明(无退出码/日志)。评审方已自跑到第 4 级(见下)。[P3]
- docs/images/completion-flash.png — 截图只有标题 + 路径两行,未展示「标题 + detail + 路径」三行满载卡;66pt 容纳三行只到第 2 级(13pt semibold + 11pt + 10pt mono + 2×2 spacing ≈ 47pt < 66,CompletionToastView.swift:35-63,Constants.swift:137-138),未在运行中 app 看过满载形态。[P3]
- 面板高度 CompletionToastWindow.swift:216 `panelHeight = cardHeight + 2` 自动跟随,命中几何 CompletionToastLayout.swift:38 也用同一常量——无漏改点(已核)。

评审方实跑(第 4 级):
- `sh scripts/check-arch.sh` → exit 0(全部通过)
- `sh scripts/doc-audit.sh` → exit 0
- `sh scripts/affected-tests.sh` → 选类 CompletionDetectorTests,CompletionPathTests,CompletionToastLayoutTests,CompletionToastQueueTests;通过 34 / 失败 0,exit 0(build/test.log)
- `sh scripts/mutate.sh CompletionDetector.swift 'path: candidate.path' → 'path: nil' --only CompletionPathTests` → exit 0(变异被抓)
- `sh scripts/mutate.sh CompletionDetector.swift 'result[idx].path = v' → '= nil'` → exit 0(被抓)
- `sh scripts/mutate.sh CompletionDetector.swift 'path.hasPrefix(trimmedHome + "/")' → 'path.hasPrefix(trimmedHome)'` → exit 0(被抓,兄弟前缀用例有牙)
- `sh scripts/mutate.sh CompletionToastLayout.swift 'cardHeight = 66' → '= 52' --only CompletionToastLayoutTests` → exit 0(被抓)
- 未跑全量 lint(已知 HookInstaller.swift 存量失败,本分支未触及)。

### 教训候选

- CompletionToastLayoutTests.swift:42 — 改尺寸常量的提交必须同提交改依赖该常量的几何探针;判据:feature 提交序列每个提交单独跑受影响测试应为绿(可考虑 feat-done 抽查「改了常量的提交」的中间态)。
- ClaudeCodeService.swift:200 — 从 Claude 项目目录名反解 cwd 是有损编码,凡要把 cwd 原样展示给用户的新功能,不能信磁盘扫描来源的值(只信 hook 的 `event.cwd` 或 transcript 记录里的 cwd)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙) — 4 次变异全被抓
- [x] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)? — 提交信息无声明;评审方自跑到 4 级(P3)
- [x] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过? — N/A:新增仅值类型字段 + 纯函数,MainActor 服务内读 session.cwd
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码 — 是
- [x] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿 — nil/空 path 不渲染行,无错误路径
- [x] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗? — Toast 节:面板高度/命中几何同源跟随;无 opacity 隐藏、无 repeatForever(check-arch 绿)
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [x] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗? — README/README_CN 已更新,AGENTS.md 无不变量变化

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 7405ba277b720cfc2fbf506b52148e2083d6c712...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
