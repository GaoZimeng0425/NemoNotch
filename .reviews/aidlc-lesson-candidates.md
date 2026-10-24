# Code Review — feature/aidlc-lesson-candidates

Reviewer: 独立评审子代理 (zcode session, 2026-10-24)
Date: 2026-10-24
Reviewed-Head: a150932
Verdict: APPROVED
Scope:  2 files changed, 3 insertions(+), 2 deletions(-)

```
AGENTS.md
scripts/review.sh
```

## Findings

- scripts/review.sh:72-74 | Findings 小节的模板说明行(「逐条:位置 file:line、问题一句话、严重度…」)没有声明尾部「教训候选」小节——该小节的唯一定义在新清单项(review.sh:84)自身。清单项自带完整指引(位置+写法),机制仍闭环;但只读 Findings 头部说明的填写者不会知道有此小节,小节存在性完全依赖清单项被执行。 | P3(非阻塞,可后续把 Findings 说明行补一句小节声明)
- AGENTS.md:41 | Judge≠author 段的清单枚举现为 7 项(判别剃刀/证据纪律/Swift 6 并发/最小改动/错误路径/坑总目录对照/教训候选),模板实为 8 项基础清单(另有条件项「工作流机制清场」)——枚举缺「文档同步」。**该缺漏系既有状态**(改动前枚举同样缺文档同步而旧模板已有该项),本提交只追加教训候选、未顺手补齐,符合最小改动纪律;非本提交引入。 | P3(既有)
- 机制影响核对(通过):.githooks/feat-done.sh 评审门禁只按行首解析 `Verdict: APPROVED` / `Reviewer:` / `Reviewed-Head:`(feat-done.sh:96-116 一带),不解析清单形状——清单加项对门禁零影响,无假绿/假红路径。 | 记录性

### 工作流机制清场(grep 证据)

本分支触及 scripts/ → 触发清场项。全仓 grep(排除 .reviews/):

- `grep -rn "教训候选" --include=*.md,*.sh,*.swift .`(除 .reviews):仅 3 处,全部为本分支预期落点——AGENTS.md:41(Judge≠author 枚举)、AGENTS.md:225(reflect 读法)、scripts/review.sh:84(清单项)。无别处残留/矛盾口径。
- 清单构成的描述全仓只有 AGENTS.md:41 一处枚举;.githooks/feat-done.sh:77、:95 提到 review.sh 但不枚举条目,无矛盾。
- `grep -rn "Findings" docs/ .githooks/ AGENTS.md README*.md scripts/`(除 .reviews):Findings 结构描述仅 review.sh 自身与 AGENTS.md:225,读法(「Findings 尾部的「教训候选」小节」)与记法(review.sh:84「Findings 尾部「教训候选」小节」)同名对得上。
- docs/guardrail-backlog.md:3-5 自述为 reflect 例行落点——新 reflect 措辞(先读教训候选 → 再分流 guardrail-backlog/坑总目录)与该文件定位一致,不矛盾;backlog 引用的分流去向文件 `docs/guardrail-backlog.md` 存在。
- 结论:未发现与新实现矛盾的旧口径。

### 教训候选

- scripts/review.sh:78-85 ↔ AGENTS.md:41 | AGENTS.md 的清单枚举是 review.sh 清单的手工副本,每次清单加项都要两处同改——本次已对上,但该枚举历史上已漂过一次(文档同步至今缺席枚举)。判据:**手工同步的成对事实不做机器对账,迟早再漂**;候选硬化方向——doc-audit 加一条「review.sh 清单项名 ↔ AGENTS.md 枚举」成对断言,或干脆把 AGENTS.md 枚举删成不点名条目。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A——本改动无测试、无 Swift(纯 shell 模板行 + 手册两行)。
- [x] **证据纪律**:提交信息无越级验证声明;本记录的验证自报梯级——`sh -n scripts/review.sh` 退出码 0(梯级 4);.reviews/aidlc-lesson-candidates.md 系改动后跑 review.sh 生成的真实工件,含新清单项原文,证明 heredoc 展开正确(梯级 4);grep 结论为可重放命令+输出。
- [x] **Swift 6 并发**:N/A——无 Swift 改动。
- [x] **最小改动**:通过——全分支 2 文件 3 插入 2 删除(AGENTS.md 两行改、review.sh 一行加),逐行可追溯到任务;未顺手修邻近的「文档同步枚举缺漏」(见 Findings P3 既有项)。
- [x] **错误路径**:通过——review.sh 逻辑零改动,新行仅是 heredoc 模板文本(无 `$`、无反引号、无注入面);`sh -n` 过;门禁解析不受清单形状影响(见 Findings 第 3 条)。
- [x] **坑总目录对照**:通过——改动区为评审门禁/手册自身,AGENTS.md「Git 流程与门禁」节即坑总目录本体,已逐段对照(Judge≠author 段、reflect 段均在本次 diff 内且自洽)。
- [x] **教训候选**:有——见上方「教训候选」小节(1 条:清单枚举手工副本无机器对账)。
- [x] **文档同步**:通过——AGENTS.md 两处即文档同步本体(枚举 + reflect 读法);行为变化仅为评审模板加一项,无 README 面。
- [x] **工作流机制清场**:通过——grep 证据见上方专节,未发现矛盾旧口径。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 56f2d6332cd45e124216c65cbd119cc372550c40...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
