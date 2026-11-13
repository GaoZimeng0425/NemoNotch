# Plan: zcode 配额修复(P1 错误分类 + P2 enc:v2 凭据跟随)

日期:2026-11-13
状态:待用户批准

## 背景

改之前用户看到什么:zcode 配额块无声消失(EdgeBar 用量块/AI tab 配额条不再显示
zcode 百分比);日志每 5 分钟一条 `zcode quota: parse failed`,从 11-12 14:54 起
全部失败。改之后:配额恢复显示(五小时窗口百分比+重置倒计时);凭据失效时配额块
显示明确的「凭据失效」状态而非消失,日志记录真实错误(API 401),不再伪装成解析
失败。

## 根因(全部梯级 4-5 实证,2026-11-13 确诊)

1. zcode CLI 把凭据存储升级为 `enc:v2:os:` 格式(coding-plan api-key、
   zcodejwttoken 全是 v2 密文;密钥=钥匙串随机 32B)。NemoNotch 读的
   `oauth:bigmodel:access_token` 是明文遗留 key,CLI 不再刷新 → 过期 →
   BigModel 配额 API 返回 `{"code":401,"msg":"令牌已过期或验证不正确"}`。
2. `ZcodeQuotaParser.parse` 只认 `code==200`,401 一律返回 nil,调用方笼统记
   「parse failed」——凭据失效被伪装成解析失败,误导排查。
3. v2 逆向已完成并端到端验证(见下),钥匙串条目确定性可寻。

## 方案

### P1 错误分类(小)

- `fetchZcodeQuotaIfPresent`:响应 `code != 200` 时解析出 code/msg,记
  `.warn("zcode quota: API \(code) \(msg)")`(替换笼统 parse failed);给
  ProviderUsageQuota 增加错误状态,配额 UI 显示「凭据失效(API 401)」而非消失。
- parser 保持纯函数:decode 成功但 code 非 200 的分支返回带原因的错误,不再与
  「形状不匹配」混为一谈。

### P2 enc:v2 跟随(中)

新增 `ZcodeCredentialsV2`(或扩展现有 enum):
- key 来源:Keychain 条目 service=`ZCode Credential Encryption`,account =
  SHA256(`~/.zcode/v2/credentials.json` 绝对路径).hex(已实测吻合)。
- **Keychain 铁律(GUI app 读他 app 条目 = 跨 app ACL 弹窗,而配额刷新是自动
  定时器)**:存在性探测用 attributes-only(`kSecReturnAttributes`,静默);
  取值读走 `SecItemCopyMatching` + `SecKeychainSetUserInteractionAllowed(false)`
  包裹(对齐 Codex 凭据的既有模式)——失败(含 errSecInteractionNotAllowed)
  只置状态,绝不弹窗;状态引导用户去 zcode CLI 重新登录后自愈。
- 解密:值形如 `enc:v2:os:<fingerprint24hex>:<iv>.<tag>.<ct>`
  (base64url);key=钥匙串值本身的 32 字节(**不过 SHA256**——v1 才 hash);
  fingerprint=SHA256(key).hex 前 24 字符,不符即密钥错配,静默置状态。
  AES-256-GCM,CryptoKit 与现有 v1 代码同构。
- 取值顺序:优先解 `account-provider:coding-plan:...:api-key`(端到端已验证
  返回 200+five_hour tier);`oauth:bigmodel:access_token` 明文遗留仍作次选
  (存量用户未升级 CLI 时仍工作)。
- **tier 按实际返回渲染**:实测响应只有 five_hour(percentage+nextResetTime),
  seven_day(unit:6)缺失——parser 不假设两窗口都在,tiers 空才报错。
- 单测:加密往返(用测试自己生成的 key 加密样本再解)、fingerprint 校验、
  v1/v2/明文三形状分派、code!=200 错误分类。mutate 验证。

### 附带(同一提交)

- AGENTS.md「Usage quota」段补 v2 口径 + 上轮评审两条教训候选(总闸枚举全部
  写入者 / isInstalled≠用户意图)补进 toggle 不变量条目。

## 刻意不做

- 不逆向 `zcodejwttoken`(api-key 已足够;少一个依赖面)。
- 不写钥匙串、不自动登录、不做「重新授权」按钮(引导文案指向 zcode CLI)。
- seven_day 缺失不做合成/估算。

## 验收(用户怎么看到它修好了)

1. 配额块重新出现:zcode 五小时窗口百分比 + 重置倒计时(此刻真实值 1%)。
2. 手动把钥匙串访问拒掉(或删 key 模拟):配额块显示「凭据失效」状态、无弹窗、
   日志一行 `API 401 令牌已过期…` 而非 parse failed。
3. `sh scripts/mutate.sh` 守卫有牙。

## 风险与退化

- CLI 再改格式(第三次)→ 行为退化为 P1 的明确错误显示,不再无声失败;key 指纹
  自校验让错配可判定。
- Keychain 授权边界:一切读取静默化,最坏=配额块显示凭据失效,零打扰。
