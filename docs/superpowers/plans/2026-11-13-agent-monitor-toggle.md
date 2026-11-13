# Plan: agent 监控改为 toggle(开=注册 hook+读取,关=卸载+停止)

日期:2026-11-13
状态:已批准,已实现

## 背景

改之前用户看到什么:设置里点「卸载」删除 Claude 的 nemonotch hook 后,herdr 启动的
claude 进程仍被 record 轮询(3s 扫 `~/.claude/sessions/`)发现并跟踪,会话消失时
照弹红色「会话中断」卡;且 NemoNotch 重启后 `handleServerReady()` 无条件把
claude/gemini 的 hook 装回来,卸载形同虚设。

改之后用户看到什么:设置 → AI 与 Agent 里每个 agent 一张卡一个开关;关掉
Claude Code 开关 = hook 配置被卸、record 轮询停、事件路由丢弃、刘海/边栏/AI tab
里该源会话消失、**之后不再弹任何该源的卡**;重新打开一切恢复(装 hook、恢复
轮询)。所有 agent(Claude/Gemini/opencode/zcode/Hermes)语义一致。

## 根因(bug 的准确形状)

`claudeEnabled`/`geminiEnabled`/`opencodeEnabled`/`zcodeEnabled`/`hermesEnabled`
五个开关**已存在**于 AppSettings,但消费者全是 UI 过滤(BadgeViewModel、
UsageQuotaCardView)。服务层四处不看它:

1. `ClaudeCodeService.startRecordPolling()` 无 stop、无开关 guard(只跳 UITest)。
2. `AICLIMonitorService.routeEvent` 不拦截已禁用源的事件(含无主事件兜底归 claude)。
3. `AICLIMonitorService.handleServerReady()` 无条件重装 claude/gemini hook、无条件
   装 opencode 插件(zcode 已查 `zcodeEnabledKey`——同函数内不一致)。
4. `startSessionDiscovery()`(claude+gemini 磁盘扫描)与 `AICLIMonitorService
   .installHooks()` 无脑全跑。

## 方案

### Toggle 语义(五源一致)

- **开**:确保 hook/插件装着(未装即装,启动自愈仅对开启的源跑)、record 轮询与
  磁盘发现跑、路由放行。
- **关**:卸载 hook/插件、停止该源轮询与扫描、路由丢弃该源事件(无主兜底事件在
  claude 关闭时一并丢弃)、撤下 notch 自己 UI 上的该源条目(store 是 notch 的内存
  显示表,不是 claude 的数据——不碰外部进程/磁盘;撤下动作**不产生任何边沿事件、
  不弹任何卡**,见坑 1)。
- 关闭是即时生效的(不需要重启 app);打开同理会话发现立即恢复。

### 改动清单(按提交顺序)

1. **路由拦截**:`routeEvent` 判定事件归属后按对应 enabled 开关丢弃;claude 关闭
   时无主兜底(Claude 形状)也丢弃。测试:关 claude 后 Claude 形状事件与无主事件
   不进 store(路由纯函数化或经 store 断言)。
2. **record 轮询可停**:`ClaudeCodeService` 加 `stopRecordPolling()`
   (invalidate + nil);`startRecordPolling`/`scanExistingSessions` 增加 enabled
   guard;`startSessionDiscovery()` 按开关分派 claude/gemini。测试:guard 生效
   (注入 AppSettings 模式,对齐 UITestMode 现有 guard 风格)。
3. **自愈按开关**:`handleServerReady()` 与 `AICLIMonitorService.installHooks()`
   装 claude/gemini/opencode 前查各自开关(对齐 zcode 现状)。测试:关闭源在
   ready 回调后 hook 配置不变。
4. **静默清源(坑 1,必须)**:toggle 关闭时 store 中该源会话若直接移除,会触发
   CompletionDetector 的「仍活跃单元从快照消失 = sessionLost」边沿——关闭瞬间弹
   一波红色「会话中断」卡,恰是用户抱怨的行为。路径:`AISessionStore` 增加
   `removeSessions(for source:)`,CompletionFlashService 对「源已禁用」的消失不报
   lost(豁免进 detector 纯函数,可单测)。
5. **Hermes 联动**:`hermesEnabled` 关 = `HermesService` 停止监控(现有 stop:
   停 FSEvents+pollTimer)+ `uninstallHooks()`;开 = 重启监控+装 hook。OpenClaw
   不动(本来就是连接 toggle 语义)。
6. **UI**:`SettingsComponents.HookCard`(安装/重装/卸载按钮)改为开关卡:Toggle
   绑定 enabled,卡内小字保留 hook 实际安装状态(诊断价值:「未安装」+开着 =
   提示会自动装回)。`AIAgentsSettingsPage` 五张卡换新组件;onInstall/onUninstall
   回调改为统一 `onToggle(Bool)`。新增文案进 Localizable.xcstrings(en+zh-Hans,
   走 `scripts/xcstrings.py` 格式)。
   - **旧口径清理**:`BadgeViewModel.activeBadgeItems` 的按源过滤闭包删除(根源
     断流后永远不命中,留着误导「过滤责任在 UI 层」),`BadgeItem.sessionItems`
     的 `isEnabled` 闭包参数随之移除,单测同步更新(`edgeBarShown` 维度保留)。
   - `AIChatTab+EmptyState` 的各源「启用」按钮改走完整开启语义(装钩子+恢复
     轮询),不再是只设布尔。
   - UsageQuotaCardView 的按源过滤**刻意保留**:配额是账单事实,与会话监控是
     两个关注点(关监控仍看用量是合理状态)。
7. **文档**:AGENTS.md(架构不变量节 hook 端口段补「按源开关」口径)、README、
   README_CN 功能描述同步。

### 刻意不做

- 不动 record 轮询频率(3s)与其发现语义。
- 不动 UsageQuota 侧(已按开关过滤,零改动)。
- OpenClaw 卡不改(连接语义)。
- 不为「关闭时的存量 toast 卡」做撤回——已显示的卡按自身 5 分钟生命周期走。

## 验收(用户怎么看到它修好了)

1. 设置 → AI 与 Agent,Claude Code 卡关掉开关:~/.claude/settings.json 无
   hook-sender 残留、刘海/边栏 claude 会话消失、herdr 再跑 claude 也不弹任何卡。
2. 重启 NemoNotch(或整次 build.sh 部署)后,claude hook **不复活**、轮询不启动。
3. 重新打开开关:hook 装回、~3s 内 record 轮询重新发现活会话并显示。

## 测试与门禁

- 新测试:路由拦截、轮询 guard、静默清源不弹卡(detector 纯函数)、ready 自愈
  按开关。全部走 Swift Testing,`sh scripts/mutate.sh` 验证有牙。
- 门禁全绿(test/lint/doc-audit/check-arch/plan-audit)→ 评审(review.sh)→
  feat-done。

## 评审关注点(预埋)

- toggle 关闭的静默清源是否漏了别的 store 观察者(EdgeBar 自动开栏、QuotaAlert、
  WaitingReminder 均读 store——源级清空时它们的反应)。
- 路由丢弃无主事件:claude 关闭时 ses_/sess_ 前缀事件仍应正常归 opencode/zcode,
  只有最终兜底受 claude 开关影响。
- handleServerReady 改动不得破坏「真实 app 自愈改坏脚本」的既有行为
  (ownsSharedHookConfig 门禁保留)。

## 任务勾选(实现完成)

- [x] T1 路由拦截(routeEvent 按源 gate,含无主兜底;归属测试与开关解耦)
- [x] T2 停转(stopDiscovery = 停轮询 + 停 watcher;startSessionDiscovery 分派)
- [x] T3 自愈按开关(handleServerReady 装 konly for enabled;死代码聚合 installHooks 删除)
- [x] T4 静默清源(CompletionDetector.forget + store.removeSessions;attention 刻意不豁免)
- [x] T5 Hermes 联动(setHermesMonitoring:forget agents → disconnect → 卸钩 → 清 agents)
- [x] T6 UI(HookCard→Toggle、BadgeItem 过滤层删、EmptyState、菜单栏、xcstrings、环境注入)
- [x] T7 文档(AGENTS.md 不变量 + README×2)
