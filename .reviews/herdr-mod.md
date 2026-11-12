# Code Review — feature/herdr-mod

Reviewer: claude-opus-5-5 独立评审子代理(未参与开发;judge ≠ author)
Date: 2026-11-12
Reviewed-Head: 8d1196b
Verdict: CHANGES_NEEDED
Scope:  29 files changed, 23980 insertions(+), 45 deletions(-)(首轮范围 c865221…030a2ac;评审中途 HEAD 前进到 8d1196b「expiresAt 上限 30 天」,该提交一并审过,结论绑定 8d1196b)

```
AGENTS.md
NemoNotch/Helpers/AppDependencies.swift
NemoNotch/Models/ExternalToastPayload.swift
NemoNotch/Notch/CompletionToastWindow.swift
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/CompletionToastQueue.swift
NemoNotch/Services/ExternalCardService.swift
NemoNotch/Services/HerdrJumper.swift
NemoNotch/Settings/Pages/ExternalToastGuideSection.swift
NemoNotchTests/CompletionFlashExternalEntryTests.swift
NemoNotchTests/CompletionToastQueueTests.swift
NemoNotchTests/ExternalCardServiceTests.swift
NemoNotchTests/ExternalToastGuideTests.swift
NemoNotchTests/ExternalToastPayloadTests.swift
NemoNotchTests/HerdrJumperTests.swift
README.md
README_CN.md
docs/external-toast-agent-guide.md
docs/superpowers/plans/2026-11-12-herdr-mod.md
docs/superpowers/specs/2026-11-12-herdr-mod-design.md
integrations/herdr-mod/edges.js
integrations/herdr-mod/edges.test.mjs
integrations/herdr-mod/gpui-kit.d.ts
integrations/herdr-mod/jsconfig.json
integrations/herdr-mod/main.js
integrations/herdr-mod/mod.json
scripts/install-herdr-mod.sh
scripts/test-herdr-mod.sh
```

## 验证(评审员亲跑,worktree 内)

- `sh scripts/lint.sh` → 退出码 0(030a2ac 与 8d1196b 各跑一次;只有 scripts/index-affected.swift 的存量 warning)
- `sh scripts/doc-audit.sh` → 退出码 0(两个 head 各一次)
- `sh scripts/check-arch.sh` → 退出码 0(两个 head 各一次)
- `sh scripts/affected-tests.sh` → 退出码 0,索引闭包选出 30 个测试类,「通过 210 · 失败 0」(两个 head 各一次)
- `sh scripts/test-herdr-mod.sh` → 退出码 0(node test,fail 0)
- `sh scripts/plan-audit.sh` → **退出码 1**:plans/2026-11-12-herdr-mod.md:176 的「Step 4: 评审」未勾(见 P3-1)
- `mutate.sh` 变异验证(红 = 守卫有牙):
  - CompletionToastQueue 满员挤卡 `shownAt` → `deadline`:exit 0,红
  - CompletionToastQueue.refill `fixedDeadline ?? now…` → `now…`:exit 0,红(31 过 1 败)。第一次跑是 exit 2(0 用例、xcodebuild 65,无可解析失败)。当时另一会话正在并发写 worktree,疑似这个原因;换完整匹配串重跑后见红
  - ExternalToastPayload `guard raw.first != "-"` → `guard true`:exit 0,红
  - ExternalCardService `item.sticky = true` → `false`:exit 0,红
  - ExternalCardService `herdrTerminal == nil ? jumpURL : nil` → `jumpURL`:exit 0,红
  - (8d1196b)`guard deadline <= now.addingTimeInterval(maxLifetime)` → `guard true`:exit 0,红(24 过 1 败)
- 独立复现挑战者 P1(4 级,独立 swift 探针):`Task.sleep(for: .seconds(v))` 在 v=1e9/1e10/1e12/1e15 时 rc=0,v=1e19 时 rc=133(SIGTRAP)。这证明 030a2ac 上带令牌的 `POST /v1/toast {"expiresAt":1e19}` 能让 app 崩溃(到期 Task 在 CompletionFlashService.swift:443)。8d1196b 用 30 天上限把它挡在 API 边缘,修法与根因对应,文档四处同步改了(README×2、guide、设置内嵌)。
- 只读核对:`herdr-app status` 显示 overlays=["nemonotch"],当前 agent 地址形如 `t96`,符合 herdrTerminal 正则;`~/.local/bin/herdr-app` 是指向 `/Applications/Herdr.app/Contents/MacOS/Herdr` 的符号链接(与 HerdrJumper 的注释一致);已安装的 mods/nemonotch 下 mod.json/main.js/edges.js 与仓内逐字节一致。
- 没跑的(无法验证):`herdr-app check` 没对仓内目录跑,因为它会往目录里写 jsconfig/d.ts,违反「不改文件」。点卡后 Herdr 真聚焦、卡片环色、Spaces 行圆点这些运行中 app 的行为(5 级)没有复现,以下判断只基于代码与单测。

## Findings

### P1
- 无(030a2ac 上的 expiresAt 1e19 崩溃已由 8d1196b 修复,我复现过并验证守卫有牙,见上)

### P2
- **integrations/herdr-mod/main.js:71-88(`send`)**:每次 POST 各开一个独立 `cx.spawn`,中间还 `await endpoint()`(读两个文件)再 `fetch`,同一 key 的 show 和 close 没有先后保证。一旦 close 先到、show 后到,蓝卡(`expiresAt:"infinity"`)就永远挂着,mod 的 openKeys 也记成「开着」。这正好违反用户「答完 / 看过即撤卡」的要求,只能靠用户手点 ×。该结论系推断(2–3 级,未复现):两次边沿通常相隔秒级,但 blocked 闪一下就恢复(自动放行)这类快速翻转的窗口是真实存在的。**修法**:实例上挂一条串行链,`this.chain = (this.chain ?? Promise.resolve()).then(() => post(body)).catch(() => {})`,保证同一实例的推送按边沿顺序发出;`endpoint()` 也可以在链内读。

### P3
- **P3-1 docs/superpowers/plans/2026-11-12-herdr-mod.md:176**:「Step 4: 评审」裸框导致 plan-audit 退出码 1,feat-done 会拦。评审完成后勾上即可。
- **P3-2 integrations/herdr-mod/gpui-kit.d.ts(22652 行)与 jsconfig.json**:这两个是 Herdr 自己生成的文件,安装脚本注释里也说「Herdr writes jsconfig.json / *.d.ts into the folder itself」,install-herdr-mod.sh 也不拷贝它们。入库后已经与宿主漂移:与 `~/.config/herdr-app/gpui-kit.d.ts` 比对,在第 22205 行开始不同。**修法**:删掉,加进 .gitignore;需要编辑器类型提示时由 `herdr-app check` 现场生成。
- **P3-3 NemoNotch/Models/ExternalToastPayload.swift:265-271(herdrTerminal 正则)**:机器名只认 `[A-Za-z0-9._-]{1,64}`,`hc machine ls` 里如果有含空格或非 ASCII 的机器名,远端 agent 的**整张卡**会被 400,不只是跳转失效,而 mod 吞错不报。**修法**:要么在 edges.js 的 `card()` 里对不匹配的地址省略 `herdrTerminal`(只回落 jumpBundleId),要么在文档里明说这个限制。
- **P3-4 NemoNotchTests/HerdrJumperTests.swift:7-27**:`arguments`/`executableURL` 两个测试接近「钉手写常量」;`plan` 测试是三元式的镜像,鉴别力很弱。argv 是外发契约,保留可以接受。真正值得测的「非零 / 超时回落 openApp」只覆盖到纯函数层,`run()` 的超时与 terminate 没有测试。不强制。
- **P3-5 NemoNotch/Services/CompletionToastQueue.swift:66-67**:满员挤卡从按 `deadline` 改成按 `shownAt`,顺带改变了「从等待堆补回的卡」的命运。它的 shownAt 不重置,所以是行内最早的,下一张新卡一来它就首先被挤回堆里。这与「新到的挤最久未到达的」字面一致,AGENTS.md 也已登记,只提醒这是对存量卡的行为变化,不止影响外部卡。
- **P3-6 scripts/test-herdr-mod.sh**:没接进 feat-done / CI,edges.js 的回归只能靠人记得手跑。可考虑由 feat-done 在 `integrations/herdr-mod/` 有改动时调用它。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:Payload/Queue/ExternalCardService/FlashService 的新测试都以具体输入断言字面输出;6 个变异全部见红(见上)。HerdrJumperTests 偏弱(P3-4)。
- [x] **证据纪律**:8d1196b 的提交信息引用了挑战者 P1,我独立复现(rc=133)到 4 级。Herdr 端的真机行为停在作者自述(AGENTS.md「2026-11-12 实测」),我没法复现到 5 级,已披露。
- [x] **Swift 6 并发**:HerdrJumper.focus 是 @MainActor,只把 Sendable 的 URL、[String]、String 交给 `Task.detached`,结果 hop 回 `MainActor.run`;`run` 是非隔离的静态函数,阻塞等待放在 detached 上下文里,没压主线程。编译与测试都过了。
- [x] **最小改动**:改动都能追溯到需求;Queue 挤卡判据的改动有 AGENTS.md 登记与测试(P3-5)。
- [ ] **错误路径**:HerdrJumper 的失败会记 warn 并回落 openApp,这部分合格。mod 端 send 吞掉一切错误,而且乱序会留下僵尸蓝卡(P2);400(P3-3)也被静默吞掉。
- [x] **坑总目录对照**:外部 Toast 红线(只做字段校验、零语义翻译、不辉光、不受 completionFlashEnabled 门禁)保持;Process 不过 shell,地址在 API 边缘校验且拒绝 `-` 开头;「门禁在发射不在快照」未受影响;close 走既有 `replace(key:with:nil)`,覆盖屏上与等待堆。
- [x] **教训候选**:见下。
- [x] **文档同步**:README 双语、docs/external-toast-agent-guide.md、设置页内嵌指南、AGENTS.md 都已更新;8d1196b 的 30 天上限四处同步。旧口径「v1 不可自定义存活时长」全仓 grep 无残留(只剩 docs/superpowers 历史文档)。
- [x] **工作流机制清场**:新增 scripts/install-herdr-mod.sh、scripts/test-herdr-mod.sh,doc-audit 的脚本路径断言通过;没有推翻旧工作流口径。

## 教训候选

- NemoNotch/Services/CompletionFlashService.swift:443:外部输入换算成 `Task.sleep(for: .seconds(x))` 的时长时,必须先给上限。Duration 本身不 trap,但 sleep 换算成纳秒时 1e19 会 SIGTRAP(探针实测 rc=133)。判据:任何「外来数字 → sleep / 定时器」的路径,在 API 边缘必须有上界校验;可以考虑做成 check-arch 的 B 档规则,拦 `Task.sleep(for: .seconds(` 的参数来自 payload 的新增行。
- integrations/herdr-mod/main.js:71:「每个边沿一个独立 async 任务去 POST」天然不保序。对外推送「先开后关」这类有状态的消息必须串行化,否则会出现永不消失的卡。判据:同一 key 的 show/close 发送方必须是单队列。
- 并发会话共用一个 worktree 时,评审员的 `mutate.sh` 会和作者或挑战者的编辑互相踩(恢复的是注入时的原字节)。判据:派第二席或作者在评审期间修改时,评审员不要跑变异,或者给各席位分开 worktree。
