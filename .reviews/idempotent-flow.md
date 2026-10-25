# Code Review — feature/idempotent-flow

Reviewer: 独立评审子代理 (zcode session, 2026-10-24)
Date: 2026-10-25
Reviewed-Head: d8b3ddf
Verdict: APPROVED
Scope:  4 files changed, 51 insertions(+), 7 deletions(-)

```
.githooks/feat-done.sh
.githooks/feat.sh
AGENTS.md
docs/guardrail-backlog.md
```

## Findings

全部为 P3(边缘硬化 / 文档补全 / 措辞精度),无 P1/P2;核心机制正确且已由本评审在
主检出实测复现(见「验证记录」)。逐条:

- **[P3] feat-done.sh:93-97 + review.sh:41-44 — 自动生成模板会覆掉「已填但非 APPROVED」的评审记录**。
  review.sh 的不覆盖保护只认 `^Verdict: APPROVED`;实测:把工作区记录填成
  `Reviewer: TEST-… + Verdict: CHANGES_NEEDED` 后跑 `sh scripts/review.sh`,整份被
  重写成空模板(TEST 行消失)。现实流程:评审员提交 CHANGES_NEEDED → 作者修完重跑
  feat-done → 门禁失败 → 自动生成把已提交记录的工作区副本抹成空模板,旧 Findings
  只剩 `git show HEAD:.reviews/…` 可捞。硬化建议:review.sh 的保护扩到「Reviewer 行
  已填即不覆盖」,或 feat-done 只在文件不存在时才代跑 review.sh。
- **[P3] feat.sh:31-37 — `existing_wt` 的 awk 不滤 `prunable` 条目,静默指向死路径**。
  实测:`rm -rf .worktree/zz-reviewprobe`(带外删除)后 `git worktree list --porcelain`
  仍列出该条目(标 `prunable`),feat.sh 打印「✅ 已在进行中 — worktree 在,直接进:
  cd <不存在的目录>」且 exit 0——静默假成功。硬化:`[ -d "$existing_wt" ]` 或滤
  prunable 行,命中则先 `git worktree prune` 再挂回。
- **[P3] feat-done.sh:170-171 — 退出码分类注释与实测不符(git 2.54)**。
  实测 `merge-tree --write-tree develop <不存在的分支>` 退出码是 **1**
  (stderr:「merge-tree: … - not something we can merge」),不是 ≥2;≥2 桶只有
  usage 错(坏 flag → 129)。feat-done 流程内两参数都被前置校验(分支 :35 show-ref;
  develop 在有 worktree 时被 :83 merge-base 经 set -e fail-closed),误诊「有冲突」
  实际不可达,但注释的「1=冲突;≥2=工具不可用」应改为「1=冲突或无法合并;≥2=用法错」,
  或探针前显式双验参。
- **[P3] feat-done.sh:102-104 — else 分支无条件宣称「✅ 模板已生成」**。
  生成被跳过(:95 古老分支无 review.sh)或静默失败(:96 `|| true` 吞错)时,消息指向
  可能不存在的文件。门禁本身仍响亮失败(无假绿),但措辞可像隔壁分支一样用
  `[ -f "$wt/.reviews/$name.md" ]` 把关。
- **[P3·文档] docs/git-worktree-workflow.md:41-54 — 行为变了,细节文档没跟**。
  `git feat` 仍描述为纯创建(无 get-or-create/孤儿挂回),feat-done 序列无 merge-tree
  预检。feat-done 那行在本分支之前就缺 doc-audit/plan-audit/评审门禁(既有漂移),
  但本分支改了 feat 的可观察行为、AGENTS.md:47 又点名「细节 docs/git-worktree-workflow.md」,
  该文档应同提交补两句。
- **[P3·文档·触及行上的既有缺口] AGENTS.md:38 步骤 3 门禁序列仍缺「评审门禁」**(在
  plan-audit 与单测之间;先于本分支存在,但本分支恰好编辑了这一行插 merge-tree,是补
  上它的时机)。另 AGENTS.md:41 评审段落仍只写手动 `sh scripts/review.sh` 生成,自动
  代办只写在原则行(AGENTS.md:217)——不算错(手动仍可用),属不完整。

### 验证记录(本评审在主检出实测,梯级 4)

开发会话自报的实测逐项复核,全部复现:

- **merge-tree 退出码**:合成冲突(两个改同一文件的 commit-tree 提交挂 zz-probe-a/b)
  → `merge-tree --write-tree` rc=**1**;干净对(develop vs 纯领先分支 = fast-forward
  形态)→ rc=**0**;本分支真实对 → rc=0;坏 ref → rc=**1**(见 P3 发现三);坏 flag → 129。
  临时分支已删。
- **feat.sh 指路**:`git show feature/idempotent-flow:.githooks/feat.sh | sh -s -- idempotent-flow`
  → 「✅ 已在进行中」+ 正确 worktree 路径,exit 0。
- **孤儿挂回**:临时分支 feature/zz-reviewprobe(无 worktree)→ 「♻️ 挂回」+ worktree
  add 成功,exit 0;随后 rm -rf 复现 P3 死路径;`git worktree prune` + `branch -D` 清场。
- **feat-done 评审门禁三条消息路径**(主检出跑 worktree 版 feat-done):无记录 → 模板自动
  生成 + 新形态失败信息,rc=1;工作区已填 APPROVED 未提交 → 「已填好但未提交」专用信息;
  均在 stash 舞步**之前**退出,主检出零副作用(无 checkout/stash)。doc-audit、plan-audit
  在本分支均过。
- **POSIX sh 复核**:`|| probe_rc=$?` 是 set -e 下的标准豁免写法,probe_rc 恒为数字,
  `-ge 2` 安全;feat.sh get-or-create 分支提前 exit 正确跳过「拉最新」(分支已存在,
  基线已定,拉最新只服务新建路径),无遗漏副作用;awk 对 porcelain 的 worktree/branch
  行序配对正确;`sh review.sh >/dev/null 2>&1 || true` 的吞输出在该上下文可接受——
  review.sh 在此语境(分支、worktree 均已验在)现实上只会因环境灾难失败,且门禁本身
  仍响亮失败(见 P3 措辞项)。

### 工作流机制清场证据

- `rg -n "已存在" AGENTS.md docs/ .githooks/ scripts/ .zcode/`:无「feat 分支已存在会
  报错」类旧口径残留(仅签名脚本注释与 feat.sh 新自述)。
- `rg -n "feat-done|feat\.sh|git feat" docs/git-worktree-workflow.md` + `.zcode/skills/`
  (using-git-worktrees / finishing-a-development-branch):无旧报错语义描述;缺口为上述
  P3 文档项(不完整而非矛盾)。

## 补审(d8b3ddf)

对 091de61 六条 P3 的修复核对 + 抽查复核,逐条裁定:

- **#1 已修(留一个新 P3 残余,见 R1)**。review.sh:40-44 守卫扩为 `^Verdict:` 任意已填值
  ——实测:工作区记录临时改成 `Verdict: CHANGES_NEEDED` 后跑 review.sh,得「不覆盖」
  exit 0,Reviewer/Findings 原样(已 `git checkout --` 恢复)。feat-done 侧三态分诊
  (APPROVED 未提交 / Verdict 非 APPROVED / 文件缺=生成失败)代码核对无误。
- **#2 已修,实测复现修复生效**。feat.sh:34-42 加 `[ -d "$existing_wt" ]` 守卫 + 定向
  `worktree prune`(仅在确有僵尸注册时)。复测:临时分支建 worktree → rm -rf 目录 →
  跑新 feat.sh,不再指死路径,prune 后挂回成功 exit 0(首轮同场景是静默假成功);
  健康复用路径回归通过。prune 时机正确:不加 prune 时 `worktree add` 会撞
  「already checked out」,挂回成功本身即 prune 生效的证明。探针分支已清。
- **#3 已修**。注释改为实测口径:「1=冲突(**坏 ref 也是 1**;两 ref 已上文验证,
  实践中 1 即冲突);≥2(如 129)=用法/工具错」——与本评审实测完全一致。
- **#4 已修**。三态分诊后「模板已生成」只在文件存在时出现,文件缺失给独立的
  「生成失败」消息;门禁各路径仍全部 exit 1,无假绿。
- **#5 已修**。git-worktree-workflow.md 的 feat 描述补 get-or-create(含 prune)、
  feat-done 补全部门禁次序(与脚本实序逐项一致)+ merge-tree 预检 + 自动生成模板。
- **#6 已修**。AGENTS.md 步骤 3 在 plan 门禁与单测之间补上评审门禁(含「缺记录时
  自动生成模板」),与脚本实序一致;步骤行不再缺项。

**R1 [P3·新残余,d8b3ddf 引入]** — `^Verdict:` 把**空模板的占位行**也当「已填」。
review.sh 生成的模板自带 `Verdict: (填 APPROVED 或 …)` 行,实测匹配 `grep '^Verdict:'`;
后果:(a) feat-done 三态分诊里空模板落入「Verdict 不是 APPROVED(如 CHANGES_NEEDED)—
按 Findings 修复」支,而「✅ 模板已生成…派未参与开发的会话/子代理评审」这支对
review.sh 生成的模板**实际不可达**——主路径(未评审先跑 feat-done)的引导语从「派评
审」降级成「按 Findings 修复」(动作仍对:评审员填 APPROVED→提交→重跑,全路径仍
exit 1);(b) review.sh 拒绝刷新空模板且提示「要重评先清 Verdict 行」对空模板失义。
修法建议:已填判别子改用 `Reviewer: (填` 占位前缀(实测可区分),或 `^Verdict:`
排除 `Verdict: (` 开头。消息精度问题,无数据丢失、无假绿——不阻合并,留给收尾
reflect/硬化排期。

**补审方法附记**:复核中踩到 `feat-done … | tail; echo $?` 吃掉退出码(报 rc=0,
去管道后真实 rc=1)——正是 feat-done.sh:146-147 注释警告的管道陷阱,顺带验证了
该注释的先见。

## 教训候选

- **review.sh:41** — 自动重生模板的脚本,不覆盖保护必须盖住**所有已填内容**而非仅终态
  (APPROVED);判据:重生成前先问「这份文件里可能已有人的劳动成果吗」。
- **feat.sh:31** — `git worktree list --porcelain` 是注册表视图不是文件系统视图(含
  prunable 死条目);判据:消费 worktree 路径的代码必须 `-d` 验存在或滤 prunable。
- **feat-done.sh:170** — 注释里「退出码 X=含义」的每个取值要按失败模式逐一实测,不能
  只照文档概括:merge-tree 的 1 同时覆盖「冲突」与「无法合并」(bad ref 实测=1)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A — 本 feature 无新增测试(hook/脚本改动,仓内无 shell 测试目标;
  按手册「纯脚本/文档不产凑数测试」,验证以主检出实跑替代,见验证记录)。
- [x] **证据纪律**:自报实测由本评审独立复现到梯级 4(退出码逐个捕获);一处自报口径
  被实测修正(退出码分类,见 P3)。
- [x] **Swift 6 并发**:N/A — 无 Swift 改动。
- [x] **最小改动**:每个 hunk 可追溯到四项任务;无顺手改动;AGENTS.md 改动限于步骤 1/3
  与一条原则行;guardrail-backlog 一条。
- [x] **错误路径**:冲突 → exit 1 响亮;≥2 → 响亮警告后按注释论证的取舍 fail-open;
  review.sh 静默失败被吞但门禁仍失败响亮(P3 措辞项);无假绿路径。
- [x] **坑总目录对照**:触及区 = Git 流程节;沿用既有纪律(freshness 自检未动、stash
  舞步未动、set -e 兜底模式与既有门禁一致)。
- [x] **教训候选**:已填(见上小节)。
- [x] **文档同步**:AGENTS.md 已更(步骤 1/3 与原则行);缺口 = git-worktree-workflow.md
  未跟、步骤 3 仍缺评审门禁(P3 文档项)。
- [x] **工作流机制清场**:已 grep(证据见上);无旧口径矛盾,余两处不完整(P3)。
## 评审方法提示(给评审会话)

在 worktree 里:`git diff 146c94d6b2bbd5bc8172e4a3dc0a1b1c0d20e5c4...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
