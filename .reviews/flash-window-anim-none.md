# Code Review — feature/flash-window-anim-none

Reviewer: 独立评审会话(zcode, GLM-5.3;未参与开发)
Date: 2026-11-13
Reviewed-Head: 376a2f6
Verdict: CHANGES_NEEDED
Scope:  3 files changed, 12 insertions(+), 1 deletion(-)

```
AGENTS.md
NemoNotch/Notch/CompletionFlashWindow.swift
NemoNotch/Services/HookInstaller.swift
```

## Findings

- **[P1]** `NemoNotch/Services/HookInstaller.swift:85` — `scriptVersion` 仍是 `"# version: 16"`,而 `ensureScriptExists()`(同文件 263-268 行)的 no-op 条件是「已装脚本含版本标记 + 端口标记即跳过重写」。模板内容改了、版本号没 bump ⇒ **所有已装 v16 脚本的用户(即本修复要保护的人群)永远拿不到 `-m 1`**,只有全新安装受益;新 AGENTS.md 条目自己写的「运行时脚本会被版本更新重写」在本次提交里恰好没有发生。修法:一行,`scriptVersion` 改 `"# version: 17"`(全仓无测试钉此串,bump 安全;重写只覆盖脚本文件,不碰各 CLI settings.json,无副作用)。事故机靠手改的运行时文件暂时正常,但公开发布的 DMG 用户全部漏掉。
- **[P2]** `NemoNotch/Services/HermesHookInstaller.swift:90` — 同款放大器原样存在:健康探测 `curl -s --connect-timeout 0.3` 无总超时,对沉默服务器一样无限挂,Hermes 会话的 hook 与 claude/gemini/zcode 走同一个 HookServer,服务器再楔死(任何未来原因)时唯独 Hermes 的轮次无界挂死。修法:一行,同加 `-m 1`(此模板每次无条件重写,改完即全量生效,无 P1 的分发问题)。用户拍板原文只点名 hook-sender,但拍板的精神是「CLI 永不因沉默服务器挂死」,同仓姊妹脚本属同类。
- **[P3]** `NemoNotch/Notch/ChatBubbleController.swift:174`(`ChatBubblePanel`)与 `NemoNotch/NemoNotchApp.swift:283` 附近(`makeUITestFlashBackdrop`)— 两处程序化 `orderFront`/`makeKeyAndOrderFront` 的窗口未设 `animationBehavior = .none`,严格说与新立不变量「程序化入屏的覆盖窗一律 `.none`」不符。实测无泄漏路径:前者唯一触发是边栏头部物理点击(EdgeBarController.swift:927,用户动作 ⇒ 显示器必醒,动画 0.2s 正常完成),后者仅 `--flash` 截图模式。修法:各一行补 `.none` 求一致;不修也不构成本事故的残留。
- **[P3,披露]** `.none` 对 macOS 27 夜间路径的疗效我只到证据梯级 2-3(API 契约:`animationBehavior` 是 AppKit 窗口入屏动画的官方开关 + 本仓其余 5 个覆盖窗早已如此、闪光窗是唯一漏网——内部一致性)。梯级 5(显示器睡眠下真实触发闪光、线程数不再涨)评审台无法复现,需部署后夜间观察一次:触发一场完成闪光(可 `--uitest --flash` 外的手动完成事件),确认 `ps -M` 线程数稳定、`curl 127.0.0.1:45831/health` 秒答。非缺陷,按证据纪律披露。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A——本分支无新测试,正当性核对通过:改动为 NSWindow 属性赋值(失败形态需要显示器睡眠 + WindowServer,无便宜本地测试目标)与 shell 模板字符串(要测须先把模板抽成可注入函数,超出最小改动);符合本仓「纯窗口集成与文案级改动不产新测试」规矩。P1 的一行版本 bump 也不需要测试。
- [x] **证据纪律**:提交信息声称的调试器断点链与派发方独立机器证据吻合(非作者自述孤证);门禁全部由我亲跑,退出码见下。`.none` 疗效梯级披露见 P3 第 4 条。
- [x] **Swift 6 并发**:无新增并发面——`makeWindow` 的两个调用路径(主 Actor `rebuild()` 与 main-queue async block)本就存在,属性赋值在主队列上,无隔离/Sendable 新边界。
- [x] **最小改动**:12 行里每行可溯源(注释讲事故、属性一行、模板一行 curl + 三行注释、手册一条坑);无顺手改动邻近代码。
- [x] **错误路径**:`|| exit 0` 语义未变,模板其余部分逐字未动(diff 只增不删该行除 curl 行本身)。
- [x] **坑总目录对照**:改动区正对「具文窗口陷阱」与「Hook 端口」两节;新坑条目就位且与旧条目(「创建即入屏则两屏都正常」——那是渲染表面口径,显示器亮)无矛盾;doc-audit 对新增手册行通过(无引用不存在的脚本路径)。
- [x] **教训候选**:见下。
- [x] **文档同步**:AGENTS.md 同提交入册(代码+手册同行);无用户可见功能变化,README 不需动。

### 教训候选

- **模板内容变更未 bump 版本标记 = 修复静默不分发**(`HookInstaller.swift:85`,本次 P1 的成因):机器化候选——「模板字面量变了 ⇒ `scriptVersion` 必须变」没有便宜的一模式 lint(需跨常量与字符串字面量比对);现实的门禁形态是单测把脚本模板渲染断言钉住(须先抽 `makeScript(port:)`),能钉住修复内容本身不被回退,但 bump-遗漏仍靠评审纪律。如实记:能门禁化一半。
- **「程序化入屏的覆盖窗一律 `.none`」已入册,但存量两窗(ChatBubblePanel、UITest 背景窗)先于不变量存在**(file:line 见 P3 第 3 条):check-arch A 档候选——`orderFrontRegardless()` 调用点所属窗口类是否设 `.none` 是跨过程事实,单 ast-grep 模式做不干净(控制器文件 vs 窗口类文件会假阳),按「校准不到零不上线」规矩暂不上线,记 backlog。

## 验证记录(全部亲跑,退出码为准)

- `sh scripts/lint.sh` → exit 0(swiftformat+swiftlint 通过;warning 均为存量文件,非本分支改动文件)
- `sh scripts/doc-audit.sh` → exit 0(6 项成对断言全绿)
- `sh scripts/check-arch.sh` → exit 0(A 档全仓 + B 档新增行)
- `sh scripts/affected-tests.sh` → exit 0(选择器=索引闭包:闭包 45 文件、命中 18 测试类;**83 通过 / 0 失败**,日志 `build/test.log`)
- 无新守卫/新测试,`mutate.sh` 不适用;bug 专项镜头:①无新测试之正当性已核(见清单);②修复与根因因果对应——`.none` 阻止 `_NSWindowTransformAnimation` 被创建(因),不是给线程池加超时兜底(症);③旧口径清场 grep 完成:docs/ 命中皆为历史 specs/plans 时点记录,experience-playbook/README/注释无现在时残留。

## 结论

根因修复(`animationBehavior = .none`)正确、因果对应、与全仓其余覆盖窗一致,主泄漏点两个创建路径(`rebuild`/`applyOverlayVisibility`)都经 `makeWindow` 覆盖完整。**CHANGES_NEEDED 仅因 P1**:分发链条断在版本号没 bump,拍板的「hook-sender 健康探测补总超时」对既有安装等于没交付——一行修完后(建议顺手带上 P2 的 hermes 同款一行)我可以改 APPROVED。
