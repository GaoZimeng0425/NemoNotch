# Code Review — feature/hookinstaller-lint

Reviewer: independent reviewer subagent (Claude Opus 5.5, fresh context, not the author)
Date: 2026-10-28
Reviewed-Head: 9db7171
Verdict: APPROVED
Scope:  1 file changed, 3 insertions(+), 5 deletions(-)

```
NemoNotch/Services/HookInstaller.swift
```

## Findings

- 无 P1/P2/P3。
- 行为等价(梯级 2→4):NemoNotch/Services/HookInstaller.swift:117-137 `writeEvents` 的非嵌套分支由 `else { if events.isEmpty {remove} else {set} }` 折为 `else if events.isEmpty {remove} else {set}`,条件、两个分支体、求值顺序逐一对应,嵌套(zcode)分支未动;无副作用差异。
- 发送脚本模板未动(梯级 4):diff 唯一 hunk 在 132-136 行;模板 `let script = """`(275-355 行)在 base bb9da5a 与 HEAD 的抽取内容 shasum 均为 19f6fa128be4fa9e21d1aed65c747770171e3a42。
- 验证(梯级 4):`sh scripts/lint.sh` exit 0("swiftformat + swiftlint 通过",剩余均为他文件 warning 级);`sh scripts/affected-tests.sh` exit 0,选中 ZcodeHookInstallerTests,8 过 0 败,日志 build/test.log。该类 `flatTargetInstallWritesFlatHooksAndUninstallClears`(NemoNotchTests/ZcodeHookInstallerTests.swift:106)同时走到了被改的两个分支(install 非空写入、uninstall 空时删 hooks 键并断言 `settings["hooks"] == nil`),守卫覆盖到改动面。
- 测试前后 `~/.NemoNotch/hooks/hook-sender.sh` 的 `# port` 均为 45831(未被改写)。

### 教训候选

- 无(SwiftFormat 升级引入新规则致全仓 lint 红属工具版本漂移,一次性)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**(N/A 无新测试;既有 :106 测试断言字面结果,覆盖两分支):新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [x] **证据纪律**(评审侧已跑 lint/test 到第 4 级):提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [x] **Swift 6 并发**(N/A,纯控制流重排):隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [x] **错误路径**(N/A,无错误路径变化):失败会响(非零退出/日志),没有吞错、没有假绿
- [x] **坑总目录对照**(Hook 端口与发送脚本节:模板字节不变,端口未被测试改写):改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [x] **文档同步**(N/A,行为未变):行为变了的话 AGENTS.md / README 跟上了吗?

## 评审方法提示(给评审会话)

在 worktree 里:`git diff bb9da5a6641c62055f5d6cac51f41b688fe88c12...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
