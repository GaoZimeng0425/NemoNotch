# 外部 Toast API(插件化第一步)设计

- 日期:2026-11-01
- 状态:已批准(2026-11-01 用户拍板;含 duration 不进 v1)
- 脑暴对话:本次会话(路线乙 + 用户两次架构修正)

## 意图与为什么

NemoNotch 目前所有能弹到刘海下方 toast 的内容(AI 完成、日历到期、通知镜像)都产自内部服务。用户希望把这条路开放出去:**自己实现的其它应用(任何语言、GUI 或脚本)也能弹 toast**,并以此为插件化的第一步——远期演进到外部应用推送持续数据卡、乃至经配置在 notch 展示自定义内容(tab / 内容区 / 按权重竞争展示位)。

第一步只交付:外来 toast。但接口格式与边界按远期方向留位,后续每一步都落在加法区。

## 目标 / 非目标 / 反目标

**目标**

1. 本机任何应用能通过 HTTP 接口在刘海下方弹出一张 toast 卡(应用名、图标、标题、正文、可选点击跳转);
2. 接口与内部功能共用同一条内容管线、同一个卡片 schema——内部源是这条管线的第一个(已存在的)用户;
3. keyed 推送:同一 key 反复推送刷新同一张卡(为远期"进度条平滑更新"铺路),应用崩溃后卡片靠 TTL 自然消失,无需显式关闭协议;
4. wire schema 版本化,后续加字段不破坏既有调用方。

**非目标(本期不做)**

- 通用声明式 UI / 组件拼装(L3):schema 里只留 version 位,不实现;
- 自定义 tab / notch 内容区 / 展示权重(L3);
- `nemonotch` CLI 命令封装(本期给 curl 示例,CLI 后续单独提);
- 按应用黑名单/限频(本期只有全局开关 + 队列天然上限);
- 把日历卡/通知卡迁移改造——它们**已经**是统一卡片模型的生产者,不动。

**反目标(做错了就算功能正常也算失败)**

- **旁路**:外来内容绕过统一 schema 直捅 toast 队列,或内部源出现第二条专用通道;
- **给外来数据做语义适配**:NemoNotch 理解/翻译外部应用的领域格式——不可能也不该做;
- schema 无版本地破坏性变更。

## 核心架构:一个入口,一种卡片

```
内部源(AI 会话/agent 注册表)─ CompletionFlashService 快照+边沿检测 ─┐
内部源(日历到期/蓝牙)──────── showCompletionFlash(items:) ────────┤ 内部适配层
内部源(通知镜像)──────────── showNotificationToast / update ──────┤ (NemoNotch 侧,
                                                                    │ 它懂自己的事件)
                                                                    ▼
                                                     统一卡片模型(CompletionItem)
                                                                    ▲
外部应用 ── POST /v1/toast(请求体即 schema 实例)── 校验+解码 ────┘
            (应用侧自己适配成 schema —— 它懂自己的数据)
                                                                    │
                                                                    ▼
                                        CompletionToastQueue(纯值,已单测)
                                                    │
                                                    ▼
                                        刘海下方 toast 横排(A 位置)
                              (远期 L3:tab / notch 内容区 = 同一模型的新读者)
```

**边界规则(本设计的根基,评审重点)**:

1. **适配层只存在于内部源一侧**。内部源 → schema 的翻译由 NemoNotch 做;外部应用 → schema 的翻译由应用自己做。schema 是两侧唯一的汇合点与公开契约。
2. **外来数据零语义翻译**:NemoNotch 对 `/v1/toast` 请求只做验令牌 → 解码 → 校验 → 入队。解码(JSON → Swift 结构)是编解码不是适配;除字段校验外不存在任何"理解外来内容"的代码路径。
3. **wire schema 是公开产品**:内部模型(CompletionItem)可自由演化,但它投影出的 JSON 契约要稳定;变更需版本协商(见下)。

## 现状侦察结论(已读代码,证据梯级 2-4)

| 侦察点 | 结论 |
|---|---|
| HookServer 路由 | `processRequest` 手写首行前缀路由(`GET /health`、`POST /hook`、404 兜底),加 `POST /v1/toast` 分支顺手(`HookServer.swift:272-321`) |
| 鉴权 | **已有共享令牌**:`~/.NemoNotch/hook-token`(0600,32 字节随机),`X-NemoNotch-Token` 头,失败关闭(`HookServer.swift:22-25,418-468`)。外来 API 直接沿用同一令牌 |
| DoS 防护 | 并发 32 连接 / 单请求 2MB / 15s 请求时限,外来 API 免费继承(`HookServer.swift:34-36`) |
| 统一卡片模型 | `CompletionItem`(`CompletionDetector.swift:29`)已具雏形:基础字段 + `source` 判别 + 按源挂专属 payload(`notice: NotificationCard?`、`calendar: CalendarCard?`——"外来源加 case + 挂专属字段"是既有模式的第三次重复) |
| 队列 keyed 能力 | `CompletionToastQueue` 纯值已支持:同 key 到达就地刷新(`add`,`CompletionToastQueue.swift:46-71`)、`replace(key:)` 内容替换不重计时(`:77-96`)、栈式 4 卡 + 等待堆 20、TTL 过期、悬停暂停。无 key 一次性 / 有 key 持续的语义就绪。**每卡自定义时长刻意不在 v1**(用户拍板):TTL 是队列级常量(300s),支持每卡时长需改造纯值结构;契约允许未来作为可选字段无损加入 |
| UITest 防污染 | `UITestMode.ownsSharedHookConfig` 门禁已存在,外来 API 的开关/令牌刷新遵守同一门禁 |

## Wire Schema(公开契约,评审重点)

`POST /v1/toast`,请求头 `X-NemoNotch-Token: <~/.NemoNotch/hook-token 内容>`,请求体:

```json
{
  "schema": 1,
  "app": "MyDownloader",
  "key": "download-42",
  "title": "下载完成",
  "body": "nemo-1.2.3.dmg · 84 MB",
  "icon": "sf:arrow.down.circle",
  "duration": 5,
  "jumpBundleId": "com.me.mydownloader"
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schema` | Int | ✓ | 契约版本,本期恒为 1;不识别 → `400` |
| `app` | String | ✓ | 应用显示名;1–48 字符 |
| `key` | String? | | 有 = keyed 持续卡(同 key 刷新同一张,重置计时);无 = 一次性卡,**每次推送独立身份、各自成卡**(my call,见默认决策);1–128 字符。`app` 与 `key` 都**禁含 `::`**(含则 400,防构造碰撞键)。keyed 卡身份键为 `ext:<app>::<key>` |
| `title` | String | ✓ | 1–120 字符 |
| `body` | String? | | ≤ 280 字符 |
| `icon` | String? | | 图标描述,本期仅 `sf:<SF Symbol 名>`一种形式;非法/缺失 → 通用卡片图标,不报错 |
| `jumpBundleId` | String? | | 点击卡片激活该应用(复用 `CompletionJump` + `AppActivator.bringForward` 既有链路);缺失 = 点击只关卡 |

每卡自定义时长(`duration`)**刻意不在 v1**(用户拍板):统一对齐内部 5 分钟;真实需求出现后作为可选字段无损加入(队列改造的代价记录在案)。

**keyed 重推的缺省语义(my call)**:请求体**就是完整卡面**——同 key 二次推送缺 `body`,正文即消失,不做"缺省保留旧值"的逐字段合并。这与"外部必须严格给出 schema 数据、每次推送完整内容、无增量"的协议精神一致,也免去定义"如何显式清空某字段"。

响应:`200 {"status":"ok"}` / `400`(schema 不识别、必填缺失、超长、`app`/`key` 含 `::`)/ `401`(令牌错)。

**端口发现(my call)**:外部应用读 `~/.NemoNotch/hook-port`(纯文本,一行端口号),文件缺失用默认 `45831`。NemoNotch 在 listener ready 时写此文件——与 `hook-token` 同模式,同受 `UITestMode.ownsSharedHookConfig` 门禁(测试宿主/`--uitest` 不写,不污染)。这让端口回落(45831 被占 → 45832)对外部应用自愈,与 hook-sender.sh 的自愈语义一致。

**契约纪律**:

- 未知字段**忽略**(前向兼容:L3 加字段,老版本 NemoNotch 不炸);
- 已有字段**只加可选不改语义**,语义变更 → `schema` 递增;
- 长度上限是契约的一部分(外来数据不可信,即使过了令牌——令牌防伪造不防滥用,能读用户家目录的进程都能拿到它)。

## 内部实现要点

1. **CompletionSource 加外来源 case**(如 `.external`),`CompletionItem` 加对应 payload 字段(`external: ExternalCard?`,照 `notice`/`calendar` 先例)。渲染层(`CompletionToastCard`)为该 source 增加样式:图标 + 应用名 + 标题 + 正文,与现有卡同族。
2. **新服务 `ExternalCardService`**(`@MainActor @Observable`,归 `AppDependencies` 组合根):职责 = 读全局开关 → 解码校验(纯函数,单测)→ 组装 `CompletionItem` → 调 `CompletionFlashService` 的外来入口。**它不做任何语义翻译**——它存在的意义是门禁、校验和让外来源有唯一落点。
3. **CompletionFlashService 加外来入口**(类比 `showNotificationToast`:不走全屏辉光——辉光是"AI 工作完成"的强信号,外来源不配触发;不走 `completionFlashEnabled` 门禁——外来卡有自己的开关)。
4. **HookServer 加路由**:`POST /v1/toast` 分支 + 令牌校验(复用 `isAuthorized`)+ 响应。解码失败/校验失败响亮返回 4xx 并记日志(外来数据是坏输入的最高发源)。listener ready 的 `ownsSharedHookConfig` 分支同时写 `~/.NemoNotch/hook-port`(见端口发现)。
5. **设置**:设置页加"外部应用 toast"开关(归属页在 plan 阶段定,候选:通知卡所在页);默认**开**(my call,理由见下)。
6. **本地化**:开关标题/说明进 xcstrings(en + zh-Hans),走 `scripts/xcstrings.py` 归一。

## 默认决策(我的裁量,用户可否决)

| 决策 | 理由 |
|---|---|
| 开关默认**开** | 令牌(0600)已是准入门槛,与 hook 事件同级;不涉及系统权限弹窗,不违反"弹窗只在用户动作处出现"原则;队列上限 4+20 天然兜底刷屏 |
| 外来卡**不触发全屏辉光** | 辉光绑定"完成"语义(~2s 节流管线),外来源质量不可控 |
| 图标只收 `sf:` SF Symbol | 零 IO、零安全面;bundle id 取图标(读别的 app 资源)后续有需求再加 |
| 点击跳转只收 bundleId | 复用既有 `CompletionJump` 链路;pid 易失效,bundleId 稳定 |
| 同 key 推送**重置计时**(而非不重计时) | 外来 keyed 卡语义是"进度/状态还在变" = 还值得看;与通知卡的 `replace`(内容变了、无新到达)不同——那是撤回语义 |
| 无 key 卡**每次推送独立身份** | "一次性 toast"的产品直觉 = 一次一张;按 app 聚合是通知卡模式(聚合后还有"已读"语义),外来无 key 卡没有该语义;刷屏风险由队列上限(4+20)与用户自己的应用可控性兜底 |
| keyed 重推**缺省即清空**(完整卡面) | 从"外部严格给 schema 数据、每次完整内容、无增量"原则直接推导;免定义"显式清空"语法 |
| 端口经 **`~/.NemoNotch/hook-port` 文件**发现 | 与 hook-token 同模式、同门禁;端口回落对外部应用自愈;契约一行("读文件,缺失用 45831") |

## 远期演进(L2 → L3,只留位不实现)

- **L2 持续数据卡**:`key` 字段本期已就位,零接口变更;
- **L3 组件拼装**:`body` 字段未来扩展为结构化内容(组件树),靠 `schema` 版本协商;tab / notch 内容区 = 卡片模型的新读者(订阅同一 store),"权重" = 读者选卡的排序参数;
- 内部源(日历/通知)后续可逐个显式过"适配层"名分,本期不动。

## 交给实现者的侦察项(plan 阶段)

1. `CompletionSource` 枚举定义位置与 `CompletionToastCard` 渲染 switch 的全部触点;
2. `ExternalCardService` 在 `AppDependencies` 的注册与 UITestMode 门禁范围;
3. 设置开关归属页与 `AppSettings` 字段落点;
4. `CompletionJump.make` 对"只有 bundleId、无 pid"输入的现成支持度。

## 测试策略(符合仓库剃刀:断言面在边界)

- **纯函数单测**:schema 解码 + 校验(合法/缺必填/超长/未知字段忽略/坏 schema 版本/坏 icon 降级)、`ext:<app>::<key>` 键构造、开关门禁;
- **端到端**(手动验证配方,照审批卡 e2e 先例):`curl` 带 token POST → 真弹卡;同 key 二次 POST → 原卡刷新计时;
- 每个新守卫过 `scripts/mutate.sh` 验牙;
- 修 bug 类改动先落失败测试(本期是新功能,不强制 TDD,但纯函数测试是验收标准的一部分)。

## 方案备选记录(为什么不是它们)

- **甲 · 塞进现有 hook 事件格式**:HookEvent 是会话语义容器,外来卡硬塞污染 schema,`/hook` 的 stdin 协议也不适合通用调用;L2 时推倒。被否。
- **丙 · 一步到位插件框架**(插件目录/清单/权限/热加载/DSL):SwiftBar 调研教训全部在场(执行层要沙箱、安全模型必须自建),远期形态(L3 细节)尚未定型,提前变现大概率返工。被否。
- **乙的初稿(旁路版)**:外来 API 作为绕过内部管线的新路。被用户否——内部源必须与外部源在同一 schema 前平等,内部功能是第一个插件。
- **乙的初稿(外来适配层版)**:为外来数据建翻译层。被用户否——外部应用是开放集合,NemoNotch 不可能懂它们的格式;适配责任在应用侧,schema 是唯一契约。
