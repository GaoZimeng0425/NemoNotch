# NemoNotch 项目开发经验手册

> 生成日期:2026-10-20(同日按独立审读意见修订)
> 本手册是对 NemoNotch 约六个月开发过程(提交历史、项目文档、代码结构、工程流程四个视角)的一次经验蒸馏:去重、合并、归类,提炼出脱离本项目也成立的通用原则,并保留本项目战例与证据供回溯。

> **证据标注约定**(全手册适用):
> - 无标注 = 仓库内可复核:commit 哈希可 `git show -s` 验证存在与日期;`path:line` 只证明代码**现在**长这样(1.2 的第 2 档),事件经过靠 commit 正文与代码注释回溯,不等于运行时行为被复现过。
> - **(仓库外)** = 出自原作者本机的 Claude Code auto-memory(`memory *.md`)或兄弟仓库 macos-playbook(`docs/macos` 为 gitignore 的本地符号链接,fresh clone 不存在,`.gitignore:26-27`;本机当前也无此链接)。接手读者拿不到,仅作线索;凡结论仅依赖仓库外材料的,均随文声明。
> - **(未重放)** = 数字或叙述转录自四份挖掘材料,本次未在仓库复核。
> - 2026-10-20 已实测/重放的命令与输出全部列在附录,含独立审读后补测的部分。

---

## 项目速览

NemoNotch 是一个 macOS 刘海(notch)工具:在 MacBook 刘海区提供交互式浮层面板,集成媒体控制、日历、AI CLI 会话监控(Claude Code / Gemini / opencode / zcode)、多 agent 监控(OpenClaw / Hermes)与应用启动器。技术栈为 Swift 6 + SwiftUI(AppKit NSWindow、EventKit、IOKit),全程单人开发者 + AI 代理协作开发。工程纪律高度机械化:Git Flow + git hooks 门禁 + 合并即自动构建部署,平台深坑沉淀于按 file:line 锚定的活手册(AGENTS.md / macos-playbook)。

**关键指标**(除注明外均为 2026-10-20 实测,命令见附录):

| 指标 | 数值 |
|---|---|
| 提交总数 | 968(164 merge + 804 非 merge) |
| 时间跨度 | 2026-04-18 → 2026-10-20(约六个月) |
| 作者 | 唯一作者 GaoZimeng(+ AI 协作) |
| tag | 36 个(v0.1.0 → v0.8.0) |
| 规模 | 233 个 Swift 文件 / 39,512 行(其中 NemoNotchTests 56 个) |
| docs 提交 | 非 merge 且 subject 以 docs 开头 137 条;其中 touch docs/superpowers/ 的 65 条 |
| AI 协作痕迹 | 非 merge 提交正文含 `Co-Authored-By: … Claude` 的 134 条 |

(挖掘材料另称「约 81 条 docs 提交为设计 spec / 实现 plan」,该口径未能复现,故速览表采用上述可复现口径。)

---

## 第一章 流程与协作(单人 + AI)

### 1.1 设计先行:spec → plan → 代码 → 归档

- **通用原则**:特性动代码前先落两份文档(设计 spec、实现 plan),完成后把计划归档——变更因此可审计、「当初为什么这么做」可回溯,AI 协作者获得稳定上下文。给实施代理的计划不要只写目标,要把实现所需的关键符号、类型签名、file:line 预先查好写进计划(「关键事实」节),省去实施会话的重复检索,也避免它查错。
- **本项目战例**:全库 docs 提交遵循同一节奏(挖掘材料统计约 81 条,口径未复现,见速览表注):2026-04-21 先 7e74d0d(设计)+ d053a39(计划)再 52a39c3(Phase 1 实现);06-12 先 7c64df4 + 0d0c046 再连落 12 个 feat(flash);05-23 一条 5dbda55 归档 16 份已完成计划;06-23 66241ca 固化为 Superpowers specs/plans 目录布局。uitest-screenshots 计划带「关键事实(实现时直接用,无需再查)」一节,连新增/修改文件清单与配套单测都排好。
- **证据**:commits 7e74d0d / d053a39 / 52a39c3、5dbda55、66241ca;`docs/superpowers/plans/2026-06-01-uitest-screenshots.md`(路径存在已验证)。

### 1.2 验证声明必须声明证据档位

- **通用原则**:任何「已验证」的声明必须标明证据档位,且要清楚每档证明什么:①自述(无价值)→ ②指到 file:line / commit(证明代码现在这样、当时提交了这样一条信息,**不**证明运行时行为发生过)→ ③走通失败路径(主动触发失败分支并观察到预期的失败,例如删掉守卫看测试变红)→ ④实际跑过(可重跑的脚本/测试,交付退出码 + 完整日志)→ ⑤在运行中的 app 复现(真机观察)。安全相关结论没到第 ④ 档不得写成定案——听起来合理的 write-up 无论真假同样可信,「合理」不是证据;验证失败时先怀疑观测方法、再怀疑系统(支撑战例见 3.7 与 7.6,二者的定位手段都是先验证观测层)。委托工作(子代理/脚本)要检查产物本身,不看委托者的总结。
- **本项目战例**:AGENTS.md 把它定为行为准则(Evidence Discipline);scripts/test.sh 的存在由它驱动——测试结果必须引用脚本退出码和 build/test.log 日志路径,禁止凭记忆转述「测试过了」。本手册按同一梯子自评:战例大多停在第 ② 档(commit + file:line 回溯),已实测的数字集中在附录。
- **证据**:AGENTS.md「Development Conventions → Evidence Discipline」;`scripts/test.sh`;本手册附录的重放清单。

### 1.3 纪律机械化成 git hooks,围栏由真实事故驱动

- **通用原则**:能用 hook / 脚本 / CI 强制的纪律就不要依赖自觉;每道围栏都应能追溯到一次真实事故,并把事故写进文档(否则后人不知道围栏防什么、何时可拆);每道硬围栏配显式、有痕迹的逃生口(`--no-verify` / 环境变量),而不是拆规则;hooks 源跟仓库走、安装副本放进共享 `.git` 目录(git-common-dir)才能跨分支跨 worktree 生效。对 AI 协作者,若所用代理工具支持「写入后钩子」(本项目为 Claude Code 的 PostToolUse;前提是工具链有此机制),可对每次文件写入自动格式化,把风格纪律从提示词约定降级成无需记忆的机械动作。
- **本项目战例**:2026-06-26 本地 main 因 GitHub PR 按钮与本地 merge 双路推进,与 origin/main 产生 490/530 内容相同但 SHA 全异的分叉——此后 pre-commit 拦死 main 直提与主检出一切直提、pre-merge-commit 只放行 feature/* → develop、post-merge 合并即自动构建部署;事故根因写进 docs/git-worktree-workflow.md 的 Background 节。`.claude/settings.json` 的 PostToolUse hook 对 Write|Edit 的 .swift 自动 swiftformat,与 pre-commit lint 形成双保险。「围栏彩排当天真拦下一次已在途违规提交」「整套 ~90% 语言无关,换 lint/test/build 三脚本即可移植」两说仅见仓库外 memory,未在仓库内复核。
- **证据**:`.githooks/pre-commit:16-54`、`.githooks/pre-merge-commit:15-36`、`.githooks/install.sh:1-32`、`.claude/settings.json:3-11`(PostToolUse + swiftformat,已实测存在)、`docs/git-worktree-workflow.md:106-114`;memories nemonotch-guardrails-workflow.md / nemonotch-guardrails-backlog.md(仓库外)。

### 1.4 门禁防假绿:退出码、零用例守卫、管道吃退出码

- **通用原则**:测试入口的唯一交付物是退出码 + 完整日志路径,不要转述;必须防御「跑 0 个测试却返回 0」的静默假绿;门禁发现检查工具缺失时必须非零退出而非跳过(尤其在 AI 代理跑门禁的场景,静默跳过会被当作「通过」写进结论);shell 里把检测命令接进管道会吃掉它的退出码,把「检测出错」降级成「无问题」——fail-closed 的检测保持裸命令。
- **本项目战例**:scripts/test.sh 把 xcodebuild 输出整体重定向进 build/test.log(不用 tee,POSIX sh 拿不到管道退出码),结尾打印退出码与日志路径;实测 Xcode 27 下 `--only` 过滤器无匹配会跑 0 个用例仍返回 0,脚本以「通过 + 失败双零即判失败」兜底。lint.sh 缺 swiftlint/swiftformat 即 exit 1,注释写明「防 agent 在未装工具的机器上假绿通过门禁」。feat-done 里 `git diff --name-only` 特意不接 `| head`;build.sh 的 `grep … || true` 后接显式 fallback 并标注「load-bearing」。
- **证据**:`scripts/test.sh:42-55、76-83`;`scripts/lint.sh:30-41`;`.githooks/feat-done.sh:36-38`;`build.sh:30-34`。

### 1.5 评审者 ≠ 作者

- **通用原则**:写代码的会话不能给自己的代码盖「安全」章——合并前评审必须出自没写过这段代码的会话/子代理;评审者拿不到足够上下文时应明说「无法给 verdict」,不得静默放行;CI 绿、lint 绿、构建成功只是信号,不是结论。
- **本项目战例**:feat-done 前由 code-review 子代理独立过 feature diff;.superpowers/sdd/ 留下完整证据链:7 个任务各有 brief/report 与逐任务 review diff,progress.md 记录每任务结论(含一次 Critical 修复),终审覆盖全分支找出 4 个 Important → 修复 commit → 复审 Approved 才合并。狗粮实测抓出过 P1 静默假绿与合并解析缺陷(仓库外 memory 记述)。
- **证据**:AGENTS.md「Git Workflow → Judge ≠ author」;`.superpowers/sdd/progress.md` + review-b1c82e2..e995506.diff(路径存在已验证)。

### 1.6 合并即部署 → 门禁前移;昂贵自动化触发面收窄

- **通用原则**:当某个事件(合并)会自动触发昂贵且影响真实的动作(部署)时,质量门禁必须插在事件之前,而不是事后补救;自动化越昂贵,触发条件越要收窄并逐条写明排除理由,还要防御「默认格式变化导致永不触发」的静默失效。
- **本项目战例**:post-merge 让 develop 收下 feature 合并就自动 ./build.sh 装进 /Applications 并重启,所以 feat-done 在合并前先在 feature worktree 跑单测,失败即中止、分支原样保留。post-merge 触发要求同时满足「develop + 主检出 + HEAD subject 是来自 feature/hotfix 的集成合并」,注释逐条解释(worktree 里 merge develop 只是同步);来源从 HEAD subject 解析而非 MERGE_MSG(hook 运行时可能已被清理),并为无引号自定义合并信息补了第二条 sed——不加它自动构建永远不触发。
- **证据**:`.githooks/feat-done.sh:28-55`;`.githooks/post-merge:6-34`。

### 1.7 活手册:AGENTS.md + file:line 锚定的 cookbook

- **通用原则**:与 AI 结对的项目要维护一份持续更新的工程手册:架构、坑、流程规则全部落在版本库里,并要求每次功能改动同步更新,让每个新会话开机即继承全部经验;平台深坑解法沉淀进按 file:line 锚定的 cookbook 并随修复持续增补;给 AI 协作者的说明文件必须是被工具真正读取的那份实体文件(旧名只留链接),避免两份文档漂移;刻意不做并已定案的决定也要记录并标注「勿再议」。**注意:同步更新是立下的规则,不是自动达成的事实**——手册与代码会漂移,应把「手册落后于实现」当作预期内的故障模式对待(见下)。
- **本项目战例**:AGENTS.md 671 行,Debug Pitfalls 按日期记录实测坑;CLAUDE.md 符号链接到它;macos-cookbook 拆到兄弟仓库 macos-playbook(仓库外,本机 docs/macos 链接当前也不存在)。已定案记录:不强制 TDD、锁屏面板保持 display-only、SMAppService 路线在获得稳定签名前不再试。**漂移实例(2026-10-20 实测)**:HookServer 早在 27cb231(2026-05-16)改为 127.0.0.1 TCP(`NemoNotch/Services/HookServer.swift:18、:74、:102` 现为 NWListener),但 AGENTS.md:127 架构图与 :192 opencode 段至今仍写 Unix socket——落后 5 个月。「随代码更新」的规则本身没有防护,数字与架构断言类文档要么配对账 CI,要么写明「截至日期」。
- **证据**:AGENTS.md 全文 + Coding Conventions;commits 7d0168a、e07571b、77097c5、1cdba8a;AGENTS.md:127、:192 与 HookServer.swift:18/:74/:102 的矛盾(本次实测)。

### 1.8 worktree 嵌套的三重隔离 + DerivedData 路径哈希陷阱

- **通用原则**:在仓库内部嵌套第二份检出时,必须同时在 .gitignore、每个 lint/format 工具的排除表里登记,否则重复代码被扫描、格式化甚至误提交;构建缓存按项目路径哈希分配,每个 worktree 各有一份——在里面验证 UI 一律显式 `-derivedDataPath` 且每次构建前清空,最终确认以部署版为准(硬编码旧路径去 open 会启动过期二进制,而旧二进制跑起来「正常」,完全看不出是旧的)。
- **本项目战例**:git feat 把 feature worktree 建在 `.worktree/<name>`(commit 0b7c69a 一次改齐 8 个文件);「不排除时全仓 lint 扫 466 文件而非 232」出自仓库外 memory,数法未声明(当前全仓 Swift 文件 233,量级吻合)。2026-09-29 整轮设置窗调试都跑在前一天的旧构建上、结论全错同样出自仓库外 memory。本仓库「build」一词固定指 ./build.sh(archive→DMG→装 /Applications→重启),裸 xcodebuild build 只写 DerivedData。
- **证据**:commit 0b7c69a;`.swiftlint.yml:28`、`.swiftformat:5`;AGENTS.md:643-647(仅支撑上段末句「build 一词」的语义约定);memory worktree-ui-verify-deriveddata-trap.md(仓库外,DerivedData 陷阱的唯一来源)。

### 1.9 工具拥有的文件格式配「规范序列化器 + 提交时归一化」

- **通用原则**:由外部工具 GUI 拥有格式的文件,必须有一个逐字节复刻工具输出的规范序列化器,并在提交时归一化——否则脚本/手工编辑会把一次小改动放大成全文件重排。
- **本项目战例**:xcstrings.py 的 dump_canonical 复刻 Xcode String Catalog 的全部怪癖(2 空格缩进、冒号两侧空格、不排序、空对象展开、无尾换行),注释强调「这是唯一的序列化契约,绝不许用会排序 key 的临时序列化器」;pre-commit 对暂存的 *.xcstrings 自动归一重暂存,GUI/脚本/手改殊途同归为最小 diff;中英双语键随特性同提交落地。
- **证据**:`scripts/xcstrings.py`(WHY THIS EXISTS 注释);`.githooks/pre-commit:70-85`;commits 23c01a7、0afe9ab。

### 1.10 CI 的每个非常规选择带实测注释——注释里的数字会过期

- **通用原则**:CI 的缓存键、构建配置、目录排除、cron 分钟都该带注释说明实测原因——这些注释就是 CI 的坑记录,防止后人「优化」回退;配套最小权限 token 与 concurrency 取消。**衍生教训:注释里的统计数字会过期,应带日期**——数字型注释(「N 个文件占 X%」)过期后反而误导。
- **本项目战例**:codeql.yml 注释密度极高:缓存键用 Package.resolved 而非 github.sha(否则每次提交都 miss);在 CodeQL tracer 启动前预解析 SPM(git 子进程 fetch 在 tracer 下会卡死);用 Debug 构建(数据库取自编译前端,快数倍);cron '27 6 * * 1' 避开整点。目录排除注释原文为「NemoNotchTests holds 27 of 143 Swift files (19%)」——27 是测试文件数、143 是当时全项目 Swift 文件总数;2026-10-20 实测已是 56/233,注释未更新,本身即「数字注释会过期」的活例。
- **证据**:`.github/workflows/codeql.yml:22-30、34-38、55-82、91`(91 行原文与当前 56/233 实测均为本次核对)。

### 1.11 动效/手感以小步提交迭代,保留整个删掉的选项

- **通用原则**:探索性工作(动效/手感)每调一版就提交,让手感历史可回退可 bisect;纯装饰动效反复出问题时,删掉它比修它便宜——颜色/发光常能承载同样的状态语义。
- **本项目战例**:完成闪光一天内 6 连调(55abd87→5258a07:实心边→双脉冲曲线→全 easeInOut);FAB 会话环的 repeatForever 脉冲在芯片重排时画幽灵环(详见 4.2),最终由 e44da3f 直接删掉脉冲改用颜色承载状态。
- **证据**:commits 55abd87、0f9a3dd、fb9098a、12652e7、1310446、5258a07、e44da3f。

---

## 第二章 架构与状态设计

### 2.1 多提供方收敛到单一事实源 store + registry

- **通用原则**:多个数据提供方写同一个中心可观察 store,UI 只读排序视图、永不碰提供方内部状态;同类外部系统的适配器统一实现一个协议,由 registry 收集并暴露合并读——接入新提供方 = 向 store 写入 / 一次 register 调用,零消费端改动。协议只收公共接口,各实现的专有字段留在具体类型里。**前提:派生视图「每次变更全量重建」的取舍只适用于实体数小(本项目会话数为个位~几十)的场景;千级以上实体应改增量维护或索引排序,照抄全量重排会踩坑。**
- **本项目战例**:AISessionStore(@MainActor @Observable)收拢 Claude/Gemini/opencode/zcode 四个提供方,各自把 hook 事件 + 文件解析翻译成 upsert/mutate,UI 只读缓存的 sortedSessions(每次变更全量重排,N 小可接受);AgentMonitorRegistry 统一 OpenClaw/Hermes,组装根里就是两行 register。mutate 内集中盖 phaseChangedAt 时间戳——一个写点,所有读者(等待提醒的 waited 时长)免费获得。
- **证据**:`NemoNotch/Services/AISessionStore.swift:1-130、:69-71`;`NemoNotch/Services/AgentMonitorRegistry.swift:1-31`;`NemoNotch/Helpers/AppDependencies.swift:94-96`;AGENTS.md:184(AISessionStore 段落起点)。

### 2.2 多写者竞态:每个事件自带权威来源标签

- **通用原则**:当多方(含第三方插件)对同一实体乱序写入时,把来源标识做成事件的权威字段、每次更新重赋值,而不是首写定终身;再用实体 id 前缀对未知来源做兜底归因——否则先到者会铸造幽灵记录,且错误归属永远无法被后续正确事件自愈。
- **本项目战例**:2026-06-26 外部 opencode 插件(oh-my-openagent)抢在对 ses_ 会话 POST 一条无标签的 Claude 形状事件,铸造出 .claude 幻影会话(opencode 图标变螃蟹);4cb1382 让 mutateOrCreate 里调用方的 cli_source 权威(session.source 改 var 每次重赋值),routeEvent 按 ses_ 前缀归因 opencode、sess_ 前缀归因 zcode,走在 Claude fallback 之前。
- **证据**:commit 4cb1382;`NemoNotch/Services/AISessionStore.swift:76-91`;`NemoNotchTests/AISourceRoutingTests.swift`。

### 2.3 组合根:构造顺序是行为

- **通用原则**:把内联的服务装配抽成组合根时,第一刀只做逐字、保序搬移,零重组零逻辑改动,全量测试绿即收——服务生命周期与启动顺序本身就是行为,重组与搬移混在一刀里出了问题无法二分;组合根用非可选 let 依赖列表(读起来是目录而不是 25 个可选字段 + if let 链),给 UI 的注入工厂放在依赖表旁边,新服务漏注入在编译期就暴露。
- **本项目战例**:AppDelegate 上 25 个可选服务字段 + 240 行内联构造抽成 AppDependencies.build(),提交正文明确「build() is a verbatim, order-preserving move — construction order is behavior, relocated not reorganized」;notchContent() 工厂紧挨依赖表。
- **证据**:commit 134b28b;`NemoNotch/Helpers/AppDependencies.swift:1-15、:71-229、:236-263`;refactor-roadmap 阶段 1 同约束。

### 2.4 决策纯函数 + 副作用外壳

- **通用原则**:把「给定输入该做什么」抽成无副作用的纯函数/纯结构体单独成文件,服务类只负责观察状态、调用纯函数、执行 I/O——最易错的分支组合不 mock 任何系统就全覆盖测试;极端受限环境(信号 handler、中断上下文)同理:把决策上移为普通环境下可测的纯标量函数,受限环境只留 I/O。
- **本项目战例**:三处同一模式:WaitingReminder.plan(提醒谁/撤回谁)、KeepAwakeReconciliation((系统标志, 标记) 全组合,注释原话「这是整个功能最容易出错的地方」)、CrashRestartPolicy(循环保护,注释「handler 在 async-signal-safe 约束下只能做标量运算,决策逻辑集中在这里以便测试」)。三个决策核各有独立单测文件,测试里没有任何系统 mock。
- **证据**:`NemoNotch/Services/WaitingReminderMonitor.swift:113-157`;`NemoNotch/Services/KeepAwakeService.swift:9-27`;`NemoNotch/Services/CrashGuard.swift:4-33`;对应三个测试文件。

### 2.5 三态决策:nil 是「读不到」不是 false

- **通用原则**:对外部系统的读取存在「读不到」时,决策函数的输入必须建模为 Optional 三态;任何一项未知就选保守动作(保留标记、不执行),并把这个理由写成代码注释——否则会把「观测失败」误当「状态已关闭」执行破坏性动作。
- **本项目战例**:KeepAwakeReconciliation 特意区分「系统确实没禁休眠」与「pmset 读不到」:nil 时若删掉所有权标记,App 会永久忘记那个 SleepDisabled=1 是自己开的,用户的 Mac 从此永不睡眠;KeepAwakeSleepNowDecision 三个 Optional 输入任一 nil 都不执行 sleepnow(宁可不睡,不把在用的机器睡黑)。
- **证据**:`NemoNotch/Services/KeepAwakeService.swift:16-27、:33-45`。

### 2.6 观察失效场景用 tick 兜底;观察先重挂再行动

- **通用原则**:事件驱动观察只在「被观察数据变化」时触发;当阈值靠时间流逝就能越过而数据不变时,必须补一个低频 tick;观察回调先重挂观察再执行动作,防止求值期间的变化丢失。
- **本项目战例**:WaitingReminderMonitor 类注释直接写明设计理由:阈值会在 store 毫无变化时被越过,纯观察永远触发不了,所以 30s Timer + withObservationTracking 双通道;observe() 的 onChange 里先调 self?.observe() 再 evaluate(),注明镜像 re-arm-before-acting 惯例。
- **证据**:`NemoNotch/Services/WaitingReminderMonitor.swift:10-13、:32-56`。

### 2.7 快照 diff 检测状态边沿,首帧只记基线

- **通用原则**:「X 从忙变闲」这类事件检测用纯值类型保存上一次快照、对拍当前快照实现;首次调用只记基线不报事件——天然免疫启动瞬间的误报,也不需要任何 mock。
- **本项目战例**:CompletionDetector 是 struct,持有 prior: [String: Bool],step() 对拍当前候选列表返回本回合转闲的单元;文件注释原话「首步只记基线,启动时已在跑的单元绝不误报」。CompletionFlashService 只负责喂数据和消费结果。
- **证据**:`NemoNotch/Services/CompletionDetector.swift:93-121`;`NemoNotchTests/CompletionDetectorTests.swift`。

### 2.8 快事件路径必须配慢轮询兜底,共享同一去重

- **通用原则**:文件系统/系统事件回调会静默丢事件,可靠性关键路径用「快路径(事件)+ 保底路径(定时轮询)」双轨,并共享同一份去重状态;C 回调进 Swift 先在线程上同步抽取 Sendable 字段再跳线程,不可跨线程携带非 Sendable 对象。
- **本项目战例**:Hermes 监控先轮询,05-13 换 FSEvents 提速,随即连吃两次 EXC_BAD_ACCESS(缺 kFSEventStreamCreateFlagUseCFTypes 的 cf99005;残留 UnsafeRawPointer 回调的 2fb12d8),且实测事件仍偶发不触发;次日 d59f37b 把 3s 轮询加回来作兜底、共享 lastMessageCounts/lastModDates 去重。
- **证据**:commits 55bae0f → cf99005 → 2fb12d8 → d59f37b(2026-05-13 → 05-14)。

### 2.9 解析器的前向兼容:未知输入忽略而非失败

- **通用原则**:解析外部进程/服务输出的解析器,遇到无法识别的字段或行应跳过而不是报错——老版本客户端面对新版本输出才能继续工作;解析器做成纯函数,不依赖进程即可测。
- **本项目战例**:ChatStreamEvent.decode 的注释原话「unknown lines are ignored——一个新 CLI 字段不能弄死读取器」,是气泡会话在 Claude CLI 升级后仍能存活的保险;JSONLFramer 同为纯函数,各有畸形输入测试。
- **证据**:`NemoNotch/Services/ChatTurnRunner.swift:5`;`NemoNotch/Helpers/JSONLFramer.swift`;`NemoNotchTests/ChatStreamEventTests.swift`、`NemoNotchTests/JSONLFramerTests.swift`。

### 2.10 编译器/检查器严格度按阶梯抬

- **通用原则**:语言/并发严格化迁移按 minimal → targeted → 完整模式逐级开旗标,每级配套逐文件桥接提交(@preconcurrency、nonisolated(unsafe) 等),CI 与本地同步对齐——一步到位只会淹没在报错里。
- **本项目战例**:2026-04-24 一天内 0e8c0a7 开 minimal、3ab1581 升 targeted、119d0d3 切 Swift 6 语言模式,中间穿插 6 个 swift6: 前缀的逐文件桥接提交;次日 b89787f 撤掉默认 actor 隔离改显式 @MainActor,05-06 9d18e51 再为 CI 修严格并发错误。
- **证据**:commits 0e8c0a7、3ab1581、119d0d3、b89787f、9d18e51(2026-04-24 → 05-06)。

### 2.11 服务随消费视图生命周期启停

- **通用原则**:只被某个可见 UI 消费的后台工作,用一个幂等的 setActive 协议绑定到叶子视图的 onAppear/onDisappear;挂在容器上会让服务在不可见时仍空转——让采样类成本与用户实际看到它的时刻对齐。
- **本项目战例**:LifecycleAware 协议要求 setActive 幂等,配套 .activates(service) modifier 明确指示「用在消费该服务的叶子视图上,不要用在容器上」;SystemService 等采样服务由此对齐可见性。
- **证据**:`NemoNotch/Helpers/LifecycleAware.swift:1-23`。

### 2.12 防抖/延迟意图状态机配 generation guard

- **通用原则**:「延迟后的意图」要带代数:同一时刻只允许一个 pending 决定,新意图取消旧的,回调执行前先校验代数是否仍是自己的——cancel() 不是已出队项的可靠撤销(这是 DispatchWorkItem 的文档语义,本项目为预防性设计,无记录在案的翻车实例)。
- **本项目战例**:EdgeBarHoverIntent 的头注释直接写了教训与对策:每个 pending 决定配 generation 计数,迟到的回调因代数不符被丢弃;同文件的行切换状态机(0.15s/0.12s 双 dwell)复用同一注入调度器,有专门单测。
- **证据**:`NemoNotch/Notch/EdgeBar/EdgeBarIntent.swift:15-22`;`NemoNotchTests/EdgeBarIntentTests.swift`。

### 2.13 「彻底重构」冲动先用数据评估,默认绞杀者而非重写

- **通用原则**:用户喊「代码很垃圾要重写」时先量化:文件数、行数、最大文件、有无 God file、测试覆盖;项目最值钱的资产往往是文档里 encode 的真机验证过的深坑解法,重写等于全部回归。默认方案是分阶段绞杀者:路线图入库、每项独立走完测试门再合并、阶段一只做逐字机械搬移零逻辑改动;正被高频修改的「战场文件」刻意推迟拆分,免得把后续改动变成大面积冲突。
- **本项目战例**:2026-09-30 评估:144 文件 / 2.87 万行 / 814 commits、最大 1096 行、无 God file——数据不支持重写(评估细节出自仓库外 memory,量级与当前 233 文件 / 3.95 万行一致)。绞杀者路线后:AIChatTab 1096→315+3 扩展(5fc334e)、UsageQuotaService 955→143+5 扩展(9488639);878 行的 SettingsView 因是 settings-resizable 拉锯的活跃战场被标记「刻意缓拆,稳定两周再拆」。
- **证据**:`docs/superpowers/plans/2026-09-30-refactor-roadmap.md`(在库);commits 9dddf34、4176728、5fc334e、9488639、134b28b;memory nemonotch-refactor-impulse-2026-09-30.md(仓库外)。

---

## 第三章 平台深坑与调试方法

### 3.1 框架回调在哪个队列到达,必须实测而不是读文档

- **通用原则**:框架「回调应该在注册线程到达」的假设会被系统版本推翻:回调按 @MainActor 隔离标注而在错误队列到达,会触发 Swift 6 的 dispatch_assert_queue 直接 SIGTRAP;框架子系统的同步初始化还可能死等内部锁。手法:回调线程先抽 Sendable 字段再 Task { @MainActor } 跳岛、主线程重解析非 Sendable 对象;框架初始化挪进带常驻 runloop 的专用线程。**转述纪律:区分「实测现象」与「归因」——现象是卡死/崩溃可复现,根因(哪个守护进程状态不佳、哪把锁)常常只是作者的推定。**
- **本项目战例**:2026-10-12 两份同栈 .ips:IOBluetooth 连接事件实际经 CoreBluetooth 协调器到达 com.apple.bluetooth.iobluetooth.coordinatorQueue,@MainActor 的 @objc 回调启动后 ~1s 崩(表象「app 打不开」)——队列错位是 .ips 栈可证的。两天后的另一案:**实测现象**是主线程同步调用 IOBluetoothDevice.register/pairedDevices 后卡死在 applicationDidFinishLaunching、无任何日志;**作者归因**为「bluetoothd 状态不佳时该初始化在信号量上无限等待」(BluetoothService.swift:136 注释原文如此,如何排除其他锁未交代);修法(挪专用线程)有效。
- **证据**:commits f0701c0、9723d4c(2026-10-12 → 10-14);两份同栈 .ips;`NemoNotch/Services/BluetoothService.swift:136`;AGENTS.md:318。

### 3.2 状态 API 会撒谎:能力验证要跑真实往返

- **通用原则**:注册/状态类接口可能返回成功而底层机制从未生效;判断「真的接上了吗」必须跑一次真实的能力往返(如 XPC ping),绝不能拿 status 枚举当验证;选定替代路线时,把「为什么放弃教科书方案」的实测数据写进文档,防止后人再走一遍弯路。
- **本项目战例**:ad-hoc 签名下 SMAppService.register() 返回成功、status 报 .enabled——两者都在撒谎,launchd 从不拉起 helper,XPC 直到超时才暴露;同探针还发现用户授权绑 app 的 bundle id 而非 cdhash(重签名不需重新授权),以及更换 helper 必须 unregister → register(探针细节记录在仓库外 memory)。
- **证据**:AGENTS.md「Keep Awake → Privilege route」对比表与「The trap」段;memory macminimode-keepawake-comparison.md(仓库外)。

### 3.3 GENERATE_INFOPLIST_FILE 工程:权限 key 写构建配置才进产物

- **通用原则**:构建系统合成 Info.plist 时,源码 plist 里的 key 不进构建产物;权限描述必须写成构建配置项(两套 config 都改),并用 PlistBuddy 打印产物里的值验证;缺失 usage description 的症状是「静默失效」——系统直接不弹授权框、设置面板也加不上,甚至启动即崩,极难归因。调试权限问题时第一步查产物里的实际 key。
- **本项目战例**:缺 NSAppleEventsUsageDescription 时 macOS 静默拒绝显示自动化授权对话框且无法手动添加;缺 NSBluetoothAlwaysUsageDescription 则进程一碰 IOBluetooth 就启动即崩。项目规则:新增权限 key 必须走 pbxproj 的 INFOPLIST_KEY_*(Debug/Release 双配置)并附产物验证命令。
- **证据**:AGENTS.md:369「Info.plist Configuration」;AGENTS.md「Bluetooth capsule → macOS 26 TCC pitfall」。

### 3.4 App Nap 会无限期推迟定时器

- **通用原则**:GUI 会话空闲时被小憩的进程,其 mach-uptime 时钟的 dispatch 定时器会被无限期推迟(挂钟不受影响);正确性不能依赖这类定时器,只能当加速路径;排查「定时器没触发」先问用户当时在不在机器前,别先挖代码。
- **本项目战例**:CrashGuard 的 120s 稳定清零 asyncAfter 用户不在场时连漏 3 晚(同一二进制用户在场时准时触发;闭包首行即无条件日志,排除静默失败);handler 侧 600s 窗口读 time(nil) 挂钟,不受小憩影响,循环保护正确性因此不依赖清零。
- **证据**:commit b1af104;AGENTS.md「屏幕重配崩溃族 → App Nap」段。

### 3.5 GUI 改动的机器验证:窗口 ID 直截 + alpha 像素探测

- **通用原则**:截图验证按窗口 ID 直截(免遮挡、免多屏坐标换算);低对比场景(黑底上的黑色形状)视觉模型(analyze_image 类图像理解工具)会带着确信口吻错判,形状/轮廓断言一律用 alpha 通道逐行探测;注意截图分辨率是物理像素,Retina 下与 pt 的换算要×2;点击失灵做三层诊断(平台视图/手势/controller 各插一条日志)——悬停活但 tap 死 = 手势被非激活/key 状态吃掉,不是坐标问题。
- **本项目战例**:analyze_image(图像理解工具调用)两次把刘海凹形顶角外扩错判成普通圆角;alpha 逐行探测 +「截图会裁剪到不透明 bounding box」交叉验证:1476 物理像素 = Retina ×2 下的 (700pt 主体 + 38pt 外扩) = 738pt × 2,分毫不差;三层诊断法定位过 AIStatusWindow tap 失灵(非激活窗口吃手势)。
- **证据**:memory nemonotch-ui-visual-verification-loop.md 第 2/8/18 条(仓库外);commit f1e2bc1。

### 3.6 日志纪律:时区、只记转移、审计级独立文件、记「为什么没发生」

- **通用原则**:日志时间戳必须与系统其他证据源(崩溃报告、ps、Console)同时区可比;轮询循环里只记状态的「变化」,不记每次 tick;关键路径还要记「为什么没发生」,否则排查时无法区分「事件没来」和「来了被过滤」;需要数周后审计的低频事件写独立的不滚动文件(主日志的保留期按实测算,默认容量上限常常覆盖你配置的滚动策略);Release 构建的日志级别下,.debug 进不了文件。
- **本项目战例**:NotificationService 每 2s 记一条「AX not trusted」长成全部日志量的 96%,1MB 文件 4 小时滚一个,把有用的全挤出 7 文件窗口;KeepAwakeEventLog 因实测主日志有效窗口不足两天而单独建不滚动文件(512KB 自截断、永不留半行);DDFileLogger 默认格式化器硬编码 UTC,曾把「刚写的日志」误读成「进程几小时前就停了」——LogService 换显式本地时区。合盖跳过的每个原因(外接显示器/开关关闭)都落 info 级。
- **证据**:AGENTS.md:490-506 Logging、:328 Keep Awake → Event log;`NemoNotch/Services/KeepAwakeEventLog.swift`;`NemoNotchTests/KeepAwakeTests.swift:24-58`;`NemoNotch/Services/LogService.swift`。

### 3.7 工具链观测层也会撒谎

- **通用原则**:长输出命令经压缩代理时,grep 压缩摘要会得到假结果——精确分析要落临时文件再查或绕过代理;构建工具的怪异行为先怀疑缓存/观测层:共享缓存损坏会报成网络错、签名报错会掩盖真实编译错(签名过了不代表编译过);环境特定修法沉淀进 memory/文档,不靠重新踩坑。这一条也是 1.2「先怀疑观测方法」的正面战例。
- **本项目战例**:`git log … | grep` 经 rtk 压缩后只回 1 条假结果(需要精确输出时写临时文件再 grep 或 rtk proxy);SPM 报 unable to read tree 是共享缓存损坏而非网络问题,修法 = 一次清干净 ~/Library/Caches/org.swift.swiftpm + 对应 DerivedData 再 resolvePackageDependencies(分次清无效);本机 xcodebuild test 必须带 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual(三条均出自仓库外 memory,是原作者本机的环境结论)。
- **证据**:memories nemonotch-release-flow.md、nemonotch-feat-done-from-worktree-bug.md、xcodebuild-test-needs-adhoc-signing.md(仓库外)。

---

## 第四章 性能与观测

### 4.1 性能探针默认关闭、热路径常驻、Release 可见

- **通用原则**:性能探针禁用态只读一次静态 Bool,即可安全常驻在最热的路径里;开关走环境变量/UserDefaults,报告打 info 级让 Release 构建也能看到——现场排障 tail 日志即可定位谁在烧 CPU。附:读进程资源用 getrusage 而非 proc_pid_rusage(当前 SDK 的 rusage_info_current 结构版本与内核不匹配会 SIGABRT)。
- **本项目战例**:PerfProbe 被 17 个调用点文件引用(另加定义文件共 18 个,`grep -rl PerfProbe NemoNotch --include='*.swift'`,2026-10-20 实测;挖掘材料记为 15,系当时快照),连 rebuildSorted 这种高频内部函数也有 begin/end 计时;MainThreadProbe 把每个 runloop turn 喂给它——「主线程 ~180 次/秒 × 1.8ms」的模式才变得可见,单回合阈值探针对此盲(多短回合 ≠ 一个长卡顿),beforeWaiting 栈采样也叫不出业务函数(工作早已返回)。
- **证据**:`NemoNotch/Helpers/PerfProbe.swift:1-40`;`NemoNotch/Services/AISessionStore.swift:113-118`;AGENTS.md「Performance Probe」节;文件计数命令见附录。

### 4.2 repeatForever 停不掉且对移动布局渲染鬼影

- **通用原则**:repeatForever 动画赋新值停不下来(属性已被插值到目标,连当前值都被隐藏),只能 reset 回去(硬切);布局位置会变的元素上还会按陈旧原点渲染鬼影帧。可控循环用 TimelineView(.animation(paused:))(暂停时末帧保持、无状态可失,值从 context.date 派生);位移动效交给 Core Animation 子层随布局走;只有位置稳定的元素才允许 repeatForever。**TimelineView 解决的是"停得住",不是"便宜"**:跑着时它照样每帧全树重走,常驻(收起态/长时挂载)的循环动画要下沉 Core Animation。**下沉时相位要跟着搬出实例**:TimelineView 的值从挂钟推导,天然所有实例同相;改成每视图一个 CA 动画后相位变成按实例,同一视觉同时出现在两处(matchedGeometry 两端、每屏一份)就会对不上——相位放进实例外的共享纯时钟,各视图按它摆位。(本条为该项目对此问题的唯一完整叙述,第七章修复簇仅引用不重写。)
- **本项目战例**:黑胶唱盘暂停后继续转,TimelineView(paused:) + angle(at: context.date) 解决;但它挂在收起态媒体徽章上,连同背靠背 withAnimation 的均衡器,放歌时主进程 ~23% 单核,2026-10-30 下沉 CA(`VinylSpinner`/`EqualizerBars`)后 ~1%;首版按实例从 0° 起转,收起小盘与展开大盘每次开合都重建、封面跳回正上方,评审抓到后改共享 `VinylClock`;FAB 会话环在 chip 因注意力排序重排时按旧布局原点渲染,捕获到「四个 chip 五个环」的鬼影(仓库外 memory 存有截图线索);边栏的工作环转而用 CABasicAnimation 子层(hitTest → nil)承载。
- **证据**:AGENTS.md「Collapsed-State View Tree」末两条、「Edge Bar → Three load-bearing pitfalls」第 3 条;memory fab-evlat-chips-refactor.md(仓库外)。

---

## 第五章 权限与全局系统状态

### 5.1 权限弹窗只在用户亲手触发的那一刻出现

- **通用原则**:授权型能力一律默认关 + 惰性启动:设置开关或权限卡片是唯一触发源,系统弹窗只出现在用户动作的那一刻;被拒后用静默探测(只读属性类 API,不初始化协调器)渲染提示,绝不轮询重试;启动路径绝不碰会触发 TCC 弹窗的 API;重装/重签名在系统眼中是陌生 app,默认开 = 每次重装都骚扰用户。
- **本项目战例**:蓝牙监听原来启动即碰 IOBluetooth,每次重装(ad-hoc 重签名 = TCC 视为陌生 app)都弹权限框;2026-10-17 改为 bluetoothToastEnabled 默认关 + 开关唯一启动源 + 静默 isDenied 探测(CBCentralManager.authorization 类属性,不初始化协调器)后,默认配置下新二进制不再弹。原则来自用户明示:「只有用户真正需要并且触发了,才弹」(仓库外 memory)。日历/定位/通知同样走 PermissionCard「从不自动请求」模式。
- **证据**:`NemoNotch/Helpers/PermissionCard.swift`;AGENTS.md「Permission UI pattern」与「Bluetooth capsule」段;memories feedback-permission-prompt-only-on-user-trigger.md / nemonotch-bluetooth-lazy-start.md(仓库外)。

### 5.2 翻转全局持久的系统设置:所有权标记 + 对账 + 退出还原

- **通用原则**:应用翻转任何跨重启存活的全局系统状态时:先写所有权标记再执行操作(中间崩溃也留痕);退出时只还原「标记证明是我们设的」状态,用户手工设的同名状态如实报告但不碰;启动只展示不自动还原(否则每次启动都弹授权);外部篡改可检测、自正 UI、记事件日志,但刻意不自动还原(无人值守弹不了授权框,诚实范围是 detect → 报告)。检测系统通知可能在内核写入前到达,重查要多次延迟采样;自己写操作触发的同款通知要抑制。
- **本项目战例**:pmset disablesleep 不还原 = 用户 Mac 永不睡眠且无可见原因;~/.NemoNotch/keep-awake.enabled 标记先写后执行;外部改动检测走 Darwin 通知(0/0.2/1/2.5s 重查)+ 10s 对账轮询双通道,isBusy 期间抑制;第二层 unprivileged assertion 覆盖篡改窗口,但跟随系统真相而非用户意图,不留隐藏状态。
- **证据**:AGENTS.md:328「Ownership marker + reconciliation」;`NemoNotch/Services/KeepAwakeService.swift`;KeepAwakeReconciliation 单测。

---

## 第六章 测试与可验证性

### 6.1 假测试判据:全返回默认值还会过,就是无鉴别力

- **通用原则**:每个测试必须给被测单元喂具体输入并断言字面输出或可观察副作用;判据是「若被测代码处处返回默认值,这个测试还会过吗?」——会过就没有鉴别力,不可能因缺陷而红;禁止「只断言调用发生过」与自指期望。是否强制 TDD 用数据说话,定了案就标注「勿再议」。
- **本项目战例**:AGENTS.md 定义判别剃刀并点名纯逻辑测试(CompletionDetector/BadgeGrouping 等)为范本;独立评审实测抓出 xcodebuild 对无匹配 -only-testing 跑 0 用例仍返回退出码 0 的静默假绿(Xcode 27),已加零用例守卫。「盲评数据显示强制 TDD 无质量差异只多烧 3-8.5 倍 token」仅出自仓库外 memory,样本量与盲评方法未在仓库内交代,**读者无法复核,应视为待验证断言而非定案依据**。
- **证据**:AGENTS.md「Testing → Test discernment」;memory pstack-adoption-assessment.md(仓库外,含 TDD 盲评数据)。

### 6.2 时间类逻辑注入调度器,测试用虚拟时钟

- **通用原则**:依赖延时的逻辑把「延迟执行」做成注入的调度器闭包,测试里换成虚拟时钟手动 advance;判别性断言落在窗口边界上;并验证「去掉守卫测试确实会红」(1.2 的第 3 档)。flaky 测试的解法是确定性化,不是容忍重试;**不把环境行为当被测契约**——断言对象应是「给定输入,单元的行为」,而不是「宿主此刻恰好不卡 / 光标恰好在那块屏」这类环境属性。
- **本项目战例**:BadgeDebounceTests 原靠真实 sleep 对 16ms/600ms 时序,宿主一卡就挂(一个用例曾跑 4.6s 打破 feat-done 门);25e659a 改成注入 DelayScheduler 手动触发待决更新,断言精确落在 +150ms 边界(过了 tick、还在 grace 内必须显示旧集合);「断言活动光标在某屏」的用例换成「每块屏在自己的中心/边缘都解析到自己」;0fb9ce7 再补一道虚拟时钟回归。
- **证据**:commits 25e659a、0fb9ce7;`NemoNotch/Helpers/DelayScheduler.swift:7-11`;`NemoNotchTests/BadgeDebounceTests.swift:11-41、:85-92`。

### 6.3 Bug 修复先提交会失败的回归测试(规则新立,尚无执行实例)

- **通用原则**:回归测试以失败状态独立落地,提交信息里引用真实失败输出,评审者可复放 red → green,而不是信任「已修好」的说法;仅在没有廉价本地测试目标时可跳过。
- **本项目战例**:该规则 2026-09-30 随 d743e34(feat(test-gate): pre-merge unit-test gate + evidence-discipline conventions)写入 AGENTS.md Testing 节。**如实声明:全史检索 `git log --all --no-merges | grep -iE 'failing test|red first|regression test'` 未找到符合「回归测试以失败状态独立落地、提交信息引用实际失败输出」的 commit;规则立下至本手册生成仅 20 天,按 1.2 的梯子此条目前是「自述 + 文档规定」档,尚无第 ② 档以上的执行证据。**
- **证据**:commit d743e34(2026-09-30,已 `git show -s` 核实);AGENTS.md「Testing → Bug fixes ship a failing test first」;检索命令与空结果见附录。

### 6.4 测试/截图模式是一等环境:副作用路径显式 gate

- **通用原则**:把「UI 截图模式」「单测宿主」做成启动期可判定的环境开关,组合根里对每个会弹系统授权框或改全局状态的路径显式 gate + 一行注释说明跳过原因;测试数据指向 /tmp,不污染真实用户目录;确定性 mock 数据让截图可复现。
- **本项目战例**:UITestMode.isTestHost 用 XCTestBundlePath 环境变量 + NSClassFromString("XCTestCase") 双判定(动机:进程模态的蓝牙 TCC 弹窗会在测试连接建立前挂起整个宿主);AppDependencies.build 里 keepAwake.start、bluetooth.bind、CrashGuard.install、锁屏面板各有一行 gate;--uitest 模式 seed 营销级活跃态、冻结天气与系统采样,产出确定性 README 截图。
- **证据**:`NemoNotch/Helpers/UITestMode.swift:38-45`;`NemoNotch/Helpers/AppDependencies.swift:111-130`;`NemoNotch/Services/CrashGuard.swift:71-77`;`NemoNotch/Helpers/UITestSeeder.swift`;commits f9a734a→8f75de6。

### 6.5 文件类测试的隔离与韧性断言

- **通用原则**:涉及文件 I/O 的测试每个用例生成独立临时路径(目录级 UUID)并 defer 清理;被测写入函数要自建缺失父目录;对「超限裁剪必须保留整行」这类半行损坏风险写专门断言——边界全部来自真实事故场景(全新安装、风暴写入)。
- **本项目战例**:KeepAwakeTests 的 makeTempLogURL 每用例拼 UUID 目录;一个用例验证 record 在父目录不存在时自建(模拟全新安装);另一个预置超 1MB 文件断言自截断后仍是完整行。
- **证据**:`NemoNotchTests/KeepAwakeTests.swift:5-16、:43-58`。

---

## 第七章 多轮才修好的教训(反复修复簇)

> 这些是花了多轮、多个提交才收敛的修复簇——同一症状反复出现,通常意味着修复停在错误的层,或问题本身有多层。这一节最值钱。为避免同一知识三处维护,与前文重合的内容只写增量并交叉引用(4.2 = repeatForever 全量;2.4 = 决策上移纯函数)。

### 7.1 同一类性能 bug 有多层:body 频率不等于渲染成本(cpu_resource 两层 + 回归)

- **通用原则**:同一性能 bug 可能在属性图、渲染层各藏一层,修掉第一层不等于关门——挂载着的视图即使 body 极少执行,其动画与可见性仍让渲染层每帧重走全树;用崩溃报告 + Time Profiler + 状态打印三方证据定位,修完必须重测(第一层修复自己引入了「插入无动画」回归)。衍生纪律:opacity/scaleEffect/零尺寸「隐藏」只隐藏像素不隐藏工作,昂贵子树用条件挂载 + .transition 承接进出动画(状态驱动的属性动画在插入时无前值可插值,会硬切);动画成本取决于挂载树大小而非触发频率;每屏一份的视图把成本乘以显示器数;动画驱动方式(状态循环 vs repeatForever)是红鲱鱼——只有卸载有效。repeatForever 家族问题的完整清单见 4.2,此处不重写。
- **本项目战例**:cpu_resource 看门狗 7 次杀进程:87b46bf 把 playbackPosition 拆出 @Observable 结构修掉 body 重算风暴;3 天后 d396741 发现 opacity 隐藏的整棵 tab 树仍在动画期每帧重走 display list(实测 22% CPU / 1774µs / 4 个 VinylDiscView → 卸载后 ~10% / 1242µs / 2 个);次日 0ddcd01 修掉 d396741 引入的「插入无动画」回归。sample 归因 52% 主线程时间在 ViewGraph 重走;VinylDiscView 的 20fps→repeatForever、frame→scaleEffect 两次重写各实测零改善;CompletionFlashView(body 仅 0.7-2/s)同族——body 频率对渲染成本零信息量,靠这个误判连找了几轮。
- **证据**:commits 330c68c、87b46bf、d396741、0ddcd01、39a7075、9869689(2026-08-04 → 08-12);AGENTS.md「Collapsed-State View Tree」节(实测数字);`NemoNotch/Notch/NotchView.swift:75、:255-262、:475-479`。

### 7.2 Keychain 授权 11 天 6 fix:持久化信任要锚定代码身份

- **通用原则**:持久化的「用户已授权」必须绑定可验证的代码身份(如 cdhash),身份一变按未授权处理;后台自动路径只做属性探测(kSecReturnAttributes 不弹跨应用 ACL 框),交互式读取只留给用户点击的按钮——no-UI 标志抑制不了 GUI 应用读数据的跨应用 ACL 弹窗;「忘掉授权」要区分「条目真没了」(errSecItemNotFound)与「ACL 临时不允许」(errSecInteractionNotAllowed),后者保留授权稍后重试而非永久退回按钮;本地缓存热路径凭据可以跳过 Keychain,但服务器 401 要失效缓存。
- **本项目战例**:11 天连出 6 个 fix:AI 标签页每次打开都弹同意框(98edce2)→ 发现 no-UI 标志无效,改按钮门控 + 持久授权(8d59516)→ 裸 bool 在 ad-hoc 重签名后失效又弹,改按 cdhash 键控(SecCodeCopySigningInformation)→ 加本地凭据缓存(accessToken + expiresAt,绝不含 refreshToken)让睡眠唤醒后免重授权(ce23ba0、dfe0fb9)。跨睡 ACL 信任失效 + errSecInteractionNotAllowed 保授权 + 静默 gated read,三件合起来才让 app 不再每次唤醒都要求重新授权。
- **证据**:commits 98edce2 → f29c67d → 8d59516 → 139ae19 → ce23ba0 → dfe0fb9(2026-06-11 → 06-22);AGENTS.md「Usage quota」段。

### 7.3 Settings 窗口拉锯战:别跟系统组件缠斗

- **通用原则**:系统组件若在每次状态变化时重新强加你无法覆盖的约束(工具栏样式、不可调宽),继续打 AppKit/KVO 补丁就是每帧跟框架打架;换成低魔法原语组件让约束原生消失。「一行修改」部署后无效,第一反应是写最小探针(本机一分钟编译)跑变体矩阵实测平台行为,而不是继续叠修复;下「平台不支持 X」的结论前先穷举候选 API;用户质疑结论时把它当重新穷举的触发器,而非要辩护的观点;修复从一行膨胀成多轮时,主动告知用户规模和预计轮数。
- **本项目战例**:05-16 e6405ed 采用 SwiftUI Settings scene;此后围绕「工具栏两行、窗口不可调宽」反复修补(NSToolbar 桥 2762025、autosave 探针 7c5c982、scene defaultSize 36a1c04、Atoll 对齐 0544b0e 等)——scene 每次侧栏折叠都重新强加约束,KVO re-patch 能过但每帧打架;10-19 554a281 换普通 Window scene,一行总结「re-imposes both on every toolbar change」,SettingsWindowChrome 整个删除(--stat:9 files,+86/−98,其中 SettingsWindowChrome.swift −66)。两个里程碑分开记:**09-30 探针矩阵**(纯内容/固定 frame/仅 ideal/min+ideal/+defaultSize)证明 scene 忽略内容 ideal、scene 级 .defaultSize 才是真旋钮,36a1c04 的 stat 为 3 files、+9/−58(SettingsWindowChrome.swift 57 行变动)——这就是「58 行」的出处;memory 所称「删成一行」指换成的那一行 scene 级 .defaultSize,未逐行核对;**10-19 换 scene** 才彻底删除补丁。规模口径声明:「拉锯约 20 个提交」是挖掘材料点名的策展子集(58438e2…e9fa0f7 共 18 个中间提交 + 首尾);机械统计 e6405ed..554a281 区间 touch NemoNotch/Settings/ 的非 merge 提交有 41 个(本次实测),哪些算「拉锯」无客观判据。
- **证据**:commits e6405ed(2026-05-16)、7c5c982 / 36a1c04(2026-09-30,含 stat)、554a281(2026-10-19,含 stat;三者 subject 均已 `git show -s` 核实);AGENTS.md「Settings window layout」「Default size & resizability」;memory feedback-trivial-fix-balloon-verify-first.md(仓库外,探针矩阵叙述)。

### 7.4 HookServer socket 四换路径:被平台虚拟化的资源从对端验证

- **通用原则**:沙箱/容器会静默重定向文件系统路径,bind 成功不代表对端进程看得见——验证必须从消费者进程发起(stat/connect);若某机制对你的 bundle id 已被系统性污染(即:无论换到哪个路径,该 app 写出的这类资源对其他进程都不可见——本项目表现为同 bundle id 的 unix socket inode 对外不可见,外进程 stat/connect 一律 ENOENT),别再换路径,直接换机制类别。
- **本项目战例**:AF_UNIX socket 四换路径全败:/tmp 被沙箱重定向(e2a9850),~ 下仍被遗留容器劫持(4e4768d),/Users/Shared 也复现外进程 ENOENT;05-16 27cb231 彻底弃 socket 改 127.0.0.1 TCP loopback(HTTP),问题终结——`HookServer.swift:18、:74、:102` 至今仍是 NWListener on 127.0.0.1。**后记:AGENTS.md:127 架构图与 :192 opencode 段至今仍写 Unix socket(见 1.7 的漂移实例),本条以代码为准。**
- **证据**:commits e2a9850 → 4e4768d → 27cb231(2026-05-15 → 05-16);`NemoNotch/Services/HookServer.swift:18、:74、:102`(2026-10-20 实测)。

### 7.5 屏幕重配崩溃族:派发栈内不销毁资源;兜底自愈必须带熔断

- **通用原则**:在自己订阅的通知/回调派发栈内同步销毁或重建框架持有的资源(窗口、监听器),会让框架在派发栈里过度释放它——栈内可能无任何应用帧,极难归因;一律 pending 标志合并 + 推迟一个 runloop turn 再重建(NotificationCenter block 观察者 queue: .main 在主线程 post 时可能同步执行,不要依赖它异步,自己显式推迟)。不能归零的平台层崩溃配致命信号自愈,但自愈必须带重启配额熔断(时间窗内 ≤N 次自动拉起,超过则放弃等用户);重启子进程必须等垂死进程真正退出(pid 释放)再拉起,带重试与失败审计。信号 handler 环境的通用纪律:禁任何会分配内存/拿锁的操作,缓冲预分配,依赖的静态状态在注册前显式初始化,函数指针按语言规则形成;具体到本项目的 Swift 6 / POSIX 细节见战例与 2.4(决策上移纯函数)。
- **本项目战例**:三份同栈 .ips:主线程 SIGSEGV,栈 = objc_release ← autoreleasePoolPop ← AppKit 屏幕重配通知派发 ← SkyLight datagram,栈内无任何应用帧;插显示器后频率从 30 天 1 次升到 24h 2 次。L1:重建改 pending 合并 + async 推迟一个 runloop turn;L2:CrashGuard(600s 窗口 ≤3 次,稳定 120s 清零),重启子进程先 `kill -0 $PPID` 等垂死进程退出(上限 20s)再 `open -a`(带三次重试,失败 rc 落独立审计日志);App Nap 只推迟清零、无害(b1af104 定性)。**Swift 6 / POSIX 限定细节**:handler 内禁 String/Array/Foundation 构造(它们 malloc,崩溃线程可能正持有 malloc 锁),数字解析手写标量运算;读到的每个 static(含策略常量的默认参数,它们在每个调用点求值)必须在 signal() 注册前显式触碰完成懒初始化;C 函数指针只能由顶层函数引用形成(Swift 6 拒绝静态方法引用);状态文件用定长记录原地覆写,避开非 async-signal-safe 的 ftruncate/sscanf。「kill -SEGV 端到端验证过 1s 复活、第 4 次放弃」出自仓库外 memory(AGENTS.md 无此句),按 1.2 属第 ② 档以下。
- **证据**:commits 99f7f2b、4f73c33、b1af104(2026-10-13);`NemoNotch/Services/CrashGuard.swift`(全文,含 4-33 决策核与 async-signal-safe 注释);AGENTS.md「屏幕重配崩溃族」节;memory wake-crash-sigsegv-nsstatusbarwindow.md(仓库外,kill -SEGV 验证)。

### 7.6 闪光窗口:非主屏无渲染表面 + close() 过度释放两次 SIGSEGV

- **通用原则**:创建后长期 orderOut、晚些才首次入屏的 borderless 全屏窗口,在非主屏可能永远拿不到渲染表面——可见性、frame、CGWindowList 全对但 WindowServer 里没有图像(dbc0e10 的 commit subject 称之为「具文窗口」,意近「徒具其表」:一切可见性指标俱在,唯独没有画面);从消隐转可见时重建所有屏幕的窗口(新建 + 立即入屏 = 实测能渲染的路径),闲置仍可 orderOut 省电;诊断用 screencapture -l 直截窗口本体,二分「窗口无表面」vs「被遮挡」——这也是 1.2「先怀疑观测方法」的支撑战例之一。换窗绝不能用 close():其 isReleasedWhenClosed 释放语义会在 Swift 并发 job 的 autorelease pool 里过度释放旧窗 → pool 排干时再 release → SIGSEGV;纪律 = isReleasedWhenClosed = false + 先建新窗、orderOut 旧窗、字典换引用交给引用计数析构,且窗口操作不留在观察 Task 里(挪进普通 main-queue block)。显示/隐藏优化必须在外接屏验证——主屏同路径不受影响,bug 静默。
- **本项目战例**:86c87dd 的省电优化(闲置 orderOut)在外接屏孵化「只在主屏闪」静默 bug(AppKit isVisible=true、CGWindowList onscreen=true、frame 分毫不差,但 screencapture -l 报 could not create image);dbc0e10 用直截二分定位「窗口无表面」;ef66497 的 close+重建修法又两次实锤 SIGSEGV(栈 = releaseUntil ← runJobInEstablishedExecutorContext);01e725f 弃用 close() 才根治。
- **证据**:commits 86c87dd(2026-08-11)→ dbc0e10 → ef66497 → 01e725f(2026-10-14;dbc0e10 subject 已核实);AGENTS.md「具文窗口陷阱(2026-10-14)」节。

### 7.7 CF Create/Get 规则:修好又被改回去的过度释放

- **通用原则**:C API 返回指针遵循 Create/Get 规则,takeRetainedValue/takeUnretainedValue 用错是延迟引爆的过度释放——毒化内存,哪次崩看运气,表象「app 随机消失」;定位靠 dSYM 符号化(atos -l 崩溃 base);这类修复必须就地加防回归注释写明历史踩坑,否则后人重写该函数时会把修复原样改回去。
- **本项目战例**:2026-04 崩过一次已修对(e9edfb9);2026-09-29 充电胶囊提交重写 readBattery 时把 takeUnretainedValue 改回 takeRetainedValue,次日一天 3 崩「app 老消失」;dSYM 定位到 IOPSGetPowerSourceDescription,改回并注明两次踩坑史(崩溃叙述出自仓库外 memory,代码注释与提交在库)。
- **证据**:`NemoNotch/Services/HUDService.swift:291`;commits 2af3a76 / e9edfb9 / 5a5e272;memory hudservice-readbattery-overrelease-crash.md(仓库外)。

### 7.8 FAB 三月四坑:组件坑越积越多时,替换比续修便宜

- **通用原则**:当一个组件的深坑清单持续增长(事件被吞、命中区错位、动画幽灵),续修的边际成本会超过整体替换;替换的第一版若只照抄旧交互的表象仍会脆——要按底层交互模型(谁拥有命中、谁计时序)重建一次。NSView 层三条实测(本项目平台,SwiftUI↔AppKit 混编场景):.allowsHitTesting 不拦 NSViewRepresentable 收到的事件(AppKit 把 mouseDown 派给最深的平台视图,隐藏层要设 NSView.isHidden);.offset 只移渲染不移 hit area(隐形命中区会吞点击,定位要用 Layout);SwiftUI 手势/悬停在非激活面板的 never-active app 里不可靠,命中应由宿主 NSView 的 tracking area + 几何解析承担。(repeatForever 幽灵一条详见 4.2,此处不重写。)
- **本项目战例**:FAB 悬浮胶囊三个月积累 4 个深坑:SwiftUI 手势在非激活面板全灭(f1e2bc1)、offset 定位的隐形命中区吞掉所有 chip 点击(754a4e3)、隐藏-by-opacity 层仍吃点击(7fb95b4)、repeatForever 幽灵帧(e44da3f);10-18 被 evlat 式左缘状态条整体取代(10a8e33);次日发现第一版「每个元素挂 NSView overlay」仍脆,67c4c5d 按交互模型重建为单一宿主视图 + 两个 tracking area + 几何解析(点击/悬停永不打架)。
- **证据**:commits 2dc4972 → f1e2bc1 / 754a4e3 / 7fb95b4 / e44da3f → 10a8e33 → 67c4c5d → e9f00e8(2026-08-04 → 10-19);AGENTS.md「Edge Bar → Three load-bearing pitfalls」。

### 7.9 项目第 3 天的七连 fix:连环 fix 簇指向错误的层——但要如实读时间线

- **通用原则**:同一症状连续多个补丁(尤其同日)通常是在错误的抽象层修:停下来找「frame 在哪定义 / 状态归谁管」那个正确的层;正确层的修复会显著收敛后续修法(后续修补变成同层的小参数微调,而不是继续换层),但**不保证零后续**——把「找到正确层」夸成「一次修对」会让读者在后续小修面前怀疑方法本身。
- **本项目战例**:项目第 3 天(2026-04-20),tab 滑动内容溢出刘海 2 小时内七连 fix,**按提交时间排序**:84ab5ea(17:49 整个内容区可滑)→ d426676(17:51 clip 到 notch 边界)→ aba5dc8(17:54 直接 clip 可滑内容)→ 35e27a9(17:55 方向感知过渡)→ **4b1ed94(17:58「在 frame 被定义的 openedContent 层 clip」,NotchView.swift 仅 2 行)**→ fd7ec0e(18:09 圆角 clipShape,5 行)→ 608e12e(19:00 按可见 notch 宽度取 frame,2 行)。如实读:前 5 个 fix 在 9 分钟内三换思路(元素→边界→内容区→方向→层级),4b1ed94 找到正确层;其后两个 fix(fd7ec0e、608e12e)都只动 NotchView.swift 的同层代码、各 ≤5 行,是形状与宽度的参数微调而非换层——收敛的形态是「修法变小变同层」,最后一个 fix 距 4b1ed94 62 分钟。hover-peek 动画也是三连改(7179275→70d4433→76e42f3)无解,最终连特性整个删掉。
- **证据**:`git show -s --format='%h %ci %s'`(七哈希时间与 subject 本次逐一核实);`git show --stat` fd7ec0e / 608e12e / 4b1ed94(均只触 NotchView.swift,5/2/2 行);commits 7179275→76e42f3(2026-08-14)。

### 7.10 MediaBridge 五周:前提被证伪时,连权限面整链删除

- **通用原则**:建立在「X 做不到」假设上的整套 workaround,假设被实测推翻后要连权限声明、UI 卡片、字符串一起整链删除,不留双路径;旧知识只有部分为真时,把真子集写回文档;下「平台不支持 X」的结论前先穷举候选 API(包括换桥接方式——如让 Apple 签名的系统二进制代为调用私有 API)。
- **本项目战例**:05-12 为播放态先建 US-001..005 校验系统,同日 f28d74c 又改成 ScriptingBridge 权威查询;五周后 9a7313e 实测发现「Spotify 必须 AppleScript 才能 seek」只对相对 SkipBackward/Forward 命令成立、绝对 MRMediaRemoteSetElapsedTime 走 perl bridge 通吃所有播放器——于是删掉 MediaBridge、Automation 权限卡与 NSAppleEventsUsageDescription 整条链(macOS 15.4 起进程内调用已被门控,控制一律走 perl bridge)。
- **证据**:commits 7afb17a / 0203d65 / 372b396 / 9f928ea / 961eda4 → f28d74c → 9a7313e(2026-05-12 → 06-18);AGENTS.md「Media Info Retrieval」节。

---

## 可迁移清单

> 全部通用原则浓缩为 checklist,**按适用域分层**:A 层平台无关,任何项目可直用;B 层 Apple 平台限定(AppKit / IOKit / TCC / Keychain / launchd);C 层 SwiftUI 限定;D 层工具链与代理限定(Xcode / SPM / Claude Code 等)。非 Apple 项目只取 A 层。

### A. 平台无关

流程与协作:
- [ ] 特性动代码前先落设计 spec + 实现 plan,完成后归档;计划里预消化关键符号/file:line
- [ ] 每个「已验证」声明标注证据档位,并清楚每档证明什么;安全结论没实际跑过不得写成定案
- [ ] 验证失败时先怀疑观测方法,再怀疑系统
- [ ] 能用 hook/脚本/CI 强制的纪律不写在文档里等自觉
- [ ] 每道围栏追溯到一次真实事故,事故背景写进文档
- [ ] 每道硬围栏配显式逃生口,而不是拆规则
- [ ] 自动触发昂贵动作的事件,质量门禁插在事件之前
- [ ] 昂贵自动化的触发条件逐条收窄并写明排除理由,防默认格式变化导致永不触发
- [ ] 评审者 ≠ 作者:合并前评审出自未参与编写的会话/代理
- [ ] 多任务代理开发留持久化台账(简报/报告/逐任务 diff/终审)
- [ ] 维护活手册,坑记录带日期,强制随代码更新;已定案的「刻意不做」标注勿再议
- [ ] 手册与代码会漂移:数字与架构断言要么配对账 CI、要么写明「截至日期」——「同步更新」是规则不是事实
- [ ] 已定案的流程决定若依据不可复核的数据,标注数据出处与局限

门禁与 CI:
- [ ] 测试结果 = 退出码 + 完整日志路径,不转述
- [ ] 防「跑 0 个测试返回 0」的静默假绿(零用例守卫)
- [ ] 门禁缺检查工具时非零退出,不静默跳过
- [ ] fail-closed 的检测命令不接管道(管道吃退出码)
- [ ] 工具拥有的文件格式配规范序列化器 + 提交时归一化
- [ ] CI 每个非常规选择带实测注释;注释里的统计数字带日期(会过期)

架构与状态:
- [ ] 多数据提供方收敛到单一事实源 store;同类外部系统走 registry;UI 只读派生视图
- [ ] 「每次变更全量重建派生视图」只在小实体量下成立,大量实体改增量维护
- [ ] 多写者集成:来源标识做成事件的权威字段,每次写入重赋值;id 前缀兜底归因
- [ ] 抽组合根第一刀只做逐字保序搬移(构造顺序是行为)
- [ ] 决策抽成纯函数,服务类只做观察 + I/O;受限环境(handler)的决策也上移为可测纯函数
- [ ] 外部读取建模三态:nil 是「读不到」,未知走保守分支并注释
- [ ] 阈值靠时间流逝越过的逻辑:观察 + 低频 tick 双通道;观察先重挂再行动
- [ ] 状态边沿检测用快照 diff,首帧只记基线
- [ ] 可靠性关键路径:快事件 + 慢轮询双轨,共享同一去重
- [ ] 解析外部输出的解析器:未知输入忽略而非失败,做成纯函数
- [ ] 严格化迁移按阶梯抬旗标,每级逐文件桥接
- [ ] 只被可见 UI 消费的后台工作绑定叶子视图生命周期
- [ ] 延迟意图状态机配 generation guard(cancel() 不可靠)
- [ ] 「彻底重构」冲动先量化数据;默认绞杀者:路线图入库、每刀独立可验证、战场文件缓拆

调试方法:
- [ ] 框架「回调应到达的线程」实测,不读文档;回调先抽 Sendable 字段再跳目标线程
- [ ] 框架子系统的同步初始化挪出主线程(可能死等内部锁且无日志)
- [ ] 注册/状态 API 会撒谎:能力验证跑真实往返,不信 status 枚举
- [ ] 事件派发栈内绝不同步销毁/重建框架持有的资源;重建推迟一个 runloop turn
- [ ] 不能归零的崩溃配信号自愈,必须带重启配额熔断;子进程等垂死进程退出再拉起,带重试与审计
- [ ] 信号 handler:async-signal-safe(禁分配/拿锁、缓冲预分配、静态状态注册前初始化)
- [ ] 转述平台结论时区分「实测现象」与「作者归因」
- [ ] C API 的 Create/Get 规则配对 takeRetained/takeUnretained;修复处加防回归注释
- [ ] 换资源实例不用「关闭即释放」语义:建新、隐藏旧、换引用交给引用计数
- [ ] 长期隐藏后才显示的表面(窗口/图层)可能在部分输出目标拿不到渲染表面:显示时重建;用按 ID 直截二分「无表面 vs 被遮挡」
- [ ] 显示/隐藏优化必须覆盖非默认输出目标(外接屏/第二显示器)验证
- [ ] 沙箱/虚拟化下的资源可见性从消费者进程验证;机制对 bundle id 系统性失效就换机制类别
- [ ] 系统省电/休眠机制会推迟定时器:正确性不依赖它;排查「没触发」先问用户在不在场
- [ ] 日志:与系统证据源同时区、轮询只记转移、审计级事件独立不滚动文件、记「为什么没发生」
- [ ] 工具链观测层会撒谎(压缩输出/缓存损坏/签名错掩盖编译错),先怀疑观测层
- [ ] GUI 机器验证:按窗口 ID 直截 + 像素通道逐行探测,别信视觉模型;注意 DPR 换算

性能:
- [ ] 性能探针默认关闭(禁用态一次 Bool 读)、热路径常驻、Release 可见
- [ ] UI body 执行频率 ≠ 渲染成本;动画期渲染层每帧重走整个挂载树
- [ ] opacity/零尺寸不隐藏工作:昂贵子树条件挂载,动画迁到 .transition(等价物:插入/移除专用过渡)
- [ ] 动画触发值绑定屏上实际变化的值;每屏一份的成本乘以显示器数
- [ ] 同一性能 bug 可能多层,修完必须重测(防自引入回归)

权限与系统状态:
- [ ] 授权型能力默认关 + 惰性启动;弹窗只在用户触发那一刻;被拒后静默探测不轮询重试
- [ ] 启动路径不碰会触发权限弹窗的 API;测试宿主里对这些路径显式 gate
- [ ] 持久化授权绑定代码签名身份;自动路径只做属性探测
- [ ] 翻转全局持久设置:先写所有权标记、退出按标记还原、读不到时保守保留标记、启动只展示

测试:
- [ ] 假测试剃刀:被测代码全返回默认值还会过的测试没有鉴别力
- [ ] 时间逻辑注入调度器,虚拟时钟手动推进;断言落在窗口边界
- [ ] flaky 测试确定性化,不把环境行为当被测契约
- [ ] bug 修复先提交会失败的回归测试,失败输出写进提交信息(规则要有执行实例才算落地)
- [ ] 测试/截图模式做成一等环境开关;数据指临时目录
- [ ] 文件类测试:每用例独立临时目录、韧性断言(整行裁剪、自建父目录)

修复簇元教训:
- [ ] 同日连环 fix 簇指向错误的层:找「frame 在哪定义/状态归谁管」的层;「收敛」的形态是修法变小变同层,不是零后续
- [ ] 组件坑清单持续增长时,替换比续修便宜;替换也要按底层交互模型重建
- [ ] workaround 的前提被证伪时,连权限面整链删除,真子集写回文档
- [ ] 动效/手感每调一版就提交;纯装饰动效出问题时删掉比修便宜

### B. Apple 平台限定(macOS / AppKit / IOKit / TCC / Keychain / launchd)

- [ ] NSViewRepresentable 的 `.allowsHitTesting` 不拦 AppKit 事件派发;隐藏层要设 NSView.isHidden
- [ ] `.offset` 只移渲染不移 hit area;定位用 Layout
- [ ] 全屏 borderless NSWindow:长期 orderOut 后首次入屏在非主屏可能无渲染表面(详见 A 层对应条)
- [ ] NSWindow 换实例不用 close()(isReleasedWhenClosed 释放语义)
- [ ] 通知派发栈内过度释放是 SIGSEGV 高发区(AppKit 屏幕重配通知族)
- [ ] GENERATE_INFOPLIST_FILE 工程:权限 key 写 INFOPLIST_KEY_*(双配置)+ PlistBuddy 验证产物
- [ ] Keychain:no-UI 标志抑制不了跨应用 ACL 弹窗;属性探测 vs 数据读取分开;授权可锚 cdhash
- [ ] SMAppService/launchd:register() 与 status 在 ad-hoc 签名下都会撒谎,用 XPC 往返验证
- [ ] IOBluetooth:回调可能经 CoreBluetooth 协调器队列到达;同步初始化可能死等
- [ ] App Nap 推迟 mach-uptime 定时器(挂钟不受影响)
- [ ] pmset/IOPMAssertion 族:clamshell sleep 不吃 assertion;全局设置配所有权标记
- [ ] 私有 API 被门控给 Apple 签名进程时,可让 Apple 签名系统二进制(如 perl)代为调用

### C. SwiftUI 限定

- [ ] repeatForever 停不掉、移动布局上画鬼影:可控循环用 TimelineView(.animation(paused:));位移动效交 CA 子层;常驻循环动画一律 CA,相位放实例外共享
- [ ] 挂载树决定渲染成本:条件挂载 + .transition(插入时无前值可插值,状态动画会硬切)
- [ ] 非激活 NSPanel 里 SwiftUI 手势/悬停不可靠:命中交宿主 NSView tracking area + 几何解析

### D. 工具链与代理限定(Xcode / SPM / git worktree / Claude Code)

- [ ] 仓库内嵌套 worktree:gitignore + 每个 lint/format 排除表 + 永不被暂存,三重隔离
- [ ] DerivedData 按项目路径哈希:worktree 验证 UI 一律显式 -derivedDataPath 并清空;最终以部署版为准
- [ ] SPM「unable to read tree」= 共享缓存损坏,一次清干净再 resolve
- [ ] xcodebuild 无匹配 -only-testing 跑 0 用例仍返回 0:零用例守卫
- [ ] 代理工具支持写入后钩子时(如 Claude Code PostToolUse),自动格式化管住 AI 的手
- [ ] 长输出命令经压缩代理(rtk 等)时,精确分析落临时文件或绕过代理
- [ ] 「build」等词在仓库内固定语义(build.sh ≠ xcodebuild build),文档写明

---

## 附录:实测与重放清单

**来源材料声明**:本手册的战例与证据来自工作流脚本在会话内交给撰写者的四份原始经验挖掘材料(提交历史 / 项目文档 / 代码结构 / 工程流程四个视角的 JSON,含 facts 与 lessons),**未以文件形式存入本仓库,无路径可引用**——追溯链到该会话为止。撰写与独立审读两轮共重放了下述命令;未列出的 commit 哈希只做过抽查(subject/日期),未逐一重放 diff。

### 第一轮(撰写时实测)

```sh
git remote -v                                    # → git@github.com:GaoZimeng0425/NemoNotch.git
git rev-list --count HEAD                        # → 968
git rev-list --count --min-parents=2 HEAD        # → 164
git log --format='%ad' --date=short | tail -1    # → 2026-04-18
git log -1 --format='%ad' --date=short           # → 2026-10-20
git tag | wc -l                                  # → 36
find NemoNotch NemoNotchTests -name '*.swift' | wc -l                        # → 233
find NemoNotch NemoNotchTests -name '*.swift' -exec wc -l {} + | tail -1     # → 39512
ls NemoNotchTests/*.swift | wc -l                # → 56
```

### 第二轮(独立审读后补测)

```sh
grep -n '143\|19%' .github/workflows/codeql.yml  # → :91 "NemoNotchTests holds 27 of 143 Swift files (19%)"(27=测试文件,143=当时全项目)
git log --no-merges --format='%s' | grep -c '^docs'           # → 137(挖掘材料「约 81」未能复现)
git log --no-merges --format='%h' -- docs | wc -l              # → 133
git log --no-merges --format='%h' -- docs/superpowers | wc -l  # → 65
git log --no-merges --format='%b' | grep -c -i 'Co-Authored-By:.*Claude'  # → 134
grep -rl PerfProbe NemoNotch --include='*.swift' | wc -l       # → 18(含定义文件;调用点 17)
git show -s --format='%h %ci %s' aba5dc8 d426676 84ab5ea 35e27a9 4b1ed94 fd7ec0e 608e12e
  # 时间序:84ab5ea 17:49 → d426676 17:51 → aba5dc8 17:54 → 35e27a9 17:55 → 4b1ed94 17:58 → fd7ec0e 18:09 → 608e12e 19:00
git show --stat --format='' 4b1ed94 fd7ec0e 608e12e | grep -E '\.swift'  # 三者均只触 NotchView.swift(2/5/2 行)
grep -n 'nemonotch.sock' AGENTS.md               # → :127(架构图)仍有;:192 opencode 段仍写 Unix socket
grep -n 'NWListener' NemoNotch/Services/HookServer.swift  # → :18/:74/:102(现为 127.0.0.1 TCP)
git log --all --no-merges --format='%h %ad %s' --date=short | grep -iE 'failing test|red first|regression test'  # → 无匹配(6.3 由此标注「规则新立、无执行实例」)
git show -s --format='%h %ad %s' --date=short d743e34         # → 2026-09-30 feat(test-gate)
grep -n 'kill -SEGV' AGENTS.md                   # → 无匹配(该验证仅存仓库外 memory)
git show --stat --format='' 36a1c04 | tail -1    # → 3 files changed, 9 insertions(+), 58 deletions(-)(「58 行」出处)
git show --stat --format='' 554a281 | tail -1    # → 9 files changed, 86 insertions(+), 98 deletions(-);SettingsWindowChrome.swift −66
git log --no-merges --format='%h' e6405ed..554a281 -- NemoNotch/Settings | wc -l  # → 41(机械口径)
grep -n 'PostToolUse' .claude/settings.json      # → :3(hook 存在)
grep -n 'bluetoothd' NemoNotch/Services/BluetoothService.swift  # → :136(归因注释原文)
ls docs/macos 2>&1                               # → No such file or directory;.gitignore:26-27 声明其为本地符号链接
grep -n 'AISessionStore — central' AGENTS.md     # → :184(2.1 引用改此行)
```

引用路径存在性:1.1–7.10 所引的全部仓库内路径(30 项,含 .githooks/、scripts/、docs/superpowers/plans/、.superpowers/sdd/progress.md、各源码与测试文件)已逐一 `test -e` 验证存在,无悬空引用。

### 仓库外材料清单(接手读者拿不到)

- Claude Code auto-memory:`memory *.md` 系列作者本机文件——本文引用的有:nemonotch-guardrails-workflow / nemonotch-guardrails-backlog、worktree-ui-verify-deriveddata-trap、macminimode-keepawake-comparison、nemonotch-ui-visual-verification-loop、nemonotch-release-flow、nemonotch-feat-done-from-worktree-bug、xcodebuild-test-needs-adhoc-signing、feedback-permission-prompt-only-on-user-trigger、nemonotch-bluetooth-lazy-start、pstack-adoption-assessment(TDD 盲评数据)、hudservice-readbattery-overrelease-crash、fab-evlat-chips-refactor、wake-crash-sigsegv-nsstatusbarwindow、nemonotch-refactor-impulse-2026-09-30、feedback-trivial-fix-balloon-verify-first。
- 兄弟仓库 macos-playbook(docs/macos 符号链接目标)。
