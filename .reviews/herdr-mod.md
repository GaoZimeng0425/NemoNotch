# Code Review — feature/herdr-mod

Reviewer: claude-opus-5-5 独立评审子代理(未参与开发;judge ≠ author)
Date: 2026-11-12
Reviewed-Head: 0f3bfd8
Verdict: APPROVED
Scope: 增量复审 0fc4778..0f3bfd8(上轮 Reviewed-Head 0fc4778,Verdict APPROVED,留 P3-A/P3-B/P3-C/P3-1)。零代码漂移检查 `git diff 0fc4778..HEAD -- . ':!.reviews'` 不为空,所以做了完整增量审查。

```
docs/superpowers/plans/2026-11-12-herdr-mod.md        |  2 +-
docs/superpowers/specs/2026-11-12-herdr-mod-design.md |  2 +-
integrations/herdr-mod/edges.js                       | 13 +++++
integrations/herdr-mod/edges.test.mjs                 | 17 ++++++-
integrations/herdr-mod/main.js                        | 18 ++++---
```

`git diff --stat 0fc4778..HEAD` 显示本轮没有 Swift 改动。按派发要求,没有跑 test.sh、affected-tests.sh、mutate.sh。

## 验证(评审员亲跑,worktree 内,head 0f3bfd8)

- `sh scripts/lint.sh`:退出码 0。只有 scripts/index-affected.swift 的两条存量 warning。
- `sh scripts/doc-audit.sh`:退出码 0。
- `sh scripts/check-arch.sh`:退出码 0,输出「架构围栏:全部通过」。
- `sh scripts/plan-audit.sh`:退出码 0,输出「本分支动过的 plan 文档任务全勾」。上轮这里是 1。
- `sh scripts/test-herdr-mod.sh`:退出码 0,tests 14,pass 14,fail 0。
- JS 变异验证:把 edges.js 和 edges.test.mjs 复制到 scratchpad 下 4 个独立目录,逐个注入变异后跑 `node --test --test-timeout=3000`,没有改动 worktree 文件。
  - m4:去掉 `&& !agent.address.startsWith("-")`。结果 exit 1,fail 1,见红(上轮这个变异存活,P3-B 已补牙)。
  - m5:让 `bounded` 直接 race 一个只含 `task()` 的数组,不再 race `wait()`。结果 exit 1,cancelled 1,见红。
  - m6:`wait` 结束时 return undefined,不再 throw。结果 exit 1,fail 1,见红。
  - m7:把 race 里的 `task()` 换成永不 resolve 的 promise。结果 exit 1,cancelled 1,见红,由「bounded returns the task's value」守住。
  - 补充:m5 改用门禁脚本的原样调用(没有 `--test-timeout`)重跑时,输出里已经报了 `Promise resolution is still pending but the event loop has already resolved`,但进程没有退出,60s 后被 `timeout` 杀掉(exit 124)。见 P3-D。
- 宿主 API 核对(2 级,读 `~/.config/herdr-app/gpui-kit.d.ts`):
  - `spawn(body: (cx: AsyncContext) => unknown)`:body 拿到的是 AsyncContext,注释写明它跨 `await` 有效。所以 main.js:78 改成 `cx.spawn((cx) => this.lane(...))` 之后,lane 里稍后才运行的任务用 `cx.sleep` 是合法的。
  - `sleep(ms?: number): Promise<void>`:注释写「Resolves after `ms` on GPUI's foreground executor」,签名和语义都与 `bounded` 的 `wait` 参数一致。
  - 没在运行中的 Herdr 里复现挂住场景(没到 5 级)。以下判断只基于宿主类型声明和 node 单测。
- 旧口径清场:在 docs/、integrations/、README*.md、AGENTS.md、scripts/ 里 grep `不排队|no queue`,零命中。spec:116 已改成「单通道串行保序,每次推送 5 秒上限」,和实现一致。
- 没跑的:test.sh、affected-tests.sh、mutate.sh(没有 Swift 改动)、build.sh,以及任何 `herdr-app do`、`herdr-app check`、install 脚本。

## Findings

### 上轮 Findings 处置

- **P3-A main.js 推送没有超时,挂住会堵住整条通道:已修复,关闭。**
  - 修法:edges.js:95 新增纯函数 `bounded(task, wait)`,用 `Promise.race` 让任务和计时器赛跑,超时就 reject。main.js:81-85 用 `cx.sleep(PUSH_TIMEOUT_MS=5000)` 包住 fetch。超时的 reject 被 send 里的 try/catch 吞掉,lane 继续往下走。
  - 因果:上轮的根因是串行之后,一个挂住的任务会永远占住 tail。修法给每个任务设了上限,正好对着这个根因,不是绕开症状。
  - 守卫:「a hung push gives up after its wait, so the lane keeps moving」先让通道里有一个永不结束的 fetch,再断言后面的 close 照样执行。m5 和 m6 都见红。
  - 副作用(推断,2 级,不阻塞):超时时 fetch 本身没被取消,所以服务端可能晚一点才真的收到并显示卡,而 openKeys 没有记这个 key。这只影响 Herdr 重启时 `firstRun` 的补撤。运行中的撤卡由 `diff` 的边沿决定,不读 openKeys,所以「agent 处理后卡必须撤掉」这条需求在运行中不受影响。
- **P3-B edges.js:67 的 `-` 开头条件没有守卫:已修复,关闭。** edges.test.mjs 新增断言 `card(agent("-x/t7","done")).herdrTerminal === undefined`,m4 由存活变为见红。
- **P3-C spec:116 写着「不排队」:已修复,关闭。** 口径已同步,grep 零残留。
- **P3-1 plan 第 176 行裸框:已修复,关闭。** plan-audit 退出码 0。
- **P3-4 / P3-5 / P3-6:** 不在本轮修复范围,维持原状,不阻塞。P3-6(test-herdr-mod.sh 没接进 feat-done 和 CI)仍然成立。

### P1
- 无

### P2
- 无

### P3(本轮新增)
- **P3-D scripts/test-herdr-mod.sh:11 没设单测超时**:新加的超时测试一旦回归(m5 形态),node 已经报了 pending 取消,但进程不退出。实测 60s 后被外部 `timeout` 杀掉(exit 124),门禁表现为挂住,而不是很快变红。**修法**:把 `exec node --test` 改为 `exec node --test --test-timeout=10000`。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增 2 个测试和 1 条断言都用具体输入,断言字面结果(执行顺序数组、reject 消息 `/timed out/`、返回值 7、herdrTerminal 为 undefined)。m4/m5/m6/m7 全部见红。
- [x] **证据纪律**:门禁和变异都是 4 级亲跑,退出码见上。宿主 `spawn`/`sleep` 语义核到 2 级(d.ts),Herdr 真机挂住场景没到 5 级,已披露。
- [N/A] **Swift 6 并发**:本轮没有 Swift 改动。
- [x] **最小改动**:每一处改动都能对应到上轮 P3-A、P3-B、P3-C、P3-1,没有顺手修改邻近代码。
- [x] **错误路径**:超时和失败都在 catch 里吞掉,lane 不会堵住。`cx.sleep` 在 build 被重载后可能同步抛错,这时 `bounded` 同步抛出,同样落进 try/catch,不会逸出。Promise.race 已经给落败一方挂了处理器,所以超时后 fetch 再 reject 也不会变成 unhandled rejection。
- [x] **坑总目录对照**:外部 Toast 红线不变,服务端没有改动,AGENTS.md 的 Herdr mod 节不受影响。
- [x] **教训候选**:见下。
- [x] **文档同步 / 旧口径清场**:spec 已改,grep 零残留。main.js 的注释也同步写上了 5s 上限。
- [x] **工作流机制清场**:没有新增脚本或钩子。

## 教训候选

- scripts/test-herdr-mod.sh:11:测试里一旦有「永不 resolve 的 promise」这类挂起语义,运行器就必须带超时;否则回归的表现是门禁挂住,而不是变红。实测 node 已报告 pending 取消,进程仍然不退出。判据:node 测试脚本一律带 `--test-timeout`,可以考虑放进 guardrail-backlog,做成脚本模板约束。
- edges.js:95 `bounded` 的计时器由调用方注入(这里是 `cx.sleep`):纯函数既能在 node 里用假计时器即时测试,又不绑定宿主计时 API。这个手法可以复用,适合宿主 API 无法在 node 里加载的插件代码。
- 本轮 JS 变异照旧复制到 scratchpad 里跑,四个变异都没碰 worktree,沿用上轮做法有效。
