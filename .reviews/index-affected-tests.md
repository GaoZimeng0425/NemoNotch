# Code Review — feature/index-affected-tests

Reviewer: ZCode 独立评审子代理(GLM-5.3,未参与本 feature 开发,只读评审)
Date: 2026-11-03
Reviewed-Head: 7b9fc00
Verdict: APPROVED
Scope:  7 files changed, 859 insertions(+), 9 deletions(-)

```
.swiftlint.yml
AGENTS.md
docs/superpowers/plans/2026-11-03-index-store-test-selector.md
docs/superpowers/specs/2026-11-03-index-store-test-selector-design.md
scripts/affected-tests.sh
scripts/index-affected-shim.c
scripts/index-affected.swift
```

## Findings

无 P1/P2。以下全部 P3(记录性微瑕,均不阻塞合并;所有故障路径实测要么回落、要么响亮失败,不存在静默假绿路径):

- **P3-1** `scripts/index-affected.swift:203-221` — `kindName` 是死代码(全文件无调用点,probe/closure 都不用)。修法:删除,或接进 probe 的定义列表输出。
- **P3-2** `scripts/index-affected.swift:261-268` — `UnitDeps.reader` 属性存而未用(depsCb 只用 `d.owner`)。修法:删属性只留 owner。
- **P3-3** `scripts/affected-tests.sh:75` — CLI stderr `2>/dev/null` 吞掉可行动的具体原因(CLI 已产出「以下文件不在索引中:X」这类一行诊断),回落原因退化为三选一笼统话术「CLI exit 非零(索引不健康/新文件未构建/dylib 缺失)」。修法(一行):CLI stderr 并入 `reason_file` 而非丢弃。非阻塞:三个候选原因已列出,且 CLI 可独立手跑。
- **P3-4(场景记录,不修)** 幽灵测试类:分支删除 `NemoNotchTests/FooTests.swift` 且某生产文件闭包**仅**命中它时,旧索引仍含其 record → `--only` 指向不存在的类 → xcodebuild 静默 0 用例 → 被 test.sh 零用例守卫响亮拦下(exit 1,scripts/test.sh:104)。方向 = 误杀而非假绿,下次构建刷新索引后自愈。文本二级对同场景走全量(classes 空回全量),两级行为有此差异,知悉即可。
- **P3-5(提交信息不实)** commit cdac5f7 声称「历史上 scripts 无 .swift,首个落位」——`scripts/generate-app-icon.swift` 在 base(9d25f23)即存在(git log --follow 实锤,da5851e 引入)。`.swiftlint.yml` 移除 `scripts` 排除实际把该既有文件也拉进 swiftlint 门禁;实测 `lint.sh` exit 0 无实害。提交历史不动,教训入候选。
- **P3-6(无法验证项,披露)** libIndexStore dlopen 属「新增私有 API 调用/系统集成」类,按 AGENTS.md 规矩应同一提交在 macos-playbook cookbook 加条目;本机未检出 cookbook(fresh 环境,`/Users/aa00930/Documents/Learn/macos/macos-playbook` 不存在),无法核验条目是否已加。派发方若本地有检出,reflect 收尾时补核。
- **P3-7(口径清场残余)** `docs/guardrail-backlog.md:14-17` ripwire 适配条目的动机句仍以「affected-tests.sh 的 grep 映射是妥协」为现在时背景(主选择器现已是索引闭包,grep 只剩回落角色);`:57-59` 已硬化条目带日期属合法留档。backlog 为活文档,reflect 时顺手改动机句即可。

### 实测验证(全部梯级 4:亲跑 + 退出码)

- 门禁:`sh scripts/lint.sh` exit 0(index-affected.swift 4 条 warning,warning 级不拦,与仓内既有文件同状况);`sh scripts/doc-audit.sh` exit 0;`sh scripts/check-arch.sh` exit 0;`sh scripts/plan-audit.sh` exit 0。
- CLI 退出码语义:`closure` 对 `NemoNotch/NoSuch.swift` → stderr 指名文件 + exit 3 ✓;缺参/坏模式 → usage + exit 2 ✓。`DEVELOPER_DIR=/nonexistent` 下 CLI exit 1(swift 解释器自身起不来,xcrun error)——shell 侧判据是非零即回落(`||`),非 `==3` 才回落,行为仍正确;CLI 头注释「不健康信号 exit 3」不含解释器失败态,知悉即可。
- 传递闭包(本 worktree 索引,WorkspacePath 全等定位):`CompletionToastQueue.swift` → 22 文件 exit 0;**距离-2 实锤**:`AppDependencies.swift` 入闭包而 `rg -c CompletionToastQueue` 于该文件零命中(经 FlashService 传递)。耗时 8.8s 含 swift 冷启动(作者提交信息记主检出索引中位 2.74s;不同索引规模,均远低于全量 2:03 天花板)。
- 端到端索引路径:`sh scripts/affected-tests.sh --files NemoNotch/Services/CompletionToastQueue.swift` → 「选择器=索引闭包(闭包 22 文件,命中测试 6 类)」→ 6 类(CalendarDueDetectorTests, CompletionFlashExternalEntryTests, CompletionToastClickTests, CompletionToastLayoutTests, CompletionToastQueueTests, SettingsSearchTests)→ 57 例通过,exit 0。多出的 3 类均为真实传递链(toast 队列 ← FlashService/CalendarDueMonitor/SettingsSearch),正是需求「c 改动把 c b a 都测一遍」的形状。
- 端到端文本回落:`DEVELOPER_DIR=/nonexistent` 同参数 → 「选择器=文本回落(CLI exit 非零…)」→ 3 类,**索引 6 类 ⊇ 文本 3 类** ✓;回落后的 test.sh 继承污染环境,xcodebuild 挂、0 用例,被零用例守卫 exit 1 响亮拦截——注入坏环境的最终行为是响亮失败,不是静默假绿。
- 健康空闭包:`closure NemoNotch/NemoNotchApp.swift` 实测 ∩ NemoNotchTests = 0 → 对应「全量回落」代码路径(`affected-tests.sh:98-100`,打印闭包规模后 exec test.sh);该分支未实跑全量(评审约束),依代码 + 作者提交信息(分支③实锤)。
- probe 诊断:units 668,repo swift 262/262 有 record(100%;我两次 xcodebuild test 刷新了索引,作者时点 253/262),dep kinds kind1=3206/kind2=11077。
- 无参形态(feat-done 真实调用):本分支无 `NemoNotch/`|`NemoNotchTests/` .swift 改动 → 「无 Swift 改动」exit 0,与既有语义一致(scripts 改动不触发子集,全量锚点另守)。
- **未独立复现项(披露)**:「索引零 NemoNotchTests 记录 → exit 3」(index-affected.swift:449-451)需要只 build 过的 worktree 索引,本次无该样本;依代码路径与作者提交信息(「分支①首跑实锤 0 类→静默全量」促成该守卫)。逻辑独立于其余已验证路径,风险低。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A(本分支无新增 Swift Testing 测试——工具 feature,守绿即可)。工具自身鉴别力以实跑呈现:索引/文本两路径选出类集**不同且前者真超集**、传递命中(AppDependencies)经 rg 反证为非直连——若选择器到处返回固定值,这两组差异不可能出现。
- [x] **证据纪律**:作者提交信息含可重放声明(253/262 覆盖、2.74s 中位、三分支结果);本次评审逐项亲跑复核,与声明一致(数字差异均有解释:索引刷新至 100%、索引规模不同)。梯队:4。
- [x] **Swift 6 并发**:N/A 级——纯脚本单线程,无隔离标注需求;`@convention(c)` 非捕获回调 + `Unmanaged` 上下文传对象的模式正确(`passUnretained` 对象在同步 apply 期间被调用方持有);垫片静态缓冲/全局函数指针的非线程安全已在注释声明(单线程脚本)。无 `@unchecked Sendable`/`nonisolated(unsafe)`。
- [x] **最小改动**:二级文本匹配整段原样保留(diff 只重排头部注释);test.sh 零改动;`.swiftlint.yml` 单行删除且为必要条件(scripts 下有 .swift 却被排除时门禁覆盖不到——但见 P3-5 的影响面陈述失实)。
- [x] **错误路径**:实测全谱——无索引/CLI 非零→回落并打印原因类目;usage→exit 2;健康空闭包→全量+打印规模;幽灵类/环境坏→零用例守卫 exit 1 响亮。无吞错导致的静默假绿(吞 stderr 只是诊断降级,P3-3)。
- [x] **坑总目录对照**:AGENTS.md 工具与探针节(按查询类型选工具/ast-grep 零匹配/ripwire 边界)与本工具定位不冲突;dlopen 先例(SecKeychainSetUserInteractionAllowed、SkyLight)有引用;「禁手挑 --only 类名」「宁多跑不漏跑」原语义保留并被新两级继承。
- [x] **教训候选**:见下节。
- [x] **文档同步**:AGENTS.md 测试节两级化描述与实现一致(含 exit 3 语义、跑一次测试自愈、v1 不信空);README 未动(开发工具,非用户可见功能,合理);doc-audit 绿(手册引用的 `scripts/index-affected.swift` 存在)。
- [x] **工作流机制清场**:全仓 grep 旧口径(`顶层符号`/`affected-tests`)——AGENTS.md 主口径已更新;guardrail-backlog 两处为历史留档/背景性提及(P3-7);review.sh/test.sh 仅引脚本名无口径描述;旧 plan 文档为当时事实叙事,合法。

## 教训候选

- **「历史首次」类断言先查 git log 再写进提交信息**(P3-5 实锤:「历史上 scripts 无 .swift」被 `git log --follow scripts/generate-app-icon.swift` 一条命令推翻)。判据:提交信息里的事实性陈述(首次/最末/唯一)与代码改动同级,须过证据梯子,不能凭印象。
- **DEVELOPER_DIR 是进程环境,不是单命令开关**:用它屏蔽做回落实验会污染回落路径 exec 出的 test.sh/xcodebuild(本次实测 xcrun error → 零用例守卫拦下)。判据:验证回落触发用「不污染环境的触发」(如 `--files` 指向未构建文件让 CLI exit 3),或明确接受污染只断言选择器行、不断言子进程测试结果。
- **Swift `@convention(c)` 表达不了按值返回的 C 小结构体**(indexstore_string_ref_t):C 垫片把小面翻成「纯指针+标量+调用方缓冲区」是可复用解法(scripts/index-affected-shim.c,含 mtime 缓存的按需编译)。这是 cookbook 候选条目(与 P3-6 同一去向)。
- **闭包选择器的新鲜度窗口比 spec 论证的还安全**:改动文件全体是 BFS 种子,「未构建的新引用关系」必然由加引用的文件(本身在种子集)兜住——漏跑要求存在既未被改动、又未在索引中的中间层文件,结构性不可能。此论证值得随 AGENTS.md 那句「旧图偏安全」留存,防止未来重构把种子集收窄成「单个文件」。
