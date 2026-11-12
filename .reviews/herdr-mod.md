# Code Review — feature/herdr-mod

Reviewer: claude-opus-5-5 独立评审子代理(未参与开发;judge ≠ author)
Date: 2026-11-12
Reviewed-Head: 0fc4778
Verdict: APPROVED
Scope: 增量复审 8d1196b..0fc4778(上轮 Reviewed-Head 8d1196b,Verdict CHANGES_NEEDED)。零代码漂移检查 `git diff 8d1196b..HEAD -- . ':!.reviews'` 非空,做了完整增量复审。

```
.gitignore                            |     4 +
.reviews/herdr-mod.md                 |    92 +   (上轮记录,不在审查对象内)
integrations/herdr-mod/edges.js       |    20 +-
integrations/herdr-mod/edges.test.mjs |    27 +-
integrations/herdr-mod/gpui-kit.d.ts  | 22652 -----
integrations/herdr-mod/jsconfig.json  |    32 -
integrations/herdr-mod/main.js        |    12 +-
```

没有 Swift 改动(由 `git diff --stat 8d1196b..HEAD` 确认)。

## 验证(评审员亲跑,worktree 内,head 0fc4778)

- `sh scripts/lint.sh` → 退出码 0(只有 scripts/index-affected.swift 的存量 warning)
- `sh scripts/doc-audit.sh` → 退出码 0
- `sh scripts/check-arch.sh` → 退出码 0(「架构围栏:全部通过」)
- `sh scripts/test-herdr-mod.sh` → 退出码 0(node --test:tests 12 · pass 12 · fail 0;本轮新增的 3 个测试都在其中)
- `sh scripts/plan-audit.sh` → **退出码 1**:plans/2026-11-12-herdr-mod.md:176「Step 4: 评审」仍未勾(上轮 P3-1,评审落盘后再勾,见下)
- JS 变异验证:把 edges.js 和 edges.test.mjs 复制到 scratchpad 下 4 份副本,分别注入后跑 `node --test`,没动 worktree 文件。
  - m1 `tail.then(task)` → `Promise.resolve().then(task)`(取消串行):exit 1,红(11 过 1 败)
  - m2 `tail = run.catch(() => {})` → `tail = run`(失败堵死通道):exit 1,红
  - m3 去掉 JUMPABLE 条件,总是带 herdrTerminal:exit 1,红
  - m4 去掉 `&& !agent.address.startsWith("-")`:**exit 0,变异存活**(P3-B)
- 保序前提核对(2 级,读宿主类型声明):`~/.config/herdr-app/gpui-kit.d.ts` 的 `spawn` 注释写「Calls `body(cx)` and adopts the promise it returns」,即 body 同步调用。所以 `send()` 里 `cx.spawn(() => this.lane(...))` 的入队发生在 send 的同步调用中。track() 按 show、close 的边沿顺序调用 send,入队顺序就等于边沿顺序。没有在运行中的 Herdr 里复现(5 级),以下判断只基于宿主声明和 node 单测。
- 正则镜像核对:edges.js 的 `JUMPABLE` 与 ExternalToastPayload.swift:266 的 pattern 逐字一致,`-` 开头的判断也镜像了 Swift:267 的 `raw.first != "-"`。ICU 的 `$` 会接受末尾换行,JS 的 `$` 不接受,所以 JS 侧更严,结果只是少带跳转字段,不会多拿 400,方向安全。
- `git ls-files integrations/herdr-mod` 只剩 edges.js、edges.test.mjs、main.js、mod.json。工作区里的 gpui-kit.d.ts 和 jsconfig.json 已经被 `.gitignore:45-46` 忽略(`git check-ignore -v` 确认)。
- 没跑的:test.sh、affected-tests.sh、mutate.sh(派发方要求,作者在同一 worktree 跑全量),build.sh,任何 `herdr-app do`、`herdr-app check`、install 脚本。

## Findings

### 上轮 Findings 处置

- **P2 main.js `send` 的 show/close 乱序 → 已修复,关闭**。修法:edges.js 新增纯函数 `serial()`(单通道,前一个任务结束后才启动下一个,失败不堵通道),main.js 在 init 里建 `this.lane`,send 经通道发 POST。修复与根因对应:根因是多个独立 async 任务并发 fetch,修法把它们串成一条链,不是绕开症状。守卫:「serial runs tasks in submit order even when an earlier one is slower」先发慢任务、再发快任务,断言执行顺序为 ["show","close"],m1 变异见红;「keeps going after a task throws」m2 见红。说明:这是新增的纯函数,不是先对旧代码写的红测试,所以没有旧代码上的红→绿可重放。main.js 的接线本身没有单测(依赖 Herdr 运行时),保序依赖 spawn 同步调用 body 这一宿主契约,已核到 2 级(见上)。这满足用户「Herdr 里 agent 处理后卡必须自动撤掉」的要求:close 不会再先于 show 到达。
- **P3-1 plan 第 176 行裸框 → 未处置(按设计,评审落盘后再勾)**。plan-audit 当前退出码 1,feat-done 会拦,合并前必须勾上。
- **P3-2 Herdr 生成文件入库 → 已修复,关闭**。两个文件已删除,`.gitignore` 加了这个目录下的 `jsconfig.json` 和 `*.d.ts`,注释说明了原因;install 脚本本来就不拷贝它们。
- **P3-3 不合规地址整卡被 400 → 已修复,关闭**。`card()` 只在地址符合 NemoNotch 校验时才带 `herdrTerminal`,否则只带 `jumpBundleId` 回落。新测试用 `"my box/t7"` 断言没有 herdrTerminal、key 和 jumpBundleId 保留,并用 `"vps/t7"` 做正例,m3 见红。
- **P3-4 / P3-5 / P3-6**:不在本轮修复范围,维持原状,不阻塞(P3-6 test-herdr-mod.sh 没接进 feat-done/CI 仍然成立)。

### P1
- 无

### P2
- 无

### P3(本轮新增)
- **P3-A integrations/herdr-mod/main.js:76-91(`send` 的 fetch 没有超时)**:串行之后,一个挂住的 POST 会堵住后面所有的 show 和 close。原来并发发送时,挂住只影响那一张卡;现在会连带挡住所有撤卡,包括本需求要的「答完就撤」。场景:NemoNotch 进程还在、连接被接受,但应答卡住,比如主线程卡死。连接被拒和进程退出会立即报错,lane 能继续,不受影响。这是推断(2 级,没有复现;Herdr 的 fetch 有没有默认超时未知)。**修法**:如果宿主支持 `AbortSignal.timeout`,给 fetch 加一个约 5s 的超时;不支持就用 `Promise.race` 加 `cx.sleep(5000)` 给通道任务设上限。
- **P3-B integrations/herdr-mod/edges.js:67(`!agent.address.startsWith("-")`)没有守卫**:m4 变异存活。JUMPABLE 的机器名段允许以 `-` 开头(比如 `-x/t7`),这个条件是唯一的防线,去掉后整张卡又会被 400。**修法**:在 edges.test.mjs 的 P3-3 测试里加一行 `assert.equal(card(agent("-x/t7","done")).herdrTerminal, undefined)`。
- **P3-C docs/superpowers/specs/2026-11-12-herdr-mod-design.md:116**:还写着「不重试、不排队」,和现在的单通道串行矛盾(这是本分支随代码一起上线的 spec,不属于历史档)。**修法**:改成「不重试;同一实例的推送单通道串行保序」。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增 3 个测试都以具体输入断言字面输出(执行顺序数组、body 字段)。m1/m2/m3 见红,m4 存活(P3-B)。
- [x] **证据纪律**:各项门禁 4 级亲跑,退出码见上。保序依赖的宿主契约到 2 级(d.ts 注释),Herdr 真机行为没到 5 级,已披露。
- [N/A] **Swift 6 并发**:本轮没有 Swift 改动。
- [x] **最小改动**:改动都能对应到上轮 P2、P3-2、P3-3,没有顺手改邻近代码。
- [x] **错误路径**:失败任务不堵通道(有测试);不合规地址降级为不带跳转,不再整卡丢失。剩下的挂起风险见 P3-A。
- [x] **坑总目录对照**:外部 Toast 红线不变,服务端校验没动,mod 只在客户端预先避开;herdrTerminal 的 `-` 开头防注入在服务端仍然生效,客户端镜像只为不丢卡。
- [x] **教训候选**:见下。
- [x] **文档同步 / 旧口径清场**:grep 了 `no queue`、`不排队`、`jsconfig`、`gpui-kit.d.ts`。main.js 里的旧注释「no retry, no queue」已改掉;install 脚本的注释仍然正确;spec:116 还有残留(P3-C)。README 双语和 guide 对 herdrTerminal 400 的描述是服务端契约,不受影响。
- [x] **工作流机制清场**:没有新增脚本或钩子,.gitignore 的改动只限 mod 目录。

## 教训候选

- integrations/herdr-mod/main.js:75:把并发推送改成串行,修了乱序,但也让一次挂起会堵死整条通道,单点故障从一张卡扩大到所有卡。判据:引入单队列保序时,必须同时给队列里的每个任务设超时上限,否则保序就是用活性换来的。
- integrations/herdr-mod/edges.js:67:客户端镜像服务端校验时,如果镜像分成「正则 + 额外条件」两部分,每个条件都要有反例测试;只测正则部分,额外条件变异就会存活(本轮 m4 实证)。
- 上轮那条「并发会话共用一个 worktree 时评审员别跑 mutate.sh」本轮照做了:JS 变异改为复制到 scratchpad 跑,不碰 worktree,可以作为 JS 侧守卫验证的固定做法。
