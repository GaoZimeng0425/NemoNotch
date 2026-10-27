# Code Review — feature/fence-graduation

Reviewer: 独立评审子代理(ZCode 会话,judge ≠ author,未参与开发)
Date: 2026-10-27
Reviewed-Head: abec735
Verdict: APPROVED
Scope:  2 files changed, 8 insertions(+), 2 deletions(-)

```
AGENTS.md
scripts/check-arch.sh
```

## Findings

- 无 P1/P2。
- [P3·观察,不要求修改] scripts/check-arch.sh:35「规则总数 >10 条」的计数口径略歧义:指本文件内规则数,还是含毕业后独立脚本里的规则?当前 6 条(A 档 4 + B 档 2)距阈值远,两种读法近期都不触发;毕业场景真到来时建议顺手补一句口径。判据核心(需要 AST/类型信息、需要 baseline 记记,两触发为「或」)无歧义。

### 核验证据(全部真跑,退出码为准)

1. **改动面**:`git show abec735 --stat` 确认仅 AGENTS.md + scripts/check-arch.sh。check-arch.sh 的 diff 只动头部注释块(L27-37,全 `#` 开头),`set -u` 以下零代码行变更——纯注释/文档,零行为变更属实。
2. **行为不变验证**:`sh scripts/check-arch.sh --selftest` → exit 0(全部样本含 B 档合成 diff 符合预期);`sh scripts/check-arch.sh` → exit 0(架构围栏全部通过)。
3. **doc-audit 不受伤**:`sh scripts/doc-audit.sh` → exit 0(AGENTS.md 新增的 `scripts/check-<name>.sh` 是占位描述,未被当成精确路径断言)。
4. **一致性(规矩数/内容)**:脚本头「四条规矩」与 AGENTS.md「加规则四规矩」逐条事实对照一致——第 1-3 条 AGENTS 为压缩版无事实矛盾;第 4 条压缩映射:脚本「需要 AST/类型信息、需要 baseline 记账」→ AGENTS「AST/baseline 需求」;脚本「feat-done 永远只认 check-arch 这一个入口,解耦发生在规则之间,不发生在门禁链与规则之间」→ AGENTS「feat-done 只认 check-arch 一个入口」。压缩不损事实。
5. **第 4 条自洽性**:两触发条件「或」关系明确;「毕业为 scripts/check-<name>.sh 并在本文件登记」+「feat-done 只认 check-arch 一个入口」构成闭环——登记即接线,OC-612(围栏写了没接表=从没跑过)被显式防住。「单入口」经事实核实非愿景:`grep -n check-arch .githooks/feat-done.sh .github/workflows/*.yml` 确认 feat-done(L102-104)与 CI(doc-audit.yml:28)均只调 check-arch.sh。当前 6 条 ≤10,与「住本文件」现状自洽。
6. **工作流机制清场**:触及 scripts,已 grep 旧口径——`grep -rn "三条规矩" --include='*.md' --include='*.sh' --include='*.swift' .` 零匹配(exit 1);docs/ 中 check-arch 引用均为事实性引用,无三/四规矩口径漂移。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A——纯注释/文档,无测试改动。
- [x] **证据纪律**:是——本评审所有验证真跑并记录退出码(见上)。
- [x] **Swift 6 并发**:N/A——零 Swift 代码。
- [x] **最小改动**:是——两文件、8+/2-,每行可追溯到「加第 4 条毕业判据」这一任务;无顺手改动。
- [x] **错误路径**:N/A——零行为变更;门禁行为经 selftest+gate 双跑确认不变。
- [x] **坑总目录对照**:N/A——改动对象本身就是坑总目录门禁机制文档。
- [x] **教训候选**:无新教训。本提交本身即是 OC-612 教训的结构化固化(把「何时拆脚本」从口头判断变成可对照判据),作者的固化动作已完成,无需 reflect 再分流。
- [x] **文档同步**:是——AGENTS.md 与脚本头注释同一提交同步,符合门禁自己「事实变了…同一提交改」的纪律。
- [x] **工作流机制清场**:是——旧口径「三条规矩」全仓 grep 零残留(证据见核验 6)。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 7ef3d525d315c1b5dda04cd4f175863345bca8f0...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
