# Code Review — feature/hook-port-guard

Reviewer: independent reviewer subagent (Claude, fresh session; did not author this branch)
Date: 2026-10-28
Reviewed-Head: 1cd4c67
Verdict: CHANGES_NEEDED
Scope:  5 files changed, 42 insertions(+), 6 deletions(-)

```
AGENTS.md
NemoNotch/Helpers/UITestMode.swift
NemoNotch/Services/AICLIMonitorService.swift
NemoNotch/Services/HookServer.swift
NemoNotchTests/UITestModeTests.swift
```

## Findings

- **[P2] 守卫不完整,手册新不变量与实测不符** — `NemoNotch/Services/HookServer.swift:122` 的 else 分支照样调 `onReady?()`,于是单测宿主仍会跑 `AICLIMonitorService.handleServerReady`(`NemoNotch/Services/AICLIMonitorService.swift:181-193`):`HookInstaller.install(.claude/.gemini/.zcode)`(改写 `~/.claude/settings.json`、`~/.gemini/settings.json`、`~/.zcode/cli/config.json` 并经 `ensureScriptExists` 按**本 worktree 的模板**核对 hook-sender.sh)和 `OpencodePluginInstaller.install()`(无条件重写 opencode 插件)。实测(第 4 级):`sh scripts/test.sh --only UITestModeTests` 退出码 0;前后 stat 显示 opencode 插件与三份 CLI 配置的 mtime 从 1793186603 变为 1793186699(19:24:59,测试运行中);主日志 `HookServer` 19:24:59.297 「Test/UI-test instance on 45832: shared hook config left alone」紧接 19:24:59.300 「[OpencodePluginInstaller] Wrote opencode plugin (port 45831)」。端口这次是对的——只是因为 UserDefaults 已不再被改写,所以**本次症状(死端口)确已修住**;但 AGENTS.md 新节写的「只有用户的真实 app 写共享 hook 配置」不成立。剩余伤害路径真实存在:在动 hook 模板的 feature worktree 里(或从更老的分支)跑测试,宿主会用那份模板改写用户正在用的 hook-sender.sh / opencode 插件 / CLI hook 命令,直到真实 app 下次启动(`scriptVersion` 不匹配)才被修回;opencode 插件与 CLI 配置则只有 handleServerReady 的无条件安装能修。修法建议(最小):`handleServerReady` 里的四个 install 也以 `UITestMode.ownsSharedHookConfig` 门控(或在测试宿主里不 `startServer()`,与 `--uitest` 同处理,`AppDependencies.swift:80`),这样手册断言才名副其实。
- **[P3]** `NemoNotch/Services/HermesService.swift:49-51` 的 init 仍在测试宿主与 `--uitest` 实例里 `refreshScript()`(无条件整文件重写 hermes-hook-sender.sh)。端口取自 UserDefaults 故不再指向死端口,模板问题同上;顺手和 AICLIMonitorService init 一样加 `ownsSharedHookConfig` 门控可让不变量完整。本次实测该文件 mtime 未变(推测本机 Hermes hook 未装、`isHookInstalled` 为 false——未核实)。
- **[P3]** 每次 ready 都 `ensureScriptExists()` 对从未装过任何集成的用户会新建 hook-sender.sh——但 `handleServerReady` 本就无条件自动安装 claude/gemini/opencode 并写该脚本,所以没有新增副作用;Hermes 改为 `isInstalled` 门控是正向收紧(旧代码回落时会给没装 Hermes 的用户凭空写 hermes 脚本)。无需动作。
- **[P3]** `--uitest` 实例根本不 `startServer()`(`AppDependencies.swift:80`),所以 HookServer 守卫里的 `uiTest` 分量对它是冗余防线;真正起作用的是 `isTestHost`。无害,注明以免后人误以为 `--uitest` 也撞过端口。(手册「单测宿主与 `--uitest` 实例……撞 45831 回落 45832」对 `--uitest` 的描述因此不准确——它写的是 AICLIMonitorService init 那条路径,不是端口回落。)
- 判别剃刀:`UITestModeTests.sharedHookConfigOwner` 四格真值表,桩返回 `true`(ff6e31f)即红、返回常量 `false` 首格即红,有鉴别力;但它只钉谓词,接线(HookServer/AICLIMonitorService 是否真用它)无测试覆盖——这正是上面 P2 漏网的位置。接线是 AppKit/文件系统集成,按手册可不测,但手册断言应以实测而非谓词测试为据。
- 证据:红提交 ff6e31f 用 `true` 桩产出真实失败(提交信息引 exit 65),我未复跑红;绿与「hook-sender.sh 保持 45831」我复跑确认(见上)。提交信息「the opencode plugin all still point at 45831」为真,但未提到插件仍被测试宿主改写。

### 教训候选

- `NemoNotch/Services/HookServer.swift:122`:按进程角色门控副作用时,**回调链也要一起门控**——守住 ready 分支里的写入却仍触发 `onReady`,下游 `handleServerReady` 照写。判据:声明「X 进程不写 Y」前,用 stat mtime + 日志对真实运行验一次,而不是只看被改的那几行。可门禁化方向:测试宿主运行前后对 `~/.NemoNotch/hooks`、`~/.config/opencode/plugin`、`~/.claude/settings.json` 等做 mtime 快照,test.sh 发现变化即响亮警告。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [x] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [x] **Swift 6 并发**:(N/A,无新隔离/回调;改动都在既有 MainActor 路径)隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [x] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿
- [x] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [x] **文档同步**:(AGENTS.md 已加节,但其不变量表述与实测不符,见 P2):行为变了的话 AGENTS.md / README 跟上了吗?

## 评审方法提示(给评审会话)

在 worktree 里:`git diff c86295f35d9db638e1eb78773d4de066abc77a3b...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
