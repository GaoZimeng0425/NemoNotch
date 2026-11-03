# NemoNotch 外部 Toast API · Agent 接入指南

> 用法:把本文档整份复制给你的 agent,并告诉它「为 ⟨应用⟩ 写一个接入 NemoNotch toast 的脚本」。文档自带端点发现、完整契约与验收步骤,agent 无需其它资料。
>
> 同源声明:本指南与 README「External Toast API」节描述同一契约,API 变更两处必须同一提交修改。

## 1. 你的任务

你要为宿主应用 ⟨应用名⟩ 编写/集成一段推送代码:当 ⟨事件,如「下载完成 / 构建失败 / 收到消息」⟩ 发生时,调用本机 NemoNotch 的 toast API,在 Mac 屏幕顶部刘海下方弹出一张卡片。这个 API 只有一个端点、一种卡片;**请求体就是完整卡面**。按第 5 节验收清单自测,全过才算完成。

## 2. 端点与凭据(运行时发现,不要硬编码)

| 项 | 读取方式 | 回落 |
|---|---|---|
| 端口 | 读文件 `~/.NemoNotch/hook-port`(一行数字) | 文件缺失 → `45831` |
| 令牌 | 读文件 `~/.NemoNotch/hook-token`,整文件内容作为请求头 `X-NemoNotch-Token` 的值 | 读不到 → 本次静默跳过(见第 4 节) |

- 端点固定为 `POST http://127.0.0.1:<port>/v1/toast`,仅本机回环,无鉴权之外的身份体系;
- 两个文件由 NemoNotch 首次启动自动生成,用户级可读;
- 端口可能因被占用而回落,每次发送前重新读 `hook-port`(或短 TTL 缓存)。

## 3. 请求契约(公开契约 v1)

请求头:`X-NemoNotch-Token: <token>` + `Content-Type: application/json`。

请求体字段:

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schema` | Int | ✓ | 固定 `1`;其它值 → 400 |
| `app` | String | ✓ | 应用显示名,1–48 字符 |
| `key` | String? | | 见下「两种用法」;1–128 字符;**空串视为未提供**;`app` 与 `key` 都不得含 `::` |
| `title` | String | ✓ | 1–120 字符 |
| `body` | String? | | ≤280 字符 |
| `icon` | String? | | 仅 `sf:<SF Symbol 名>`;未知符号名回落通用卡片图标,不报错 |
| `jumpBundleId` | String? | | 点击卡片激活该 bundle id 的应用;缺省 = 点击只关卡;≤255 字符 |

**两种用法**:

- **不带 `key`**——一次性提醒卡:每次推送独立成卡,自动消失;
- **带同一 `key`**——持续状态卡(如下载进度):每次推送**整体替换**同一张卡并重置存活计时。请求体永远是完整卡面:省略某字段 = 清空它,没有逐字段合并。

契约规则:未知字段忽略(前向兼容);卡片存活时长 v1 不可自定义(与内部卡一致,约 5 分钟,同 key 推送会续)。

## 4. 响应与错误处理

| 响应 | 含义 | 你该做的 |
|---|---|---|
| `200 {"status":"ok"}` | 已展示 | 无 |
| `400 {"status":"error","reason":…}` | 载荷不合约(缺必填/超长/schema 错/含 `::`) | 按 reason 修正载荷;不要原样重试 |
| `401` | 令牌缺失或不匹配 | 检查 token 文件的路径与读取权限;不要把 token 写进日志 |
| 连接被拒 / 超时 | NemoNotch 未运行或端口变了 | 重读 `hook-port` 再试一次;仍失败则静默跳过 |

**任何失败都不许影响宿主应用主流程**——把推送包成 fire-and-forget(短超时、吞错误)。

## 5. 验收清单(生成脚本后自测,全过才算完成)

1. 无令牌请求 → 期望 `401`;
2. 合法载荷(仅 `schema`/`app`/`title`)→ 期望 `200 {"status":"ok"}`,Mac 刘海下方出现卡片;
3. 同一 `key` 推两次(第二次改 `title`)→ 只有一张卡且内容已更新、计时重置;
4. 发 `{"schema":1}`(缺 `title`)→ 期望 `400`,reason 提及 title;
5. 停掉 NemoNotch 再发 → 脚本不抛错、不阻塞、不重试风暴。

## 6. 最小示例(shell)

```bash
PORT=$(cat ~/.NemoNotch/hook-port 2>/dev/null || echo 45831)
TOKEN=$(cat ~/.NemoNotch/hook-token 2>/dev/null)
[ -n "$TOKEN" ] && curl -sf -m 3 -X POST "127.0.0.1:$PORT/v1/toast" \
  -H "X-NemoNotch-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"schema":1,"app":"⟨应用名⟩","title":"⟨标题⟩","body":"⟨正文⟩","icon":"sf:checkmark.circle"}' || true
```

非 shell 语言做同构翻译:读两个文件 → POST JSON → 失败静默。验收清单(第 5 节)跑完再交付。
