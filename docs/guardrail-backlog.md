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
- [ ] **HookServer 手写 HTTP 分帧的守恒不变量**(来源:fix-hookserver-http-framing,2026-11-02。
  `hasCompleteHTTPRequest` 里 `after.firstIndex(of: "\r")` 恒 nil——Swift 把 `\r\n` 聚成一个
  Character——Content-Length 分支死代码、头块到齐即判完整:两段式客户端 POST /v1/toast 首发 400、
  >64KB hook 事件截断 65312/65313B,日志指纹最早 2026-10-30、累计 202 条无人察觉;已改纯字节级并有
  `HookServerFramingTests` 七用例)。三个候选:①**NWProtocolHTTP / `NWProtocolFramer` 替换手写
  分帧**的重构(用户拍板本分支不做,留作候选);②**check-arch B 档**:新增行拦 String 上的
  `firstIndex(of: "\r")` / `firstIndex(of: "\n")`(聚簇陷阱的机器可判定形状;Data 上的 UInt8
  查找不在拦截面),出生按 A/B 档四规矩自测;③**两段式客户端验收探针**(URLSession / 原始 socket
  头‖体分段)进 external-toast 指南或 CI——curl 永远单段发送,曾让整份 curl-only 验收清单假绿。
- [ ] **`AppActivator.onScreenWindowCount` 抽纯函数 + 判别性测试**(来源:harden-review-freshness
  评审 P3-1,2026-11-02)。过滤逻辑(pid / layer==0 / ≥200×150 / NSNumber cast)是纯逻辑,抽成接受
  `[[String: Any]]` 的 `normalWindowCount(_:)` 即可用合成窗口字典测(Mail 33px 辅助窗 + 800×600 真窗 +
  layer-3 + 他 pid → 期望 1),过 `mutate.sh` 验牙。log-only 路径,非阻塞。
- [ ] **review.sh「Verdict 行存在但非标准值」要提示而不重生成**(来源:同上评审 P3-2)。只认
  APPROVED/CHANGES_NEEDED/无法验证 之后,拼写偏离(如小写 approved)的记录重跑会被洗回空白模板;
  修法:`^Verdict:` 存在且非 `(填` 却不匹配白名单时退出并提示。窄风险(feat-done 只认 `^Verdict: APPROVED`)。
- [ ] **post-merge 钩子对纯文档合并跳过 `build.sh`**(来源:本条目自身的登记过程,2026-11-02)。docs-only
  feature 合入 develop 也触发全量归档 + 替换 /Applications + 重启 app(~3 min,用户眼前 app 闪一次),
  二进制零变化。判据与 feat-done 测试门禁同款:merge 区间无 `*.swift`/pbxproj/Resources 改动即跳过并
  打印一行说明。`NEMONOTCH_HOOK_DEBUG=1` 是干跑逃生口,不是机制。

## 已硬化(留档)

- [x] **freshness 自愈与比对吃同一份源**(2026-11-02,feature/harden-review-freshness):自愈在 worktree
  cwd 调 `install.sh`(`--show-toplevel` = worktree)装的是 worktree 旧源,比对却拿主检出新源——develop
  被别的会话推进且动过 `.githooks/` 时「✅ 已重装请重跑」无限循环(fix-toast-open-reopen 实踩,前后探针
  rc=1/1 → rc=1/0)。现 `(cd "$nf_root" && sh .githooks/install.sh)`。判据:**检测与自愈动作必须吃
  同一份真相源**;自愈脚本不许依赖 cwd 的相对 git 解析。
- [x] **review.sh 只认已填 Verdict 值**(2026-11-02,同 feature):裸 `^Verdict:` 被模板占位行
  `Verdict: (填 …)` 命中,空白模板重跑误报「已填不覆盖」(评审员实遇)。现正向白名单
  `^Verdict: *(APPROVED|CHANGES_NEEDED|无法验证)`。判据:**保护性判定锚定到值而非前缀**——
  `^Keyword:` 型 grep 对模板占位行天然误报;feat-done.sh:141 的 `(填` 反向守卫是同一课的另一种写法。
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

- **设置搜索索引对账**(来源:external-toast-api 评审 P2,2026-11-01;同型于 87fd2af)。新增
  Settings 页 section 时搜索索引是独立文件,漏登记零报警——用户搜不到开关 = 功能隐形,已二次
  发生。拟:check-arch.sh A 档规则「`Settings/Pages/` 引用的 `settings.*` key 必须出现在
  `SettingsSearchIndex` 对应页 keys」(页源码 grep 提取 ↔ 索引文件对账,纯文本可判定);上线前
  按 A 档规矩校准到零命中 + `--selftest` 样本(命中样本可直接取本次 P2 的三 key 形状)。

- **分发型文档的契约对表**(来源:external-toast-guide-ui 评审 P2,2026-11-03)。设置内指南常量
  复制出去即脱离仓库,但它出生时就落后于 base 的公开契约(jumpURL 11-02 已入库、指南 11-01
  定稿未同步)——同源链「常量↔指南文档」逐字一致有单测守,「指南文档↔README 契约表」无任何
  对账,断在最长的那级。拟:check-arch B 档或独立纯文本对表——提取 README External Toast API
  字段表与指南文档字段表的字段名集合(`jumpBundleId` 等),集合不等即红(新增字段忘了同步指南
  的场景全覆盖);措辞级差异不比,只比字段名集合。教训①(contains 锚点变异须选唯一出现锚,
  mutate 假阴性实案)一并记:AGENTS mutate 节加一句的候选。

- **增长率类探针的预热/收尾判据**(来源:mediaremote-daemon-leak 评审教训候选,2026-11-05)。
  量内存/CPU 斜率的守卫脚本若基线采在零请求点,首请求惰性初始化会摊进斜率(实测 ~3MB/500 发);
  固定 sleep 收尾把结论押在环境响应速率上(放歌态 126 发/s vs 空闲 560+ 发/s,同脚本同资产两态
  结论相反)。判据:**探针结论若依赖「跑的时候没在放歌」这类环境状态,就是探针的 bug,不是环境
  的**。拟:review.sh 审查清单加一条「新增性能/内存探针脚本必查:预热后采基线 + 完成事件驱动
  收尾」;现有探针按此盘点(mediaremote-leak-check.sh 已按此修正,2026-11-05 增量评审放歌态
  双向实证)。
- **二进制资产审计的机械对拍手法**(来源:同上首轮评审)。换 vendored 二进制资产(如
  MediaRemoteMini.bin.gz)时,「资产出自 vendored 源码」可机械确证:导出符号面 + ObjC 类/方法面
  + 关键函数反汇编三重 diff,绕开不可逐字节重放(随机 LC_UUID/install_name)的障碍。拟:记入
  docs/experience-playbook 评审手法节,以后换资产作为固定评审动作。
- **模板内容变更未 bump 版本标记 = 修复静默不分发**(来源:flash-window-anim-none 首轮评审
  P1,2026-11-13)。hook-sender 模板加了 `-m 1` 但 `scriptVersion` 留在 v16,`ensureScriptExists()`
  的「版本+端口标记一致即 no-op」让所有已装脚本永远拿不到修复——修了等于没分发。判据:**改
  HookInstaller/HermesHookInstaller 的脚本模板字面量 ⇒ 同一提交必须 bump `scriptVersion`**。
  拟:抽 `makeScript(port:)` 纯函数 + 单测钉模板关键内容(防回退、防漏 bump 由测试对版本号断言
  跟随内容);在那之前靠评审清单(review.sh 模板加一行「模板改动必查版本标记」)。
- **程序化入屏窗口的 .none 不变量可 B 档门禁化**(来源:同上,flash 线程泄漏案)。教训本体已入
  AGENTS.md 坑总目录(orderFront 的覆盖窗一律 `animationBehavior = .none`,2026-11-12/13 实案);
  存量违例已清零。拟:check-arch B 档加「新增 `orderFrontRegardless()`/`makeKeyAndOrderFront()`
  行须伴 `.none` 赋值佐证」——按四规矩先校准零误报再上线(跨文件事实,单模式会假阳,B 档只拦
  新增行可避开存量)。
