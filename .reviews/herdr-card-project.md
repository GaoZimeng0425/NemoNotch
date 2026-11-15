# Code Review — feature/herdr-card-project

Reviewer: 独立评审子代理(Claude Agent SDK,未参与本分支开发;judge ≠ author)
Date: 2026-11-15
Reviewed-Head: 6df68e0
Verdict: APPROVED
Scope:  6 files changed, 98 insertions(+), 20 deletions(-)

```
AGENTS.md
README.md
README_CN.md
integrations/herdr-mod/edges.js
integrations/herdr-mod/edges.test.mjs
integrations/herdr-mod/main.js
```

## Findings

P1:无
P2:无

- **[P3] `integrations/herdr-mod/edges.js:85`:`replaceAll("::", ":")` 只做一遍不重叠替换,三个及以上冒号连在一起时仍会留下 `::`。** 我用 node 实测:`placeLabel("/x/a:::b")` 返回 `"a::b"`,`"/x/a::::b"` 也返回 `"a::b"`。NemoNotch 会以 `separatorInAppOrKey` 返回 400,这张卡就整张丢了。git 分支名不允许含 `:`,所以只有目录名带 `:::` 时才会触发(macOS 文件夹名允许冒号),很少见。修法:改成 `label.replace(/:{2,}/g, ":")`,并在测试里加 `a:::b` 的用例。
- **[P3] `integrations/herdr-mod/main.js:106-108`、`main.js:126`:close 在排队时就删掉 `headers`,不管 POST 是否成功,可能留下永不消失的旧卡。** 触发条件是 NemoNotch 在线、但这次 close 被拒(非 2xx,比如 401)。此时 `headers` 已删,`openKeys` 里还有旧标题 X。之后同一 agent 换了目录,以标题 Y 再出卡:`headers.has` 为 false,不会先撤 X。Y 成功后 `openKeys.set(Y)` 覆盖了 X,X 从此没人记得。如果 X 是蓝卡(`expiresAt:"infinity"`),它会一直挂着。改动前卡身份固定,同一个 key 再次 show 会原地替换,不存在这个问题,所以这是新引入的边角。修法:在 main.js:126 用 `this.headers.get(addr) ?? this.openKeys.get(addr)` 比对旧标题。卡已不在时多发一次 close 只会撤一张不存在的卡,不产生副作用。
- **[P3] `docs/superpowers/specs/2026-11-12-herdr-mod-design.md:111`(及同文件的「残留卡清理」段):spec 里还写着 `app: "Herdr"`,并把 openKeys 描述成「key 集合」。** 按「推翻旧口径就全仓 grep 清场」的规矩,`docs/` 也在范围内。修法:在这两处加一行「2026-11-15 起 `app` = `placeLabel` 标题,openKeys 为 地址→标题,见 AGENTS.md Herdr mod 节」。`docs/superpowers/plans/2026-11-12-herdr-mod.md:22,142` 是历史 plan,按惯例可以不动,或者挪进 archive/。
- **[P3] `integrations/herdr-mod/main.js:49-62,106-133`:卡片身份的核心逻辑没有任何测试覆盖。** 这部分包括 headers 记账、旧数组迁移、换目录先撤旧卡、close 成功后按 app 匹配再删,都在 main.js 里。main.js 要导入 herdr,node 跑不了。edges.js 的测试只证明 `card` 和 `closeBody` 会带上传进来的 app,证明不了 main.js 在每条路径上都传对了。修法(可选):把「给定 headers/openKeys 与 show/close 序列,算出要发的 body 列表」抽成 edges.js 里的纯函数并单测,上一条和迁移都能顺带锁住。提交信息里也没写任何验证证据(退出码或日志),验证都是我亲跑补上的。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:三个新测试都用具体输入调用 `placeLabel`/`card`/`closeBody`,断言的是实际输出的字面值。我在临时副本里对 edges.js 注入 8 个变异:worktree 改用分支、去掉 `.worktrees` 这一种匹配、去掉 `::` 替换、去掉 48 字截断、忽略 fallback、card 写死 "Herdr"、closeBody 写死 "Herdr"、去掉末尾斜杠处理。8 个都让 `node --test edges.test.mjs` 以 exit=1 变红,测试有鉴别力。缺口是 main.js 的身份逻辑没测(见第四条 P3)。
- [x] **证据纪律**:提交信息里没有验证声明。以下是我亲跑的结果(第 4 级):
  - `sh scripts/test-herdr-mod.sh`:exit 0,tests 18 / pass 18 / fail 0。
  - `herdr-app check integrations/herdr-mod`:exit 0,输出 "check passed"。
  - `sh scripts/doc-audit.sh`:exit 0。
  - `sh scripts/check-arch.sh`:exit 0。
  - `sh scripts/lint.sh`:exit 1。我用 `swiftformat --config .swiftformat --lint .` 定位到唯一的 error 是 `NemoNotch/Services/OpenClawService.swift:139:1 (andOperator)`。`git diff b0b6dd2 HEAD -- OpenClawService.swift` 为空,`git diff --name-only` 里也没有 `.swift` 文件,因此确认是 develop 上原有的失败,与本分支无关。
  - **证据完备度**:我没在运行中的 Herdr 里实测(第 5 级)。`panes()` 是否给 agent 所在的 pane 填 cwd/branch,以及 `agent.pane` 能否与 `PaneInfo.pane` 对上,只依据 `~/.config/herdr-app/herdr.d.ts` 的类型定义(AgentInfo.pane 与 PaneInfo.pane 都是 string,cwd 注释为 "Its live folder")。`herdr-app ls` 只读输出里有 pane id,但没有 cwd。
- [x] **Swift 6 并发**:N/A,没有 Swift 改动。
- [x] **最小改动**:每一行都对应「标题改为项目 + worktree」以及由此带来的卡身份配对。README 顺带提了 AI logo,这是已有行为(`iconFor`),描述准确。
- [x] **错误路径**:推送失败吞掉不重试,沿用原有设计(`main.js:80-83` 注释)。`loadKeys` 对 JSON 损坏、`null`、数字、非 string 值都有兜底(第 51-56 行)。`placeLabel` 遇到 cwd 为空、`/` 或 basename 为空时,依次回落到 space 名,再回落到 "Herdr",我用 node 实测过。剩下的边角见前两条 P3。
- [x] **坑总目录对照**:对照了 AGENTS.md 的「外部 Toast API」与 Herdr mod 节。
  - 卡身份 `ext:&lt;app&gt;::&lt;key&gt;`:show 和 close 是否配对,我按以下场景逐条推演,都没问题:
    - show X 后在 POST 落地前就排进 close:close 用排队时记下的 headers,发的是 X。
    - 换目录:先撤旧卡 X,再出新卡 Y。
    - 首次启动:用持久化的 地址→标题 清理残留卡。
    - 旧数组格式:迁移成 "Herdr",之后的 close 或换标题都会撤掉旧的 "Herdr" 卡。
    - done 与 blocked 互切:标题不变,原地替换。
    - Herdr 关着期间换了目录:重开后,下一次 show 先撤持久化里的旧标题卡。
  - `app` 契约:Swift 端长度按字素数检查 `app.count &gt; 48`,`Array.from` 按码点截断到 48,码点数不小于字素数,所以截断后一定合规。`::` 的漏洞见第一条 P3。
  - 「`done` 只表示你没看着时跑完」这条语义没变。
- [x] **教训候选**:见文末。
- [x] **文档同步**:README、README_CN、AGENTS.md 已同步。残留的是 spec 里的 `app: "Herdr"` 和「key 集合」口径(见第三条 P3)。`NemoNotchTests/*` 里的 `"app":"Herdr"` 只是测试用的字面样本,不是口径,不用改。

## 教训候选

- `integrations/herdr-mod/edges.js:85`:「禁止出现某分隔符」不能用一遍 `replaceAll(sep, 短串)` 来做,替换后相邻字符会重新拼出分隔符(`:::` 变成 `::`)。判据:净化之后要断言 `!includes(sep)`,或者用 `/:{2,}/` 这种吸收连续字符的写法。测试样本至少要有一个「分隔符 + 1 个字符」的形状。可以考虑在 test-herdr-mod 里加一个对 `placeLabel` 的字符串 fuzz。
- `integrations/herdr-mod/main.js:106-126`:一旦卡身份里有了动态成分(比如这里的 `app`),外部推送方要按「最后一次成功落地的身份」撤卡,而不是按「最后一次排队的身份」。只在排队时记账,遇到被拒的请求就会丢失旧身份。判据:凡是身份会变的撤卡路径,比对旧身份时要同时查排队态和落地态。
