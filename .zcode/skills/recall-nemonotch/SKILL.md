---
name: recall-nemonotch
description: 重建 NemoNotch 最近的工作上下文并交回接续简报。用于"继续/接续/我做到哪了/上次做到哪/最近在忙什么"类开场,或任何 resume 工作之前。Use before starting or resuming NemoNotch work.
---

# Recall — NemoNotch 接续简报

重建最近的工作上下文,交回一份紧凑简报**再动工**。只读不写、不猜、先核活体状态;每个事实带出处(commit hash / 文件路径 / 记忆条目)。

## 数据源(按优先级)

1. **活体状态(永远先看)**:`git log --oneline -15`、`git status`、`git feat-list`(在途 worktree;结合主检出当前分支判断是否有未收尾的 feature)。
2. **评审与决策记录**:`.reviews/*.md`——各 feature 的 Verdict、findings、评审时的 head 短哈希(可对照 rebase 与否)。
3. **计划档案**:`docs/superpowers/plans/`(在途)与 `plans/archive/`(已 ship);文件名即日期与主题。
4. **经验与坑**:AGENTS.md 坑总目录、`docs/experience-playbook.md`。
5. 持久记忆(memory 目录,若有)与会话 transcript 只作补充,不作首选。

相邻功能不提,除非阻塞本线程。需要挖多深取决于接续的问题:能三层内回答就不挖第四层。

## 输出契约(简报四段,写完才动工)

- **胶囊**:≤5 条——这项工作是什么、总体停在哪。
- **线程**:每行一个,带且仅带一个状态标签:`[已合并 <hash>]` `[在途 <分支>]` `[已验证未提交]` `[已回滚 <原因>]` `[计划未动工]`。没有标签 = 没完,必须标。
- **反复出现的问题**:≤5 条,含用户实报症状与"修了又被回滚"的修复——下次尝试从上次失败处起步,不从零。
- **下一步**:单一、具体的下一动作。

简报之后问用户是否按"下一步"执行,不要自作主张动工。
