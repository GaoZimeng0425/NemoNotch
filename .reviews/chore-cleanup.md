# Code Review — feature/chore-cleanup

Reviewer: 独立评审子代理(Claude Agent SDK,未参与 feature/chore-cleanup 开发)
Date: 2026-11-15
Reviewed-Head: c5e5c70
Verdict: APPROVED
Scope:  2 files changed, 2 insertions(+), 1 deletion(-)

```
NemoNotch/Services/OpenClawService.swift
docs/superpowers/plans/archive/2026-11-12-herdr-mod.md
```

## Findings

- [P3] docs/superpowers/plans/archive/2026-11-12-herdr-mod.md:22 —— 注记放在被它修正的「mod 卡面」那行的**上一行**,而且只出现一次。正文后面还有旧卡面口径(由 .reviews/herdr-card-project.md:75 指出的 :142 附近),读者只看到那里时不会注意到上面的注记。修法:不必修。文件已经进了 archive/,plan-audit 也不审判归档;如果想更稳,可以在 :142 附近同样加一句「见 :22 注记」。

无 P1/P2。

### 验证记录(第 4 级,评审亲跑,worktree @ c5e5c70)

- `sh scripts/lint.sh` → exit 0(「✅ swiftformat + swiftlint 通过」;只剩 scripts/index-affected.swift 的存量 warning,与本分支无关)。
- 红到绿重放:`git show ceae771:NemoNotch/Services/OpenClawService.swift` 落到 scratchpad,`swiftformat --lint --config .swiftformat` 报「Source input did not pass lint check. 1/1 files require formatting」;HEAD 版本是「0/1 files require formatting」。与症状 1(:139 andOperator)因果对应。
- `sh scripts/doc-audit.sh` → exit 0(「✅ 文档对账通过」)。
- `sh scripts/check-arch.sh` → exit 0(「✅ 架构围栏:全部通过」)。
- `sh scripts/plan-audit.sh` → exit 0(「本分支未动 plan 文档 — 跳过」)。核对过脚本 :8-9、:34:pathspec 显式 `:(exclude)docs/superpowers/plans/archive/`,并用 `--no-renames --diff-filter=AM`。所以挪进 archive 被跳过是设计口径,不是假绿。归档文件里唯一的 `- [ ]` 在 :3,是说明文字里的示例,不是任务裸框。
- `sh scripts/affected-tests.sh` → exit 0。选择器是索引闭包(16 个文件),命中 ConsoleOrderTests、OpenClawApprovalValidationTests、SettingsSearchTests,build/test.log 里全部 passed。全量 725 passed 是作者在 commit c0eae20 里的自述,评审**没有**独立复跑全量。

### 语义等价(OpenClawService.swift:139)

`if a &amp;&amp; !b` 改为 `if a, !b`。Swift 的 condition-list 按从左到右的顺序求值,前一项为 false 就短路,不再求后面的项;`&amp;&amp;` 的右侧是 autoclosure,同样短路。两个操作数都是 `Unicode.Scalar.Properties` 的纯 Bool 只读属性,没有副作用,也没有 optional binding 参与,所以两种写法的求值次数、顺序和结果完全一致。改动是纯格式。

### 旧路径清场

`rg -n --hidden -g '!.worktree' -g '!.git' 'plans/2026-11-12-herdr-mod'` 只命中 .reviews/herdr-card-swap.md:17、.reviews/herdr-card-project.md:75、.reviews/herdr-mod.md:10,全是历史评审记录(永久证据链,不应改写)。代码、脚本、AGENTS.md、docs 里没有任何活引用。

### 注记内容核对

注记写的是「app 改为项目 · worktree;title/body 对调为状态行 / space·tab;以 spec 与 AGENTS.md 为准」。对照 spec docs/superpowers/specs/2026-11-12-herdr-mod-design.md:111(2026-11-15 `app` = placeLabel,项目 · worktree,无则分支)、:114-116(title 是状态行,body 是 space / tab),以及 integrations/herdr-mod/edges.js:105-106(title = parts.join(" · "),body = `${space_name} / ${tab_name}`),三处一致。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A。没有新增或改动的测试(纯格式和文档搬运,按规矩不产新测试)。
- [x] **证据纪律**:c0eae20 的提交信息带了 lint 改前 exit 1、改后 exit 0,以及 test.sh exit 0(725/0),到了第 4 级;评审已独立复现 lint 的红到绿。
- [x] **Swift 6 并发**:N/A。只改了一个条件的书写形式,没有隔离或 Sendable 变化。
- [x] **最小改动**:Swift 只动了 :139 一行,就是 SwiftFormat 报的那一处;plan 是 rename(similarity 98%)加一行注记,没有顺手改别的。
- [x] **错误路径**:N/A。没有改动错误处理。
- [x] **坑总目录对照**:对照了「生成技能文本 / plan 归档」惯例(ship 后 plan 挪 archive/)和「推翻旧口径 ⇒ 全仓 grep」,都已满足;OpenClaw 区域在坑总目录里没有相关条目。
- [x] **教训候选**:见下。
- [x] **文档同步**:行为没变,不需要改 AGENTS.md 或 README。

## 教训候选

- 无。(一个附带观察,不算新坑:develop 上能积攒出一处全仓 lint 存量失败,说明有提交没经过 lint.sh 的全仓路径,比如只 lint 了 staged 文件,或者用了 `--no-verify`。这是一次性现象,来源没有查证,不归因。)
