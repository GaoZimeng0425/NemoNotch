# Code Review — feature/zcode-quota-authorize

Reviewer: ZCode 独立评审子代理(judge ≠ author,未参与开发)
Date: 2026-11-13
Reviewed-Head: 2521b53
Verdict: APPROVED
Scope: 4 files changed, 95 insertions(+), 18 deletions(-)

```
AGENTS.md
NemoNotch/Services/UsageQuotaService+Keychain.swift
NemoNotch/Services/UsageQuotaService+Zcode.swift
NemoNotchTests/ZcodeUsageReaderTests.swift
```

## Findings

- **[P3]** README.md:38 / README_CN.md:38 — zcode 配额句未提新增的 Authorize 按钮与一次性系统授权框。自动路径的描述仍真(定时器确实绝不弹窗),但用户可见行为变了(新增授权按钮)而 README 未跟上;减轻项:Codex 的 Authorize 按钮(f29c67d)当年同样未进 README,属仓库既有粒度。修法:38 行 zcode 句尾补一句「钥匙串访问未授权时配额卡提供『授权』按钮,点击弹一次系统授权框后恢复静默读取」(en/zh 两处,≤3 行机械项,可顺手)。
- **[P3]** NemoNotch/Services/UsageQuotaService+Zcode.swift:142 — `padding(toLength: 44, ...)` 按 NSString padding 语义会截断超长输入:>44 字符的合法字母表串截成 44 后可能解出恰好 32 字节并通过校验。CLI 固定写 43 字符 base64url,实际不可达;如要收紧可先 `guard b64.count <= 44`。
- **[观察,上一 feature 范围,不要求本分支处理]** NemoNotch/Services/ZcodeUsageReader.swift:244-246 — `accessToken()` 走 v1 decrypt,值若是 `enc:v2:`(本机实测 `oauth:bigmodel:access_token` 现已是 v2 加密)会因前缀不符原样返回密文当 token → API 401 → 「需要登录」。仅在 credentials 文件没有 api-key 条目时触发;本机真实文件 api-key 条目存在,不触发;AGENTS 已有「legacy 过期即 401」口径。
- **[观察,流程]** 本 feature 无独立 plan 文档(docs/superpowers/plans/ 只有上一 feature 的 2026-11-13-zcode-quota-enc-v2.md);plan-audit 只查本分支动过的 plan,不会拦。派发事实称用户已拍板,流程问题归派发方。

## 验证证据(全部亲跑,引用真实退出码)

| 命令 | 退出码 | 结果 |
|---|---|---|
| `sh scripts/lint.sh` | 0 | swiftformat + swiftlint 通过(仅既有 warning) |
| `sh scripts/doc-audit.sh` | 0 | 文档对账通过 |
| `sh scripts/check-arch.sh` | 0 | A 档全仓 + B 档本分支全部通过 |
| `sh scripts/affected-tests.sh` | 0 | 索引闭包选 ConsoleOrderTests/EdgeBarAlertCardsTests/ZcodeUsageReaderTests,20 用例全过 |
| `sh scripts/test.sh --only ZcodeKeyringKeyDecodeTests,ZcodeQuotaEnvelopeTests` | 0 | 4 用例全过(手动补跑) |
| `sh scripts/mutate.sh UsageQuotaService+Zcode.swift "key.count == 32" "key.count == 31" --only ZcodeKeyringKeyDecodeTests` | 0(变异被抓) | 测试退出码 65,套件变红;文件已恢复 |
| `sh scripts/mutate.sh ... "key.count == 32" "key.count >= 0" ...` | 0(变异被抓) | 负向长度断言同样有牙 |
| `git status --short` | — | 仅 review.sh 生成的模板 untracked,代码零改动 |

真实环境取证(梯级 4):
- `security find-generic-password -s "ZCode Credential Encryption"`(attributes 查询,只读不弹窗):条目实存,`acct = 51b0ace5…8ec8`,与 `SHA256("/Users/aa00930/.zcode/v2/credentials.json")` 逐位一致 — authorize() 交互读与自动静默读共用同一 service+account 寻址(UsageQuotaService+Zcode.swift:112-113 与 UsageQuotaService+Keychain.swift:86-88),能命中真实条目。
- credentials 文件实测:`account-provider:…:api-key` 条目存在且 `enc:v2:` 前缀 — `apiKeyIsV2` 门控分支(UsageQuotaService+Zcode.swift:13-16)的真实输入成立。

## 专项镜头结论

1. **authorize() 交互读寻址正确**:service=`"ZCode Credential Encryption"` + account=`SHA256(凭据路径).hex`,与实测条目逐位一致;`interactiveKeychainRead` 刻意不带 `applyNoUI`(UsageQuotaService+Keychain.swift:149-164)→ ACL 未授时弹系统授权框;claude/gemini 在入口被拒(:75-81);Codex 路径 account=nil 行为不变。
2. **自动定时器绝对无弹窗**:granted=false → 只走 `keychainProbe`(attributes-only + `applyNoUI`,:51-69)——attributes 读不弹;granted=true → `keychainBlob` 有双保险(LAContext/kSecUseAuthenticationUIFail + 进程级 `SecKeychainSetUserInteractionAllowed(false)` 兜底,:17-43),弹窗被压成 `errSecInteractionNotAllowed`。经 `git show 80d1e6c` 核对,双保险是 base 既有,本分支未削弱,反而把 base 的无条件 data 读收紧为 grant 门控。
3. **grant 记忆与恢复链闭合**:authorize 成功 → `setKeychainGranted(true, .zcode)`(记 cdhash,:105-116)→ `refresh(force: true)` 绕过 60s 节流 → 下轮 `keychainGranted` 命中 → 静默 data 读;只有 `errSecItemNotFound` 忘授权,瞬时失败保留(UsageQuotaService+Zcode.swift:120-127)——与 AGENTS Keychain 节铁律逐条一致,与 Codex `readKeychainCredential`(UsageQuotaService+Codex.swift:102-140)同构。
4. **decode 细节**:`ZcodeKeyringKeyResult: Equatable` 关联值 `Data` 自动合成 `==`;测试断言具体字节(非自指);base64 字母表本身大小写敏感,替换只动 `-_` 与 padding;新增的 `key.count == 32` 校验是收紧(base 原实现无长度校验)且两个变异证实守卫有牙。
5. **上一 feature 测试未破坏**:ZcodeUsageReaderTests 9 用例 + ZcodeQuotaEnvelopeTests 3 用例全过;diff 对测试文件只增不改。

**无法验证(如实披露)**:授权框真实弹出 + 「始终允许」后静默读恢复的端到端(梯级 5)未做——需要真 GUI 点击系统对话框且铁律禁跑 build.sh;该链路结论基于代码级推理(梯级 2-3)+ 寻址实测(梯级 4)+ 与已上线 Codex 同款模式同构。

## 审查清单(逐项)

- [x] 判别剃刀:decode 测试以具体输入断言字面输出,注释点破「43 个 A 是合法 32 字节」陷阱;两个变异均红 = 有牙。
- [x] 证据纪律:提交信息无自述验证声明;本评审全部脚本亲跑并引用退出码。
- [x] Swift 6 并发:authorize 的 Task.detached 捕获 String?(Sendable),对话框期间不冻结主线程;值类型隐式 Sendable 且只在 MainActor 内流转;测试 suite @MainActor 标注正确。
- [x] 最小改动:4 文件每行可追溯到任务;没顺手改邻近。
- [x] 错误路径:probe .failure → .unavailable → .expired 状态对象;状态迁移日志防刷屏;无吞错。
- [x] 坑总目录对照:Keychain 节铁律逐条对照符合;AGENTS zcode 段口径已同步。
- [x] 教训候选:见下节。
- [x] 文档同步:AGENTS ✓;README 见 P3 第一条(有 Codex 按钮不进 README 的先例,定 P3)。
- [N/A] 工作流机制清场:未触 hooks/scripts/CI。

## 教训候选

- **affected-tests 的「文件名即类名」盲区第二次咬人,建议门禁化**(实测复现:`grep -c ZcodeKeyringKeyDecodeTests build/test.log` = 0)。可硬化方向:affected-tests.sh 对每个命中测试文件 grep `@Suite.*struct (\w+)`,与 `--only` 清单比对,缺的打印警告行。
- **「零打扰」设计断言要先问「用户怎么恢复」**:上一 feature 的 plan「不做重新授权按钮 / 最坏=凭据失效零打扰」部署实测即翻车——ACL 拒绝后用户没有任何恢复路径(重登 CLI 不改 ACL)。判据:写「最坏情况=X」时若 X 是终态且无用户出口,这个「优雅降级」其实是死胡同;降级设计必须附带恢复路径或明确记录「无法恢复」。

---

**Verdict 理由**:代码行为正确且与 Codex 已验证模式同构,三门禁全绿,新守卫变异有牙,钥匙串寻址经真实条目实测逐位一致,AGENTS 口径同步;仅存 P3 文档精度项(有仓库先例)与两条不属本分支范围的观察。我愿意为这个合并背书。
