# NemoNotch 绞杀者重构路线图

> 2026-09-30 制定。原则:**不推倒重写**(项目 800+ commits、无失控 God file、大量真机验证过的 macOS 深坑解法 encoded),逐阶段、每项独立可验证、全部走 worktree + 测试门 + feat-done 流程。
> 阶段 1 约束:纯机械搬移,零逻辑改动,拆后全量测试绿即收。

## 状态总览

| # | 项 | 状态 | 提交 |
|---|---|---|---|
| 0a | 硬前提:在途改动全部提交 | ✅ 完成 | 用户完成 |
| 0b | UI 先行:NotchShape 单一路径外壳(凹形顶角外扩 6/19pt) | ✅ 完成 | 4176728 |
| 0c | UI 先行:内容进外壳单一 clip 子树(boring.notch 架构) | ✅ 完成 | 2e78ca6 |
| 0d | UI 先行:黑胶 matchedGeometry 形变(币↔面板) | ✅ 完成 | 24c2aca |
| 0e | 核销:精确刘海测量 —— 核实发现早已实现(ScreenExtensions 同款公式) | ✅ 无需改动 | — |
| 1a | 拆 AIChatTab:1096 → 315 核心 + EmptyState/Summary/Sessions 三扩展 | ✅ 完成 | 5fc334e |
| 1b | 拆 UsageQuotaService:955 → 143 核心 + Zcode/Claude/Codex/Gemini/Keychain 五扩展 | ✅ 完成 | 9488639 |
| 1c | AgentMonitorTab.swift:核实非死代码(是 agent 组件库),改名 AgentListComponents.swift | ✅ 完成 | 07facb3 |
| 1d | 拆 SettingsView:878 → 每页一文件 | ⏸️ 缓拆 | — |
| 2a | 测试护栏:覆盖审计 + 补缺 | ✅ 完成 | 见下 |
| 2b | 服务装配:抽取 AppDependencies 组合根(非可选依赖表 + 原序 build + 注入闭包工厂) | ✅ 完成 | 44ef213 |
| 3 | UI 逐屏重做 | ⬜ 待需求 | — |

## 阶段 1:拆上帝文件(纯机械)

**1d SettingsView(878 行,9 页)—— 刻意缓拆。**
理由:它是用户 settings-resizable 系列的活跃战场,现在拆会把后续改动变成大面积冲突。触发条件:该文件稳定约两周无迭代,或用户明确说"现在拆"。
做法:每页一个文件(通用/提醒与动效/AI 与 Agent/应用列表/通知/快捷键/番茄钟/防休眠/关于),SettingsView 只留页面枚举与分发。

**1-候补(600-800 行档,阈值:超过 ~800 或再次成为改动热点时拆):**
- OpenClawService(802):WebSocket 客户端 + 模型 + 状态机可分
- OverviewTab(~700,含 morph):日历/媒体/天气三段可分
- AgentListComponents(596,刚改名):rows 与 setup/approval cards 可分
- AIStatusFABView(640)/NotchView(~580):刚经历外壳重构,冷却期后再看

## 阶段 2:测试护栏 + 服务边界

**2a 覆盖审计 → 补测试。(2026-09-30 完成,736c156)**
审计结论:原评估列的五个候选(quota 归一化、pomodoro 状态机、badge 聚类、CompletionDetector、KeepAwakeReconciliation)**全部已有测试** —— 套件比制定计划时所以为的更完整。真实缺口只有两类:
- 时间驱动 UI 状态机(定时器内嵌,如 MediaService 乐观 reconcile、AIStatusWindowController 隐藏延迟)—— 需可测试性重构才可测,收益/成本比低,搁置;
- 渲染层(MarkdownRenderer 返回 `Text` 不可断言)—— 不值得。
实际补上的一块:`BadgeDebounceTests` —— `BadgeViewModel.applyBadgeUpdate` 的 16ms 合并 + 600ms 空态宽限端到端时序测试(真实时钟、~10x 余量,含区分性断言"宽限期内显示必须保持旧集合")。这是唯一真正无护栏且修过真 bug 的行为(OpenClaw idle-dip 闪烁)。

**2b 服务装配拆分。(2026-09-30 完成,44ef213)**
落地形态:`AppDependencies` 组合根(NemoNotch/Helpers/AppDependencies.swift)—— 25 个非可选 let 属性按域分组(跨域依赖注释标出),`build()` 逐句原序搬移(构造顺序是行为,只搬家不重排),刘海的 22 连 `.environment` 注入闭包收编为 `notchContent()` 与成员表同址。AppDelegate 只剩生命周期;SettingsSceneRoot 九重 if-let 塌缩成单解包。328 用例全过。
后续可选:真正的分层 stack 结构(把跨域服务归层)—— 组合根就位后再做才是安全顺序。
部署冒烟时踩了已知坑:重签名二进制重弹蓝牙 TCC(进程模态、阻塞启动),AX 点"允许"即恢复 —— 非重构回归。

## 阶段 3:UI 逐屏重做(需求驱动)

不预设方案。候选视角(待用户点名,一次一屏):
- AI tab 信息密度(会话行/配额卡/摘要卡的层级)
- Overview 布局(三卡比例、无媒体态)
- 设置视觉(刚收敛 NavigationSplitView chrome,冷却中)
每屏:先出对照方案 → 用户选 → 实现 → 截图验证闭环。

## 明确不做(已裁定)

- 推倒重写(全量):否决 —— 功能追平期以月计,已修 bug 全部回归
- Shelf 文件拖拽搁架:无需求
- 刘海手势通道(上滑关闭):非痛点,且与滚动冲突
- boring.notch 的"layout mask 尺寸哲学":其代码实为值驱动 + 幽灵 spacer,无剩余可抄
