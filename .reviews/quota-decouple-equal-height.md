# Code Review — feature/quota-decouple-equal-height(增量复审,第 2 轮)

Reviewer: 独立评审子代理(ZCode / GLM-5.3,两轮均为同一独立评审员,未参与开发)
Date: 2026-11-13
Reviewed-Head: 73c00e2
Verdict: APPROVED
Scope(增量): e2eaf88..73c00e2,4 files changed(+74 −14):AIChatTab.swift、UsageQuotaCardView.swift、NemoNotchTests/UsageQuotaTests.swift、docs/superpowers/plans/2026-11-13-agent-monitor-toggle.md

## 零代码漂移检查

`git diff e2eaf88..HEAD -- . ':!.reviews'` 只含上述 4 个预期文件,无评审范围外改动;`git status` 干净,零 git 状态变更,未改任何文件,未跑 build.sh。

## 上轮 Findings 处置核验(逐条,全部亲证)

- **[P1 弹性泄漏] 已修,实证通过**:`AIChatTab.swift:332-335` `.fixedSize(horizontal: true, vertical: false)` → `.fixedSize()`,why 注释准确写入了泄漏机制。修法与本评审上轮探针验证的 fixed 模式逐字等价;探针本轮复跑数字稳定:**两卡 67=67(等高达成)、header 71(不膨胀)、ScrollView 175(列表不被压)**,对照 stretch 模式(119/119/123/123)。两卡上的 `frame(maxHeight:.infinity)` 按计划保留,等高语义不变。
- **[P2 失败测试] 已做,护栏有牙(亲跑 mutate)**:`UsageQuotaCardView.swift:13-34` 抽出 `static func visibleProviders(...)`,详情与 compact 两视图均桥接调用;`NemoNotchTests/UsageQuotaTests.swift:354-380` 新增 `QuotaVisibilityTests`。变异验证亲跑:`sh scripts/mutate.sh NemoNotch/Tabs/UsageQuotaCardView.swift "if hasClaudeSnapshot {" "if false && hasClaudeSnapshot {" --only QuotaVisibilityTests` → `dataPresenceDrivesVisibility` 红、MUTATE_EXIT=0(变异被抓住),文件已自动恢复。
- **[P2 plan 旧口径] 已清**:`plans/2026-11-13-agent-monitor-toggle.md:75-76` 更正注记准确。
- **[P3 死属性] 已删**:详情视图 `@Environment(AppSettings.self)` 移除,文件内无残留引用。

## 门禁与验证(全部亲跑,真实退出码)

- `sh scripts/lint.sh` → exit 0
- `sh scripts/doc-audit.sh` → exit 0
- `sh scripts/check-arch.sh` → exit 0
- `sh scripts/test.sh`(全量)→ exit 0,711 用例通过 0 失败,`QuotaVisibilityTests` 在全量中执行
- `sh scripts/mutate.sh ... --only QuotaVisibilityTests` → exit 0(红=有牙)
- 布局探针复跑:base 67/48/71/175 · stretch 119/119/123/123 · fixed 67/67/71/175

## Findings(增量,均 P3,不阻塞)

- **[P3] compact 副本上方旧口径注释漏清**:`UsageQuotaCardView.swift:247-248`「Providers to surface: Claude when enabled…」与其下新注释字面冲突(详情视图那份已清,compact 这份仍在)。修法:删这 2 行。
- **[P3] static `visibleProviders` 两份完全重复,守卫只钉一份**:card 与 compact 各持一份逐字节相同的实现,测试只调 `UsageQuotaCardView.visibleProviders`——compact 副本若被单独改坏测试仍绿。修法:删 compact 副本,桥接改调共享实现。
- **[P3] compact 的 `appSettings` 链路成死代码**:`:239` 声明 + `:342` popover 注入,详情卡已不读 AppSettings。

## 教训候选(增量)

- **清场声明的核对粒度**:「同类残留顺手清了」要按「命中位置清单」核对——旧注释同文有两份,只清了第一份。
- **抽纯函数防副本分叉**:抽共享逻辑时两个调用点各留一份拷贝,守卫只钉一份,第二份即测试盲区——「两处必须永远一致」的逻辑只允许一份实现。

## Verdict

**APPROVED**——P1 修复与上轮探针验证的修法逐字等价且效果复现,P2 两项落实并经亲跑复核,全量 711 用例绿。三条 P3 均为机械清理,不构成合并障碍。

---

