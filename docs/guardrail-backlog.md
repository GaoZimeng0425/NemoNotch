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
- [ ] **advisory 债表模式**——未来新增门禁若遇存量债(如新 lint 规则上线时上百违例),
  别做"全有或全无":登记表只减不增 + 某项跑绿时哨兵提示删条目(参考 octok-platform
  local-ci 的 TYPECHECK/JEST_LEGACY_ADVISORY + advisoryPassed 设计,2026-10-24 调研)。

## 已硬化(留档)

- [x] **影响面测试选择**(2026-10-23,feature/harden-gates):`--only` 类名从 agent 挑选
  → `scripts/affected-tests.sh` 确定性映射(改动文件→顶层符号→测试引用;空映射回落
  全量)。关闭历史假绿类(--only 选错类)。
- [x] **判决新鲜度**(同上):评审记录 `Reviewed-Head:` 行 + feat-done 门禁自动核对
  最近一次非 .reviews 提交的 head;rebase/重写即拒绝,补审才能合。
- [ ] **门禁自测框架推广**——check-arch 的 --selftest(样本级鉴别力断言,含"不
  命中样本取自真实易误写形状")开了先例(octok local-ci.test.mts 借鉴,
  2026-10-27);doc-audit/plan-audit 尚无同款 red/green 用例表,模式腐化只能
  靠人工发现。做一版 scripts/test-gates.sh 统一喂样本。

- **test.sh 共享文件篡改哨兵**(来源:hook-port-guard 评审教训候选,2026-10-28)。单测宿主与用户真实 app 共享 `~/.NemoNotch/hooks/*`、`~/.claude/settings.json`、`~/.gemini/settings.json`、`~/.zcode/cli/config.json`、opencode 插件、UserDefaults `hookServerPort`;一次测试把它们改坏就会让所有 CLI 事件静默丢失。拟:`test.sh` 前后对这些文件取 mtime/哈希快照,变化即响亮告警并列出文件——把「这个进程不写 X」从口头声明变成每次测试都验证的事实。
