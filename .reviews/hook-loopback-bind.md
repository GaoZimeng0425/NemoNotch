# Code Review — feature/hook-loopback-bind

Reviewer: 独立评审子代理(Claude Opus 5.5,未参与本分支开发)
Date: 2026-10-30
Reviewed-Head: 37d963a
Verdict: APPROVED
Scope:  3 files changed, 31 insertions(+), 6 deletions(-)

```
AGENTS.md
NemoNotch/Services/HookServer.swift
NemoNotchTests/HookServerBindTests.swift
```

## Findings

无 P1/P2。

- NemoNotchTests/HookServerBindTests.swift:9 — 测试钉的是 `listenerParameters` 的返回值,不钉 `attemptStart` 真的用它(HookServer.swift:66/72)。有人把 attemptStart 改回内联参数,测试仍绿。监听地址是"发出去的东西",真契约在 socket 上;但要测它得起真 listener,与"只测纯逻辑"约定冲突,接受现状。[P3]
- HookServer.swift:70-72 注释说 `on:` 与 requiredLocalEndpoint "冲突"——实测更硬:两者同传 `NWListener(using:on:)` 直接抛 EINVAL(22)。若有人加回 `on:`,init 每个端口都抛 → tryNextPort 把 10 个端口烧光 → hook server 永不起、只有一条 error 日志。注释可写明"会抛 EINVAL、全端口失败",不阻塞。[P3]
- 范围外观察(非本分支引入):`~/.NemoNotch/hooks/hermes-hook-sender.sh` 仍是 `# port: 45832`(10-28 事故残留);只在 `HermesHookInstaller.isInstalled` 时刷新(HookServer.swift:124),Hermes 未装则惰性无害。[P3,仅记录]

实测(评审员自跑,第 4 级):
- 独立 Swift/Network 探针(同参数,端口 47911–47913,未碰 45831/45832),exit 0:
  - A 钉回环、只经 requiredLocalEndpoint 给端口 → ready,`listener.port`=47911,lsof `IPv4 127.0.0.1:47911`;127.0.0.1 连通、`localhost` 连通(nc 回落 v4)、`::1` 拒绝、LAN IP 172.28.96.235 拒绝。
  - B 同端口第二个钉回环 listener → `.failed(EADDRINUSE 48)`,即 handleListenerState 的 failed 分支 → tryNextPort,回落照常(测试宿主/第二实例场景)。
  - C/D 通配 listener 与钉回环 listener 同端口**可共存**(任一先后,allowLocalEndpointReuse/SO_REUSEADDR),回环流量归更具体的 127.0.0.1 绑定。即:旧版构建或别的进程占着 `*:45831` 时新 app 不会回落,而是并存且赢得回环流量——对我们无害(发送方全打 127.0.0.1),但排查时 lsof 可能同时见 `*:` 与 `127.0.0.1:` 两行。
  - F `NWListener(using: pinned, on: port)` → init 抛 EINVAL,印证去掉 `on:` 是必须。
- 发送方全扫:hook-sender.sh 模板 HookInstaller.swift:281、Hermes HermesHookInstaller.swift:89、opencode 插件 OpencodePluginInstaller.swift:52 均为字面 `http://127.0.0.1:<port>`,无 `localhost`、无 IPv6 客户端;仓内无其他打 hook 端口的客户端。盘上已装副本(hook-sender.sh、opencode 插件)亦为 127.0.0.1。
- `sh scripts/affected-tests.sh` → exit 0,14 通过 0 失败(HookServerAuth/Bind/PermissionHold、NemoNotchTests、OpencodeProviderTests)。
- `sh scripts/mutate.sh HookServer.swift 'requiredLocalEndpoint = .hostPort(...)' → 'requiredLocalEndpoint = nil' --only HookServerBindTests` → exit 0(变异被抓,测试红 65),文件已恢复,git status 干净。
- `sh scripts/doc-audit.sh` exit 0;`sh scripts/check-arch.sh` 全部通过。
- 每次跑完 `grep -E '^# port' ~/.NemoNotch/hooks/hook-sender.sh` → `# port: 45831`,未被改写。运行中的 app(旧构建,未部署本分支)lsof 仍为 `IPv6 *:45831`——合并后 post-merge 自动 build 部署,届时应变为 `IPv4 127.0.0.1:45831`。

### 教训候选

- AGENTS.md「Hook 端口与发送脚本」: `allowLocalEndpointReuse` 下,钉地址的 listener 与通配 listener 同端口可共存、不触发 EADDRINUSE——"端口被占就回落"只对**同地址**成立。判据:回落逻辑的前提是同地址冲突;lsof 同端口出现两行(`*:` + `127.0.0.1:`)不是回归,是旧实例/别的进程占通配。
- 可门禁化候选(check-arch B 档):新增 `NWListener(using:` 且同文件未设 `requiredLocalEndpoint` → 拦(防再出现绑所有网卡的 listener)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [x] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [x] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [x] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿
- [x] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [x] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗?

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 2724d27e6edafd2fb254bd3ef003f70d86fe4e42...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
