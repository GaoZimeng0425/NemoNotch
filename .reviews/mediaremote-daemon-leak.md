# Code Review — feature/mediaremote-daemon-leak

Reviewer: ZCode 独立评审子代理(GLM-5.3;judge ≠ author,未参与开发、不见作者对话)
Date: 2026-11-05
Reviewed-Head: 494c5a2
Verdict: CHANGES_NEEDED
Scope:  21 files changed, 1536 insertions(+), 2 deletions(-)

```
AGENTS.md
NemoNotch/Resources/MediaRemoteMini.bin.gz
NemoNotch/Services/NowPlayingCLI.swift
NemoNotchTests/DaemonLeakGuardTests.swift
scripts/build-mediaremote-mini.sh
scripts/mediaremote-leak-check.sh
scripts/mediaremote-mini-src/adapter/env.h
scripts/mediaremote-mini-src/adapter/env.m
scripts/mediaremote-mini-src/adapter/get.h
scripts/mediaremote-mini-src/adapter/get.m
scripts/mediaremote-mini-src/adapter/globals.h
scripts/mediaremote-mini-src/adapter/globals.m
scripts/mediaremote-mini-src/adapter/keys.h
scripts/mediaremote-mini-src/adapter/keys.m
scripts/mediaremote-mini-src/adapter/now_playing.h
scripts/mediaremote-mini-src/adapter/now_playing.m
scripts/mediaremote-mini-src/include/MediaRemoteAdapter.h
scripts/mediaremote-mini-src/private/MediaRemote.h
scripts/mediaremote-mini-src/private/MediaRemote.m
scripts/mediaremote-mini-src/utility/helpers.h
scripts/mediaremote-mini-src/utility/helpers.m
```

## Findings

- **[P1] scripts/mediaremote-leak-check.sh:78,83 — 守卫在本机放歌态既到不了结论又会对已修复资产假红;修法:① 发 ~300 发预热并等其响应完后再采 BEFORE;② `sleep 8`(L83)改为轮询 responses.jsonl 行数达 CALLS(带上限超时)再采 AFTER。** 评审实测(本机放歌中,即实案 artwork 场景):默认 5000 发两次跑均 PROBE-FAIL exit 2(8s 内仅 1277/5000、1264/5000 响应,~126 发/s);降档 `--calls 800` 迁就时限后,因 BEFORE 采在 0 发(首 ~500 发的 ~3MB 惰性初始化计入增长)对**已打补丁的现行资产**报 `LEAK-RED per_call=4935B` exit 1(假红)。数学上本机任何 call 数都无绿路径:≥~2200 发超时、≤~1000 发预热摊薄假红。提交 f3ea816 的 green 自述(5000 发 950B)只能在响应 ≥560 发/s 的空闲态成立——守卫结论依赖环境是否放歌,恰与要守的场景互斥。注意主修复本身有效(见下「独立测量」);假红的根本违背本仓 A 档校准哲学「会假红的警报会被学会忽略」(AGENTS.md 架构围栏节)。修好后建议同步改 AGENTS.md:168 「5000 发断言」一句的口径。
- **[P3] scripts/check-arch.sh:130-134 — rusage 围栏规则的 why/校准注释未登记本分支新增的首个 A 档豁免位点;修法:校准行补一句「2026-11-05 NowPlayingCLI.swift:214 看门狗以显式 RUSAGE_INFO_V3 + fence: allow 成为豁免位点」。** 按「规则与为什么同住」四规矩,校准现状(「0 命中」)已过期,不更新会误导下一个读者以为无合法位点。
- **[P3] docs/experience-playbook.md:236 — 「读进程资源用 getrusage 而非 proc_pid_rusage」的一刀切口径已被本分支部分推翻(显式固定 flavor V3 + 匹配结构体安全,评审已独立探针 rc=0 验证);修法:句尾补「(显式固定 flavor 如 V3 + 匹配结构体可用,见 AGENTS.md 媒体节看门狗)」。**
- **[P3] scripts/build-mediaremote-mini.sh:14 — 「gzip -9n(无时间戳,可重放)」夸大可重放性:dylib 链接含随机 LC_UUID、install_name 嵌 mktemp 路径,同机两次构建也不逐字节相同(评审实测两次重编 sha 均异;UUID 置零后反汇编/符号面才全同);修法:注释改口为「gzip 层可重放;Mach-O 层受随机 UUID 与 install_name 路径影响」,或加 `-Wl,-uuid,<固定值>` 后再声明。** 不阻塞——评审已用导出符号面 + ObjC 面双全同 + `_adapter_get` 47 行反汇编逐指令对拍,确证提交资产出自 vendored 源码。
- **[P3] scripts/mediaremote-leak-check.sh:1(整文件)— 守卫未接任何自动门禁(CI 与 feat-done 都不跑,仅 build 脚本注释与 AGENTS.md 引用);修法:P1 修好后接进 CI(macOS runner 无媒体 = 空闲快响应态,恰是 5000 发能跑完的场景,且旧资产的 7.6KB/发空闲泄漏在 CI 上可测)。** 现状「可重跑」仅是手动可用。

## 评审方法与独立验证(全部第 4 级证据,评审亲跑)

门禁(真实退出码):`lint.sh`=0、`doc-audit.sh`=0、`check-arch.sh`=0(fence: allow 豁免按引擎口径生效,filter_hits 对 A 档同样滤 `fence: allow` 行,与 check-arch.sh 头注释「已知的合法位点带行内豁免」一致)。

测试:`affected-tests.sh cbf67816…`(索引闭包,闭包 13 文件命中 2 类)→ BadgeDebounceTests + DaemonLeakGuardTests 6 用例全过,exit 0。变异 ×2:`256 * 1024 * 1024→128 * 1024 * 1024`、`guard destExists else { return true }→return false` 均被抓住(exit 65),文件恢复原字节。

泄漏主修复独立测量(分段线性探针,/tmp 手写、未动仓库):
- 旧资产(git show cbf67816 提取):放歌带 artwork ~735KB/发纯线性(1500 发涨至 1.07GB,每 300 发 +221~224MB);经提交版守卫 `--calls 500` 复放 = exit 1、560658B/发(红侧成立,红→绿可重放)。
- 新资产(提交版):首 ~500 发预热 ~3MB,之后 500→2500 发段斜率 ~582B/发——降 99.9%,主修复确证有效;与提交自述「补丁版 ~500B」一致(空闲态)。
- vmmap 峰值行解析验证:`Physical footprint (peak):` 的 $2 为 `footprint`(无冒号),awk 锚定 `$2 == "footprint:"` 只中非 peak 行,解析器正确。

proc_pid_rusage 契约:评审独立 C 探针(同款 v3 结构 + flavor 3)本机 rc=0、footprint 数值合理(1.1MB 小程序);与 PerfProbe 实案的 `rusage_info_current` SIGABRT 是不同形状,NowPlayingCLI.swift:204-218 的写法(显式 V3 + 结构体重绑)经核正确。

二进制资产审计:重编产物与提交资产导出符号全同、ObjC 类/方法面全同、`_adapter_get` 反汇编 47 行逐指令同;整文件差异由 LC_ID_DYLIB(install_name = build 脚本 mktemp 模板在用户 TMPDIR 下的路径,长度吻合 cmdsize 112)与随机 LC_UUID 解释。

Bug 专项镜头:①红→绿:守卫脚本(1beae11)先于修复(f3ea816)提交,彼时资产为旧版 → 按构造即红,评审已用旧资产实跑复放 exit 1;Swift 策略测试随实现同提交(新代码测试,非回归测试),可接受。②根因对应:`@autoreleasepool` 包住 perl 守护每行 stdin 调用的 `adapter_get`(get.m:122),恰是主线程同步路径的 autorelease 积累点(GCD 队列 block 自带池排空,不漏);实测两侧对比证实因果。③旧口径清场:见 P3 ×2(check-arch 注释、experience-playbook);README 无 MediaRemoteMini 表述,N/A。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:DaemonLeakGuardTests 断言字面期望,变异 ×2 全红,有牙;leak-check 对旧资产红/新资产渐近绿,方向有鉴别力——但其时间/预热缺陷(P1)会让「有牙」变成「乱咬」。
- [x] **证据纪律**:提交信息带实测数字与退出码(1beae11 引真实红输出,f3ea816 引对拍数字);唯一未能复放的是 f3ea816 的 green 数字(本机放歌态跑不完,见 P1)——其余声明(红、syscall rc=0、变异红)评审全部独立复现。
- [x] **Swift 6 并发**:看门狗在既有 `queue` 上调用,与超时重启同款上下文;syscall 为 static 纯函数;`@preconcurrency import CryptoKit/Foundation` 合规;无新 Sendable 边界。
- [x] **最小改动**:NowPlayingCLI +88/-2 全部可追溯到三项需求;vendored 源码整目录新增是「允许重编资产」需求的必要部分;无顺手改动。
- [x] **错误路径**:守卫 exit 2 响亮报探针故障;指纹读失败 → 重解压(fail-safe 方向);sidecar 写失败注释明说不致命;syscall 失败返回 nil 跳过本轮;无吞错假绿。
- [x] **坑总目录对照**:媒体节新增实案条目;PerfProbe rusage 雷区以显式 V3 绕开并独立验证;未复活 ScriptingBridge;MediaRemote 私有化路线未动;check-arch 绿。
- [x] **文档同步**:AGENTS.md 媒体节 +1 行完整记录三层修复与守卫入口;README/README_CN 无此深度表述,N/A。
- [x] **工作流机制清场**:触及 scripts/——grep 过 AGENTS.md/docs/注释,两处过期口径已列 P3;leak-check 未进门禁链已列 P3。

## 教训候选

- **增长率类探针必须「预热后采基线 + 完成事件驱动收尾」**(scripts/mediaremote-leak-check.sh:78,83):量内存斜率的守卫,基线采在零请求点会把首请求惰性初始化摊进斜率,固定 sleep 又把结论押在机器/环境响应速率上——判据:探针结论若依赖「跑的时候没在放歌」这类环境状态,就是探针的 bug,不是环境的。
- **二进制资产的可审计性可机械对拍**(参考本次手法):导出符号面 + ObjC 面 + 关键函数反汇编三重 diff 能在不可逐字节重放(随机 UUID/install_name)时确证「资产出自 vendored 源码」,可作为以后换资产的固定评审动作。

---

**Verdict: CHANGES_NEEDED**——主修复(@autoreleasepool 补丁 + 指纹强制重解压 + 看门狗)我愿意背书,证据充分;但需求明列的交付物「可重跑的回归守卫」当前形态在本机放歌态跑不到结论、且会对健康资产假红(P1),修完该条(机械改动)并补审 `--prev 494c5a2` 增量复审后即可 APPROVED。P3 四条默认不阻塞,≤3 行的两条(check-arch 注释、playbook 措辞)可顺手带走。
