# Code Review — feature/external-toast-api

Reviewer: 评审员-第2轮(独立会话,未参与开发;judge ≠ author;第1轮为另一独立会话,记录原样保留在下方)
Date: 2026-11-01(第2轮,补审修复提交 eb3aeb7)
Reviewed-Head: eb3aeb7
Verdict: APPROVED
Scope:  第1轮 20 files/1214 insertions @ ca012f7;修复提交 eb3aeb7(13 files,+126/−28);累计 develop...feature = 22 files,1313 insertions

> 轮次索引:第1轮 Verdict: CHANGES_NEEDED @ Reviewed-Head: ca012f7(见下节原记录);
> 第2轮核验全部意见修复 + 回归后翻 APPROVED @ Reviewed-Head: eb3aeb7(见文末第2轮节)。

## 第 1 轮(原记录,Reviewer: 评审员-第1轮;Reviewed-Head: ca012f7;Verdict: CHANGES_NEEDED——正文原样保留)

```
AGENTS.md
NemoNotch/Helpers/AppDependencies.swift
NemoNotch/Models/AppSettings.swift
NemoNotch/Models/ExternalToastPayload.swift
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/ExternalCardService.swift
NemoNotch/Services/HookServer.swift
NemoNotch/Settings/Pages/AlertsSettingsPage.swift
NemoNotchTests/AppSettingsExternalToastTests.swift
NemoNotchTests/CompletionDetectorTests.swift
NemoNotchTests/ExternalCardServiceTests.swift
NemoNotchTests/ExternalToastPayloadTests.swift
NemoNotchTests/HookServerRouteTests.swift
README.md
README_CN.md
docs/superpowers/plans/2026-11-01-external-toast-api.md
docs/superpowers/specs/2026-11-01-external-toast-api-design.md
```

## Findings

- **[P2] `NemoNotch/Settings/SettingsSearchIndex.swift:20-27`** — 新开关的三个 key
  (`settings.external_toast.header/enabled/hint`)未登记进设置搜索索引:`.alerts` 页条目列了
  该页其它所有 toggle key,搜索(`SettingsView.swift:237-239`,唯一数据源是
  `SettingsSearchIndex.matchingPages`)搜「external / 外部」找不到新开关,与既有每个 toggle 都
  可被搜到的平权破缺(对照 `settings.notificationToast.enabled` 在 `:41` 有登记——正是 plan
  叫抄写的范本)。修法:把三 key 加进 `.alerts` 的 keys 数组(xcstrings 两语言已在,登记即生效;
  SettingsSearchTests 不枚举页内条目,零测试改动)。
- **[P3] `NemoNotch/Notch/CompletionToastView.swift:269-272`** — `sf:` 后跟不存在的 SF Symbol
  名渲染为空白图标而非 spec 意图的「通用卡片图标」降级(契约只定义格式级合法,实现照 plan 字面
  `Image(systemName:)`;实现者已 deferred)。建议渲染前 `NSImage(systemSymbolName:)` 存在性
  探测,缺失回落 `app.dashed`。
- **[P3] `NemoNotch/Models/ExternalToastPayload.swift:114,133`** — 空 key 字符串按无 key 处理
  (parse 归一 + cardKey 双层防守)无专属单测钉住;plan 接口文本「非空且非空串」支持当前行为,
  但该契约目前只靠双层冗余各自成立,删任一层测试仍绿(实现者已 deferred)。
- **[P3·披露] 端口回落场景未实测** — `writePortFile`(HookServer.swift:467-483)读 `tryNextPort`
  已变更的 `port`、`.ready` 只在回落成功后触发,代码路径自洽;但「真机占用 45831 → 文件反映
  45832」未制造实测,证据梯级 2-3(实现者风险清单已如实自报,非隐瞒)。

### 偏差核验(实现者 ledger 八项,逐条独立复核——全部成立,不构成 finding)

①`ExternalToastRejection` 补 `Error`:Swift `Result` 的 Failure 必须 conform Error,plan 字面签名
编译不过(ExternalToastPayload.swift:26)。②`cardKey` 默认参数 `{ UUID().uuidString }`:plan 字面
`= UUID().uuidString` 是 String 非闭包,类型不匹配(ExternalToastPayload.swift:132)。③缺 schema 键
→ `.badSchemaVersion`:raw DTO 用 `Int?`,拒绝枚举无专属 case;HTTP 仍 400,契约不破(本评审 e2e
实测 `{"schema":2,…}` → 400)。④空 key 按无 key:plan Task 1 接口原文「`key` 非空且非空串 → keyed;
否则 unique」——实现即 plan,不算偏离。⑤测试名去 `testXxx`:全套件无一用前缀,仓库惯例赢。⑥
`ExternalCardService` 不加 `@Observable`:plan 签名只给 `@MainActor`,服务无可观察状态。⑦Task 5
Step 1 红不可达:字段按 plan Task 3 自己的 Interfaces 落地,时序上无法先红。⑧400 reason 经
`JSONSerialization` 编码(`toastErrorBody`,HookServer.swift:546-553):防注入加固,e2e 实测响应体
`{"reason":"Malformed JSON body","status":"error"}` 合法 JSON。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:有牙。三个守卫我亲跑变异:①merge 保留旧 external 卡
  (`merged.external = older.external`)→ CompletionDetectorTests 变红 1(mutate exit 0);
  ②`externalToastEnabled` 门禁取反 → 3 红(mutate exit 0);③实现者自报的 app 48 上限 /
  400 映射 / `::` 分隔符三变异 exit 0(ledger)。注意:我第一次变异
  (`item.external ?? older.external`)存活——item.external 非-nil 时 `??` 短路,该变异对被测输入
  是语义 no-op,不构成护栏无牙的证据;换真回归即被抓。新测试全部以具体 JSON 输入断言字面
  输出/呈现次数,非自指。
- [x] **证据纪律**:提交信息含真实退出码与 e2e 输出(Task 4 commit body 记 200/401/400 与端口
  文件实测);我复跑 affected-tests(107/0,exit 0)、lint(exit 0)、doc-audit(exit 0)、
  check-arch(exit 0)、xcstrings check(canonical,exit 0),并在部署后的真 app 上复跑 e2e 六条
  curl(见下证据节)。
- [x] **Swift 6 并发**:`ExternalToastPayload`/`ExternalToastRejection`/`ExternalToastAcceptance`
  全 Sendable 纯值;`HookServer` @MainActor,`processRequest` 经 `Task { @MainActor }` 入 MainActor
  (HookServer.swift:249-252),`onExternalToast` 闭包在 MainActor 上设与调,
  `ExternalCardService.handle` @MainActor 无跨隔离调用;`toastResponseStatus`/`toastErrorBody`
  nonisolated static 供测试。无 Sendable 边界违规。
- [x] **最小改动**:diff 每行可追溯到 plan 五任务;无顺手改动邻近代码(diff 里零删改既有行,
  CompletionToastView/CompletionDetector 均纯新增 case/字段);文档三处(README×2/AGENTS)同步。
- [x] **错误路径**:401/400/500(未接线防御)全响亮并记 `.warn`/`.error`;`writePortFile` 失败
  `.error` 日志;`parse` 失败 `.rejected` 不吞;门禁关静默 `.ok` 是 plan 规定语义(调用方无错)。
- [x] **坑总目录对照**:HookServer 区——hook-port 写入与 `setHookServerPort` 同处、同受
  `ownsSharedHookConfig` 门禁(HookServer.swift:131-133),不踩测试宿主污染坑;toast 区——外来卡
  复用既有队列无新增动画/隐藏手段,check-arch B 档过;通知卡先例(自有开关、不走辉光)照搬正确。
- [x] **教训候选**:见下小节。
- [x] **文档同步**:AGENTS「Hook 端口与发送脚本」节新增 `/v1/toast` + hook-port 两行事实(未动
  doc-audit 断言字符串,doc-audit 实跑 exit 0);README/README_CN 对称新增功能条目 + API 小节,
  curl/字段表与 spec 一致。

### 教训候选

- **设置搜索索引登记漂移**(`SettingsSearchIndex.swift:20-27` vs `AlertsSettingsPage.swift:19-29`):
  新增 Settings 页 section 时,搜索索引是独立文件、编译器不强制,漏登记无任何报警——本次 P2 与
  历史 87fd2af(search index follow-up)同型。判据:**「Settings/Pages 里引用的 `settings.*` key
  必须出现在 SettingsSearchIndex 相应页的 keys 里」可机器判定**(grep 页源码提取 key ↔ 索引对账),
  建议进 `scripts/check-arch.sh` A 档或 doc-audit,收尾 reflect 分流进 guardrail-backlog。
- **`??` 短路变异是 no-op 陷阱**(评审自身过程教训,写给后续 mutate 使用者):对非 nil 左值的
  `x ?? y` 变异不会改变行为,变异存活≠护栏无牙;变异要先确认对被测输入语义承重。

## 评审方法与证据(本会话亲跑,退出码为准)

在 worktree `.worktree/external-toast-api`(head ca012f7)执行:

- `sh scripts/affected-tests.sh` → **exit 0,107 通过 / 0 失败**(含全部 6 个新测试类,选择清单见
  build/test.log)。
- `sh scripts/lint.sh` → **exit 0**(仅存量 HookServer.swift:235 closure_parameter_position 警告,
  error 级门禁不拦,非本分支引入);`python3 scripts/xcstrings.py check` → **canonical,exit 0**。
- `sh scripts/doc-audit.sh` → **exit 0**;`sh scripts/check-arch.sh` → **exit 0**。
- 变异验证(亲跑):merge 保旧卡 → **exit 0(红,1 失败)**;门禁取反 → **exit 0(红,3 失败)**;
  `item.external ?? older.external` → exit 1(存活,但为语义 no-op 变异,见教训候选)。
- **e2e(梯级 5,部署后的真 app)**:运行中 pid 98441 为本分支构建(hook-port 文件由其启动后 2s
  自写,mtime 对齐;`lsof` = `IPv4 127.0.0.1:45831` LISTEN,回环钉住未回归)。六条 curl:
  合法 keyed 推送 → `{"status":"ok"}` HTTP 200;同 key 二推 → 200(队列同 key 就地刷新 + 重置计时
  另由单测 keyedPushesShareCardKey + CompletionToastQueue.add 代码路径钉住);无令牌 → 401
  `{"status":"unauthorized"}`;`schema:2` → 400 `{"reason":"Unsupported schema version",…}`;
  `app`/`key` 含 `::` → 400 各一;`not json` + 令牌 → 400 合法 JSON reason 体。
  卡面视觉渲染本轮未独立截图复核(实现者 Task 4 commit body 有截图证据;渲染代码 + 队列单测 +
  200 响应链已覆盖),此为披露的证据边界。
- plan 忠实度:五任务逐个对照(diffstat 与 plan 文件清单一致,Task 1/4/5 逐 commit stat 核对);
  提交信息 = plan 规定信息 + 任务号后缀;plan 勾选独立成 commit(ca012f7 只动 plan 文件)。
  实现未越出 plan 加改动;八项偏差全部 ledger 记录且经我独立复核成立(见上文偏差核验节)。

**Verdict 理由**:实现质量高、契约纪律(execution 面零语义翻译、缺省即清空、401/400 响亮、
门禁语义)全部落实且证据链扎实;但 P2(搜索索引漏登记)是用户可见的功能缺口且修法一行,
应修后再合——修完登记 Reviewed-Head 更新即可翻 APPROVED,其余 P3 不阻塞。

---

# 第 2 轮评审(评审员-第2轮,独立会话;Reviewed-Head: eb3aeb7)

修复提交 `eb3aeb7`(13 files,+126/−28)逐条对照第 1 轮 Findings 核验 + 全量回归。本节所有
命令与退出码均在本会话于 worktree `.worktree/external-toast-api`(head=eb3aeb7)亲跑。

## 上轮意见逐条核验

| # | 上轮意见 | 级 | 核验结果 |
|---|---|---|---|
| 1 | 搜索索引漏登记 external_toast 三 key | P2 | **已修**:`SettingsSearchIndex.swift:23` 三 key 进 `.alerts` 数组;xcstrings en+zh-Hans 值在且含 "External/外部"(亲查 JSON);SettingsSearchTests 在 affected 套件内绿 |
| 2 | keyed 重推缺 jumpBundleId 旧 jump 存活 | P2 | **已修**:`CompletionDetector.swift:238-242` `.external` 来源 jump 整卡替换(AI 会话 nil-保旧走 else 不变,`mergeKeepsJump` 绿);`mergeReplacesExternalPayloadWholeCard` 扩断言 `merged[0].jump == nil` 与 `external?.jumpBundleId == nil`;变异 `if case .external`→`if false` 被抓住(红 1/14,mutate exit 0)——护栏有牙,我亲跑 |
| 3 | sf: 不存在符号名渲染空白 | P3 | **已修**:`CompletionToastView.swift:269-279` 渲染前 `NSImage(systemSymbolName:)` 探测,缺失回落 `app.dashed`。渲染层无单测(视图代码,仓库惯例只测纯逻辑);真 app 推送 `sf:definitely-not-a-real-symbol` 200(像素未截图,梯级 2+5 部分披露) |
| 4 | 空 key 行为无专属单测 | P3 | **已修**:`emptyKeyTreatedAsAbsent` 断言 `payload.key == nil` 且 `cardKey == "ext:Demo::u1"` |
| 5 | 端口回落未实测 | P3 | **已记录**:实现者在 eb3aeb7 提交信息 + plan 偏差节记录真机实测(占 45831 → hook-port=45832、释放自愈回 45831)。**本人未独立复跑**(需杀掉用户正在运行的 app 重启,越出评审边界);代码级论证第 1 轮已核(writePortFile 读 tryNextPort 已变更 port,.ready 在回落成功后触发),梯级 2-3 + 实现者运行实证声明,如实披露 |
| 6 | detector 假约束句 | P3 | **已删**:`CompletionItem.external` 注释只留 "Whole card face for an external-app push" |
| 7 | 叙事注释五处(MUST KILL) | P3 | **全删**:ExternalCardService:16-18、ExternalToastPayload:54、AppDependencies:127-128、HookServer:357-358、CompletionToastView:148(只留 "Mirrors noticeText" 指路),diff 逐一核对 |
| 8 | 空 key 未在 README 披露 | P3 | **已修**:README/README_CN key 行补 "an empty string is treated as absent / 空串视为未提供" |
| 9 | jumpBundleId 无长度上限 | P3 | **已修**:`ExternalToastPayload.swift:113-115` ≤255(`.jumpBundleIdTooLong`),256 拒/255 过两边界测试在;变异 `> 255`→`> 256` 被抓住(红 1/13,exit 0);README×2 同步 ≤255 |
| 10 | 外来入口绕门禁/不辉光零覆盖 | P3 | **已修**:新增 `CompletionFlashExternalEntryTests`(completionFlashEnabled=false 仍入队 + flashLevel==0 + overlayVisible==false);变异把 `addToasts` 挂到 `settings.completionFlashEnabled` 下被抓住(红 1/0,exit 0)——正是"改道被门禁吃掉"的未来回归形状 |
| 11 | 偏差①–⑧未落档 | P3 | **已修**:plan 尾部「实现偏差记录」节(8 项 + 评审修复清单)随 eb3aeb7 提交 |

## 第 2 轮新 Findings

- **[P3] `docs/superpowers/plans/2026-11-01-external-toast-api.md:200`** — 偏差节开头括注
  「完整过程见 .superpowers/sdd/2026-11-01-external-toast-api/progress.md」:`.superpowers/` 被
  gitignore(`git check-ignore` → IGNORED;`git ls-files .superpowers` → 0 文件),fresh clone 里
  该指针悬空。偏差实质内容已全量提交在本节内,证据链未断;建议删掉括注或标注为本地过程工件,
  非阻塞。

## 回归检查(本会话亲跑)

- `sh scripts/affected-tests.sh` → **exit 0,108 通过 / 0 失败 / 0 跳过**(18 类,含全部
  7 个新/守卫测试类;日志 build/test.log,grep 计数 108 passed / 0 failed / 0 skipped)。
  注:实现者 eb3aeb7 提交信息写 109/0,与实测差 1(两轮均 0 失败,非实质)。
- `sh scripts/lint.sh` → **exit 0**(警告全为存量文件,非本分支新增)。
- `sh scripts/doc-audit.sh` → **exit 0**;`sh scripts/check-arch.sh` → **exit 0**;
  `python3 scripts/xcstrings.py check` → **canonical,exit 0**。
- 变异三连(全部被抓住,文件经 trap 恢复,`git status` 复核干净):
  ①merge `.external` 分支 → `if false`:红 1/14;②`showExternalToast` 入队挂到
  completionFlashEnabled:红 1/0;③`jumpBundleId > 255` → `> 256`:红 1/13。均 `sh scripts/mutate.sh …` exit 0。
- **e2e(梯级 5,部署后的真 app)**:部署二进制 mtime 16:21 > 修复提交 16:17(含 eb3aeb7);
  `lsof` = `IPv4 127.0.0.1:45831` LISTEN(回环钉住未回归),hook-port 文件=45831 一致。
  亲跑 curl:256 字符 jumpBundleId → **400** `{"reason":"jumpBundleId exceeds 255 characters","status":"error"}`;
  255 字符 → **200**;keyed + 未知 sf 符号名 → **200**(卡上屏);误用 Bearer 头 → **401**
  (顺带复核 401 路径;正确头是 README 的 `X-NemoNotch-Token`)。sf 回落像素与 jump 清空点击
  行为未独立目验(渲染层/交互层),由代码 + 单测 + 变异覆盖,如实披露。
- 忠实度:eb3aeb7 是评审响应提交,超出 plan 五任务但必要且提交信息逐条给了理由与证据;
  plan 无裸框(`grep -c '\- \[ \]'` = 0);分支未 rebase(第 1 轮提交 bba5cec…ca012f7 SHA 不变,
  eb3aeb7 直接叠加)。

**Verdict 理由(APPROVED)**:第 1 轮两条 P2 均已修复且各有"测试钉死 + 变异验牙"双保险;
接受的 P3 全部落地(上限、披露、钉子测试、注释清理、偏差落档),拒绝项为零并明说;全量回归
绿(108/0)、四道门禁绿、三个新守卫变异全红、部署后真 app 边界行为实测吻合。唯一新发现为
plan 文档里一处悬空指针(P3,非阻塞)。合并前提醒:**本评审记录当前未提交**——feat-done 的
评审门禁读 `HEAD:.reviews/external-toast-api.md` 首个 `Verdict:`/`Reviewed-Head:` 行,需由
实现者 `git add .reviews/external-toast-api.md && git commit` 后门禁方可核对 eb3aeb7。
