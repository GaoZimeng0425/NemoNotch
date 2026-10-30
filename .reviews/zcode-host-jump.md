# Code Review — feature/zcode-host-jump

Reviewer: independent review subagent (Opus 5.5, fresh context; did not author the branch)
Date: 2026-10-30
Reviewed-Head: f4b0649
Verdict: CHANGES_NEEDED
Scope:  3 files changed, 66 insertions(+), 5 deletions(-)

```
AGENTS.md
NemoNotch/Services/AppActivator.swift
NemoNotchTests/AppActivatorTests.swift
```

## Findings

- **[P2] 无 `.regular` 祖先时整条宿主丢失,回归了「隐藏 Dock 的终端」** — `NemoNotch/Services/AppActivator.swift:124-129,137-139`。旧谓词「任何 NSRunningApplication」在这类链上能跳,新谓词 `policy == .regular` 爬过它们直到 launchd → `nil` → `recordHost` 不写宿主(`:92`)→ 边栏 `hasHost` 为假、Go 按钮消失(`EdgeBarModel.swift:160`),toast `CompletionJump.make` 返回 nil(`CompletionDetector.swift:21`)。受影响形状:终端被用户设为不进 Dock(Ghostty `macos-hidden = always`——本机 Ghostty 二进制 `strings` 可见 `macos-hidden` 与 `setActivationPolicy:`;iTerm2「Exclude from Dock and App Switcher」同理,本机未装,系推断),此时终端本体就是 `.accessory`,激活它确实会把窗口提到前台。证据梯级 2–3(代码路径 + 二进制字符串),未在运行中复现。修法机械、对 zcode 无副作用:走一遍记下第一个 `.regular`,同时记下第一个任意 app(旧行为);有 regular 返回 regular,否则回落第一个 app。zcode 链有 ZCode(regular)不受影响;ZCode 本体退出而 cli 仍活时回落 helper,等于旧行为。`noRegularAncestor` 用例(`NemoNotchTests/AppActivatorTests.swift:102-111`)需相应改为断言回落到 20(或另设「零 app 链 → nil」用例),并补一条「accessory 终端仍可跳」用例。
- [P3] 聊天气泡会话行为静默改变 — `AppActivator.swift:127`。气泡的 `claude` 子进程父进程是 NemoNotch 自身(实测 pid 24051 `com.nemo.BrightnessApp.NemoNotch`,`.accessory`),旧逻辑把宿主记成 NemoNotch(卡片「Open in NemoNotch」,点了基本无效),新逻辑记为 nil(Go 按钮消失)。这其实更诚实;若采纳上条 P2 的回落,会恢复旧行为——两者择一时请明示取舍,别让它成为附带结果。
- [P3] 已用 helper pid 记录过的会话会自愈 — `AppActivator.swift:92`:`session.launchingAppPID != host` 时覆盖,zcode 下一个带 cli_pid 的 hook 事件即改写为 70848。但**已经弹出的 toast** 的 `CompletionJump` 是完成时快照(`CompletionFlashService.swift:75`),部署前弹出的卡仍指向 helper——一次性,无需处理,仅备注。
- [P3] VS Code / Cursor 集成终端、JetBrains、tmux/ssh:VS Code/Cursor 的 pty 宿主在 `Code Helper`(Electron helper,若注册为 app 也是非 regular),新逻辑会爬到 regular 的 Code 本体——是改进;JetBrains 的 shell 父进程即 IDE java 进程(regular),不变;tmux/ssh 链顶在 launchd,前后都是 nil(靠 tabLink)。本机未运行 VS Code,此条为代码推断(梯级 2)。
- 证据核对(梯级 4,本评审亲跑):`~/.NemoNotch/logs/...2026-10-30--02-25-10-935.log:3651,9128` 确有 `Activating session host pid 70919`,`...2026-10-29--06-34-47-869.log:9792` 有 `resolved: pid 70919, bundle dev.zcode.app.helper`;`ps` 链 70919→70909→70848→1 与提交信息一致;NSRunningApplication 实读 70919/70909 = accessory/`dev.zcode.app.helper`,70848 = regular/`dev.zcode.app`。红绿:1108dcd 保留旧谓词 `policy != nil` 落测试,提交信息引用 exit 65 与两条失败输出,f4b0649 只改谓词——red→green 可重放。
- 本评审运行:`sh scripts/affected-tests.sh` → 选 AppActivatorTests,exit 0(9 过 0 败);`sh scripts/mutate.sh NemoNotch/Services/AppActivator.swift 'policy == .regular' 'policy != nil' --only AppActivatorTests` → 变异被抓住(内层 exit 65,失败 2/通过 7),文件已恢复。之后 `~/.NemoNotch/hooks/hook-sender.sh` 仍为 `# port: 45831`,真实 app(pid 24051)仍 LISTEN 45831。

### 教训候选

- `AppActivator.swift:137` — 「是不是 app」≠「能不能被带到前台」:LSUIElement helper 与用户隐藏 Dock 的主程序都是 `.accessory`,单靠 activationPolicy 无法区分;判宿主时用「优先 regular、否则回落任意 app」的两级选择,而不是单一谓词收紧(收紧会把旧的正确路径一起砍掉)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**(mutate 回旧谓词 → 2 例变红):新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [x] **证据纪律**(日志/ps/policy 实读复核到 4 级):提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [x] **Swift 6 并发**(纯函数注入闭包,非逃逸,无新隔离面):隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [ ] **错误路径**(见 P2:无 regular 祖先时静默丢宿主):失败会响(非零退出/日志),没有吞错、没有假绿
- [x] **坑总目录对照**(zcode 节、Edge Bar Go、toast 跳转快照):改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [x] **文档同步**(AGENTS.md zcode 节已加;若采纳 P2 回落需同步措辞「只认 .regular」):行为变了的话 AGENTS.md / README 跟上了吗?

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 32619a4ac98eb324c94b6c488eb6532060a4507d...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
