# Code Review — feature/fix-hookserver-http-framing

Reviewer: 独立评审子代理(judge ≠ author,未参与开发;ZCode 派发,只读 worktree + 仅本记录可写)
Date: 2026-11-02
Reviewed-Head: 46e9d56
Verdict: APPROVED
Scope:  4 files changed, 532 insertions(+), 21 deletions(-)

```
NemoNotch/Services/HookServer.swift
NemoNotchTests/HookServerFramingTests.swift
docs/guardrail-backlog.md
docs/superpowers/plans/2026-11-02-fix-hookserver-http-framing.md
```

## Findings

- **[P2]** `docs/superpowers/plans/2026-11-02-fix-hookserver-http-framing.md:3-11` — 全部 9 个任务框裸着未勾,`sh scripts/plan-audit.sh` 实跑 exit=1,feat-done 会被 plan 全勾门禁拦下(或诱发 SKIP 逃生阀)。修法:合并前把已完成任务(0–6)勾上;任务 7(修后探针,依赖部署)按 plan-audit 允许的形态处理——部署后补跑探针再勾,或勾上并在行尾写明「feat-done post-merge 自动部署后验」的时序原因。纯流程项,不涉代码。
- **[P3]** `NemoNotch/Services/HookServer.swift:394-407` — /hook decode 失败仍回 200 ack(吞错假绿形状保留)。判定为刻意且可接受:hook 语义不许因坏事件挂死 CLI,且本修复后该路径只剩「真发送端中断/真坏 JSON」会走(framing 成因的「截断体被 ack、发送端无感」已消除);已有 .error 日志含 body 字节数与 500 字符 snippet,失败会响。无需本分支动。
- **[P3]** `NemoNotch/Services/HookServer.swift:286-293` — 累积缓冲每收一段就从头重扫 `\r\n\r\n` 并重解析头块(O(chunks×n))。以 2MB 上限 / ≥64KB 单段计最多 ~32 次重扫、memcmp 量级,且旧实现每段做全量 `String(data:)` UTF-8 校验(更贵)——不劣于修前,无需改,留观。

无 P1。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:有牙。8 用例全部字面字节输入 → 断言字面 Bool,零自指。变异亲跑(`sh scripts/mutate.sh NemoNotch/Services/HookServer.swift 'return bodyBytes >= contentLength' 'return true // mutated' --only HookServerFramingTests`):5 红(①②⑤a⑥⑦)/ 3 绿,mutate exit=0,文件 trap 恢复、git 状态干净——恒真变异精确复放旧 bug 本体(头块到齐即完整),5/8 与作者自述一致;反向恒 false 变异下 ③④⑤b⑦-full 亦必红。⑦ 号用例专防「一行字符串修法」回潮(CL 为末位头时该修法仍恒真;curl 8.7.1 实测恒此序,plan 证据链 9),是超出 ask ①–⑥ 与外部报告的增量守卫。
- [x] **证据纪律**:过。plan 证据链 10 条逐条标梯级(2/4/5),单变量隔离探针(分段为唯一变量)、活体日志闭环、202 条指纹审计(119×65312B + 83×65313B,算术 = 65536−224/223 头块);未夯实处明示披露(65312B↔224B 未逐字节对账、802/803B 别类不归因、「行为差异:非 UTF-8 体 挂死→400」)。本评审自身全部结论亲跑:affected-tests 23 通过 0 失败 exit=0;lint / doc-audit / check-arch 均 exit=0;plan-audit exit=1(见 P2)。注:`build/test.log` 已被变异运行与本次局部运行覆盖,「全量 626 通过」未独立复看数字,但 `build/test-head.txt` = dc7a4b6 = HEAD,锚点只由全量绿测写入,是该 head 全量绿过的机械记录。
- [x] **Swift 6 并发**:过。三个新函数均 `nonisolated static` 纯函数、零共享可变状态,`Data`/`Int` 全 Sendable;receive 回调线程直调无需 MainActor hop(@MainActor 类上的 nonisolated static 合法,affected 测试编译+运行即编译器并发检查实证)。Data 切片保留父索引的陷阱用 `distance(from:to:)`/`index(_:offsetBy:)` 规避且有注释(:289-290)。
- [x] **最小改动**:过。diff 严格贴 plan 范围纪律:receive 循环结构 / 2MB 上限 / 413 / 15s deadline / 回环钉扎 / processRequest 体提取逻辑一律未动(仅两处对应关系注释);测试缝仅 private→internal;旧口径注释改写只动归因句、保留「纯函数判定不跳 MainActor」正确论证。
- [x] **错误路径**:过。无 CL → 头块到齐即完整(与旧兜底一致,GET /health 不回归);CL 值解析失败/溢出 → 视同无 CL(文档化,不崩);新的「等全 body」行为被既有 2MB 上限(413)与 15s 请求截止兜住,无新增无界等待——修后服务器会等而修前不会,这两道既有守卫恰好覆盖此新增等待面。非 UTF-8 体从「挂到 isComplete/15s deadline」变「即刻 400」为 plan 明示接受并披露的行为差异(两端点均 UTF-8 JSON)。
- [x] **坑总目录对照**:过。AGENTS.md Hook 端口节(回环钉扎 / hook-port / 外部 toast 红线 / ownsSharedHookConfig)均未触碰;`headerToken` 处既有「\r\n 聚簇」警告注释与本次根因同源——旧 :266 是全仓唯一没躲开的调用点(plan 证据链 2 已引用)。
- [x] **教训候选**:有,见尾部。
- [x] **文档同步**:过。行为变化是恢复应有语义的 bug 修复,无 AGENTS.md/README 叙事漂移;guardrail-backlog 登记三候选齐。旧口径清场彻底:全仓 rg「--max-time」仅剩 HookServer.swift 三处改写后的正确表述 + HookInstaller(:342/:352、HermesHookInstaller:110)与 notch.md 的 curl 事实参数;「died exactly this way」「sender aborted mid-body 为因」类断言零残留(notch.md:165/:650 是 curl 用法事实,非事故归因,正确不动)。

## bug 专项镜头

1. **新测试真钉住行为**:变异重放 5 红(上述,梯级 4 亲跑);且 `git show bc5b25e:NemoNotch/Services/HookServer.swift` 核对——测试提交时被测函数仍是旧 String 实现(仅可见性缝已改),red→green 序列可重放。
2. **修复与根因因果对应**:根因钉在旧 :266 `after.firstIndex(of: "\r")` 恒 nil(Swift 把 \r\n 聚成一个 Character)→ CL 分支死代码 → :273 恒真兜底;新实现零字符语义、纯字节算术。两个症状(两段式客户端 400、>64KB hook 首段 65536B 读即截断)由同一道门解释,65312/65313B 指纹算术闭环;65KB「--max-time 中断」旧归因被诊断席探针证伪(发送端 sendall 全部成功、余体未发服务端即刻回 400)。
3. **旧口径清场**:见文档同步项,零残留。

## 教训候选

- **协议分帧的完整性判定只认字节,绝不走 String/Character 语义**(`NemoNotch/Services/HookServer.swift:286`):Swift 把 `\r\n` 聚成一个 Character 使 `firstIndex(of: "\r")` 恒 nil——这类死代码编译器不报、不碰就永绿;同文件 `headerToken` 注释早已警告此坑而 :266 仍中招,「注释警告 ≠ 防线」。可门禁化:check-arch B 档拦 String 上的 `firstIndex(of: "\r")`/`firstIndex(of: "\n")`(已进 guardrail-backlog 候选 ②)。
- **curl 单段发送,curl-only 验收清单对此类 bug 假绿**(`docs/guardrail-backlog.md` 候选 ③):两段式客户端(URLSession / 原始 socket 头‖体分段)是唯一能暴露分帧门 bug 的形状;外部 toast 的验收清单应补该探针或进 CI。

## 评审方法记录

`git diff develop..HEAD` 全量阅读 + HookServer.swift 关键区(receive/processRequest/常量)全文上下文;全部门禁与测试在 worktree 亲跑并引用退出码(见证据纪律项);未跑 build.sh(会部署,评审禁项)。APPROVED 意为愿意为此合并背书:P2 为流程项、feat-done 前补勾即可,不构成代码改动要求。

## 增量补审(2026-11-02,46e9d56)

- 范围核对:`git show 46e9d56 --stat` 仅 plan 文档 1 文件、9 行,全部为 `[ ]`→`[x]`(零文字改动);`git diff dc7a4b6..46e9d56 -- . ':!.reviews' ':!docs/superpowers/plans'` 为空——**零代码漂移**,dc7a4b6 上的全部验证(变异 5 红 3 绿、lint/doc-audit/check-arch 三绿)继续有效。
- **P2 已处理**:9 框全勾,plan-audit 判据满足(任务 7 依赖部署后验证、任务 8 的 feat-done 为闸前最后一步,勾选顺序是门禁语义下唯一可行序)。
- **任务 7 探针升级为本评审梯级 5 亲跑**(对运行中部署实例,lsof 确认 NemoNotch 监听 127.0.0.1:45831):`python3 -I /tmp/nemonotch-framing-probe.py` → single-segment **200 OK** / two-segment(头‖体)**200 OK** / partial-5B → recv timed out(服务端持续等待,不再即刻 400)——两段式症状在活体上消失,与作者自述一致。
- 观察披露:部署(日志 12:09:46 listener ready)后 /hook 零新增 `Failed to decode HookEvent`(65312/65313B 指纹停增);12:10:44 仍有一条 `/v1/toast Malformed JSON body`(.warn)——非本 bug 形状(两段式已实证 200),属外来坏输入或无 Content-Length 的 chunked 客户端(plan 范围纪律已披露的接受面),不阻塞、留观。
