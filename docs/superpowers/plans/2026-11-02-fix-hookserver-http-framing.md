# Plan: HookServer HTTP 完整性判定改纯字节级——两段式客户端不再 400、>64KB hook 事件不再截断

- [x] 0. 前置:根因确认状态与证据基线(只读,不改代码)
- [x] 1. 失败测试:`HookServerFramingTests` 七用例钉红(含 `private`→internal 测试缝)
- [x] 2. 修复:`hasCompleteHTTPRequest` 字节级重写(零字符语义)+ `processRequest` 体提取边界对应关系钉注释
- [x] 3. 旧口径清场:两处 `--max-time 中断` 归因注释改写为真死因
- [x] 4. guardrail-backlog 登记:分帧字节级不变量(NWProtocolHTTP 重构 / check-arch 候选 / 两段式验收探针)
- [x] 5. 守卫有牙:`scripts/mutate.sh` 验证新测试(让判定退化为恒真,套件必须红)
- [x] 6. 影响面测试 + lint 全绿
- [x] 7. 修后确认探针(梯级 5,真机重放双客户端分段探针)
- [x] 8. 独立评审 + feat-done 合并部署 + reflect

## 0. 根因确认(首部声明)

**复现状态:真机/日志确凿。**根因经诊断席活体探针独立复现(梯级 5,运行中 app 127.0.0.1:45831),
挑战者审计 `sound: true / mechanicalFix: true / recommendation: proceed`,拍板闸五者俱全免闸直通
(复现确凿 + 证据链成立 + 修法机械 + 有确认探针 + 挑战者放行)。**非代码审阅推断,无需「已经用户确认」标注。**

### 症状:期望 vs 实际

| | 期望 | 实际 |
|---|---|---|
| ① `POST /v1/toast` | 任何合法客户端 200;请求完整性按 Content-Length 字节判定,体未到齐继续收 | URLSession 客户端**首发必 400** `{"reason":"Malformed JSON body"}`(URLSession 新连接先写头、后写体 = 两个 TCP 段);同连接复用后成功。curl 永远单段发送永远成功 → external-toast 指南的 curl 验收清单全过、bug 不可见。Pulse 项目的告警 toast 卡在此 |
| ② `POST /hook` 大事件 | 完整收到再解析 | >64KB 事件被截断丢弃,日志 `Failed to decode HookEvent … Unexpected end of file — body 65312B`(2026-11-01 17:57–17:59 三连;65312 = `receive(maximumLength: 65536)` 首段 65536 − 224B 头块) |

### 根因(一行)

`NemoNotch/Services/HookServer.swift:266`:`hasCompleteHTTPRequest` 里
`after.firstIndex(of: "\r")` **恒 nil**——Swift 把 `\r\n` 聚成一个 Character,头块字符串里不存在独立的
`\r` 字符 → Content-Length 分支整体死代码 → 兜底 `return true`(:273,头块到齐即宣布完整)。
receive 循环 :248 以此为**唯一分帧门**,头块一到就 `processRequest`,拿空体/半体去解析。

### 证据链(逐条带梯级;②=本建环席本次 Read/rg 核对,④⑤=诊断席探针,ask 提供)

1. **(梯级 2,建环席本次核对)** `HookServer.swift:259-274` 逐行::261 `range(of:"\r\n\r\n")` 找头块边界、
   :264 找 Content-Length、:266 `after.firstIndex(of: "\r")`、:273 兜底 `return true`;
   :248 是全仓唯一调用点(本次 `rg -n "hasCompleteHTTPRequest"` = 仅 :248 调用 + :259 定义,测试零引用);
   :234 `receive(minimumIncompleteLength: 1, maximumLength: 65536)`(65312 指纹的算术前提)。
2. **(梯级 2,建环席本次核对)** 同文件 :521-523 `headerToken` 注释**明文警告此坑**
   (「Swift 把 "\r\n" 视作单个 Character,不能用 `firstIndex(of: "\r")` 找行尾」)且 :529 用
   `components(separatedBy: .newlines)` 规避——:266 是全仓唯一没躲开的调用点。
3. **(梯级 4,诊断席)** `swift /tmp/cr-cluster-check.swift` → `firstIndex(of: CR) is nil: true` /
   `range(of: CRLF) found: true`。
4. **(梯级 4,单变量隔离,诊断席)** `swift /tmp/nn-hascomplete-isolation.swift`(函数逐字抄自 :259-274,
   仅改 :266 行尾查找方式):CL 头已找到、执行进入 after(排除「CL 找不到」备择);original 在
   ①头+CL+空体、②头+部分体 5B 上返回 true(应 false),③全体④GET 无 CL 正确 →
   `SUMMARY: original wrong on 2/4; line-end-fixed wrong on 0/4`。因果钉在 :266 一行。
5. **(梯级 5,诊断席)** `python3 -I /tmp/nemonotch-framing-probe.py` 对运行中 app
   (lsof:`IPv4 127.0.0.1:45831 (LISTEN)`,端口文件同值):单段→`200 OK`;两段(头‖体)→
   `400 Bad Request {"status":"error","reason":"Malformed JSON body"}`;两段(头+5B‖余体)→
   同样 400;partial-5B(余体不发)在脚本 3s socket 超时内**即刻**回 400(服务端未等余体),sendall 全部
   成功 → 排除「发送端中断」旧口径。单段/两段唯一变量是分段、载荷字节相同 → 排除「载荷本身坏」。
6. **(梯级 5,诊断席)** `swift /tmp/nn-urlsession-probe.swift` → `status: 400 | body: …Malformed JSON body`
   (症状①独立复现:URLSession 是现实中的两段式客户端)。
7. **(梯级 5,日志-探针闭环,诊断席)** 提交时刻 `date` 与 `~/.NemoNotch/logs/` 中
   `External toast rejected: Malformed JSON body` 三条新记录(两次 python 探针 400 + 一次 URLSession 400)
   时间戳逐一对应——运行中二进制与日志同源;ask 引用的历史行号时间戳全部对上。
8. **(梯级 5,日志指纹审计,诊断席)** `grep "Failed to decode HookEvent" | grep -o "body [0-9]*B" | sort | uniq -c`
   → 119×65312B + 83×65313B(=202 恒值;65312/65313 = 65536−224/223 头块)+ 2×803B + 1×802B(别类);
   最早 2026-10-30 19:59:48,早于 ask 所述——bug 存在更久而非新近。±1B 与 CL 5/6 位数头块差一致
   (此句为梯级 3 推断:65313B↔223B 已被 curl --trace-ascii 逐字节夯实,65312B↔224B 未逐字节对账)。
9. **(梯级 4,修法警示,诊断席)** 外部报告的一行字符串修法(`after.range(of:"\r\n")?.lowerBound`)在
   **Content-Length 为末位头**时仍恒 true(`swift /tmp/nn-cl-last-header-check.swift` →
   `CL as LAST header, empty body → report-fix returns: true (correct: false)`,因 :262 headers 子串不含末行
   CRLF);而 `python3 -I /tmp/nn-curl-header-order.py` 假服务端抓包实测 **curl 8.7.1** 以 hook-sender.sh
   同形(`-H … -H … -d`)发 POST 时 **Content-Length 恒为最后一个头** → 一行修法对 /hook 64KB 截断无效,
   字节级重写是必要而非偏好;回归清单补 ⑦(ask ①–⑥ 与外部报告均未含)。
10. **(引用,未复做)** 外部独立报告 `~/Documents/Learn/macos/pulse/.scratch/nemonotch-toast/NEMONOTCH-HOOKSERVER-BUG.md`
    (本次建环席已核实其存在于该路径;根因行号、复现表、隔离验证与 ask 转述一致;其 URLSession 头/体分段
    抓包未复做,根因证明不依赖它——python 探针直接控制分段这一变量)。

### 挑战者审计吸收(全部进本 plan)

| 审计 gap | 本 plan 落点 |
|---|---|
| 判定与 `processRequest` 体提取(:277 `String(data:)`、:295-299 / :339 `range(of:"\r\n\r\n")`)是两套分帧逻辑,防未来改一处漏一处 | 任务 2:两处钉「同一 `\r\n\r\n` 边界,改一处必改另一处」注释(探针 3 已证完整体时该路径零丢失,不重构、不共享代码) |
| 回归清单缺 ⑦「CL 为末位头→false」 | 任务 1 已含(且注明它是「一行修法回潮」的守卫) |
| 65312B↔224B 头块逐字节对账未做 | 接受为披露项(65313B↔223B 已夯实;不影响根因),不阻塞 |
| 802/803B 小体解码失败别类未归因 | 范围纪律:不在本分支;修后若指纹仍增长另开调查 |
| 行为差异:非 UTF-8 体 → 旧=解码 nil 恒 false 挂到 isComplete/15s deadline,新=判定完整 → `processRequest` :277 → 400 | 范围纪律明示接受并披露(两端点均 UTF-8 JSON;400 优于挂死),评审勿当回归 |

## 1. 失败测试(首任务)

新文件 `NemoNotchTests/HookServerFramingTests.swift`(Swift Testing,同 `HookServerBindTests` 风格)。
**测试缝**:`HookServer.swift:259` `private nonisolated static func hasCompleteHTTPRequest` 去掉
`private`(internal,`@testable` 直调——与 :110 `listenerParameters`、:398 `permissionHoldTimeout`
同款先例),调用点 :248 不动。缝随测试同一 commit。

判别剃刀自检:被测单元若到处 `return true`,用例 ③④ 过、**①②⑤⑦ 必挂**——有鉴别力;全部用
**字节输入直接断言字面 Bool**,零自指。

七用例(`json` 为定长合法 toast 体,CL 用 `json.count` 动态生成防手数错):

1. `headersWithContentLengthAndEmptyBodyIsIncomplete`:头块 + `Content-Length: N` + **空体** → `false`
2. `partialBodyIsIncomplete`:头块 + CL=N + 体前 5B → `false`
3. `fullBodyIsComplete`:头块 + CL=N + 全体 → `true`
4. `requestWithoutContentLengthIsCompleteAtHeaderEnd`:`GET /health` 形状(无 CL)头块到齐 → `true`
5. `multiByteBodyIsJudgedInBytes`:体 `"中"`(3B)CL=3 只发前 2B(切在 UTF-8 字符中间)→ `false`;
   并列 `multiByteBodyCountsBytesNotCharacters`:体 `"中中"`(6B/2 字符)CL=6 全发 → `true`
   (若实现误按字符数算会 2<6 → 红)
6. `contentLengthHeaderNameIsCaseInsensitive`:`content-length:` 与 `CONTENT-LENGTH:`(混合大小写)
   空体 → `false`、全体 → `true`
7. `contentLengthAsLastHeaderIsHonored`:头序 `Content-Type → X-NemoNotch-Token → Content-Length`
   (curl 8.7.1 实测恒此序)+ 空体 → `false`(**此用例专防「一行字符串修法」回潮**——见证据链 9)

**预期红集(先钉红,本 plan 未跑测试、由实现者捕获真实输出)**:现状实现下 ①②⑥(空体变体)⑦ 返回
`true` 而断言 `false` → 红;③④ 绿;⑤ 前半**现状碰巧绿**(`String(data:encoding:.utf8)` 对截断的
UTF-8 返 nil → guard `return false`),它守的是重写本身不得退回字符语义。

提交:测试 + 测试缝单独成 commit,提交信息引用真实红输出(以下两项为 bug 本体的已验失败指纹,一并引用):
活体探针 `two-segment → 400 Bad Request {"status":"error","reason":"Malformed JSON body"}`(梯级 5)
与隔离脚本 `SUMMARY: original wrong on 2/4`(梯级 4)。red→green 可重放:`git checkout <测试commit>`
跑 `sh scripts/affected-tests.sh` 见红 → 回 HEAD 见绿。

## 2. 修复:字节级重写(用户已拍板方向,勿改成字符串修法)

`hasCompleteHTTPRequest` 重写为**纯字节级**,零字符语义:

- 头块边界:`data.range(of: Data("\r\n\r\n".utf8))` 找 `\r\n\r\n` **字节序列**;找不到 → `false`。
- Content-Length:头块按 `\r\n` **字节**切行;每行取首个 `:` 之前为头名,ASCII 大写→小写
  (仅 `A-Z` 映射 `+0x20`,其余字节原样——别用 `| 0x20`,0x0D|0x20=0x2D 会把 `\r` 变 `-`);
  与 `content-length` 逐字节相等才认。值:容忍首尾 SP/HTAB,至少一个 ASCII 数字,解析失败 → 视同无 CL。
- 完整性 = 纯字节算术:`已收体字节数 = data.distance(from: 分隔符尾, to: data.endIndex)`,
  `体字节 ≥ Content-Length` → `true`;**无(可解析的)CL → `true`**(头块到齐即完整,GET /health 形状,
  与旧兜底语义一致)。
- **Data 切片陷阱**:subscript 出来的 Data 保留父索引(`startIndex ≠ 0`),一律用
  `distance(from:to:)` / `index(_:offsetBy:)`,绝不 `count` 减法。
- 注释里写明 why:Swift 聚簇 `\r\n`、旧 `firstIndex(of: "\r")` 恒 nil、65312/65313B 指纹、
  两段式客户端 400(指向本 plan)。

实现草图(**以七用例为准,草图只定语义**):

```swift
nonisolated static func hasCompleteHTTPRequest(_ data: Data) -> Bool {
    guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
    let bodyBytes = data.distance(from: sep.upperBound, to: data.endIndex)
    guard let cl = contentLength(in: data[data.startIndex..<sep.lowerBound]) else { return true }
    return bodyBytes >= cl
}
// contentLength(in:):按 \r\n 字节切行 → 首个 ':' 前为名(ASCII 小写化)→ 名 == "content-length"
//   才解析值;parseDecimal 容忍 SP/HTAB、只收 ASCII 数字、空/杂 → nil(视同无 CL,兜底 true)。
```

**配套(挑战者 gap 1)**:`processRequest` 的体提取(:295-299 /hook、:339 附近 /v1/toast 的
`range(of:"\r\n\r\n")`)与 :277 `String(data:)` 保持不动,但在两处体提取旁各加一行注释:
「此字符串边界与 `hasCompleteHTTPRequest` 的字节边界指同一 `\r\n\r\n`——**改一处必改另一处**」。
不重构、不共享抽象(完整体时该路径零丢失已被探针 3 证实:两段切半补发余体 → 200)。

## 3. 旧口径清场(推翻旧口径 ⇒ 全仓 grep 残留)

本次 rg 全仓(`NemoNotch/ NemoNotchTests/ docs/ AGENTS.md README*`)核实:旧归因残留**仅**
`HookServer.swift` 两处注释(HookInstaller 里的 `--max-time` 是真实 curl 参数,不是归因,不动):

- :226-231 receive 文档注释:归因「`--max-time`-capped curl abort mid-body … observed: a 65KB
  PostToolUse died exactly this way」。真死因 = 分帧判定恒真,首段 64KB 即被宣布完整。**保留**
  「纯函数判定不跳 MainActor」的正确论证,只改归因句:65KB 事件死于 :266 恒真判定,`--max-time`
  中断在这个判定下同样只送半截,是伴随表象不是死因。
- :316-320 decode 错误注释:「size below Content-Length means the sender aborted mid-body (e.g.
  the hook script's --max-time)」→ 改为:截断体最常见来源是分帧判定在体到齐前放行(本 bug),
  与 65312/65313B 恒值指纹的关系。

## 4. guardrail-backlog 登记

`docs/guardrail-backlog.md` 待硬化节加一条(已核实该文件存在、当前无 HookServer/分帧条目):

- **HookServer 手写 HTTP 分帧的守恒不变量**——①NWProtocolHTTP/`NWProtocolFramer` 替换手写分帧的
  重构候选(用户拍板本分支不做);②check-arch B 档候选:新增行拦 `firstIndex(of: "\r")` /
  `firstIndex(of: "\n")` 的 String 用法(Swift 聚簇陷阱的机器可判定形状);③两段式客户端
  (URLSession / 原始 socket 分段)验收探针进 external-toast 指南或 CI——curl 单段发送曾让整份
  验收清单假绿。

## 5. 变异验证(守卫有牙)

```sh
sh scripts/mutate.sh NemoNotch/Services/HookServer.swift "return bodyBytes >= cl" "return true" --only HookServerFramingTests
```

字面量以实现最终形态为准,原则:让完整性判定退化为恒真(即回到 bug 本体),套件必须变红
(exit 0 = 有牙;0 个测试跑 = exit 2 = 过滤/接线错误,先修再信)。

## 6. 影响面测试 + lint

- `sh scripts/affected-tests.sh`(映射自动选类——改 HookServer.swift 会吸进全部 HookServer* 测试族;
  **禁手挑 `--only` 类名当门禁**;映射为空回落全量)
- `sh scripts/lint.sh`
- 全绿后进评审。报告测试结果必须引脚本退出码与 `build/test.log`,不凭记忆复述。

## 7. 修后确认探针(梯级 5,真机)

部署新构建后(worktree 内 `./build.sh` 会替换 /Applications 并重启——已知副作用;或等 feat-done
post-merge 自动部署后验):

```sh
lsof -iTCP:45831 -sTCP:LISTEN          # 确认 app 在听(端口以 ~/.NemoNotch/hook-port 为准)
python3 -I /tmp/nemonotch-framing-probe.py
#   期望:single-segment → 200;two-segment → 200;partial-5B → 服务端继续等待
#   (脚本 3s recv 超时、无 400),而非即刻 400
swift /tmp/nn-urlsession-probe.swift   # 期望 status: 200(症状①在真实两段式客户端上消失)
```

`/tmp` 探针重启即失,附录 A 存了完整可重建副本。**副作用披露**:成功探针会真弹 toast(约 5 分钟
自撤)。日志侧:修后 `grep -c "body 6531[23]B" ~/.NemoNotch/logs/*.log` 相对基线(119+83)不得增长;
`External toast rejected: Malformed JSON body` 不再出现新记录(Pulse 的告警 toast 应能弹出)。

## 8. 评审与合并

- 独立评审:`sh scripts/review.sh fix-hookserver-http-framing`,未参与实现的会话填写,
  Verdict: APPROVED + Reviewed-Head;评审 prompt 只给 diff + AGENTS.md + worktree 只读权,不带本 plan。
- 合并镜头带 bug 专项:失败测试必须由红转绿、修复与根因(:266)因果对应、⑦ 号用例在场。
- `git feat-done fix-hookserver-http-framing`(主检出执行;post-merge 钩子自动部署)。
- reflect:教训候选「**协议分帧绝不走 String/Character 语义,只认字节**」——评审记录尾部教训候选
  → 评估进 AGENTS 坑总目录(Hook 端口节)或任务 4 的 check-arch 候选。

## 范围纪律

**只动**:`HookServer.swift`(:259-274 重写 + 可见性一词、:226-231 与 :316-320 注释、体提取旁对应
关系注释)、新测试文件、`docs/guardrail-backlog.md` 一条、本 plan 勾选。
**不动**:receive 循环结构(:232-257,含 2MB 上限/413 路径)、`processRequest` 的体提取/路由/鉴权逻辑、
HookInstaller/hook-sender 脚本、不引 NWProtocolHTTP(进 backlog)、其他 endpoint、
802/803B 小体解码失败(别类,修后指纹仍增长另开调查)、`docs/external-toast-agent-guide.md`
(主检出未跟踪文件,不属本分支;其 curl-only 验收清单的盲区由任务 4 的 ③ 候选跟进)。
**接受的行为差异(披露)**:非 UTF-8 体 → 旧=恒 false 挂到 isComplete/15s deadline,新=判定完整 →
400 Bad Request;两端点均 UTF-8 JSON,无现实影响。Transfer-Encoding: chunked 无 CL → 仍头块到齐即完整
(与旧兜底一致,无客户端用它)。不顺手改格式、不"改进"邻近代码;只清自己制造的垃圾。

## 附录 A:确认探针完整副本(/tmp 失效时重建)

`/tmp/nemonotch-framing-probe.py` — 原始 socket 分段探针(诊断席原件,逐字):

```python
import socket, time, json, os, sys

HOST, PORT = "127.0.0.1", 45831
token_path = os.path.expanduser("~/.NemoNotch/hook-token")
token = open(token_path).read().strip() if os.path.exists(token_path) else ""
body = json.dumps({"schema":1,"app":"probe","title":"framing probe","body":"two-segment probe"}, ensure_ascii=False).encode()
head = (
    "POST /v1/toast HTTP/1.1\r\n"
    f"Host: {HOST}:{PORT}\r\n"
    "Content-Type: application/json\r\n"
    f"X-NemoNotch-Token: {token}\r\n"
    f"Content-Length: {len(body)}\r\n"
    "Connection: close\r\n\r\n"
).encode()

def probe(name, chunks):
    s = socket.create_connection((HOST, PORT), timeout=3)
    try:
        for c in chunks:
            s.sendall(c)
            time.sleep(0.05)  # 保证落成独立 TCP 段
    except OSError as e:
        print(f"{name}: send error (server closed early?): {e}")
    try:
        resp = s.recv(4096)
        first = resp.split(b"\r\n")[0]
        snippet = resp[-120:]
        print(f"{name}: {first.decode(errors='replace')} | tail={snippet.decode(errors='replace')}")
    except OSError as e:
        print(f"{name}: recv error {e}")
    s.close()

probe("single-segment", [head + body])
probe("two-segment  ", [head, body])
probe("partial-5B   ", [head, body[:5]])
```

URLSession 探针要点(完整件在 `/tmp/nn-urlsession-probe.swift`):`URLSession.shared.dataTask` POST
`http://127.0.0.1:45831/v1/toast`,带 `X-NemoNotch-Token`(读 `~/.NemoNotch/hook-token`)与
`Content-Length`,`swift` 直跑,断言打印的 `status: 200`。
