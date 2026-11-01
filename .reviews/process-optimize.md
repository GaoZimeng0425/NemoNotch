# Code Review — feature/process-optimize

Reviewer: 独立评审子代理(GLM-5.3 会话,未参与本分支开发;judge ≠ author)
Date: 2026-11-01(第 2 轮增量复审同日)
Reviewed-Head: 83d65ab
Verdict: APPROVED
Scope:  3 files changed, 63 insertions(+), 13 deletions(-)

```
.githooks/feat-done.sh
.zcode/workflows/implement-with-review.dwf.ts
scripts/test.sh
```

## 第 1 轮(基线 1a99a13;头部原判 CHANGES_NEEDED / Reviewed-Head: 1a99a13)

### Findings

- **[P1] scripts/test.sh:115 + .githooks/feat-done.sh:200-203 — `--only` 子集跑成功也写 test-head.txt,feat-done 全量兜底被默认路径绕过。**
  test.sh 尾部无条件写锚点,不区分全量与 `--only` 子集;而 affected-tests.sh:89 以 `exec sh scripts/test.sh --only <classes>` 收尾,IMPLEMENTER_PERSONA(dwf.ts:126)与 VERIFY_PERSONA(dwf.ts:133)又都把 affected-tests.sh 列为常规步骤——Swift feature 的默认路径就是「实现者/工兵跑影响面子集 → 写锚点 → feat-done 短路跳过」。feat-done.sh:197 注释断言「重跑是纯重复」,但 feat-done 历来跑的是**全量**,评审/工兵跑的是**子集**,二者不是同样套件,前提不成立。后果:合并前全量单测从未跑过(CI 也不跑单测,release.yml 只出 DMG),合并即部署 /Applications,违反 AGENTS「测试必须先于部署」不变量的字面语义。affected-tests 的符号映射「宁多跑不漏跑」仍有盲区(函数级降级、extension 过滤),全量兜底正是为此存在。
  **修法(一行)**:test.sh 只在无 `--only` 时写锚点——`[ -z "$only" ] && git rev-parse --short HEAD > "$root/build/test-head.txt" 2>/dev/null || true`。全量锚点下短路优化照常成立(评审轮全量 + feat-done 全量才是真重复)。
- **[P2] .zcode/workflows/implement-with-review.dwf.ts:380 — 工兵只跑一次,round≥2 挑战者仍被引导「可直接引用」过期工件,且无作废条款。**
  工兵在 round 1 之前跑一次(349-351);修复回流后 HEAD 已变,工件头 head 必然与当前 HEAD 不符(描述的是修复前状态)。评审员 prompt 有「head 不符则工件作废、按原纪律全亲跑」(363),挑战者 prompt 没有——每轮都说「全套门禁已由中立工兵预跑并落工件(可直接引用,无需重跑门禁)」,round 2/3 的挑战者可能把修复前的绿灯(如 lint/check-arch 过)当成修复后现状,增量攻击镜头恰恰只看修复提交、最需要新鲜的门禁信号。
  **修法**:挑战者 prompt 与评审员对齐,加同一句「工件头 head ≠ 当前 HEAD 则工件作废,不得引用」;或 round>1 时不给工件路径。
- **[P3] dwf.ts:362-363 — 抽查指令自相矛盾:「至少复跑其中 2 项、其中 1 项须为变异验证」。**
  「其中」指工件里工兵跑的五项(lint/affected-tests/doc-audit/check-arch/xcstrings),变异验证(scripts/mutate.sh)不在五项内,字面执行不可能满足;评审员要么困惑要么把变异验证 silently 略过,削弱「评审必须亲跑」的抽查纪律。
  **修法**:改措辞为「至少复跑工件中 2 项,另做至少 1 次变异验证(sh scripts/mutate.sh)」。
- **[P3] dwf.ts:414 — 「MUST KILL …(同受 ≤3 行约束)」与首句「修复以下全部 P1/P2 意见」矛盾。**
  MUST KILL 由挑战者标记,通常承载于 P1/P2;「同受 ≤3 行约束」可被实现者读成「>3 行的结构化修复可推迟」,与「修复全部 P1/P2」冲突。第二轮挑战者「MUST KILL 逐条验收」会兜底,但指令本身应无歧义。
  **修法**:改为「MUST KILL 属 P1/P2 时必须修、不受 ≤3 行约束(与 P3 纪律无关)」。
- **[P3] AGENTS.md:61(本分支未改)— feat-done 测试门禁行为变了(条件短路),AGENTS 测试节口径未同步。**
  「feat-done 合并前在 worktree 跑单测——合并即部署,测试必须先于部署」在短路面下不再无条件成立,须补短路口径与前提(全量锚点才可短路——随 P1 修法一起落)。
  **修法**:同提交在 AGENTS.md 测试节该句后补「(build/test-head.txt 记录的全量测试正对当前 head 时跳过重跑)」。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A——纯脚本/流程改动,无新测试、无被测单元。
- [x] **证据纪律**:见下「评审证据」——shell 用 bash -n + /tmp 最小场景实测(真实退出码);dwf.ts 用 bun transpile + deno check 机械验证(提交信息声明的「语法 deferred」被本次评审补上,exit 0 均为梯级 4)。
- [x] **Swift 6 并发**:N/A——无 Swift 改动。
- [x] **最小改动**:diff 紧贴五项;feat-done.sh 的嵌套重构是实现短路的最小形状;未发现顺手改邻。
- [x] **错误路径**:短路分支外失败路径原样保留(test 失败 exit 1);锚点写失败被吞但 fail-closed(空/缺锚点 = feat-done 真跑,实测场景 3/6/7/8);`current_head` 求值在 set -e 下 rev-parse 失败即整脚本退出,fail-closed。
- [x] **坑总目录对照**:改到 feat-done/test.sh/test 门禁——对照了「报告测试必须引退出码」「合并即部署测试先行」「--only 手挑假绿实案」相关条目;P1 正是「合并即部署测试先行」不变量被弱化处。
- [x] **教训候选**:见下。
- [x] **文档同步**:P3(AGENTS.md:61)。
- [x] **工作流机制清场**:grep 过 AGENTS.md / docs/ / .reviews/ 的 test.sh 旧口径;CI(.github/workflows)无 test-head/全量测试引用,不受影响;dwf.ts 内 REVIEWER_PERSONA「验证必须亲跑」与 task 级「默认读工件+抽查」并存未改 persona(工兵是中立第三方、非自述,逻辑上不违反,但见 P3 措辞项)。

## 评审证据(全部真实退出码,梯级 4)

- `sh -n .githooks/feat-done.sh` → exit 0;`sh -n scripts/test.sh` → exit 0。
- VERIFY_PERSONA 五条命令目标全部存在(ls exit 0);`python3 scripts/xcstrings.py check` → exit 0;.gitignore:9 确有 `build/`(工件不进提交的声称成立)。
- dwf.ts 语法:顶层 return 系 dwf 既有格式(ba8c77f 同款);包进函数体后 `bun build --target=node` → exit 0(纯语法/括号/引号/模板串配平);注入宿主声明(agent/phase/hole/report/log/artifact/args)后 `deno check` → exit 0——无 TDZ 违规、无 const 重复声明;evidencePath(348)声明在两处用点(362/380)之前,作用域正确;P3 统计与模板拼接类型合法。
- E 安全边界实测(/tmp/featdone-probe 最小 git 仓库 + worktree,复刻 feat-done.sh:200-203 短路逻辑与 test.sh:115 锚点写入):无锚点→RUN;全量后锚点=HEAD→SKIP(预期);未提交改动+锚点匹配→SKIP(设计内:未提交不进合并,锚点正对要合并的提交);锚点残留旧值→RUN;amend 后→RUN;真 rebase(develop 前进重放)后→RUN;无 build 目录→RUN;锚点 12 位 vs 默认 7 位长度漂移→RUN;多行/损坏锚点→RUN。**除正例与设计内场景外全部 fail-closed 落真跑**。(场景 4 首测 SKIP 系探针自身笔误 `--noedit`,git rc=129 amend 未发生,修正 `--no-edit` 后复测 RUN。)
- P1 证据链:scripts/affected-tests.sh:89 `exec sh scripts/test.sh --only "$classes"` → test.sh:115 无条件写锚点 → feat-done.sh:201-203 只比对 head 不比对范围;IMPLEMENTER_PERSONA(dwf.ts:126)与 VERIFY_PERSONA(dwf.ts:133)使子集锚点成为默认路径;CI 无单测兜底(.github/workflows 仅 codeql/doc-audit/release)。

## 教训候选

- scripts/test.sh:115 — **「锚点式跳过门禁」必须绑定锚点的范围,不能只绑身份(head)**:head 相同不蕴含验证面相同(--only 子集 ≠ 全量)。可门禁化:test-head.txt 内容带 scope 标记(或仅全量写锚点),feat-done 只认全量锚点——修 P1 时一并落,候选进 guardrail-backlog 的「门禁的门禁」类。
- .zcode/workflows/implement-with-review.dwf.ts:380 — **共享工件要写清「保鲜条件」且对所有消费者一致**:给一席写作废条款、另一席不写,过期工件就会从另一席漏进去。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff ba8c77f2250640504a38dd635051c59df0438882...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

---

**复审备注(2026-11-01 评审员)**:P1 修法一行(test.sh 加 `[ -z "$only" ]` guard)+ AGENTS 口径一句即可解;P2/P3 均为 dwf.ts 措辞级修补。修完更新本记录 Verdict 与 Reviewed-Head 再提交。

---

## 第 2 轮(增量复审,Reviewed-Head: 83d65ab)

复审范围:`git log 1a99a13..HEAD` = 单提交 83d65ab(4 文件,+16/−9),只核修复提交,首轮已过的其余面未动代码(feat-done.sh 仅注释、test.sh 仅尾部守卫、dwf.ts 仅三处 prompt 措辞、AGENTS.md 一句)。

### 逐项核验

- **P1 已修(实测通过)** — scripts/test.sh:118-120 `if [ -z "$only" ]; then git rev-parse … > build/test-head.txt …; fi`,正是首轮给的一行修法;注释写明「锚点的语义 = 该 head 的全量套件绿」;feat-done.sh:197-200 注释同步「仅全量——affected-tests 的 --only 子集不写」。行为实测(/tmp 最小仓库复刻守卫 + feat-done 比对):(A) `--only` 成功后锚点不存在;(B) 全量成功后锚点=head;(C) 同 head 下后续 `--only` 不覆盖既有全量锚点(该 head 的全量确实绿过,保留正确);(D) rebase 后仅子集跑 → feat-done 判 RUN。门禁语义恢复:短路只在「全量绿正对当前 head」时成立。
- **P2 已修** — dwf.ts:381-382 挑战者 prompt 补「(工件头部 head 与当前 HEAD 不符则作废,不得引用)」,与评审员侧条款对齐;「不得引用」对挑战者是正确动作(它本就无需重跑门禁)。
- **P3-1 已修** — dwf.ts:362「至少复跑其中 2 项,并另行做至少一次变异验证」,自相矛盾消除。
- **P3-2 已修** — dwf.ts:415「伴随 P1/P2 的按其严重级全修,纯 P3 的同受 ≤3 行约束」,与「修复全部 P1/P2」不再冲突。
- **P3-3 已修** — AGENTS.md:39 feat-done 流程句补「全量新鲜短路」口径(仅全量写锚点、--only 不写、防子集顶替全量兜底),与实现逐点一致;doc-audit 实跑 exit 0(新引用的 test.sh / build/test-head.txt 不触路径存在性断言)。

### 本轮验证证据(梯级 4,真实退出码)

- `sh -n scripts/test.sh` exit 0;`sh -n .githooks/feat-done.sh` exit 0。
- dwf.ts 改后复验:注入宿主声明 `deno check` exit 0;包装后 `bun build --target=node` transpile exit 0(挑战者 prompt 新增拼接段类型/配平合法)。
- 守卫行为探针:首轮探针 B/C 场景失败系复刻漏 `mkdir -p build`(真 test.sh:41 有),修正后 A/B/C/D 全部符合预期——失败在我探针,不在被审代码。
- `sh scripts/doc-audit.sh` exit 0;`sh scripts/check-arch.sh` exit 0。

### 新引入问题

无。修复未越出五项意见,diff 无顺手改邻。

Verdict: **APPROVED** — 五项意见全部落地且实测核验;本头(83d65ab)即当前分支 head,无 rebase 重写。愿意为合并背书。
