# Code Review — feature/hold-ask-card

Reviewer: ZCode 评审子代理(judge ≠ author,未参与开发)
Date: 2026-10-23
Verdict: APPROVED
Scope:  3 files changed, 47 insertions(+), 8 deletions(-)

```
NemoNotch/Notch/EdgeBar/EdgeBarController.swift   (+16/−6,含注释改写)
AGENTS.md                                          (+2/−1,恢复文档事故)
.reviews/hold-ask-card.md                          (评审记录)
```

基线:`git diff 2b3701941110540fef12429ee6c791bc76ff38b9...HEAD`(单提交 70b3263,--amend 过)。

## Findings

无 P1/P2。以下 P3 均不阻塞合并:

- **[P3] `EdgeBarController.swift:246`** — 新 doc comment 末句 "answered, it closes
  itself **wherever the cursor is**" 与 `autoCard` 的 `guard !pointerOnBar() else {
  return }`(`:274`,本提交未动)矛盾:答完时光标恰在栏上时**不**自收,栏由 hover
  持有到下次 exit 才关。建议改成 "answered, it closes itself — unless the cursor
  is on it, whose exit then closes it"。AGENTS.md 恢复 bullet 的"答完最后一个审批
  才自行收起"是同一蒸馏(丢了 on-bar 例外),手册层可接受,代码注释建议精确。
- **[P3] `EdgeBarController.swift:251`** — `isOpen ? content.rows : content.closedRows`
  的 `closedRows` 分支不可达:不变量 `autoOpened ⇒ isOpen` 成立(autoOpened 只在
  `openNow()→onChange(true)→openBar()` 之后置位 `:263-264`;自收路径先清后关
  `:275-276`;`closeBar` 首行即清 `:566`;特性关闭 `:171`、拖拽 `:706`、head
  `:806`、jump `:838` 全走 `closeNow→onChange(false)→closeBar`,无绕过)。防御性
  三元无害,记录备查——若哪天出现 autoOpened 栌栏关闭的路径,该分支才是兜底。
- **[P3] 残留面扩大(非新根因)**:CLI 在 hook 等待中死亡(或合成 PermissionRequest)
  → phase 永卡 waitingForApproval → `holdsBarForApproval` 永真 → 栏对 exit 免疫,
  直到显式关闭(拖拽/head/特性开关仍有效)。真实会话无此问题:Claude 120s fail-close
  (`HookServer.swift:314-333`)后 CLI 继续发 PostToolUse 等事件清 phase。该残留
  (徽章永黄、notch 永挂审批)先前已存在,本改动只是让其多一种表象;可接受。但
  **"合成会话测试配方必须以 SessionEnd 收尾"这一坑未落任何文档**(只在评审简报里),
  建议后续顺手补进 AGENTS.md 该 bullet。

确认项(非 finding):hold 只保护**自动开**的栏——用户 hover 开的栏即使有 pending
审批,exit 仍照常折叠(notch 的 AI tab 里提问还在)。与提交信息声明的范围一致。

## 逐项代码路径验证(简报要求,全部走代码)

1. **exit 抑制状态一致性 — 闭环成立**:
   - 开:`autoCard :262-264` `hover.openNow(); autoOpened = true`(openNow 先经
     onChange(true)→`openBar` 置 controller isOpen,再置 autoOpened——顺序保证不变量)。
   - hold 下 `.exited`:`:495-497` 不调 `pointerExited()` → `EdgeBarHoverIntent.isOpen`
     恒 true、无 pending;后续 `.entered`/`.moved`(`:485`/`:503`)→ `want(true)==isOpen`
     → `cancelPending`(`EdgeBarIntent.swift:66-69`)无害。✓
   - 答完、光标不在栏:`:273-278` `!next.rows.contains(waiting)` → `autoOpened=false;
     hover.closeNow()` → onChange(false) → `closeBar :563`。干净。✓
   - 答完、光标在栏:`:274` guard 提前 return,**autoOpened 保留 true**(简报问点:置
     false 确在 guard else 侧,`:275`)→ `holdsBarForApproval` 变 false(无 pending 行)
     → 下一次真 exit 正常转发 → `want(false)` → closeTolerance → `closeBar :566` 清
     autoOpened。闭环,无残留。✓ 停留期间新审批到来则 hold 重新咬合(新提问同样受
     保护)。✓
2. **抑制分支其余清理仍执行**:`:487-490`(rowSwitch.cancel、hoveredRow/hoveredButton/
   isOverHead 清空)在 hold 判断**之前**无条件跑;`selectedRow` 不动 → 卡不消失,
   仅 hover 视觉复位。正确。✓
3. **显式退出不被 hold 阻塞**:拖拽 `:706` 直调 `closeNow`(且 `pointer()` 在
   isDragging 时整体早退 `:480-482`);特性关闭 `:171`;head 点击 `:806`;jump
   `:838`——全部绕过 `.exited` 转发。UITestMode:`autoCard :255` 早退 → autoOpened
   永不置位 → hold 在 UI 测试里恒假,抑制不生效。✓
4. **AGENTS.md 恢复完整性**:对照 `git show bf0efd7 -- AGENTS.md` 原 bullet——除刻意
   改写的收起规则句(交还句 → hold 句,即本功能本身)与删掉的口语尾巴"没什么可等
   的"(无信息量)外,其余全部保留(PointerRelay/wasInside 坑、waitingForInput 不强
   开、夺卡先到先得、zcode 天然不触发);`- ` 前缀与列表结构恢复,bullet 位次回到
   事故前(边栏拥有 AI 会话 → 审批卡 → 多选问题)。develop 上的事故态(整条 bullet
   被吞 + 多选问题丢前缀)实存,本提交修复。✓
5. **测试门禁**:`EdgeBarAutoCardTests` 12 例不动、12/12 通过——合理:改动是控制器
   时序(exit 转发门控),仓库无 hosting-view/tracking-area 测试 harness;被测纯函数
   `EdgeBarAutoCard.plan` 未动。`holdsBarForApproval` 是单行谓词,抽纯函数测试的
   鉴别价值边际(判别剃刀下测它近似同义反复),不强制;若未来 harness 落地,优先
   测"hold 下 exit 不折 / 答完光标在栏由 exit 收"两条时序。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:无新增测试;现有 12 例覆盖未动的纯决策,非假绿(变异验证此前
      轮次已做过 plan)。控制时序部分无 harness,见上第 5 条评估。
- [x] **证据纪律**(本评审自跑,梯级 4):`sh scripts/doc-audit.sh` exit 0;
      `sh scripts/test.sh --only EdgeBarAutoCardTests` 12/12 通过 exit 0
      (build/test.log);`sh scripts/lint.sh` exit 0(残余 warning 均为别的文件、
      warning 级不拦)。提交信息声明与 diff 一致,无越权声明。
- [x] **Swift 6 并发**:无新隔离边界。`holdsBarForApproval` 是 MainActor 控制器上
      的同步计算属性,读 `@Observable content`,调用点 `pointer()` 在 hosting 回调
      (MainActor)链上——安全。无 Sendable/`nonisolated(unsafe)` 变化。
- [x] **最小改动**:控制器每行可追溯到"exit 抑制"或其注释;`.entered` 删
      `autoOpened=false` 是语义取消(交还语义随 hold 取消),提交信息明说;AGENTS.md
      只恢复事故 + 写入 hold 规则。无顺手改动、无测试之外的新文件(评审记录除外)。
- [x] **错误路径**:无新错误路径;抑制分支无吞错。
- [x] **坑总目录对照**:改到的 Edge Bar 区在 AGENTS.md 有既有坑节;hold 规则与
      "显式退出仍关"已写入恢复的 bullet;doc-audit 成对断言全过。
- [x] **文档同步**:AGENTS.md 已同步;README 不涉(行为细节属手册层级,合理)。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 2b3701941110540fef12429ee6c791bc76ff38b9...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
