# Code Review — feature/mediaremote-daemon-leak

Reviewer: ZCode 独立评审子代理(GLM-5.3;judge ≠ author,未参与开发、不见作者对话)
Date: 2026-11-05
Reviewed-Head: 9ce7456
Verdict: APPROVED
Scope:  增量复审 494c5a2..9ce7456(5 files,+47/−18,无 Swift 改动);首轮全量 21 files,+1536/−2 的结论见文末「首轮记录(已被本记录取代)」

## Findings(针对 494c5a2 之后的改动)

- **[已解决·上轮 P1] scripts/mediaremote-leak-check.sh — 修法与根因因果对应,非绕过**:① 基线改为预热 500 发**响应落地后**采样(`wait_lines` 轮询计数文件,不再押响应速率);② 固定 `sleep 8` 删除,改为 `wait_lines WARMUP+CALLS`(超时 240s,daemon 死亡即 PROBE-FAIL);③ 阈值 2000B/发与默认 5000 发**未动**——没有放大阈值迁就。响应计数从落盘 `wc -l` 改为流式 awk 计数(每 50 行刷计数文件),顺带解决 artwork 单行 ~735KB 的落盘浪费,合理。**放歌态实证(评审亲跑,本机播放中 playbackRate=1)**:新资产默认参数 `calls=5000 warmup=500 per_call=716B` → LEAK-GREEN **exit 0**(56s 跑完;上轮同态两次 exit 2、降档 800 发假红 exit 1);旧资产 `--calls 1000 per_call=779196B` → LEAK-RED **exit 1**(红侧同样走新轮询机制)。守卫在本机最严苛场景双向有牙、无误红。
- **[已解决·上轮 P3] scripts/check-arch.sh:134-135 — rusage 围栏规则登记首个 A 档合法豁免位点**(NowPlayingCLI 看门狗显式 RUSAGE_INFO_V3 + fence: allow),「规则与为什么同住」口径恢复;check-arch 实跑 exit 0。
- **[已解决·上轮 P3] docs/experience-playbook.md:236 — getrusage 一刀切口径补 V3 例外指针**,措辞与本轮实测一致(评审独立探针 rc=0 复核过)。
- **[已解决·上轮 P3] scripts/build-mediaremote-mini.sh:14-16 — 「可重放」夸大已改口**(gzip 层可重放 / Mach-O 层受随机 LC_UUID 与 install_name 影响,资产审计用符号面+ObjC面+反汇编对拍),与评审实测一致。
- **[P3·遗留·非阻塞] scripts/mediaremote-leak-check.sh 仍未接自动门禁(CI/feat-done 都不跑)**;修法:P1 已修好,建议排期接进 CI(macOS runner 无媒体 = 快响应态,空闲泄漏 7.6KB/发可测),入 guardrail-backlog 即可。上轮已明示为修好后的建议项,不阻塞本次合并;需求「可重跑的回归守卫」以手动重放形态已满足并双向实证。

## 增量验证(全部第 4 级证据,评审亲跑)

- 零漂移检查:`git diff 494c5a2..HEAD -- . ':!.reviews'` = 5 文件(AGENTS.md / experience-playbook / build 脚本注释 / check-arch 注释 / leak-check 脚本),全部逐行过,无夹带。
- 门禁:`check-arch.sh` exit 0、`doc-audit.sh` exit 0。
- 守卫双向:新资产默认 5000 发放歌态 **exit 0**(716B/发);旧资产 `--calls 1000` **exit 1**(779196B/发)。
- 跳过项与理由:lint.sh / affected-tests.sh / mutate.sh——本增量零 Swift 改动(diff 无 .swift 文件),同 Swift 文件在上轮 494c5a2 已全绿(affected 6 用例 exit 0、变异 ×2 exit 65)。
- AGENTS.md:168 守卫口径同步(「预热 500 发后量斜率…放歌/空闲态皆可」)与脚本实际行为一致——doc-audit exit 0 佐证路径断言未破。

## 审查清单(沿用首轮,增量项复核)

- [x] **判别剃刀**:守卫修后双向实证(绿 716B / 红 779KB),预热消除了斜率污染,误红消除。
- [x] **证据纪律**:修复提交信息自述与评审独立复跑结果一致;关键数字(126 发/s、~582B 渐近)与本机实测吻合。
- [x] **Swift 6 并发**:本增量无 Swift 改动,N/A(上轮结论维持)。
- [x] **最小改动**:5 文件逐行可追溯到 P1+P3×3;响应计数改流式是 P1 修复的必要配套(artwork 行 ~735KB 不宜落盘),非顺手改。
- [x] **错误路径**:`wait_lines` 超时/daemon 死亡均响亮 PROBE-FAIL exit 2;100% 响应齐才量斜率(比旧 90% 更严,方向正确);计数文件瞬时空读由循环自愈(下一秒重读),无假路径。
- [x] **坑总目录对照**:AGENTS.md 媒体节口径随守卫行为同 commit 更新,三处对账(代码/手册/断言)齐。
- [x] **文档同步 / 工作流机制清场**:见上轮 P3×3 全部落实;遗留 CI 接线已列 backlog 项。

## 教训候选

- **增长率类探针必须「预热后采基线 + 完成事件驱动收尾」**(scripts/mediaremote-leak-check.sh,本轮已落地验证):量内存斜率的守卫,基线采在零请求点会把首请求惰性初始化摊进斜率,固定 sleep 又把结论押在机器/环境响应速率上——判据:探针结论若依赖「跑的时候没在放歌」这类环境状态,就是探针的 bug,不是环境的。(候选入 guardrail-backlog:以后新增性能/内存探针脚本时按此判据审。)
- **二进制资产的可审计性可机械对拍**(首轮手法):导出符号面 + ObjC 面 + 关键函数反汇编三重 diff,能在不可逐字节重放(随机 UUID/install_name)时确证「资产出自 vendored 源码」,可作为以后换资产的固定评审动作。

## 首轮记录(494c5a2,已被本记录取代,留档)

首轮 Verdict CHANGES_NEEDED:P1 = 守卫固定 `sleep 8` + 零发基线,放歌态跑不到结论(exit 2)且降档假红(exit 1);P3×4 = check-arch 校准注释、playbook 口径、build 脚本「可重放」措辞、CI 接线。主修复(@autoreleasepool 补丁 + 指纹强制重解压 + 看门狗)首轮即实证有效:旧资产放歌 735KB/发纯线性 vs 补丁资产 ~582B/发渐近;proc_pid_rusage V3 契约独立探针 rc=0;提交资产经符号面/ObjC 面/反汇编对拍确证出自 vendored 源码;lint/doc-audit/check-arch/affected(6 用例)/变异(×2 exit 65)全绿。上述首轮验证结论在 9ce7456 复核范围内未被任何改动触碰(Swift/资产/vendored 源零变更),继续有效。

---

**Verdict: APPROVED**——P1 修复与本轮实证闭环(放歌态双向:新资产 exit 0 / 旧资产 exit 1,阈值未动),P3×3 落实,遗留 CI 接线为非阻塞 backlog 项。我愿意为这个合并背书。

关键文件:`/Users/aa00930/Documents/Learn/macos/NemoNotch/.worktree/mediaremote-daemon-leak/scripts/mediaremote-leak-check.sh`(P1 修复,已验证)、`.../scripts/check-arch.sh`、`.../docs/experience-playbook.md`、`.../scripts/build-mediaremote-mini.sh`(P3×3)、`.../AGENTS.md`(口径同步)、`.../.reviews/mediaremote-daemon-leak.md`(本记录,待你方落盘提交)。
