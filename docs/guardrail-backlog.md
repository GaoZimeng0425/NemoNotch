# 护栏待硬化清单(guardrail backlog)

> reflect 收尾例行的落点:任务提炼出的教训,凡是"能做成门禁(lint/钩子/脚本)强制的"
> 记到这里并排期,而不是写进提示词靠自觉(pstack reflect 的 Backlog 路由同款)。
> 条目完成时保留并标 ✅(带 feature 名),给"教训→结构"留证据线。

## 待硬化

- [ ] **P8 结构化结果契约**——lint/test/build/affected 脚本输出是人读文本,机器无法可靠
  解析。目标:`{success, stage, code, message, fix}` 机器可读层(退出码之外)。
  动机:两个案例(NemoNotch/DynamicIsland)互证的普遍缺口。
- [ ] **记忆层证据独立复核(P9)**——agent 持久记忆断言无独立核验通道(宿主能力边界);
  reflect 例行收窄了产生侧,复核侧仍空。等宿主或自建审计脚本。
- [ ] **ripwire 的 Swift Testing 适配**——`--affected`/`--test-gate` 对宏风格测试解析为
  零(2026-10-23 实测 tests=0、graph_ambiguous=249),影响面映射被迫自建
  (affected-tests.sh 的 grep 映射是妥协:同名符号会多吸,方向安全但粒度粗)。
  上游修好可换回。
- [ ] **挑战者多模型对抗**——双席评审的对抗性当前来自镜头多样性(单 provider 妥协);
  用户点名第二个模型即可启用(workflow 原生支持 subagent_model)。
- [ ] **doc-audit 对 .zcode 的对账**——workflow/skills 已入库,但没有"人格里引用的
  脚本路径存在"类断言(doc-audit 只查手册引用)。低优先:漂移面小。

## 已硬化(留档)

- [x] **影响面测试选择**(2026-10-23,feature/harden-gates):`--only` 类名从 agent 挑选
  → `scripts/affected-tests.sh` 确定性映射(改动文件→顶层符号→测试引用;空映射回落
  全量)。关闭历史假绿类(--only 选错类)。
- [x] **判决新鲜度**(同上):评审记录 `Reviewed-Head:` 行 + feat-done 门禁自动核对
  最近一次非 .reviews 提交的 head;rebase/重写即拒绝,补审才能合。
