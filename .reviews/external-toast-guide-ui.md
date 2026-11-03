# Code Review — feature/external-toast-guide-ui

Reviewer: ZCode 独立评审子代理(未参与开发;judge ≠ author)
Date: 2026-11-03
Reviewed-Head: b6d075b
Verdict: APPROVED
Scope:  10 files changed, 379 insertions(+), 2 deletions(-)

```
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Settings/Pages/AlertsSettingsPage.swift
NemoNotch/Settings/Pages/ExternalToastGuideSection.swift
NemoNotch/Settings/SettingsSearchIndex.swift
NemoNotchTests/ExternalToastGuideTests.swift
README.md
README_CN.md
docs/external-toast-agent-guide.md
docs/superpowers/plans/2026-11-03-agent-guide-settings.md
docs/superpowers/specs/2026-11-03-agent-guide-settings-design.md
```

## Findings

- **[P2] 指南缺 `jumpURL` 字段——「完整契约」「与 README 描述同一契约」的自称在出生时即不成立**。
  位置:`docs/external-toast-agent-guide.md:30-40`(字段表 7 行,无 jumpURL)与 `NemoNotch/Settings/Pages/ExternalToastGuideSection.swift:34-44`(常量同段,两处逐字一致)。
  证据:实际契约在 `NemoNotch/Models/ExternalToastPayload.swift:25`(jumpURL 字段)与 `:126-140`(≤2048、绝对 URL、禁 file:、trim 后空=未提供);base(b18b5d8)的 README 已文档化——`README.md:95`、`README_CN.md:93`(jumpURL 于 2026-11-02 随 external-toast-jump-url 入库,README 示例用例 `mydownloader://downloads/42` 正是深链场景)。指南定稿于 11-01 脑暴轮,未随 11-02 的契约新增重同步;ledger 无相关 ruling,判系疏漏非刻意裁剪。
  影响:指南是供复制分发的技术工件——agent 按它生成的接入脚本缺深链能力,且每次点「复制指南」都在分发一份不完整契约(复制出去即脱离仓库,事后无法回收);指南头部两处自称(「文档自带端点发现、完整契约与验收步骤」「与 README『External Toast API』节描述同一契约」)失真。注意:**已写内容逐项核对全部准确**(schema==1、app 1–48、key 1–128/空串=未提供/`::` 禁、title 1–120、body ≤280、icon `sf:`、jumpBundleId ≤255、401/400/200、hook-port 回落 45831、hook-token 0600 自动生成),不产生运行时错误——缺项,非错项。
  修法:`docs/external-toast-agent-guide.md` 与 Swift 常量**同一提交**各加一行字段表(`jumpURL | String? | | 点击卡片打开该 URL(深链/网页),优先于 jumpBundleId;带 scheme 的绝对 URL、禁 file:、≤2048 字符;原样透传`),可顺带在验收清单加一条(带 jumpURL 推送 → 点击卡片打开 URL)。README 那句 "full contract" 在补齐前与其一并成立,无需另改。

- **[P3] 锚点测试对「多处出现锚点的单处损坏」失明;测试文件头注释「删掉任一锚点子串即红」表述过强**。
  位置:`NemoNotchTests/ExternalToastGuideTests.swift:4`(注释)。
  实测(本评审亲跑,见 evidence):`X-NemoNotch-Token` 在常量中出现 3 次,`mutate.sh` 按设计只替换第一处(脚本头注释「只换第一处」),剩余 2 处即可满足 `contains` → 测试仍绿;另「后缀追加」型变异(`X-NemoNotch-Token`→`X-NemoNotch-TokenX`)对 `contains` 构造上不可见(超串包含原串)。守卫对**其声明目的**(常量被清空、字段名整体改丢)有牙——`jumpBundleId`(唯一出现锚)→`jumpTarget` 变异被抓住(1 failed,mutate exit 0)。建议:注释改为「任一锚点子串**整体消失**即红」,或在测试中加 `text.components(separatedBy:).filter` 型计数断言;非阻塞。

- **[P3] 连点复制时「已复制」会提前复位**。
  位置:`NemoNotch/Settings/Pages/ExternalToastGuideSection.swift:96-99`。每次点击 spawn 新 `Task`,旧 Task 仍按**首击**时刻 2s 后把 `copied` 置 false(t=0、t=1.5 连点 → t=2 标签提前翻回「复制指南」,第二击的 2s 窗口只剩 0.5s)。纯观感、低频交互;KeepAwake 先例无此状态,非沿用引入。修法:记世代(generation counter)或持有 Task 先 cancel。非阻塞。

- **e2e 降级评估(ledger ruling 不重审,评估残余风险)**:降级留下的三个真实疑点中最大者已被本评审用运行时探针排除——`Label(copied ? "…" : "…")` 三元字面量是否解析到 String 重载显示裸 key:对真 SwiftUI `dump` 实证 title 存储为 `LocalizedTextStorage` + `LocalizedStringKey`(本地化重载胜出,`DisclosureGroup("key")` 纯字面量同机制)。残余未验风险只剩纯观感(DisclosureGroup/ScrollView 在 macOS Form 里的 chevron 对齐与 320 高度滚动观感)与运行时 pasteboard 行为;后者数据面 = `ExternalToastGuide.text` 全文(与源文档 74 行逐字一致,本评审 diff 亲证),API 用法与 KeepAwakeSettingsView.swift:62 先例同款,复制交互留用户验收是合理边界。

### 教训候选

- **contains 型锚点守卫的变异验证要选「唯一出现锚 + 非超串替换」**:`scripts/mutate.sh` 只换第一处,而锚点串在长常量里常出现多次——单处替换后 `contains` 仍绿,易误判「守卫没牙」;后缀追加型变异对 `contains` 构造不可见。(本评审实测三次变异,见 evidence;`NemoNotchTests/ExternalToastGuideTests.swift:4` 注释可顺手修正。)
- **「复制分发型」常量交付前应 diff 源文档**:本次常量与 `docs/external-toast-agent-guide.md` 逐字一致(亲证),但两者一起落后于 README 契约——同源声明链(常量→doc→README)只在相邻两级间成立,没人对表最外级;copy-paste 工件型 feature 的 plan 里可加一步「与契约实现/README 字段表对表」。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:有牙(decisive 变异 `jumpBundleId`→`jumpTarget` 变红,exit 0);盲区与注释过强记 P3。锚点断言面对「常量换成空串/默认值」必红,非自指期望。
- [x] **证据纪律**:ledger 各声明均引真实退出码;测试 2/0 本评审复跑吻合;e2e 未到第 4/5 级但 ledger 如实降级记录、未粉饰。spec/plan 的验证配方可重放。
- [x] **Swift 6 并发**:`@State`/`Task`/`NSPasteboard` 全在 View body 的 MainActor 上下文(Button action 闭包非 @Sendable、继承隔离);`ExternalToastGuide` 无例枚举 + `static let` 不可变,天然 Sendable;Swift 6 模式整模块编译通过(test.sh 构建即证)。无回调线程假设。
- [x] **最小改动**:AlertsSettingsPage 仅 +1 行;README×2 各一句、不动契约描述;无顺手改进邻近代码;全部改动可追溯到 plan 任务。
- [x] **错误路径**:门禁/测试失败路径响亮(退出码);`setString` 返回值忽略与先例(KeepAwakeSettingsView.swift:62)一致,toast 级低风险,可接受。
- [x] **坑总目录对照**:本地化节遵守——正文 verbatim 不进 xcstrings(仅 3 个 UI key 双语,`xcstrings.py check` canonical);「三元字面量→LocalizedStringKey」机制经运行时实证而非凭直觉;xcstrings 保持插入序(external_toast 家族内连续插入,未排序)。
- [x] **教训候选**:见上小节。
- [x] **文档同步**:README×2 已加;AGENTS.md 按其自身纪律只收坑与不变量、不收功能说明书,本 feature 无新增不变量,不进是正确的。

## Review Focus 五条逐条(plan)

1. **复制完整指南而非片段**——结构 ✅:复制动作写 `ExternalToastGuide.text` 全文常量(ExternalToastGuideSection.swift:94),常量与源文档逐字一致(diff 亲证);e2e(pbpaste)按 ledger 降级,残余风险见 Findings 降级评估段。✅(结构级+数据级,交互级留用户验收)
2. **常量与文档同源不漂**——出生点一致 ✅;但同源链最外级(README/实现)缺 jumpURL,记 P2(这是「同源声明被违反」而非「常量与 doc 漂移」)。锚点变异 decisive 有牙 ✅。
3. **搜索能找到**——`SettingsSearchIndex.swift:24-25` 三 key 登记 ✅,xcstrings 双语值在(`Localizable.xcstrings:3814/3831/3848`)✅。
4. **折叠态可复制**——Button 在 DisclosureGroup **外**(VStack 兄弟节点,ExternalToastGuideSection.swift:91-105 vs 106),折叠/展开均可见可点 ✅(代码结构级;点击交互留用户验收)。
5. **切语言跟随**——按钮/标题经 SwiftUI key 解析;三元字面量选本地化重载已运行时实证(LocalizedTextStorage+key);正文 `Text(verbatim:)` 刻意不随语言(spec 非目标)✅。

## Evidence(本评审亲跑,worktree 内,真实退出码)

| # | 命令 | 结果 |
|---|---|---|
| 1 | `sh scripts/test.sh --only ExternalToastGuideTests` | exit 0,2/2 passed(guideCoversEndpointAndCredentials、guideCoversContractFieldsAndAcceptance) |
| 2 | `python3 scripts/xcstrings.py check` | exit 0,"NemoNotch/Resources/Localizable.xcstrings: canonical" |
| 3 | `sh scripts/lint.sh` | exit 0,"✅ swiftformat + swiftlint 通过"(4 条 warning 均为无关文件存量,error 门未触发) |
| 4 | `sh scripts/doc-audit.sh` | exit 0 |
| 5 | `sh scripts/check-arch.sh` | exit 0 |
| 6 | `sh scripts/mutate.sh … 'X-NemoNotch-Token' 'X-NemoNotch-TokenX' --only ExternalToastGuideTests` | exit 1(变异存活——后缀追加对 contains 构造不可见,且只换 3 处中的第 1 处;**指定变异选得无效,不构成守卫无牙的证据**) |
| 7 | `sh scripts/mutate.sh … 'X-NemoNotch-Token' 'X-Other-Token' --only ExternalToastGuideTests` | exit 1(存活——只换第一处,余 2 处满足 contains) |
| 8 | `sh scripts/mutate.sh … 'jumpBundleId' 'jumpTarget' --only ExternalToastGuideTests` | **exit 0,guideCoversContractFieldsAndAcceptance FAILED——守卫有牙**;文件已自动恢复,`git status` 干净 |
| 9 | 常量 vs 文档逐字比对(提取 Swift 多行字符串去缩进后 `diff`) | IDENTICAL,74/74 行 |
| 10 | 真 SwiftUI 运行时探针:`dump(Label(cond ? "a" : "b", systemImage:))` / `dump(Text(cond ? "a" : "b"))` | 三元与纯字面量均 `LocalizedTextStorage` + `key: LocalizedStringKey`——本地化重载胜出,裸 key 上屏风险排除 |
| 11 | 契约事实核对(指南每条断言 vs `ExternalToastPayload.parse` / `HookServer.swift:415-451,579-590`) | 除 jumpURL 缺项外全部吻合(上限、`::`、空 key、sf:、401/400、hook-port/hook-token 生成) |

无法验证项(明说):设置窗口内实际渲染观感与点击复制交互(ledger 已降级,本评审以代码结构 + 存储级探针覆盖其风险面);`affected-tests.sh` 全量未由本评审复跑(ledger 称 8/0,门禁脚本本评审已另跑 4 项全绿)。

## Verdict 依据

CHANGES_NEEDED:唯一实质问题是 P2(jumpURL 缺项)。它不是运行时缺陷——代码、测试、四道门禁全绿,守卫有牙,本地化与最小改动纪律全部遵守——但本 feature 的交付物就是这份「复制出去即脱离仓库」的契约工件,它在出生时已落后于自己 base 里的公开契约,并违反其自带同源声明的最外级。修法机械(两处同一提交各加一行,可选一条验收项),修复后走增量复审(`--prompt --prev 7dc0978`)应可直接改判。两个 P3 建议顺手(注释一句、Task 世代),不单独阻塞。

---

# 增量复审 Round 2 — 7dc0978..b6d075b(2026-11-03)

Reviewed-Head: b6d075b | Verdict: **APPROVED**

零漂移:`git log 7dc0978..b6d075b` 唯一提交 b6d075b,改动 = 修复三文件(doc/常量/测试)+ 本评审记录随分支入库(.reviews 83 行,流程预期)。worktree 其余干净。

## 逐条核对 Round 1 Findings

- **P2(jumpURL 缺项)——已修 ✅**。`docs/external-toast-agent-guide.md` 与 `ExternalToastGuideSection.swift` 同提交各加 jumpURL 字段表行(措辞与 `README.md:95` 及实现逐项对齐,本评审核对 `ExternalToastPayload.swift:126-140`:URL 优先/回落 bundleId ✓、带 scheme 绝对 URL 且 ≠file ✓、≤2048 ✓、trim 后空=未提供 ✓、原样透传/percent-encode 自理 ✓)+ 验收清单第 6 条(与 `ExternalCardService.swift:61-63` 的 tabLink/回落实现一致)。锚点测试加 `#expect(text.contains("jumpURL"))`。**常量与文档仍 74→76 行逐字一致**(diff IDENTICAL,含 swiftformat 缩进修复后的最终态)。实现者称先红后绿;红态无法用 mutate.sh 单跑复现(见下),绿态本评审亲证 2/2。
- **P3-1(注释过强)——已修,但示例失准,记新 P3(不阻塞)**。注释主体改准(「锚点子串全数删尽才红——单处损坏在多处出现的锚上测不到」),但推荐示例「选唯一出现的锚,**如 jumpURL**」在修复后不再成立:jumpURL 现出现 2 次(字段表行 + 验收第 6 条),jumpBundleId 3 次(表行 + 验收第 6 条 + jumpURL 行自身引用)——**全部锚点均已非唯一**。本评审实证:`mutate.sh 'jumpURL'→'jumpURX'`(只换第一处)存活(exit 1)——照注释选锚做变异验证会得出「守卫没牙」的**假阴性**。修法(≤3 行,顺手项):示例改为「整段删除型变异(如把常量改空/改名)」或加计数断言(`text.components(separatedBy:"jumpURL").count-1 == 2`)。守卫对声明目的(清空/字段名整体消失)仍有牙——语义与 Round 1 已实证的 contains 机制相同。
- **P3-2(连点复位截短)——deferred ✅**。>3 行观感项,ledger 有记录(Final fix pass 行),符合 P3 纪律。

## 本轮亲跑证据(worktree 内,真实退出码)

| 命令 | 结果 |
|---|---|
| `git log 7dc0978..b6d075b` / `git status` | 唯一提交 b6d075b;worktree 干净(变异后亦然) |
| `sh scripts/test.sh --only ExternalToastGuideTests` | exit 0,2/2 passed(TEST SUCCEEDED,build/test.log) |
| `python3 scripts/xcstrings.py check` | exit 0,canonical |
| `sh scripts/lint.sh` | exit 0 |
| `sh scripts/doc-audit.sh` | exit 0 |
| `sh scripts/check-arch.sh` | exit 0 |
| 常量 vs 文档逐字 diff | IDENTICAL(76 行) |
| `sh scripts/mutate.sh … 'jumpURL' 'jumpURX' --only ExternalToastGuideTests` | exit 1 存活——实证新注释示例失准(第一处换掉后第二处仍满足 contains) |

implementer 声明的 affected-tests 8/0 未由本评审复跑(四道门禁 + 目标测试已亲证;改动面仅 3 文件且 2 个纯文本行)。

## Round 2 Findings

- **[P3] 测试注释的变异选锚示例失准**:「唯一出现的锚,如 jumpURL」——jumpURL 现出现 2 次,全部锚点均非唯一;照做会得假阴性「守卫没牙」(exit 1 实证)。`NemoNotchTests/ExternalToastGuideTests.swift:5-6`。≤3 行机械项,可顺手修,不阻塞合并。

## 判决

**APPROVED**。P2 修复正确且完整(同提交、双语两工件逐字一致、措辞与实现/README 对齐、验收项与锚点断言到位);四道门禁 + 目标测试亲跑全绿;常量-文档一致性保持。唯一残留是修复自身引入的一行注释示例失准(P3,默认不修),不构成背书障碍。
