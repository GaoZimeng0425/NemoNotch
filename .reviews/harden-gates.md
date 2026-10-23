# Code Review — feature/harden-gates

Reviewer: ZCode 独立评审子代理(GLM-5.3,未参与本 feature 开发,judge ≠ author)
Date: 2026-10-23
Reviewed-Head: 445ce8c
Verdict: APPROVED
Scope:  7 files changed, 155 insertions(+), 10 deletions(-)

```
.githooks/feat-done.sh
.zcode/workflows/implement-with-review.dwf.ts
AGENTS.md
docs/guardrail-backlog.md
scripts/affected-tests.sh
scripts/review.sh
scripts/test.sh
```

## Findings

- **[P2]** `scripts/affected-tests.sh:53` — `extract()` 的前缀组 `(final |public |internal |open |@main )?` 只容**单个**前缀,抽不到两类声明:(a) 同行属性 `@Observable final class X`;(b) 叠加前缀 `public final class X`。SwiftFormat **不会**归一(实测:/tmp 探针 `@Observable final class ProbeSameLine {}` 原样通过 `swiftformat --swiftversion 6.0`),缓解只剩当前约定。**当前仓库零实际命中**:全仓扫描(NemoNotch + NemoNotchTests)同行属性顶层声明 0 个、叠加前缀 0 个(34 个顶层 `private struct` 虽也不在前缀集,但顶层 private=文件作用域,测试从别的文件语义上引用不到,漏抽无害);AISessionStore.swift:9-11 是 `@MainActor`/`@Observable` 各自独行 + `final class AISessionStore` 列 0,正常抽取。危险侧在未来:风格漂移到同行属性 + 该文件还有其它可抽类型掩盖回落时,会**静默少跑**测试(单类型文件会因 symbols 空→映射空→回落全量自愈)。建议后续把前缀组改成可重复且容 `@Word`(方向:`^((@?[A-Za-z][A-Za-z0-9_]* )*)(class|struct|…)`);非阻塞。→ **4d71ee6 已部分修复**(extract 侧已改,declared 集过滤侧未跟上,目标场景净效果不变——见文末「复核 4d71ee6」节)。
- **[P3]** `scripts/affected-tests.sh:57/78` — `for f in $changed_prod` / `for t in $changed_tests` 无引号分词:含空格的路径会被静默拆开、`[ -f ]` 跳过 → 生产文件符号漏抽(危险侧)/测试类漏加。实测仓库 0 个含空格路径(`git ls-files | grep ' '` 为空),Swift/Xcode 命名约定也不产空格;记录备查。
- **[P3]** `scripts/affected-tests.sh:65-68` — `declared_tmp` 无 trap:mktemp 与 rm 之间被 SIGINT 会在 /tmp 残留一个小文件(两个提前退出路径 36/44 都在 mktemp 之前,正常路径必清)。化妆级。
- **[P3]** `.githooks/feat-done.sh:101-104` — 评审者贴**长**哈希(`git rev-parse HEAD`)或忘填模板占位时,核对失败方向 fail-closed(不会假绿),但报错文案固定说"评审后 rebase/重写过",误导排障。短/长哈希歧义当前不存在:本仓对象量级下 `git rev-parse --short HEAD` 与 `git log --format=%h` 同为 7 位(实测均 29b3b57)。
- **[P3]** `scripts/test.sh:33` — `--only` 全路径形式里若含逗号,`tr` 拆出的伪类条目在**其余部分命中**时静默贡献 0 个用例(零用例守卫只在全部无匹配时触发)。仅影响手工调试传参;affected-tests.sh 生成的类名不含逗号。

无 P1。核心机制全部真跑验证(见下),P2 为潜伏性盲区且当前代码零命中、方向仍严格优于被替换的手挑 `--only`。

## 验证记录(全部亲跑,命令 + 退出码)

1. `sh scripts/affected-tests.sh nonexistent-base-ref` → 响亮报错,exit 2(base 不存在 fail-closed)。
2. `sh scripts/affected-tests.sh HEAD`(模拟主检出 HEAD==base 空 diff)→ "无 Swift 改动 — 无需跑测试",exit 0。
3. `sh scripts/affected-tests.sh --files NemoNotch/Ghost.swift`(不存在路径)→ "映射为空 → 回落全量" → **全量 523 通过 / 0 失败,exit 0**(顺带:本分支全量绿;回落路径 + 零用例守卫真跑)。
4. `sh scripts/affected-tests.sh --files NemoNotch/Models/SessionPhase.swift` → 选出 10 类逗号列表(AskAnswerTests…LockScreenAIPanelModelTests),**72 通过 / 0 失败,exit 0** — 与提交信息声明逐字一致;test.sh 多 `-only-testing:` 逗号列表路径真跑。
5. `sh scripts/affected-tests.sh --files NemoNotchTests/AskAnswerTests.swift` → 选 AskAnswerTests,**7 通过,exit 0**(改动的测试文件自身必进清单)。
6. 新鲜度历史模拟:`git log --format=%h -1 423005e -- . ':!.reviews'` → **3fe6d0b**(423005e 是只动 .reviews 的记录提交,`':!.reviews'` 路径排除在 git 2.54.0 实测有效,code_head 正确稳定指向其前的代码提交);当前 `git rev-parse --short HEAD` = `git log --format=%h -1 -- . ':!.reviews'` = 29b3b57。
7. 抽取盲区扫描:全仓同行属性顶层声明 0;叠加访问前缀 0(仅 34 个顶层 `private struct`,文件作用域);`NemoNotch/Helpers/PerfProbe.swift:29` `enum PerfProbe`、`NemoNotch/Notch/QuickStartWindow.swift:4` `final class QuickStartWindow` 均列 0 可抽,`grep -l 'PerfProbe|QuickStartWindow' NemoNotchTests/*.swift` 零引用 → 映射空 → 回落全量,与提交信息一致。
8. 正则元字符注入面:`extract()` 捕获组 `\3` 约束为 `[A-Za-z_][A-Za-z0-9_]*`,declared 集同约束再经 `grep -Fx -f` 精确过滤,`paste -sd'|'` 拼出的模式按构造不可能含元字符;symbols 为空时 `[ -n "$symbols" ]` 挡住空模式,不进入 grep。
9. `sh scripts/doc-audit.sh` → exit 0(手册引用脚本路径全部存在,含新 scripts/affected-tests.sh)。
10. `shellcheck -s sh` 四个改动脚本(affected-tests / test / feat-done / review)→ 0 findings。
11. swiftformat 探针(/tmp,仓库未动):`@Observable final class ProbeSameLine {}` 原样保留 → P2 的缓解仅是约定,非结构性的。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A(本 feature 无新测试;硬化的是"选哪些测试跑"的门禁本身——其鉴别力由第 4/5/3 条真跑区分:SessionPhase 精确选 10 类、Ghost 空映射回落全量、AskAnswerTests 单类,三种输出互不相同,不是恒等映射)。
- [x] **证据纪律**:提交信息三组声明(SessionPhase→10 类 72 例绿 / PerfProbe、QuickStartWindow→回落全量 / 无 Swift→跳过)全部复现且退出码一致(验证记录 4/7/2)。
- [x] **Swift 6 并发**:N/A(无 Swift 代码改动——7 文件全是 scripts/hooks/docs/workflow)。
- [x] **最小改动**:每个 hunk 可追溯到两项硬化之一或其文档同步;review.sh 仅 +1 行模板;feat-done.sh 22 行全在评审门禁段内,未顺手改别处。
- [x] **错误路径**:缺 base exit 2;空映射回落全量(fail-safe,宁多跑);grep 长模式失败也经 `|| true` 落入回落(不假绿);feat-done 缺 Reviewed-Head 行 exit 1、占位忘填/长哈希均 != code_head 拒绝(fail-closed);--only 无匹配的零用例守卫保留。
- [x] **坑总目录对照**:AGENTS 新表述与实测行为一致(逗号列表✓、回落全量✓、"同名符号误吸只会多跑"与 grep 子串匹配行为一致);doc-audit 过;`.zcode` workflow 人格两处与 AGENTS 同步且与脚本真实接口(affected-tests.sh 回落语义)一致。
- [x] **文档同步**:AGENTS.md 三处、guardrail-backlog.md(新,含已硬化两案留档)、workflow 人格同步齐全;"禁手挑 --only" 目前是人格约束非机械——backlog 已如实登记 ripwire 适配等后续项,表述诚实。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 08cde40a1bdeafddc00bc83416e3a879732f5c6f...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

---

## 复核 4d71ee6(2026-10-23,第二轮;amend 前旧 head 29b3b57)

Reviewer: 同上(ZCode 独立评审子代理)
Reviewed-Head: 4d71ee6
Verdict: APPROVED(维持;无新增 P1,残留 P2 仍为潜伏性、当前代码零命中)

### 改动核对

`git diff 29b3b57..4d71ee6` = `scripts/affected-tests.sh` **仅一行**正则(extract() 前缀组 `(final |public |internal |open |@main )?` → 可重复 `((final |public |internal |open |@[A-Za-z]+ )*)`,捕获组 `\3`→`\4` 正确重编号;`@main ` 被 `@[A-Za-z]+ ` 覆盖)+ 本评审记录文件入提交(评审记录随分支走,符合惯例)。无其它代码改动,`private`/`fileprivate` 仍不在前缀集(首轮已判定无害:顶层 private=文件作用域,他文件测试语义上引用不到)。

### 复核 Findings

- **[P2·残留] `scripts/affected-tests.sh:66`(首轮 P2 的修复不完整)** — extract() 现在能抽到 `@Observable final class X`(探针:`echo '@Observable final class ProbeSameLine {'` 经新 sed 捕获 `ProbeSameLine`),但 **declared 集过滤仍用无属性词表**:`^[[:space:]]*(final |public |private |fileprivate |internal |open |static )*(class|…)` 对同一行 grep 为**空**(探针实测),line 67 的 `grep -Fx -f` 会把该符号**滤掉**。对修复声称的目标场景(同行属性声明)管线净效果与修复前相同:多类型文件里被其它符号掩盖时仍静默少跑;单类型文件仍经"符号空→映射空→回落全量"自愈。修复建议:line 66 的前缀组同步改为容 `@[A-Za-z]+ `(与 extract 同词表)。仍非阻塞:全仓同行属性声明依旧 0 个,纯潜伏。→ **445ce8c 已修闭环**(declared 集词表已同步,见文末「复核 445ce8c」节)。
- 无新增 P3;新正则未引入误吸面(`@[A-Za-z]+ ` 要求尾随空格,`@objc(FOO)` 这类带括号形式不匹配,列 0 本就罕见)。

### 复核验证(亲跑,命令 + 退出码)

1. `sh scripts/affected-tests.sh --files NemoNotch/Services/AICLIMonitorService.swift` → 命中 1 符号,选 AISourceRoutingTests,AppActivatorTests,BadgeDebounceTests,**14 通过 / 0 失败,exit 0**。注:该文件声明是**约定格式**(@MainActor/@Observable 独行 + `final class AICLIMonitorService` 列 0,3-5 行)——旧正则同样可抽,此跑是回归检查而非修复路径检查。
2. `sh scripts/affected-tests.sh --files NemoNotch/Models/SessionPhase.swift` → 与首轮**逐字一致**:同 10 类逗号列表,72 通过 / 0 失败,exit 0(无回归)。
3. 两段管线探针(literal I/O,仓库未动):同行属性声明经新 extract 捕获 `ProbeSameLine`、经 declared 集 grep **零匹配** → 滤掉,证实上面的 P2·残留。
4. `git rev-parse --short HEAD` = 4d71ee6 = `git log --format=%h -1 -- . ':!.reviews'`(评审记录入提交后 code_head 仍稳定)。

### 结论

修复方向正确但只改了管线两段中的一段;目标场景行为未变。鉴于该场景在当前仓库零命中(纯潜伏)、非阻塞,维持 APPROVED,建议随本 feature 或下一个 touches-scripts 的 feature 把 line 66 前缀组对齐后关闭该 P2。

---

## 复核 445ce8c(2026-10-23,第三轮;amend 前旧 head 4d71ee6)

Reviewer: 同上(ZCode 独立评审子代理)
Reviewed-Head: 445ce8c
Verdict: APPROVED(维持;第二轮 P2·残留已修闭环,仅余信息性 P3)

### 改动核对

`git diff 4d71ee6..445ce8c -- scripts/` = **仅 `scripts/affected-tests.sh` 一行**(line 66 declared 集管线:grep 与 sed 同步把前缀组改为可重复并加入 `@[A-Za-z]+ `,sed 捕获 `\3`→`\4` 重编号正确)。另:第二轮评审记录更新被卷入本 amend——即流程教训实例(见下)。

### 复核 Findings

- **第二轮 P2·残留 → 已修闭环**(证据见下,管线两段词表已一致,同行属性声明端到端精准选类)。
- **[P3·信息] 带括号属性仍两段一致抓不到**:`@available(macOS 13.0, *) final class X` 经 extract sed 与 declared grep 均零匹配(探针实测)——`@[A-Za-z]+ ` 要求尾随空格,`@available(…)`/`@objc(FOO)` 不匹配。与第二轮的不对称不同,这次**两段一致**,单类型文件仍自愈回落;列 0 同行带括号属性比无括号属性更罕见。记录备查,不建议本 feature 内再扩。
- 无新增 P2;declared 集扩大只增不减(grep -Fx 交集方向安全),未引入误吸面。

### 复核验证(亲跑,命令 + 退出码)

1. **修复路径端到端探针**(仓库临时文件,跑完即删,`git status --porcelain` 空):创建 `NemoNotch/ProbeSameLine.swift`(`@Observable final class ProbeSameLine { var value = 42 }`,声明与属性**同行**)+ `NemoNotchTests/ProbeSameLineTests.swift`(真断言 `#expect(ProbeSameLine().value == 42)`)→ `sh scripts/affected-tests.sh --files NemoNotch/ProbeSameLine.swift` → **命中符号 1 个**(第二轮此处会被 declared 集滤成 0 → 回落全量)、精准选出 `ProbeSameLineTests`、**1 通过 / 0 失败,exit 0**(pbxproj 是 PBXFileSystemSynchronizedRootGroup,新文件自动进 target,真编译真跑)。
2. **回归**:`sh scripts/affected-tests.sh --files NemoNotch/Models/SessionPhase.swift` → 与前两轮**逐字一致**:10 类、72 通过 / 0 失败,exit 0。
3. 括号属性一致性探针(literal I/O):`@available(macOS 13.0, *) final class ParenAttr {` 两段管线均零匹配 → 上述 P3·信息。
4. `git rev-parse --short HEAD` = 445ce8c;记录更新后待提交(feat-done 的 `grep '^Reviewed-Head:' | head -1` 读首行 = 445ce8c,与 `git log --format=%h -1 -- . ':!.reviews'` 一致)。

### 流程教训(记入证据链)

**代码 amend 与评审记录提交必须分开**:本 feature 连续两轮 amend 把评审记录卷进代码提交,`Reviewed-Head:` 随之连续过期两轮(29b3b57→4d71ee6→445ce8c)——这正是判决新鲜度门禁在正确咬合:Verdict 描述的必须是当前代码,head 一动就得补审。后续约定:评审记录单独 commit(它本身在 `':!.reviews'` 排除集内,不会推走 code_head),代码 amend 不 touching `.reviews/`。

### 结论

第二轮 P2 修复闭环(两段词表一致,同行属性场景端到端验证通过),回归零变化。维持 APPROVED。
