# Code Review — feature/external-toast-icon

Reviewer: claude-opus-5-5 独立评审子代理(fresh session,未参与开发)
Date: 2026-11-13
Reviewed-Head: 4f8cbc4
Verdict: APPROVED
Scope:  15 files changed, 169 insertions(+), 53 deletions(-)

```
AGENTS.md
NemoNotch/Models/ExternalToastPayload.swift
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/ExternalCardService.swift
NemoNotch/Settings/Pages/ExternalToastGuideSection.swift
NemoNotchTests/CompletionDetectorTests.swift
NemoNotchTests/CompletionFlashExternalEntryTests.swift
NemoNotchTests/ExternalCardServiceTests.swift
NemoNotchTests/ExternalToastPayloadTests.swift
README.md
README_CN.md
docs/external-toast-agent-guide.md
integrations/herdr-mod/edges.js
integrations/herdr-mod/edges.test.mjs
```

## 验证(评审员亲跑,worktree @ 4f8cbc4)

- `sh scripts/lint.sh` → 退出码 0(✅ swiftformat + swiftlint 通过;仅 scripts/index-affected.swift 存量 warning,非本分支)
- `sh scripts/doc-audit.sh` → 退出码 0(✅ 文档对账通过)
- `sh scripts/check-arch.sh` → 退出码 0(✅ 架构围栏:全部通过)
- `sh scripts/test-herdr-mod.sh` → 退出码 0(tests 15 / pass 15 / fail 0)
- `sh scripts/affected-tests.sh` → 退出码 0(索引闭包选择器,改动 9 个 Swift 文件,命中 29 个测试类;通过 208 · 失败 0;日志 build/test.log)
- `sh scripts/mutate.sh NemoNotch/Models/ExternalToastPayload.swift '[A-Za-z0-9.-]{1,255}' '.{1,255}' --only ExternalToastPayloadTests` → 变异被抓(失败 1 / 通过 26,xcodebuild 退出码 65),已恢复原文件
- `sh scripts/mutate.sh NemoNotch/Models/ExternalToastPayload.swift 'case "ai":' 'case "aix":' --only ExternalToastPayloadTests` → 变异被抓(失败 2 / 通过 25,退出码 65),已恢复原文件
- 运行后 `git status --short` 仅有派发方原有的 `?? .reviews/external-toast-icon.md`,零 git 状态变更
- 未做:Herdr mod JS 映射的变异测试(手工改文件违反只读铁律)。不过 `card()` 的 deepEqual 断言 `icon: "ai:claude"`,`iconFor` 测试也同时断言了命中与回落两侧,按判别剃刀推理有牙,属于第 2–3 级证据,不是第 4 级
- 未做:运行中 app 的实际渲染(第 5 级),原因是禁跑 build.sh。渲染分支是对既有 `aiIcon`(从 `.ai` case 原样抽出)和 `AppIconCache` 路径的复用,依据只有代码阅读

## Findings

### P1
无

### P2
无

### P3

- P3-A `NemoNotch/Notch/CompletionToastView.swift:327-338`(`AppIconCache.icon`):查不到的结果(nil)不进缓存。所以 `app:&lt;未安装 bundle id&gt;` 的外来卡每次 body 求值都会在主线程同步查一次 LaunchServices(`urlForApplication`)。这个行为通知卡原本就有,频率是视图更新级、不是逐帧,所以不阻塞合并。修法:对 nil 也记一个负缓存,或者在 `ExternalCardService.makeItem` 时一次性解析好。
- P3-B `integrations/herdr-mod/edges.js:53-58`:`opencode`/`gemini`/`zcode` 的前缀映射没有本机样本,本机只实测过 `claude-code`。猜错时会安全回落成 `sf:terminal`,不会出错。修法:在注释里补一句"仅 claude-code 实测,其余为推断",方便以后拿到样本时校准。
- P3-C 旧口径清场(只是记录,不要求修改):`docs/superpowers/specs/2026-11-01-external-toast-api-design.md:98` 写的是"本期仅 `sf:`",`docs/superpowers/plans/2026-11-01-external-toast-api.md:41/75/83/109` 用的还是 `iconSymbol` 字段名。两份都是带日期的历史设计/计划文档,算历史叙述,不是现在时的契约。现行契约的 4 处(README、README_CN、docs/external-toast-agent-guide.md、ExternalToastGuideSection.swift)和 AGENTS.md 已同步。代码里 `rg iconSymbol` 零残留。不修。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:`iconForms` 用字面输入断言字面输出,正例和反例都覆盖:`ai:codex`、`ai:Claude`、`app:../../etc`、空值、`png:`。`aiIconThroughParse` 从公开 `parse` 入口证明"坏 icon 不拒卡"。两次变异都变红。edges.test.mjs 断言具体映射值,也断言 `sf:terminal` 回落。如果被测代码到处返回默认值,这些测试过不了。
- [x] **证据纪律**:提交信息里没有验证声明(没有夸大)。评审侧已亲跑到第 4 级,见上方"验证"。
- [x] **Swift 6 并发**:`ExternalToastIcon` 是 `Sendable` 值类型(`AISource` 是 String raw enum,隐式 Sendable)。渲染新增的调用只走既有 `AppIconCache`,和通知卡在同一个视图上下文里;没有新增跨线程边界。编译通过,影响面单测通过。
- [x] **最小改动**:`aiIcon` 从 `sourceIcon` 原样抽出,目的是让 `.ai` 和外来 `ai:` 共用,属必需。`genericExternalIcon` 抽出是为了三处回落共用。`icon(fromWire:)` 由 private 改为 internal,是为了直接测。没有顺手改邻近代码。
- [x] **错误路径**:坏 icon 一律降成 nil,回落通用图标,不返回 400。这是契约明文规定的行为,不是吞错:卡照常弹出,只是图标降级。`app:` 值用正则 `^[A-Za-z0-9.-]{1,255}$` 收紧,外来字符串不会以任意形状进入 LaunchServices 查询。
- [x] **坑总目录对照**:外部 Toast API 的"零语义翻译 / additive 不升 schema"已遵守(schema 仍 1,未知写法静默忽略)。Herdr mod 地址守卫没动。新增内容不碰 hit-testing、动画或常驻渲染路径(图标是静态 Image 或 Shape,`ClaudeCrabIcon` 等是既有组件)。check-arch 通过。
- [x] **教训候选**:见下方小节。
- [x] **文档同步**:README、README_CN、agent 接入指南、设置页内嵌指南(ExternalToastGuideTests 已守卫内嵌指南与文档一致,通过)、AGENTS.md 外部 Toast API 条目都已同步。bug 专项镜头:①本分支是功能增强,N/A;②N/A;③旧口径全仓 grep 已做,见 P3-C。

## 教训候选

- 无(本次没有新坑)。可一提的判据是:外来字符串进入系统查询(LaunchServices、SF Symbol 探测)前先过白名单正则。这次 `app:` 已经这样做,与既有 `herdrTerminal` 校验同一思路,不是新教训。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff f0f45214a23991e567ae291d731c2f3a5fb92bed...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
