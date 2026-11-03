# Code Review — feature/autopush-develop

Reviewer: (填:评审会话/子代理标识。绝不能是写这段代码的那个——judge ≠ author)
Date: 2026-11-03
Reviewed-Head: (填:评审时分支 head 短哈希,git rev-parse --short HEAD。feat-done 会核对它与最近一次非 .reviews 提交的 head 一致——rebase/重写后旧 Verdict 失效,须补审)
Verdict: (填 APPROVED 或 CHANGES_NEEDED —— feat-done 门禁按行首「Verdict: APPROVED」匹配,保持行首裸格式)
Scope:  2 files changed, 27 insertions(+), 4 deletions(-)

```
.githooks/feat-done.sh
AGENTS.md
```

## Findings

- (逐条:位置 file:line、问题一句话、严重度 [P1/P2/P3];没有就写"无")

## 审查清单(评审者逐项过,不适用项标 N/A)

- [ ] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [ ] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [ ] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [ ] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [ ] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿
- [ ] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [ ] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [ ] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗?
- [ ] **工作流机制清场**:本分支触及 hooks/scripts/CI——旧口径(措辞/路径/次序)全仓 grep 过了吗(AGENTS.md、docs/、注释)?证据贴 Findings。
## 评审方法提示(给评审会话)

在 worktree 里:`git diff 6d6bbe0bc62d89eeac3d88702363d3d851ebac39...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
