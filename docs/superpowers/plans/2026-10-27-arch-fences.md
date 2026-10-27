# Architecture Fences (check-arch.sh) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 坑总目录里"机器可判定"的不变量从散文变成秒级门禁:feat-done 与 CI 跑 `scripts/check-arch.sh`,触犯的改动在合并前被拦下,输出规则名 + file:line + 指向 AGENTS.md 对应坑条目。照抄 octok-platform 围栏舰队的机制精髓,按我们仓库规模裁剪:无 baseline(A 档校准到零 / B 档只扫新增行)、规则与"为什么"同住、豁免写在代码里。

**Architecture:** 单个 shell 脚本 + 内嵌规则表。A 档规则全仓扫描(仅非注释行,行尾 `// fence: allow` 豁免);B 档规则只扫本分支 diff 的新增行。`--selftest` 对每条规则喂"应命中/不应命中"样本行验证模式本身(防模式腐化的迷你自测)。`--all` 全仓体检(A 档全量 + B 档全仓仅列举不拦截)。

**Tech Stack:** POSIX shell + grep -E(可移植:macOS BSD grep 与 CI ubuntu GNU grep 都认;不用 rg,CI 不保证装)。无新依赖。

## Global Constraints

- Everything happens in this worktree (`.worktree/arch-fences`, branch `feature/arch-fences`). **Never run `./build.sh`** and **never merge or run `git feat-done`**(主检出收尾)。
- 最小改动:不动 Swift 行为代码;唯一 Swift 改动是 NotchView.swift:562 加一行豁免注释(纯注释,lint 安全)。
- grep 可移植性:全部用 POSIX ERE;字面 `?` 写成 `[?]`;词边界不用 `\b`(BSD 语义不稳),用显式字符类;注释行(行首空白后以 `//` 开头)全局跳过——已知局限:行尾注释里提到模式词仍会误报,首版接受(记录在脚本头"已知局限")。
- 每条规则的模式必须有自测样本(判别剃刀:样本要能让"模式写错了"这件事变红,不是摆设)。
- 每任务完成即提交,提交信息见任务末步。

## Review Focus

评审员重点看的接缝(单测/selftest 覆盖不到的):

1. **merge-tree 探针挪到链首后**,原位置的注释与"降级"逻辑是否完整跟迁,退出码语义(0/1/≥2 三分)是否原样保留——这是搬移不是重写, diff 应近乎纯位移。
2. **check-arch 在 feat-done 的插入点**(plan-audit 之后、评审门禁之前)与"无 .swift 变更整段跳过"的判定是否与测试门禁同款。
3. **规则与 AGENTS.md 的指针一致性**:每条规则的 why 指针指向的条目真的存在(doc-audit 只查脚本路径存在,不查指针内容)。
4. **AGENTS.md 四处增量**是否都做了、doc-audit 硬字符串约束是否完好(脚本会跑,信退出码)。
5. **--selftest 的样本是否有鉴别力**:每个"不应命中"样本都得是真实容易误写的形状(如 `.sortedSessions`、`.sessions(for:`、Color.opacity(0) 渐变端点)。

---

### Task 1: check-arch.sh — 骨架、规则表、A 档、豁免、--selftest

**Files:**
- Create: `scripts/check-arch.sh`

**规则表(A 档,全仓、非注释行、`// fence: allow` 行内豁免):**

| id | 模式(POSIX ERE) | why 指针(AGENTS.md) | 校准现状 |
|---|---|---|---|
| scriptingbridge | `ScriptingBridge\|SBApplication` | 「媒体」节:MediaRemote 私有函数锁给 Apple 签名进程,控制只走 perl 桥 | 0 命中 |
| opacity-hide | `\.opacity\(.*[?].*0.*:.*1\)` 与 `\.frame\(width:[[:space:]]*0\)` / `height` 同款 | 「坑总目录」opacity(0) 不卸载子树(CPU 22% 实案) | 1 命中=入场过渡瞬时态→Task 2 豁免 |
| proc-pid-rusage | `proc_pid_rusage\(` | 「工具与探针」PerfProbe:当前 SDK 结构版本不齐,SIGABRT 实案 | 0(仅注释提及,注释行已跳过) |
| ui-store-dict | `\.sessions([^[:alnum:]_(]\|$/)` 仅扫 `NemoNotch/Tabs`、`NemoNotch/Notch`、`NemoNotch/Settings` | 「架构不变量」UI 只读 sortedSessions | 0 命中 |
| keychain-returndata | `kSecReturnData` 文件级允许清单 = `Services/UsageQuotaService+Keychain.swift` + `Services/UsageQuotaService+Codex.swift`,清单外文件出现即拦 | 「Keychain/权限/TCC」绝不自动弹窗 | 现存恰好全在清单 |

**接口:**
- 默认(门禁模式):扫 A 档全仓;有命中 → 逐条打印 `规则id  file:line  一句话为什么  → AGENTS.md <条目>` 并 exit 1;零命中 → exit 0。
- `--all`:A 档全量 + B 档全仓列举(信息性,exit 0)。
- `--selftest`:对每条规则跑应命中/不应命中样本,断言模式本身;任何一条样本结果不符 → exit 1。
- 注释行跳过:`grep -vE '^[[:space:]]*//'`;行内豁免:含 `fence: allow` 的行跳过。

**Steps:**
- [x] 写脚本:头部注释(动机/用法/已知局限:行尾注释误报、无类型信息故不查 NSWindow close())、规则表、A 档执行器、B 档执行器、豁免与注释过滤、--selftest 样本表
- [x] `sh scripts/check-arch.sh --selftest` 全绿(样本表见下)
- [x] `sh scripts/check-arch.sh --all` 跑全仓:A 档四条全绿;opacity-hide 降 B 档(见 Task 2)
- [x] commit: `feat(fences): check-arch.sh — A-tier fences + B-tier new-lines-only, with selftest`

**--selftest 样本表(每条:violation 必须命中 / clean 必须不命中):**
- scriptingbridge: 命中 `let app = SBApplication(bundleIdentifier: x)` / 不命中 `// SBApplication 已死`
- opacity-hide: 命中 `.opacity(hidden ? 0 : 1)` / 不命中 `.opacity(0)`(渐变端点)、`opacity(active ? 0 : 1)` **带** `fence: allow` 时
- proc-pid-rusage: 命中 `proc_pid_rusage(pid, ...)` / 不命中 `/// proc_pid_rusage 已弃用`
- ui-store-dict: 命中 `store.sessions[id]` / 不命中 `store.sortedSessions`、`store.sessions(for: tab)`
- keychain-returndata: 命中出现在允许清单外文件 / 不命中清单内文件

---

### Task 2: 校准落账 — NotchView 豁免注释

**Files:**
- Edit: `NemoNotch/Notch/NotchView.swift`(仅 :562 一行加注释)

### Task 2: 校准落账 — opacity-hide 降 B 档(无 Swift 改动)

**校准实测推翻了原计划的两点,记录在此:**
1. 原以为条件隐藏只有 NotchView:562 一处瞬时过渡态。实测全仓 **8 处** `? 1 : 0` 形的
   持久/半持久隐藏(NotchCapsuleView 胶囊淡出、EdgeBarView 可见性×3、BadgeIconView 徽章显隐、
   NotchView 内容等),逐处判「是否昂贵子树」超出围栏成熟度 → 按本 plan 自己立的规矩
   「校准不到零就进 B 档」,**整条降 B 档,只拦新增行**。
2. 首版 else 分支模式 `\.opacity\(.*:.*0` 被 `.black.opacity(0.3), x: 0` 类阴影参数误伤
   (冒号贪婪)— 收窄为「必须先有 `?` 且 `:` 不跨 `)`」,该误报类已进 selftest 样本。

**Steps:**
- [x] 模式收窄 + 降档写进脚本注释(校准日期与存量数)
- [x] 误报类进 selftest 样本(变暗三元 0.68/0.5、悬停 0.16、阴影 x: 0)
- [x] commit: 并入 Task 1 提交(同一份脚本的迭代)

---

### Task 3: B 档执行器 — 只拦新增行(opacity-hide + repeatForever)

(实现上与 Task 1 的脚本合为一体:`b_tier_diff` 取 merge-base develop 的 -U0 diff,
`added_line_hits` 用 awk 按 +++/@@ 头跟踪 file:line,滤行首注释与豁免行。)

**Steps:**
- [x] B 档执行器 + selftest 合成 diff 样本(命中:新增 repeatForever 行;不命中:删除行、
  注释行、`fence: allow` 行、context 行;行号从 @@ 头起算)
- [x] 临时注入 repeatForever 新增行验证门禁 exit 1(trap 保护还原)— 出生仪式(Task 6)统一复跑
- [x] commit: 并入 Task 1 提交

---

### Task 4: 接线 feat-done — check-arch 门 + merge-tree 挪链首

**Files:**
- Edit: `.githooks/feat-done.sh`

**Steps:**
- [x] merge-tree 冲突预检整段(含退出码三分与降级注释)从测试门禁之后**原样搬移**到门禁链最前(doc-audit 之前),原注释保留、新增链首理由注释
- [x] plan-audit 之后、评审门禁之前插入 check-arch 门:无 `.swift` 变更也跑(A 档防全仓级复活,秒级);逃生阀 `NEMONOTCH_SKIP_ARCH=1`
- [x] 顺手收口 R1 残留(占位行 `Verdict: (填` 被误判成已填,分诊走错支 — 本轮端到端实测现形,就在本文件):占位行单独路由到「模板已生成」话术,行为仍 fail-closed
- [x] 对照验证:注入 SBApplication 违规 → feat-done 停在 check-arch(exit 1,输出含修复指引);还原后过 check-arch 停在评审门禁(占位模板 → 正确的「模板已生成」消息)
- [x] commit: `feat(gates): wire check-arch into feat-done; merge-tree probe to chain front; R1 triage fix`

---

### Task 5: CI + AGENTS.md + backlog

**Files:**
- Edit: `.github/workflows/doc-audit.yml`(同 workflow 加一步,零新 runner)
- Edit: `AGENTS.md`(四处)
- Edit: `docs/guardrail-backlog.md`(⑤ 门禁自测框架条目)

**AGENTS.md 四处:**
- [x] feat-done 步骤 3 门禁链描述:链首加 merge-tree 预检、plan-audit 后加 check-arch(含 `NEMONOTCH_SKIP_ARCH=1`)
- [x] 「Git 流程与门禁」新增「架构围栏门禁」段落(doc-audit 段之后):两档语义、豁免、加规则三规矩、--all/--selftest
- [x] Judge≠author 段加一句(⑥):评审 prompt 不带 plan 文档/实现笔记/设计讨论——干净上下文最现实的泄漏口
- [x] 证据纪律加一句(⑦):披露证据完备度——「以下判断只基于 X」

**CI:** doc-audit job 加 `sh scripts/check-arch.sh` 步骤(门禁语义;B 档在 CI checkout 拿不到 merge-base develop 时脚本自身响亮降级,A 档不受影响)。

**Steps:**
- [x] CI 加步骤;本地 `sh scripts/doc-audit.sh` 全绿(新引用的 scripts/check-arch.sh 被路径断言验证存在)
- [x] AGENTS.md 四处 + backlog ⑤ 条目(门禁自测框架推广)落笔
- [x] commit: `docs(gates): AGENTS.md fence section + review/evidence lines; CI runs check-arch`

---

### Task 6: 出生仪式 — 全链见红一次

**Steps:**
- [x] `sh scripts/check-arch.sh --selftest` 全绿(20 样本含 B 档合成 diff)
- [x] 红绿实测:A 档注入 SBApplication(工作区)→ exit 1 含 why 指针,还原 exit 0;B 档**须带真提交**(B 档扫的是已提交 diff,工作区注入对它不可见——门禁管的是进合并的内容,语义如此)→ exit 1 含 `b:repeatForever` + file:line,reset 后 exit 0
- [x] 全部任务框勾完(plan-audit 门禁依赖)
- [x] commit: `test(fences): birth ceremony — A/B tier red-green recorded`

---

### Task 7: 评审回流修复(F1 假绿 / F2 selftest 缺口 / F3 崩溃守卫 / F4 文档清场)

评审员(新鲜会话,26dca2e 记录)实测坐实:B 档 opacity 规则在门禁模式下
**假绿放行**——`awk -v` 对值做反斜杠转义,`\.opacity\(` 剥成裸 `.opacity(`
→ awk 正则语法错 exit 2 → 命令替换吞退出码 → 「无命中」。出生仪式没抓到
是因为 B 档只用无反斜杠的 repeatForever 测过。

**Steps:**
- [x] F1:模式改经 `ENVIRON` 传入 added_line_hits,绝不用 `-v`(评审隔离复现 ENVIRON 路线正确)
- [x] F2:selftest 新增「真模式(含反斜杠)过 B 档执行器」用例——repeatForever 探不出这类雷
- [x] F3:B 档执行器退出码 fail-closed 守卫(崩溃≠无命中);A 档加模式合法性预检(坏正则 grep exit 2 同样会假绿)
- [x] F4:docs/git-worktree-workflow.md 旧门禁链清场(「推翻旧口径 ⇒ 全仓 grep 残留」)
- [x] 回归证明:同一探针(真提交 `.opacity(probe ? 0 : 1)`)修复前 exit 0(评审实测)→ 修复后 exit 1,reset 后绿
- [x] commit: `fix(fences): ENVIRON for awk pattern (F1 fake-green), crash guards, selftest via real pattern`
