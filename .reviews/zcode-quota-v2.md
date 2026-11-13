# Code Review — feature/zcode-quota-v2

Reviewer: 独立评审子代理(zcode / GLM-5.3,未参与开发,judge ≠ author)
Date: 2026-11-13
Reviewed-Head: c1df4c3
Verdict: CHANGES_NEEDED
Scope:  7 files changed, 338 insertions(+), 8 deletions(-)

```
AGENTS.md
NemoNotch/Services/UsageQuotaService+Keychain.swift
NemoNotch/Services/UsageQuotaService+Zcode.swift
NemoNotch/Services/UsageQuotaService.swift
NemoNotch/Services/ZcodeUsageReader.swift
NemoNotchTests/ZcodeUsageReaderTests.swift
docs/superpowers/plans/2026-11-13-zcode-quota-enc-v2.md
```

## Findings

### P1

无。两条铁律逐条验过:Keychain 全程静默(keychainBlob 是既有函数仅加 account 默认参数,三层 no-UI 防护[LAContext.interactionNotAllowed + kSecUseAuthenticationUIFail + SecKeychainSetUserInteractionAllowed(false) 包裹]原样生效,失败即 nil,无任何交互读路径);不写钥匙串(SecItemAdd/SecItemUpdate 全仓零匹配)、不做授权按钮(zcode 的 fetch 永不产生 .needsAuthorization,UI 两处 authorizeButton 均以该状态为挂载条件 → 永不出现)、不碰 zcodejwttoken(零匹配)。

### P2

1. **钥匙串 key 不可用时配额显示「读取中」而非计划验收 2 承诺的「凭据失效」,且该场景不发 API 请求、验收 2 描述的「日志一行 API 401」也不会出现** — `NemoNotch/Services/UsageQuotaService+Zcode.swift:12-18` + `NemoNotch/Services/UsageQuotaService.swift:124-127`。链路(代码级推演,梯级 2):v2 条目在、key 读不到(ACL 拒绝/条目缺失)→ `zcodeBearerToken()` 返 nil → `fetchZcodeQuotaIfPresent` 返 nil → `refresh()` 的 `quotas = next` 整体替换**清掉** .zcode 旧值 → detail 卡 `statusKey(nil)` 永久显示 `quota.status.reading`(「读取中」——永远不会完成,是欺骗性状态);已批准 plan 的验收 2(「手动把钥匙串访问拒掉(或删 key 模拟):配额块显示『凭据失效』状态…日志一行 API 401」)在该实现下不可达。同族:HTTP 非 200 与网络错误两处 return nil 也会清掉已显示的配额(这正是原症状「无声消失」的机制,只修了信封 code!=200 一条)。修法(一行级):token 不可用时返回带状态的 ProviderUsageQuota(如 `.parseError` + errorMessage "v2 key unavailable",或 `.expired`),对齐 Codex 失败也返回状态对象的既有模式;UI 走既有文案,零 UI 改动。证据完备度披露:未跑 app 实测渲染(梯级 5 缺),UI 链为代码级核对(statusKey/挂载条件逐行读)。

2. **affected-tests 门禁漏跑本 feature 的新守卫(过程假绿,已被人工兜住)** — `scripts/affected-tests.sh:80` 的「文件名即类名」约定:闭包命中 `ZcodeUsageReaderTests.swift` 后只生成 `ZcodeUsageReaderTests` 一个类名,同文件的 `ZcodeCredentialsV2Tests`(5 例)与 `ZcodeQuotaEnvelopeTests`(3 例)不在 `--only` 内。实测(梯级 4):affected-tests 跑 51 用例全绿,但 build/test.log 中两个新 suite 名零匹配——新守卫一次都没执行;评审员直接 `--only ZcodeCredentialsV2Tests,ZcodeQuotaEnvelopeTests` 补跑,9 用例通过(退出码 0)。这正是 AGENTS「--only 选错类的假绿出过实案」的再现,本次靠作者手动 mutate + 评审补跑才没有假绿合入。修法:affected-tests.sh 映射测试文件时提取文件内**全部**顶层 suite 名(如 grep `^@Suite` 或 `^struct .*Tests\b`),不只 basename——共享基建改动,可走独立小 feature 或 guardrail-backlog,不阻塞本分支,但合入前应有人认领。

### P3

1. **HTTP 非 200 分支没走状态迁移日志** — `NemoNotch/Services/UsageQuotaService+Zcode.swift:26` 仍是裸 `LogService.warn("zcode quota: HTTP …")`:上游 5xx 时回到每 5 分钟刷同一行的老毛病(本 feature 刚为 apiError/parse 分支建立的纪律漏了这条)。修法:同走 `logQuotaStateTransition("HTTP \(code)")`。
2. **AGENTS.md 旧口径引语残留** — Usage quota 段加粗引语「**zcode/Codex/Gemini 配额路径保持现状是同一次拍板,一行不动**」仍在,其后 zcode 部分已整体改写为 v2 口径,自相矛盾(违反「推翻旧口径 ⇒ 清残留」原则)。修法:引语改为「Codex/Gemini 保持现状;zcode 已于 2026-11-13 跟随 v2」之类。
3. **README.md:38 / README_CN.md:38 未同步** — zcode 凭据描述仍是「解密 CLI 本地凭据文件」,未提 v2 钥匙串路径与凭据失效状态;描述不算错但行为已扩展,顺手补一句即可。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:通过。roundTrip 与 CLI 同构 seal 对拍;tamperedFingerprintRejected 直接刻画指纹 guard 的唯一可观察行为(正确 key + 真密文 + 坏前缀必须拒,注释明说「没有 guard 这会解密成功」);apiErrorExtracted 断言字面 code/msg。mutate 复核:`envelope.code != 200 → false` 变异被抓住(apiErrorExtracted 变红,退出码 0,文件已恢复)——声明有牙属实。
- [x] **证据纪律**:通过。提交信息声明 mutate×2 并如实披露「指纹 guard 变异存活暴露盲区后补篡改用例」;评审复核其一属实。
- [x] **Swift 6 并发**:通过。keychainBlob 沿用 Codex 既有模式(MainActor 同步调、快、no-UI 包裹;全局 interaction toggle 在 MainActor 串行下无竞态);sqlite 读取仍 Task.detached(镜头⑤与既有调度一致)。
- [x] **最小改动**:通过。keychainBlob 只加默认参数不破坏既有调用点;每行可追溯;无顺手改动。
- [x] **错误路径**:部分通过——信封错误/parse 失败/迁移日志到位;HTTP 非 200、网络错误、key 不可用三处仍 return nil 且前一处日志不迁移(P2-1、P3-1)。
- [x] **坑总目录对照**:通过。Keychain 节铁律全程静默守住(镜头①);Usage quota 节口径已更新(doc-audit 退出码 0);日志 transition 制与 lastClaudeQuotaLogState 同款。
- [x] **文档同步**:AGENTS 已更但有 P3-2 引语残留;README 轻微未同步(P3-3)。
- [x] **专项镜头**:①全程静默 ✓(三层 no-UI,失败 nil,无交互读);②v2 格式与逆向事实一致且经真实数据梯级 4 验证(钥匙串 acct=SHA256(路径).hex 逐字节吻合;api-key 条目 enc:v2:os: 前缀被前后缀规则命中;指纹=SHA256(key).hex[:24] 与真实密文前缀 `0319d0c6…` 同构);③刻意不做三项全部未做 ✓;④.expired 走既有 `quota.status.login_required` 文案,EdgeBar 块省略无数据 provider 是其注释声明的既有设计(状态在 AI tab 卡解释)✓;⑤与 keychainBlob 既有调用同为 MainActor 同步,一致 ✓。

## 门禁验证(评审亲跑,退出码为证)

- `sh scripts/lint.sh` → 0(仅存量 warning)
- `sh scripts/doc-audit.sh` → 0
- `sh scripts/check-arch.sh` → 0
- `sh scripts/affected-tests.sh` → 0(51 用例;**不含新 suite**,见 P2-2)
- `sh scripts/test.sh --only ZcodeCredentialsV2Tests,ZcodeQuotaEnvelopeTests` → 0(9 用例,补覆盖)
- `sh scripts/mutate.sh … 'envelope.code != 200' 'false' --only ZcodeQuotaEnvelopeTests` → 变异被抓住,0(文件已恢复,`git status` 仅 .reviews 模板)

## Verdict 说明

CHANGES_NEEDED 的唯一必修项是 **P2-1**(一行级改动:key 不可用返回带状态对象而非 nil,兑现计划验收 2)。P2-2 是共享基建缺口,不阻塞本分支但须认领(教训候选已记)。P3 按仓规默认不修(P3-2 一行文档可顺手)。修完 P2-1 后 `--prompt --prev c1df4c3` 增量复审即可。两条用户拍板的修复(P1 错误分类、P2 v2 跟随)本身实现正确、守卫有牙、真实数据验证通过——修的是边界场景的状态完整性,不是主路径缺陷。

## 教训候选

- **affected-tests 的「文件名即类名」约定 vs Swift Testing 一文件多 suite**(`scripts/affected-tests.sh:80`):在既有 *Tests.swift 里新增非同名 @Suite 时,--only 会静默漏跑它,门禁绿灯照常。判据:映射测试文件时应提取文件内全部顶层 suite 名(可 grep `^@Suite`/`^struct .*Tests\b` 门禁化)。建议进 guardrail-backlog 排期硬化。
- **计划验收条款要按路径拆开写**:验收 2 把「拒钥匙串 → 显示凭据失效」与「日志 API 401」写进同一条,实际是两条互斥路径(key 读不到则根本不发请求)。写计划时对每个故障路径单独问一遍「用户看到什么 / 日志记什么」,可避免验收条款自相矛盾与实现漏项。
