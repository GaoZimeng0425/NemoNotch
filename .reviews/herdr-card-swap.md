# Code Review — feature/herdr-card-swap

Reviewer: Claude Opus 5.5 独立评审子代理(未参与本分支开发,未见作者对话)
Date: 2026-11-15
Reviewed-Head: 5b9f133
Verdict: APPROVED
Scope:  3 files changed, 9 insertions(+), 7 deletions(-)

```
docs/superpowers/specs/2026-11-12-herdr-mod-design.md
integrations/herdr-mod/edges.js
integrations/herdr-mod/edges.test.mjs
```

## Findings

- [P3] docs/superpowers/plans/2026-11-12-herdr-mod.md:22 仍写着旧口径「title `&lt;space_name&gt; / &lt;tab_name&gt;`(≤120),body `&lt;跑完了|等你回应&gt; · &lt;app&gt; · &lt;title&gt;`(≤280)」,和 spec(:114–116)与 edges.js:105–106 相反。这份 plan 已经交付,留在 plans/ 而不在 archive/,grep 时容易误读成现行事实。修法:在该行加一句「2026-11-15 已对调,见 spec」;或者按惯例把这份已交付的 plan 移到 archive/。不挡合并。

无 P1/P2。

核对记录(证据梯级 4,都在 worktree @ 5b9f133 亲跑):
- 契约:新 title = `[WORD[status], app, title].filter(Boolean).join(" · ")`(edges.js:99,105)。`card()` 唯一的调用点是 main.js:133,数据只来自 `diff().show`,show 只收 `ATTENTION = {done, blocked}` 的 agent(edges.js:7、:32)。WORD 对这两种状态都有非空词(edges.js:8),所以 title 至少是「跑完了」或「等你回应」,满足 ExternalToastPayload.swift:238 的非空校验。JS 端 `clip` 按 code point 截到 120 / 280;Swift 端 `String.count` 按字符簇计数,字符簇数 ≤ code point 数,所以截断后一定在 :239 / :243 的上限内。body 来自 space/tab 模板串,永远非空(`undefined` 的情形与改动前完全一样,不是本分支引入的)。卡面上三排都是 `lineLimit(1)`(CompletionToastView.swift:157/163/169),对调不会让任何一排换行或溢出。
- `sh scripts/test-herdr-mod.sh` → exit 0(pass 18 / fail 0)
- `herdr-app check integrations/herdr-mod` → exit 0(check passed)
- `sh scripts/doc-audit.sh` → exit 0
- `sh scripts/check-arch.sh` → exit 0(全部通过)
- `sh scripts/lint.sh` → exit 1。失败是存量问题:`swiftformat --config .swiftformat --lint NemoNotch/Services/OpenClawService.swift` 报 `139:1: error: (andOperator)`;`git diff --name-only &lt;mb&gt;...HEAD -- '*.swift'` 为 0 行;该文件与 merge-base 无差异。SwiftLint 只有 warning。
- JS 变异测试(在 scratch 副本中做,worktree 未动;基线 18/18 绿):
  - M1 把 title/body 换回旧顺序 → exit 1,fail 3
  - M2 title 上限 120→121 → exit 1,fail 1
  - M3 body 上限 280→281 → exit 1,fail 1
  - M4 去掉状态词 WORD → exit 1,fail 3
  四种变异全部被杀死。
- 提交信息里自述的「还原旧顺序 fail 3」与本人 M1 的结果一致。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:done 卡用 deepEqual 断言字面全卡;blocked 卡断言 `title` 的字面值;截断测试断言 title 的长度和前缀(前缀同时证明 app 为 null 时那一段被省略)。M1–M4 四种变异全部变红,测试有鉴别力。
- [x] **证据纪律**:提交信息写了 test-herdr-mod 的 exit 0(18/18)、herdr-app check 通过,并在副本里还原旧顺序验证测试会变红;本人复跑结果一致,达到第 4 级。
- [x] **Swift 6 并发**:N/A(零 Swift 改动)
- [x] **最小改动**:代码改动只有 edges.js 里两行字段对调加一行 why 注释,测试与 spec 同步改,没有顺手改别的。
- [x] **错误路径**:N/A(纯字段映射,推送和错误处理路径未动)。已确认契约不会被违反(title 非空、长度在上限内),所以不会引入新的 400。
- [x] **坑总目录对照**:AGENTS.md 的「Herdr mod」节和「外部 Toast API」节都对照过。卡身份 `ext:&lt;app&gt;::&lt;key&gt;` 只取 app 和 key,对调 title/body 不影响撤卡身份;`edges.js` 仍然没有 herdr 导入。
- [x] **教训候选**:无(见下)
- [x] **文档同步**:spec 已更新并注明拍板日期。README/README_CN 只描述卡头(项目 · worktree),没写第 2/3 排的内容,不需要改;AGENTS.md 也没有第 2/3 排的口径。plan 文档残留旧口径,见 P3。

## 教训候选

无。这是一次纯字段对调,契约安全靠「状态词永远非空」这个结构性事实保证,现有测试与变异已经覆盖;没有发现以后会再咬人的新坑。
