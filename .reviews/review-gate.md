# Code Review — feature/review-gate

Reviewer: independent-review-subagent(zcode, fresh context)
Date: 2026-10-20
Verdict: APPROVED
Scope: 3 files changed, 132 insertions(+), 1 deletion(-)

```
.githooks/feat-done.sh
AGENTS.md
scripts/review.sh
```

## Findings

首轮(2026-10-20,同评审者)1×P1 + 2×P2 已在 6a65fa2 修复并经本轮实测复验,见文末「修复复验记录」。以下为残留项,全部 P3、不阻塞合并:

- **[P3] .githooks/feat-done.sh:70 — 触发集仍漏根目录脚本与代码邻接文件。** `build.sh`(post-merge 自动部署脚本)不匹配 `scripts/*`;`Package.swift`/`Package.resolved`/`*.xcconfig`/`.swiftlint.yml` 同漏。与自述"触及代码/scripts/hooks/CI"规则不符,后续 feature 可补。
- **[P3] scripts/review.sh:14-20 — `set -u` 无 `set -e`:usage 死码 + 潜在假绿。** 零参调用死在 `name="$1"` 的 unbound-variable(自带的 usage 仅显式空串参数可达);中段 `git diff`/`cat > "$note"` 失败仍会打印"模板已生成"。同目录 feat-done.sh 用 `set -e`,该看齐。
- **[P3] docs/git-worktree-workflow.md:52-63,91-94(+ AGENTS.md 门禁一节第 3 条)— 文档漂移未同步。** :61-63 仍说"从 worktree 内跑 feat-done 会合并完再打印清理命令",与 d1ccb1b 的合并前拒绝直接矛盾;:91-94 评审段仍是无机制旧约定;feat-done 流程列表无评审门禁。AGENTS.md 主段落已同步,此文件可作后续 feature 清偿。
- **[P3·已知取舍] scripts/review.sh:41 — 防覆盖守卫只保护 APPROVED,未提交的 CHANGES_NEEDED 记录会被模板再生成覆盖**(本轮 regen 即覆盖了首轮记录)。已提交的历史才是证据链、无摩擦重评是设计意图,可接受;若要更稳可改为"任何非占位 Verdict 都不覆盖"。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [N/A] **判别剃刀**:无测试改动,仓库亦无 shell 测试面。但门禁判定本身本轮做了鉴别性实测(未提交记录被拒/裸模板被拒/裸 APPROVED 通过),见复验记录。
- [x] **证据纪律**:6a65fa2 的三项修复声明经本评审独立复现(第 4 级:真跑退出码,见下);d1ccb1b 首轮已核(红测描述具体)。
- [N/A] **Swift 6 并发**:无 Swift 改动。
- [x] **最小改动**:修复提交只动两个文件的最小 hunks(18+8 行),无顺手改动。
- [x] **错误路径**:门禁三条失败路径(记录未提交、记录不存在、提交了未填模板)全部实测 fail-closed;无 worktree 分支改为响亮警告(与测试门禁同款形态);review.sh 的 set -e 缺口降为 P3 残留。
- [x] **坑总目录对照**:「管道吃退出码」的坑在此被有意识且方向安全地使用——`git show` 失败输出为空 → grep 无匹配 → 拒绝分支,注释写明了推理;触发 diff 仍保持裸命令。grep 处于 `if !` 条件上下文,set -e 豁免,无意外退出。
- [x] **文档同步**:AGENTS.md(评审门禁段落)已同步;workflow 文档漂移记为 P3 残留(见上)。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 2b8da3bdc53b72cc45c22b537144a28bb3540747...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

### 修复复验记录(6a65fa2,本评审实测,非采信提交信息)

- **P1 修复核验**:模板头改为行首裸格式(`Reviewer:`/`Date:`/`Verdict:`/`Scope:`),门禁、review.sh 防覆盖、门禁回显三处 grep 与模板格式一致;实测未填模板行 `Verdict: (填 …)` **不匹配** `^Verdict: APPROVED`(提交空模板 = fail-closed),裸 `Verdict: APPROVED` 匹配。
- **P2(无 worktree)修复核验**:`elif [ -n "$wt" ]` 补了 else 警告分支,嵌套正确(else 绑外层 if),与测试门禁同款"响亮跳过"形态。
- **P2(已提交记录)修复核验**:在 `set -e` 下原样复跑门禁判定行——当前 worktree `.reviews/` 未提交,`git show HEAD:…` 失败经管道落入 **REJECT** 分支(退出码语义正确:管道取 grep 状态,空输入 = 无匹配 = 拒绝);回显提取行以 sed 收尾,空输入不触发 set -e。
- `sh -n` 两脚本通过;`git status` 仅 `.reviews/` 未跟踪,无其它文件被改动。

APPROVED 依据:P1/P2 全部修复且实测复验通过,门禁各失败路径 fail-closed;残留项均为 P3(触发集缺口、review.sh 严格性、workflow 文档漂移、防覆盖范围),不损害门禁正确性,可作为后续 feature 清偿。
