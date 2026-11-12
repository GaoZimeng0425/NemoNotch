# Herdr mod → NemoNotch 提醒设计

日期:2026-11-12;状态:已批准(2026-11-12)
来源:用户需求「给 Herdr 写 mod,执行编程 agent 时通过我们暴露的 API 发 toast,点卡片进入 Herdr 里对应 session 的面板」;2026-11-12 对话逐项拍板 + 4 轮 spike 实测。

## 改之前 / 改之后(用户看到什么)

改之前:在 Herdr 里跑的 agent 跑完/卡住,只有 Herdr 窗口自己知道;NemoNotch 的提醒只来自它自己的 CLI hook,点卡片最多把终端 app 拉到前台,进不到 Herdr 里具体那个 agent 的面板。

改之后:
- Herdr 侧栏 "Spaces" 标题行多一个**圆点 + "NemoNotch"** 字样(圆点亮 = NemoNotch 在跑且连得上;灰 = 连不上)。别无其它 UI。
- Herdr 里任一 agent **跑完** → 刘海下弹一张**绿环**卡;**卡住等你** → 弹一张**蓝环**卡。
- 点卡片 → Herdr 切到前台并**聚焦到那个 agent 的面板**。
- 在 Herdr 里看过(done→idle)/答完(blocked→working)/终端关了 → NemoNotch 上对应的卡**自动撤掉**。

做错了用户会看到:卡片重复/撤不掉;点卡片只把 Herdr 拉前台不进面板;Spaces 行文字压到别的行上;侧栏折起时文字浮在终端上。

## 目标 / 非目标 / 反目标

**目标**
1. Herdr mod `nemonotch`:观察 Herdr 的 agent 状态边沿,向 `POST /v1/toast` 推卡与撤卡;侧栏一处极小的状态标识。
2. NemoNotch `/v1/toast` 四个 additive 扩展(schema 仍为 1):可选 `tone`、可选 `herdrTerminal`、可选 `action: "close"`、可选 `expiresAt`。
3. 安装脚本:幂等安装/卸载 mod 到用户的 Herdr。

**非目标**
- 不碰 NemoNotch 原有 agent 提醒逻辑(hook 路径、CompletionDetector、AttentionDetector 一行不动)。重复提醒由用户自行卸载 CLI hook 处理——**mod 与 NemoNotch 都不做去重**。
- 不在 NemoNotch 设置里加 Herdr 专属 UI/开关;NemoNotch app 对 Herdr 的唯一认知是 `herdrTerminal` 跳转目标。
- 不做点击回调给 mod(L3)、不做 Herdr 侧的审批代答。
- 不追 Herdr 窗口关闭期间(herdr-core 仍托管 agent)发生的边沿——mod 只在 Herdr 窗口运行时活着,这正是用户要的「用 Herdr 时开,不用时关」。
- 不克隆/修改 Herdr 布局(用户明确否决)。

**反目标**
- `/v1/toast` 变成「外部传命令、NemoNotch 执行」——`herdrTerminal` 只是一个经严格校验的地址,命令与可执行文件由 NemoNotch 写死。
- 外部卡能传任意色值(破坏「四色 = 接手原因」)。
- 影响用户日常使用 Herdr:不占 tab、不改布局、不抢焦点、不被误拖走。

## 约束(实测得来,勿推翻)

以下均在用户真实 Herdr 0.1.15 上 spike 验证(梯级 4/5),spike 产物已清理:

- **mod 必须有宿主才运行**:`place: "none"` 不被引用就不启动;`main` 布局只读(改结构须克隆,已否决);`mod.json` 的 `place` 自动停靠**在本机未生效**(运行中放入 + 用户重启后,`seen.json` 无记录、布局无该块)。
- **可用宿主 = 常驻浮窗**:`mod.json` 声明 `overlay: {kind:"window", key, keep:true, frame:"none", width, height, at}`,执行一次 `herdr-app do mod.open --name <mod>` 即打开;Herdr 把它记进 `windows.json` 的 `kept.main`,**重启后自动重开**(实测一次重启后回来)。切到其它布局时不在,切回 `main` 回来。
- **坐标是绝对定位**(相对 Herdr 窗口左上,逻辑像素)。侧栏固定 268px、不可拖宽,"Spaces" 标题行位置恒定;实测 `at: {x: 66, y: 52}`、`height: 20` 正落在 "Spaces" 与 "+" 之间。"Agents" 行随窗高/折叠移动,**不可用**。
- **卸载顺序**:先 `mod.open`(再调一次=关闭,`kept.main` 清空),**后**删文件夹。反序会留下 `status.errors: "no mod folder"` 且按 id `overlay.close` 关不掉(实测)。
- **浮窗不随 tab 收起停跑**;mod 的 `render` 在 Herdr 实时数据变化时自动重跑(收起/不可见也重跑,实测捕获 `t7t: done->idle`)。
- **边沿延迟**:状态变化到 `/v1/toast` 返回 200 约 0.23s(实测 `t9m working->done` 09:05:20.153 → push 200 09:05:20.381);用户看一眼 → `done->idle` 在 6.7s 后到达。
- **mod 能读** `~/.NemoNotch/hook-port`、`hook-token`(`readTextFile`,home 内可读),`fetch` 本机回环可达(实测 `/health` 200)。
- **Herdr 无 URL scheme**(Info.plist 无 `CFBundleURLTypes`,bundle id `dev.herdr.app`)。外部跳转唯一入口是 CLI `do agent.focus --terminal <address>`。`~/.local/bin/herdr-app` 是指向 `/Applications/Herdr.app/Contents/MacOS/Herdr` 的符号链接;**直接执行该二进制带参数即 CLI 模式**(实测 `Herdr status` 正常返回、未多开窗口)。
- agent 地址形如 `t9m`;远程机器上为 `<machine>/t7`。

## 方案(已拍板)

| 维度 | 选项 | 取舍 | 结论 |
|---|---|---|---|
| 推卡来源 | A Herdr mod 推 / B 补全 hook 的 Claude 卡跳转 | A 覆盖 Herdr 识别的一切 agent,代价是 Claude 双卡(用户自卸 hook);B 只覆盖已 hook 的 CLI | **A**(用户) |
| mod 源码与安装 | 1 仓库 + 安装脚本 / 2 NemoNotch 设置页一键装 / 3 不进仓库 | 1 协议与 mod 同仓同审、零 Herdr UI 进 app;2 多一块 UI+安装器服务;3 无版本、协议一变静默坏 | **1**(用户) |
| mod 宿主 | 克隆布局 / 专用收起 tab / 1×1 隐形窗 / mod.json 停靠 / 可见浮窗贴 Spaces 行 | 克隆、tab、隐形窗均被用户否决;停靠实测不生效 | **可见浮窗贴 Spaces 行**(用户) |
| 颜色 | 任意色值 / 可选类型 | 类型复用四色语义,色值单一出处 | **可选类型 `tone`**(用户) |
| `blocked` 映射 | 蓝(来点允许)/ 琥珀(来决定) | Herdr 不区分审批与提问 | **蓝**(用户) |
| 撤卡 | 只推 / 推+撤 | 撤需新接口 | **推+撤,同 app+key 识别**(用户) |
| 撤卡入口 | 同 `POST /v1/toast` 加字段 / 新端点 | 同端点复用鉴权、端口发现、日志 | **同端点加 `action`**(我的选择,用户未反对) |

## 已定设计

### NemoNotch:`POST /v1/toast` 扩展(schema 仍为 1,均可选)

旧版 NemoNotch 收到新字段 = 忽略(未知字段忽略契约)→ 降级为彩虹卡、点击只激活 Herdr、close 被当作 show 处理(会弹一张卡——见「留给 builder」第 5 条)。

1. **`tone`**: `"done" | "decide" | "approve" | "error"` → `ReminderTone` 的 green / amber / blue / red。只影响卡片环色;**不注入任何文案**(不把 `ReminderKind.verb` 之类的字塞进外部卡——零语义翻译红线)。缺省 = 彩虹(现状)。非法值 → 400 `toneInvalid`。色值唯一出处仍是 `ReminderTone`。
2. **`herdrTerminal`**: Herdr agent 地址。校验:`^([A-Za-z0-9._-]{1,64}/)?[A-Za-z0-9]{1,32}$`,且首字符不能是 `-`(防被 CLI 当选项)。非法 → 400 `herdrTerminalInvalid`。点击时:
   - 经 `NSWorkspace.urlForApplication(withBundleIdentifier: "dev.herdr.app")` 定位 `Contents/MacOS/Herdr`,`Process` 以**参数数组**(不过 shell)执行 `do agent.focus --terminal <addr>`,主线程外、带超时(~3s);
   - 然后把 Herdr 带到前台(复用 `AppActivator` 既有激活路径,bundle `dev.herdr.app`);
   - 找不到 Herdr / 命令非零退出 / 超时 → 记 `.warn`,仍尝试激活 Herdr(或 `jumpBundleId`),不崩、不弹窗。
   - 跳转目标随卡快照(同 `CompletionJump` 现有纪律)。
3. **`action`**: `"show"`(缺省)| `"close"`。
   - `close`:必须带 `key`(缺 → 400 `closeRequiresKey`);按 `ext:<app>::<key>` 移除卡,**屏上或等待堆都撤**(复用 `CompletionToastQueue.replace(key:with:nil)`);卡不存在 → 200 no-op;`title` 等其余字段不要求、忽略。
   - 非法 `action` 值 → 400 `actionInvalid`。
   - 功能开关 `externalToastEnabled` 关闭时 close 同样 200 静默(与 show 一致)。
4. **`expiresAt`**(用户拍板:展示时长字段,用时间戳,不消失用 infinity):卡的**到期时刻**,取值为 Unix 时间戳(秒,数字,可带小数)或字符串 `"infinity"`。缺省 = 现状(到达后 5 分钟到期)。
   - `"infinity"` = 永不自动到期,只由 `action:"close"`、用户点击或 × 撤下(与 NemoNotch 自家审批卡 `ask:` 同一常驻语义)。**必须带 `key`**(否则调用方无法撤卡,缺 → 400 `infinityRequiresKey`)。
   - 时间戳 ≤ 当前时刻 → 400 `expiresAtInPast`;非数字也非 `"infinity"` → 400 `expiresAtInvalid`。
   - 刻意与 `tone` 解耦——颜色不暗含生命周期。
   - (作者的选择)显式时间戳是**绝对截止**:悬停暂停、被挤进等待堆都不顺延它(现有「悬停离开重计满 5 分钟」只作用于缺省到期的卡);同 key 重推以新值为准。
5. 校验顺序在现有链后追加:… → jumpURL → action → (show 时才校 title 必填)→ tone → herdrTerminal。注意:close 不要求 title,所以 title 必填校验要挪到 action 判定之后。

### Herdr mod `nemonotch`

源码 `integrations/herdr-mod/`(`main.js` + `mod.json`;边沿逻辑可拆 `edges.js` 纯函数模块)。

**mod.json**
```json
{ "place": "none", "title": "NemoNotch",
  "overlay": { "kind": "window", "key": "nemonotch", "keep": true, "frame": "none",
               "width": 110, "height": 20, "at": { "x": 66, "y": 52 } } }
```

**UI**:一个圆点 + "NemoNotch" 文字,侧栏同底色(`theme().chrome`)、`muted` 文字色、11px。圆点:最近一次 `/health` 成功 = 亮色(主题色,builder 选 `done` 或 `accent`),失败 = `dim`。**不显示**计数/状态词/已推数(用户明确)。左键按下 `stop_propagation`(防误拖)。侧栏折起(宽 < 160)时渲染空内容。`/health` 每 30s 一次(`cx.timer`,数据用途,符合 Herdr「timer 只为数据」规矩)。

**边沿规则**(按 agent `address`,`render` 重跑时与上次快照比对;首次 render 只种基线、不补发):

| 前 → 后 | 动作 |
|---|---|
| 非 done → `done` | show,`tone: "done"` |
| 非 blocked → `blocked` | show,`tone: "approve"`,`expiresAt: "infinity"`(用户拍板:挂着直到处理) |
| {done, blocked} → 其它(idle/working)或 agent 消失 | close |
| done ↔ blocked | show(同 key 原地换色换文) |

**残留卡清理**(`infinity` 的配套):mod 在 `localStorage` 记下自己推出且未撤的 key 集合;每次启动(首次 render 种基线时)对集合里「当前不处于 done/blocked 的地址」(含已消失的 agent)逐个推 `close` 并移出集合。这样 Herdr 关闭期间被处理/结束的 agent,其蓝卡在下次打开 Herdr 时被清掉;Herdr 一直不开则蓝卡一直挂着(用户可手动 ×)。localStorage 跨 Herdr 重启是否保留需实现时实测,不保留则改用 `writeTextFile` 存到 `appHome()` 下的私有文件。

**卡面**(show):
- `app: "Herdr"`,`key: <address>`
- `title`: `<space_name> / <tab_name>`(截到 120)
- `body`: `<状态词> · <agent app> · <终端标题>`(状态词:跑完了 / 等你回应;`app` 为 null 时省略该段;截到 280)
- `tone`、`herdrTerminal: <address>`、`jumpBundleId: "dev.herdr.app"`(旧版 NemoNotch 的降级点击目标)

**推送**:每次推送现读 `hook-port`(缺省 45831)与 `hook-token`;`X-NemoNotch-Token` 头;失败(连不上/非 2xx)只记本地日志、不重试、不排队。

### 安装脚本 `scripts/install-herdr-mod.sh [--uninstall]`

目标状态式、可重跑:
- 安装:要求 Herdr 窗口在跑(`herdr-app status` 可达,否则响亮失败提示先开 Herdr);只复制我们的源文件到 `~/.config/herdr-app/mods/nemonotch/`(不删 Herdr 写进去的 `jsconfig.json`/`.d.ts`);`herdr-app check` 必须通过;`status.overlays` 不含 `nemonotch` 时才 `do mod.open --name nemonotch`(它是开关,已开再调会关掉)。
- 卸载:`overlays` 含 `nemonotch` 则先 `mod.open` 关闭,确认 `windows.json` 的 `kept.main` 不再含它,**再**删文件夹。
- `herdr-app` 定位:优先 PATH,回落 `/Applications/Herdr.app/Contents/MacOS/Herdr`。
- `HERDR_APP_HOME` 尊重。

### 文档

README.md / README_CN.md 字段表与示例、`docs/external-toast-agent-guide.md`(及设置页内嵌的可复制指南 `ExternalToastGuideSection`,若内容同源)、AGENTS.md 外部 Toast 段加四字段半句 + 一行 Herdr mod 指针(宿主约束与卸载顺序这两条坑必须进手册)。

### 测试与验证

- Swift Testing(纯逻辑):`ExternalToastPayload` —— tone 四值映射/非法拒;herdrTerminal 合法(`t9m`、`vps/t7`)/非法(`-x`、空、含空格、两段斜杠、超长)拒;close 无 key 拒、close 无 title 通过、非法 action 拒;show 仍要求 title;`infinity` 无 key 拒、过去时间戳拒、非法类型拒、合法时间戳与 `"infinity"` 通过。`ExternalCardService` —— close 移除屏上卡与等待堆卡(含 infinity 卡)、infinity 卡不到期、时间戳卡在截止时刻到期且不被悬停顺延、不存在 no-op、功能关时 close 不动队列;tone 落到卡上;`herdrTerminal` 进跳转快照。点击决策:有 herdrTerminal 的卡走 Herdr 跳转分支。
- 变异验证:把 herdrTerminal 校验退化为恒真 → `-x` 用例须红;把 close 退化为 show → 撤卡用例须红。
- mod:`herdr-app check` 通过 + `herdr-app shot` 截图核对位置;真机走一遍「agent 跑完 → 绿卡 → 点 → Herdr 聚焦该 agent → 卡撤」「blocked → 蓝卡 → 在 Herdr 里答 → 卡撤」。

### 评审

触及 HookServer 对外协议(高爆炸半径面)且新增 `Process` 执行外部二进制 → 停顿时提议加开挑战者第二席。

### 评审员问题的处置(builder check,均为作者的选择,供推翻)

- **带色外部卡的开关与辉光**:只受 `externalToastEnabled` 门禁,不受 `completionFlashEnabled`/`attentionToastEnabled`/`failureToastEnabled` 管;带 tone 也**不触发全屏辉光**(维持外部卡既有红线)。
- **你正盯着的 agent 跑完不发绿卡**:Herdr 的 `done` 定义是「在你没看时跑完」,你正看着的 pane 跑完会直接 working→idle,不产生 done 边沿 → 无卡。符合「只提醒需要接手的时刻」,接受。
- **`jumpURL` 与 `herdrTerminal` 并存**:`herdrTerminal` 赢,`jumpURL` 忽略;回落仍是 `jumpBundleId`。
- **点卡时 Herdr 已退出**:`agent.focus` 失败 → 回落 `AppActivator.openApp(bundleId: "dev.herdr.app")`(会启动/reopen Herdr),接受面板不聚焦。
- **远程 agent(`vps/t7`)**:按原样传给 `agent.focus`;spike 只验证过本机地址,实现时需真机确认,不通则远程卡只激活 Herdr。

## 留给 builder

1. 浮窗精确坐标/宽度在用户当前 zoom 与字号下的微调(以 `herdr-app shot` 为准);宽度是否改为按内容自适应。
2. 侧栏折起检测的具体读法(`layout()` 里 sidebar 节点尺寸,或其它可靠信号)——需实测。
3. 圆点亮色取 `theme().done` 还是 `accent`。
4. `tone` 在 `CompletionItem` 上的承载方式(新字段 vs 映射到代表性 `ReminderKind`)——前提是外部卡面不渲染 `kind.verb`;builder 需核对外部卡的渲染路径后选,保证只改环色。
5. 旧版 NemoNotch 把 `action:"close"` 当 show 时会因缺 title 400(close 不带 title)——即旧版天然拒绝 close,无副作用;确认这一点,无需额外处理。
6. `agent.focus` 执行后是否已自带把 Herdr 拉前台——实测后决定是否保留显式激活(保留也无害)。
7. 错误文案、日志措辞、`edges.js` 是否拆分及是否为它加最小 node 测试脚本。
