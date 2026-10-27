# Code Review — feature/arch-fences

Reviewer: 独立评审会话(ZCode,未参与本分支任何开发;judge ≠ author)
Date: 2026-10-27
Reviewed-Head: 10a37c3
Verdict: CHANGES_NEEDED
Scope:  6 files changed, 475 insertions(+), 30 deletions(-)

```
scripts/check-arch.sh(新增 270 行)
.githooks/feat-done.sh(+75/−30 内含位移)
AGENTS.md(四处增量)
.github/workflows/doc-audit.yml(+4)
docs/superpowers/plans/2026-10-27-arch-fences.md(+144)
docs/guardrail-backlog.md(+4)
```

(模板原 Scope 写的 2 files/413 insertions 是 ee60bf3 时点的陈旧快照,已按
`git diff develop...HEAD --stat` 实况更正。)

## Findings

- **[P1] B 档 opacity-hide 规则在门禁模式下死了——而且死成假绿**。
  `scripts/check-arch.sh:66` 的 `awk -v pat="$pat"`:POSIX 规定 `-v` 赋值对值做
  反斜杠转义处理,`PAT_OPACITY_HIDE`(:104)里的 `\.opacity\(` 被剥成
  `.opacity(`,awk 动态正则编译报语法错误、整个 awk 以退出码 2 中止、零输出;
  `run_b_tier`(:176)的命令替换把退出码吞掉,`report_block` 拿到空串 → 判通过 →
  脚本打印「✅ 架构围栏:全部通过」并 exit 0。**证据(全部真跑)**:
  1. 提交了一个含 `.opacity(probe ? 0 : 1)` 的真 commit(临时,已 reset)跑
     `sh scripts/check-arch.sh` → stderr 出现
     `awk: syntax error in regular expression .opacity(.*[?]...` ,
     stdout 照样「✅ …全部通过」,EXIT=0。**B 档 opacity 违规原样放行**。
  2. 最小隔离复现:同一 PAT 经 `awk -v` 喂 → awk exit 2、无输出;同一 PAT 经
     `ENVIRON`(不经 `-v` 转义)喂 → `? 0 : 1` HIT、`? 0.68 : 1` miss,行为全对。
     根因坐实是 `-v` 的转义处理,不是模式本身。
  3. 旁证:`--all` 模式同一条规则走 grep 执行器,8 处存量命中列举全对——同一条
     规则两个执行器,grep 活着、awk 死了,门禁恰恰用的是 awk 这条。
  这正中本仓最忌的失败形态(「缺工具拦而非跳过(无假绿)」/ mutate.sh 的
  「0 个测试跑=接线错误」),而且坏的是 feature 的主打交付物之一(CPU 22% 那条
  坑的机器围栏),坏的场合恰是 feat-done 实际运行的环境(macOS 本地;CI 的 B 档
  因 merge-base 缺失走跳过,反而永远踩不到)。
- **[P2] selftest 对「模式×执行器」组合的覆盖缺口——出生仪式没测到死掉的那条路**。
  `scripts/check-arch.sh:228-240`:B 档合成 diff 只用 `'repeatForever'`(无反斜杠)
  过 `added_line_hits`;`PAT_OPACITY_HIDE` 在 selftest 里只走 `grep -nE` 路径
  (:206-216)。于是 `--selftest` 全绿的同时 awk 路径是坏的。plan Task 6 的
  「出生仪式」也只记录了 repeatForever 的红(`b:repeatForever + file:line`),
  opacity 的 B 档路径从未被点亮过。这违背脚本头注释自己立的规矩 #3(:30-31
  「出生必须 --selftest 全绿 + 门禁模式对合成违规见红一次」)——红过,但只红在
  幸存的那条规则上。修法(与 F1 一并):selftest 的合成 diff 里加 opacity 的
  hit/miss 行,直接用真 `PAT_OPACITY_HIDE` 过 awk。
- **[P2] 执行器崩溃与「无命中」同形——F1 由它从报错降级成假绿**。
  `scripts/check-arch.sh:176-177`:`$(b_tier_diff | added_line_hits …)` 的退出码
  被命令替换丢弃,awk abort 产生的「空」与「没有违规」不可区分,随后还打印 ✅。
  POSIX 一行修:`if ! hits=$(b_tier_diff | added_line_hits "$PAT"); then …响亮失败
  (violations++/exit 1)`——管道退出码就是 awk 的,`if !` 即可捕获。这条不加,
  下一个执行器 bug 还会静默变绿。
- **[P2] 门禁链挪位后兄弟文档的旧口径没清场**。`docs/git-worktree-workflow.md:55-59`
  仍写「doc-audit → plan … → review … → unit tests → merge-tree conflict
  precheck → auto-stash → merge」:merge-tree 已挪链首、check-arch 整个缺失。
  AGENTS.md 步骤 5 明说 feat-done 细节「见 docs/git-worktree-workflow.md」,读者
  会被指到一份与事实相反的时序。违反本仓「推翻旧口径 ⇒ 全仓 grep 旧口径残留
  (AGENTS.md、docs/、代码注释)」——本分支自己改了口径却没跑这步(本评审替跑
  时抓到,`rtk grep -rn 'merge-tree' docs/` 现形)。修法:更新那 5 行注释即可。
- [P3] `.githooks/feat-done.sh:51-53` 注释「本流程两个 ref 都已在上文验证存在」
  只对了一半:`show-ref`(:36)验证的是 feature 分支,本地 `develop` 从未被验证
  (实测 `git merge-tree … develop feature/no-such-branch` → 退出码 1)。本地没有
  develop 的极端场景会把「ref 缺失」误报成「合并冲突」。属搬移带过来的既有措辞
  非本次引入,不拦合并,顺手修即可。
- [P3] `scripts/check-arch.sh:18` 头注释「通用过滤:注释行…跳过」对
  keychain-returndata 规则(:132-144)不成立:它是文件级允许清单,`grep -rl`
  不做行级注释过滤,新文件里**注释**提到 `kSecReturnData` 也会拦,且该规则没有
  行内 `fence: allow` 豁免通道(豁免=改脚本允许清单,倒也说得通,但与头部「通用
  过滤」的表述不一致)。当前校准为真(全仓 5 处命中恰好全在两个允许清单文件内,
  真跑核实),不拦合并,措辞对齐即可。

**做对了的(为公平记录,均真跑验证)**:A 档红绿成立(注入
`SBApplication(bundleIdentifier:)` → exit 1,file:line 与 why 指针全对;
纯注释提及 → exit 0);B 档 repeatForever 红绿成立(真 commit 注入 → exit 1,
`NemoNotch/Helpers/MarqueeText.swift:80` 定位准确);B 档 awk 的多文件/多 hunk
file:line 跟踪正确(合成 diff:删除行不推 ln、@@ 头重置、二文件四命中全对);
merge-tree 搬移经逐字节比对确证**纯位移 + 3 行新注释、零代码改动**,退出码三分
(0 干净 / 1 冲突兼坏 ref / 129 用法错)实测与注释一致;R1 分诊修正在 4 个代表
形态上互斥完备,且复现了旧逻辑确实把占位模板错分到「Verdict 不是 APPROVED」;
AGENTS.md 四处增量与脚本行为逐条对上(链序、`NEMONOTCH_SKIP_ARCH=1`、两档语义、
加规则三规矩、--all/--selftest、feat-done+CI 各一次);CI 接线在 ubuntu 上成立
(纯 grep+awk,无 rg;B 档在 checkout 无 develop ref 时响亮跳过、A 档不受影响,
与 workflow 注释一致);selftest 的「不命中」样本逐一溯源自本仓真实代码
(PomodoroTab+TodoList.swift:125 的 `0.68`、OverviewTab.swift:171 的 `0.5`、
EdgeBarCard.swift:468 的 `0.16`、三处 shadow 的 `x: 0`)——鉴别力是实的,
坏的是覆盖面不是样本质量。坑总目录对照:diff 无 Swift 行为改动,未见违背既有断言。

## 必须修(CHANGES_NEEDED 清单)

1. F1:`added_line_hits` 改用 `ENVIRON`(或等价)传模式,消灭 `-v` 转义剥蚀;
   修后用真 commit 注入 `.opacity(probe ? 0 : 1)` 复验 exit 1。
2. F2:selftest 合成 diff 增加 opacity hit/miss 样本,用真 `PAT_OPACITY_HIDE`
   过 `added_line_hits`——这是 F1 的回归守卫。
3. F3:`run_b_tier` 对执行器退出码做 `if ! hits=$(…)` 响亮守卫,崩溃不得
   同形于「无命中」。
4. F4:更新 `docs/git-worktree-workflow.md:55-59` 的门禁链时序注释。

P3 两条不拦合并,建议顺手。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:grep 侧样本有鉴别力(miss 样本溯源真实代码,见上);但 B 档
  awk 侧只测了一个无反斜杠模式,组合覆盖缺口 = F2,未过。
- [x] **证据纪律**:plan Task 6 的红绿声明对 repeatForever 可复现(第 4 级);
  但「B 档红绿已录」隐含覆盖 opacity 路径,实际没测到——声明为真、覆盖面不足
  (F1/F2)。本评审全部断言带命令与退出码,梯级 4。
- [x] **Swift 6 并发**:N/A —— 本分支零 Swift 改动(diff 实核,plan 原拟的
  NotchView 豁免随降档取消,plan 已如实记录转折)。
- [x] **最小改动**:merge-tree 段纯位移(逐字节比对);check-arch 门禁块结构与
  既有三道门禁同款(逃生阀/在 worktree 跑/失败话术三件套齐);无顺手改动。
- [x] **错误路径**:F1/F3 正是此条违背——执行器崩溃被吞成 ✅。其余路径
  (merge-tree 降级、B 档 merge-base 缺失跳过)响亮且与注释一致。
- [x] **坑总目录对照**:过;围栏规则与坑总目录条目(媒体/工具与探针/架构不变量/
  Keychain/SwiftUI 渲染)逐条对得上,why 指针有效。F4 是口径清场漏网。
- [x] **教训候选**:见下节。
- [x] **文档同步**:AGENTS.md 四处 + CI + backlog 到位;git-worktree-workflow.md
  漏(F4)。
- [x] **工作流机制清场**:本评审代跑(merge-tree/check-arch 全仓 grep),抓到
  F4;其余无残留。

## 教训候选

- **模式必须经它实际运行的那个执行器喂出生样本**(check-arch 三规矩 #3 的强化,
  可门禁化):同一条规则两个执行器(grep 列举 / awk 门禁),出生仪式只测了
  grep 侧 + 一个无反斜杠的 awk 样本,复杂模式×awk 组合成盲区——这次 F1 正好
  落在盲区里。selftest 的 B 档合成 diff 应循环**全部** B 档真模式。
- **命令替换/管道吞退出码 = 假绿的通用机制**:`hits=$(… | awk)` 里 awk abort
  → 空串 →「无命中」。与 mutate.sh「0 个测试跑 = exit 2」同判据:执行器非零
  退出必须与「无命中」可区分(`if ! hits=$(…)` 一行)。值得写进手册「工具与探针」。
- **`awk -v` 传正则的可移植性陷阱**:POSIX 规定 `-v` 值做反斜杠转义处理,
  `\.foo\(` 进去变 `.foo(`;ENVIRON 路线不经转义,是正则入 awk 的安全通道。
  建议进 macos-playbook(本仓规则:新增工具坑同一提交记 cookbook/手册)。
- **挪门禁顺序要 grep 兄弟文档**:AGENTS.md 与脚本头注释都改了,
  git-worktree-workflow.md 的时序注释没人 grep——「推翻旧口径 ⇒ 全仓 grep」
  这次没执行到位。候选硬化:doc-audit 加一条成对断言(两文档的门禁链关键词
  互相对账),或至少把该步写进「改 hooks 时的 checklist」。

## 评审方法与验证命令记录(全部在 worktree 真跑,退出码如实)

| 命令 | 结果 |
|---|---|
| `sh scripts/check-arch.sh --selftest` | exit 0(样本全绿——但这掩盖了 F2 缺口) |
| `sh scripts/check-arch.sh` | exit 0 |
| `sh scripts/check-arch.sh --all` | exit 0;A 档绿;opacity 现存 8 处、repeatForever 4 处信息性列举 |
| `sh scripts/doc-audit.sh` | exit 0 |
| `sh scripts/plan-audit.sh` | exit 0 |
| A 档红:注入 `SBApplication(…)` → 还原 | exit 1(file:line/why 指针对)→ 还原后 exit 0 |
| A 档注释免疫:注释行提及 SBApplication/proc_pid_rusage | exit 0(滤除生效) |
| B 档红(opacity):真 commit 注入 `? 0 : 1` | **exit 0 + awk syntax error(stderr)= F1 假绿实锤**;已 reset 回 10a37c3 |
| B 档红(repeatForever):真 commit 注入 | exit 1,`b:repeatForever …MarqueeText.swift:80` 对;已 reset |
| awk 隔离:`-v` vs `ENVIRON` 传同一 PAT | `-v` → exit 2 零输出;`ENVIRON` → hit/miss 全对 |
| B 档多文件/多 hunk 合成 diff | file:line 全对(A:5,6;B:101,200;删除行不推 ln) |
| `git merge-tree --write-tree` 三探针 | clean=0 / 坏 ref=1 / 坏旗标=129(git 2.54.0,与注释一致) |
| R1 分诊四形态独立测 | 4 支互斥完备;旧逻辑复现占位错分 |
| merge-tree 块纯位移比对(`diff` 旧/新块) | 仅 3 行新注释,代码零改动 |
| `rtk grep -rn 'merge-tree'/'check-arch' docs/ AGENTS.md …` | 抓到 F4;其余口径一致 |
| kSecReturnData 全仓核 | 5 处命中全在两个允许清单文件内(校准声明为真) |

## 评审方法提示(给评审会话)

在 worktree 里:`git diff e83ffb7bbda01467d3d0fe9748e7df80c29fb840...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
