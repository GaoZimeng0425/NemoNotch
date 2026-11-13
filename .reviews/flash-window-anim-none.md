# Code Review — feature/flash-window-anim-none

Reviewer: 独立评审会话(zcode, GLM-5.3;未参与开发)
Date: 2026-11-13(首轮)/ 2026-11-13(增量复审)
Reviewed-Head: 31af090
Verdict: APPROVED
Scope:  首轮 3 files (+12/−1) @ 376a2f6;增量修复 4 files @ 31af090(另含首轮评审记录落盘提交 9697703,非代码)

```
AGENTS.md
NemoNotch/Notch/CompletionFlashWindow.swift
NemoNotch/Services/HookInstaller.swift
NemoNotch/Services/HermesHookInstaller.swift
NemoNotch/Notch/ChatBubbleController.swift
NemoNotch/NemoNotchApp.swift
```

## Findings(首轮提出;增量复审逐条核对)

- **[P1] 已修复** `NemoNotch/Services/HookInstaller.swift:85` — 首轮:`scriptVersion` 未 bump,已装 v16 脚本永远拿不到 `-m 1`。修复:改为 `"# version: 17"`(一行,与首轮修法一致)。核对:已装脚本内容含 `# version: 16`,`ensureScriptExists()` 的 `contains(scriptVersion)` 判 false → 触发重写,新模板落地,分发链条闭合;上轮已确认全仓无测试钉 v16 串,bump 无雷。
- **[P2] 已修复** `NemoNotch/Services/HermesHookInstaller.swift:90` — 首轮:同款无总超时的健康探测。修复:加 `-m 1` + 两行注释,语义与 hook-sender 修法一致;该模板每次无条件重写,即改即全量生效。
- **[P3] 已修复** `NemoNotch/Notch/ChatBubbleController.swift:83` 附近 — 首轮:ChatBubblePanel 缺 `.none`。修复:加在 `makeWindow()` 的面板构造处——这是该面板唯一创建点(`show()` 里 `window == nil` 才建),效果等同类内设置,带不变量注释。
- **[P3] 已修复** `NemoNotch/NemoNotchApp.swift:288` 附近 — 首轮:UITest 背景窗缺 `.none`。修复:一行 + 注释引用 AGENTS.md 不变量。
- **[P3,披露,仍开放]** `.none` 对 macOS 27 夜间路径(显示器睡眠、无渲染表面)的疗效仍停在证据梯级 2-3(API 契约 + 本仓其余覆盖窗全部如此、闪光窗曾是唯一漏网)。梯级 5 需部署后观察一次:显示器睡眠下触发一场完成闪光,确认线程数稳定(`ps -M`)、`curl 127.0.0.1:45831/health` 秒答。非合并阻塞项,按证据纪律如实披露。

## 审查清单(增量复审)

- [x] **修复对应**:增量 4 处代码改动与首轮 4 个 Finding 一一对应,无多余改动、无顺手美化;`.reviews/` 落盘提交为派发方行为(首轮记录原文,未编辑)。
- [x] **判别剃刀**:N/A——增量仍无新测试(版本常量一行 + 属性赋值三行),正当性同首轮(纯窗口集成与模板字符串,无便宜本地测试目标)。
- [x] **证据纪律**:门禁全部增量重跑亲验,退出码见下;`.none` 疗效梯级披露见上。
- [x] **Swift 6 并发**:增量三处 `.none` 均为主线程构造路径上的属性赋值,无新增并发面。
- [x] **最小改动**:8 行代码 + 注释,每行可追溯到对应 Finding。
- [x] **错误路径**:hermes 模板 `|| { printf '{}\n'; exit 0; }` 语义未变;hook-sender 模板其余逐字未动。
- [x] **坑总目录对照**:四处 `.none` 与新立不变量「程序化入屏的覆盖窗一律 `.none`」自洽——现在全仓 orderFront 调用点所属窗口(Notch/Toast/LockScreen/EdgeBar/PermissionDrag/Flash/ChatBubble/UITest 背景)全部设 `.none`,不变量无存量违例。
- [x] **教训候选**:首轮两条(版本 bump 纪律的可门禁化一半;`.none` 覆盖检查的 check-arch A 档候选)留给收尾 reflect 分流,不阻塞本分支。
- [x] **文档同步**:AGENTS.md 坑条目在首提交已入册,增量无新行为需补文档。

### 教训候选(供收尾 reflect)

- **模板内容变更未 bump 版本标记 = 修复静默不分发**(本次 P1 成因,`HookInstaller.swift:85`):「模板字面量变了 ⇒ `scriptVersion` 必须变」没有便宜的一模式 lint;现实门禁形态是抽 `makeScript(port:)` 后单测钉住模板内容(防回退),bump-遗漏仍靠评审纪律。能门禁化一半,记 `docs/guardrail-backlog.md` 候选。
- **「程序化入屏的覆盖窗一律 `.none`」**:跨过程事实(orderFront 调用点 → 窗口类属性),单 ast-grep 模式做不干净,按「校准不到零不上线」暂记 backlog;本分支已把存量违例清零,新违例靠 B 档思路(新增 `orderFrontRegardless()` 行需带 `.none` 佐证)可日后上线。

## 验证记录(增量复审亲跑,退出码为准;首轮同套门禁亦全绿)

- `sh scripts/lint.sh` → exit 0(swiftformat + swiftlint 通过,warning 均为存量)
- `sh scripts/doc-audit.sh` → exit 0(6 项成对断言全绿)
- `sh scripts/check-arch.sh` → exit 0(A 档全仓 + B 档新增行)
- `sh scripts/affected-tests.sh` → exit 0(改动 5 个 Swift 文件;选择器=索引闭包:闭包 49 文件、命中 19 测试类,较首轮新增 `HermesReparseGateTests` 覆盖 hermes 改动;**86 通过 / 0 失败**,日志 `build/test.log`)
- `mutate.sh` 不适用(无新守卫/新测试);铁律遵守:零 git 状态变更、未改任何文件、未跑 build.sh。

## 结论

首轮 CHANGES_NEEDED 的全部根因修复与三项配套修复在 31af090 就位且一一对应:P1 版本 bump 使「健康探测总超时」真正分发到既有安装,P2 堵住 Hermes 同款放大器,P3×2 使全仓程序化入屏窗口与手册不变量完全自洽。根因修法(`animationBehavior = .none`)阻止 `_NSWindowTransformAnimation` 被创建,是因果修复而非症状兜底。门禁四件套增量重跑全绿。**我愿意为这个合并背书:APPROVED。** 部署后建议做一次披露项的夜间观察(显示器睡眠下触发闪光,线程数不涨、health 秒答)作为梯级 5 收口。
