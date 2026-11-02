# 外部 Toast 点击跳深链(jumpURL)设计(短)

日期:2026-11-02;状态:待用户批准
来源:用户点名「点击跳深链」——承接 2026-11-02 对话中对 `/v1/toast` 点击能力的盘点。

## 改之前 / 改之后(用户看到什么)

改之前:外部 app 推的卡,点击只有两种归宿——「激活某 app」(`jumpBundleId`,只到 app 首页)或只关卡。
改之后:可带 `jumpURL`,点击打开该 URL——深链(如 `pulse://alerts/123` 直接落到告警页)或网页,把用户带到**具体位置**。

## 目标 / 非目标 / 反目标

**目标**:① 新增可选字段 `jumpURL`;② 点击语义**复用**既有 `.jump`+`tabLink` 路径(日历卡同款);③ 校验:绝对 URL、必带 scheme、**scheme ≠ `file`**、≤2048 字符,非法 → 400 带 reason;④ README×2 字段表 + AGENTS.md 外部 Toast 段同步。

**非目标**:不做点击回调/事件(L3 范畴);不做多按钮;**不递增 schema 版本**(additive 可选字段,未知字段忽略策略下旧版 NemoNotch 收到 `jumpURL` 只是点击关卡——优雅降级;「改语义才递增」契约不触发);不改 `jumpBundleId` 语义;不收编 `docs/external-toast-agent-guide.md`(仍待收编,另开)。

**反目标**:外部数据做语义翻译(URL 原样透传);打开 `file:` 本地资源(通知卡点击打开本地文件/脚本是意外面,且无正当用例)。

## 方案(只有一条合理路径)

复用 `CompletionJump.tabLink`:`AppActivator.activate` 已实现「URL 可打开即赢;打不开回落 pid/bundle 激活」(`AppActivator.swift:31-37`)。排除:新建点击动作枚举(重复既有路径)、在 ExternalCardService 里自己 open(绕过统一跳转日志与回落链)。

## 已定设计(含我的选择,供推翻)

- 字段:`jumpURL: String?`(JSON key 同名,与 `jumpBundleId` 同风格);**空串视为未提供**(与 `key` 语义对齐)。
- 校验(落 `ExternalToastPayload`):trim 后非空;`URL(string:)` 可解析且 `scheme` 非空;scheme 小写 ≠ `file`;≤2048。错误枚举 `jumpURLInvalid` / `jumpURLTooLong`,reason 可读。
- 映射(落 `ExternalCardService`):`CompletionJump.make(hostPID: nil, hostBundleId: payload.jumpBundleId, tabLink: payload.jumpURL)`。并存 = URL 优先、打不开回落 bundle 激活;只有 `jumpURL` = 打不开则只关卡(hostBundleId nil 走无宿主分支);只有 `jumpBundleId` = 现状不变。
- 文档:README.md/README_CN.md 字段表加行、示例 JSON 加字段;AGENTS.md:189 外部 Toast 段加半句。
- 测试(Swift Testing,纯逻辑):Payload——合法 https/自定义 scheme 通过、`file://` 拒、无 scheme 拒、超长拒、空串=未提供;Service——`jump.tabLink == payload.jumpURL`、并存时两者都在。变异验证:把 scheme 校验退化成恒真,`file://` 拒绝用例必须变红。

## 留给 builder

错误文案措辞;README 示例深链字串;实现时核对 `AppActivator.activate` 在 pid/bundle 皆 nil 且 URL 打不开时的无宿主分支行为(预期:记日志、无动作,不崩)。
