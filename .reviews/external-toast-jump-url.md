# Code Review — feature/external-toast-jump-url

Reviewer: 独立评审子代理(GLM;judge ≠ author,未参与开发、未见作者对话)
Date: 2026-11-02
Reviewed-Head: aa9ecc6
Verdict: APPROVED
Scope:  9 files changed, 282 insertions(+), 12 deletions(-)

```
AGENTS.md
NemoNotch/Models/ExternalToastPayload.swift
NemoNotch/Services/ExternalCardService.swift
NemoNotchTests/ExternalCardServiceTests.swift
NemoNotchTests/ExternalToastPayloadTests.swift
README.md
README_CN.md
docs/superpowers/plans/2026-11-02-external-toast-jump-url.md
docs/superpowers/specs/2026-11-02-external-toast-jump-url-design.md
```

## Findings

- [P3] NemoNotch/Services/CompletionDetector.swift:225 — 存量注释「a keyed re-push without `jumpBundleId` clears the jump target」现在实际清空的还含 `jumpURL`(tabLink),后续顺手补半句;该文件不在本分支 diff 内,不拦。
- [P3] README.md:95 / README_CN.md:93 — 字段表写 "passed through verbatim",实际落库的是 trim 后的串(首尾空白被剥);且实测纯空白串 `"   "` 也视为未提供(比文档的 "empty string" 更宽松,方向无害)。可在文档补一句 "whitespace-only = absent"。不拦。

无 P1/P2。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:三个变异全被抓住(亲跑,均 exit 65、文件 trap 恢复、工作区干净):①`scheme.lowercased() != "file"` → `true`,`jumpURLRejected` 红;②`if jumpURL.count > 2048` → `if false`,`jumpURLTooLong` 红;③`tabLink: payload.jumpURL` → `tabLink: nil`,`makeItemMapsJumpURL` 红。测试断言到具体字段值(`jump?.tabLink == "pulse://alerts/1"`),非「调用发生了」型。
- [x] **证据纪律**:我亲跑——`sh scripts/lint.sh` exit 0(仅存量 warning,零 error);`sh scripts/doc-audit.sh` exit 0;`sh scripts/check-arch.sh` exit 0;`sh scripts/affected-tests.sh` exit 0(改动 4 个 Swift 文件 → CompletionDetectorTests + ExternalCardServiceTests + ExternalToastPayloadTests,40 用例全过)。作者「全量绿」声明有 `build/test-head.txt`(=5ec31ee,其后仅 docs 提交、代码未动)锚点支撑。梯级披露:本评审到梯级 4;「点击真打开深链」的梯级 5(plan Task 4 Step 3 的 curl 验证)按设计留给合并部署后。
- [x] **Swift 6 并发**:无新并发面——`jumpURL` 是 `String?` 进 Sendable struct;`parse` 纯函数无隔离;`makeItem` static。N/A 部分:无回调线程改动。
- [x] **最小改动**:9 文件全部可追溯到需求(字段 + 校验 + 一行映射 + 测试 + 文档 + spec/plan);无顺手改邻近代码。
- [x] **错误路径**:非法 URL → `.jumpURLInvalid` / `.jumpURLTooLong` → 400 带 reason(错误枚举与描述齐全,`rejectionDescriptions` 断言非空);点击侧 URL 打不开 → `AppActivator` `.warn` 日志后回落,uid/bundle 皆无 → 「No host app to activate」warn + 关卡,不崩(代码走读 AppActivator.swift:29-67 + CompletionToastWindow.swift:350-367 确认)。
- [x] **坑总目录对照**:改到的「外部 Toast API」段 AGENTS.md 已同步(校验规则、URL 优先回落、不做回调,与实现一致);复用 `CompletionJump.tabLink` 与日历卡同路径,无新增 SwiftUI/窗口/Keychain 面。
- [x] **教训候选**:有,见尾部小节。
- [x] **文档同步**:README×2 字段表 + 示例 JSON、AGENTS.md 外部 Toast 段均已更新;doc-audit exit 0。

### 契约镜头(本分支专项,逐项实测)

1. **`URL(string:)` 行为**(本机 Foundation 探针,swift urlprobe.swift exit 0):`pulse://a b`(host 段空格)→ nil,与测试断言 reject 一致;`https://example.com/a b`(path 段空格)→ Foundation 自动编码为 `%20` **接受**——「原样透传、调用方自行百分号编码」契约不矛盾(校验与点击时 `URL(string:)` 同输入同结果,确定性成立;自动编码是 Foundation 侧行为,卡内不存编码值)。非 ASCII path 同理自动编码接受,无害。
2. **`FILE:///` 大小写绕过**:实测 `URL(string:"FILE:///x")?.scheme` 返回 `"FILE"`(**Foundation 不小写化 scheme**)——实现用 `scheme.lowercased() != "file"` 是必要写法,`FiLe` 混合大小写同样实测拦截,测试已覆盖 `FILE:///x`。
3. **只有 `jumpURL` 无 `jumpBundleId` 的点击路径**:`CompletionJump.make(nil, nil, url)` 非 nil → 点击走 `.jump` → `AppActivator.activate(pid: nil, expectedBundleId: nil, tabLink:)`;URL 打不开时落「No host app to activate」warn 分支,随后照常 dismissToast——安全不崩,与 spec「留给 builder」的核对项结论一致。
4. **文档数字**:代码 2048(ExternalToastPayload.swift:130)/ 255(:122)与 README×2、AGENTS.md 表述一致。
5. **零语义翻译**:`ExternalCardService.makeItem` 只做字段搬运(`jumpURL` → `tabLink` 原样),校验全在纯函数 `parse`;keyed 重推缺 `jumpURL` 经存量 merge 的外部 jump 整体替换分支清空(CompletionDetector.swift:238-239),符合「keyed 重推 = 完整卡面」。红线未破。

## 教训候选

- **`URL(string:)` 的两个反直觉实测(macOS 27.2 Foundation,本评审探针)**:①scheme **保留原始大小写**(`"FILE:///x".scheme == "FILE"`),任何 scheme 比较必须 `lowercased()`;②`"alerts/123"` 这类 scheme-less 串解析**成功**、scheme 为 nil——「`URL(string:)` 成功 ≠ 绝对 URL」,必查 `scheme` 非空。本分支测试已钉住(变异① exit 65);若将来出现第二处 scheme 校验(比如 EdgeBar tabLink 收外来值),可考虑提成共享纯 helper 或 check-arch 规则(位置 NemoNotch/Models/ExternalToastPayload.swift:135-142,判据:scheme 比较不 lowercased 或不查 scheme nil 即错)。

---

**评审方法与证据附录**(供 feat-done 门禁核对):全量 diff `git diff f6ba079...HEAD`;`git rev-parse --short HEAD` = `aa9ecc6`;门禁与测试退出码如上;三个变异分别对 ExternalToastPayload.swift(×2)与 ExternalCardService.swift(×1)执行,均被抓住且文件恢复(worktree 仅余 untracked 的本记录模板)。plan 剩余裸框为 Task 4 Step 2(本评审落盘)/ Step 3(feat-done),流程自洽。
