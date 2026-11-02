# 外部 Toast 点击跳深链(jumpURL)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task(本仓恒选主对话执行)。Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `/v1/toast` 新增可选 `jumpURL`,点击卡片打开该 URL(深链/网页),打不开回落 `jumpBundleId` 激活。

**Architecture:** `ExternalToastPayload` 加字段 + 校验(绝对 URL、scheme ≠ file、≤2048、空串=未提供);`ExternalCardService.makeItem` 把它映射到既有 `CompletionJump.tabLink`;点击路径零改动(`AppActivator.activate` 已实现 URL 优先、失败回落)。

**Tech Stack:** Swift 6、Swift Testing、`scripts/mutate.sh`。

**Spec:** `docs/superpowers/specs/2026-11-02-external-toast-jump-url-design.md`

## Global Constraints

- schema 版本保持 1(additive 可选字段);`ExternalCardService` 零语义翻译(URL 原样透传到 `tabLink`);`ExternalCardContent` 不加字段(`jumpBundleId` 在那里只存不读,YAGNI)。
- 校验顺序追加在 jumpBundleId 之后;错误枚举两条:`jumpURLInvalid`("jumpURL must be an absolute URL with a scheme other than file")、`jumpURLTooLong`("jumpURL exceeds 2048 characters")。
- 文档同步 README.md / README_CN.md 字段表 + 示例 JSON,AGENTS.md 外部 Toast 段半句;改完跑 `sh scripts/doc-audit.sh`。
- 用户已批准短设计并说「继续」;plan 为其机械转写、无新决策 → 不再二次停顿(spec 反目标)。

## Review Focus

1. `URL(string:)` 对含空格/中文的字符串返回 nil → 按 invalid 拒,是否符合「原样透传」预期 → Task 1 测试「含空格 → invalid」钉死行为(契约:调用方须自行百分号编码)。
2. 大小写 `FILE:///x` 绕过 scheme 检查 → Task 1 测试小写比较。
3. `jumpURL` 非空但 `jumpBundleId` 为空时 `CompletionJump.make` 必须非 nil → Task 2 测试。
4. 空串/纯空白 `jumpURL` 不得产生 jump → Task 1(解析为 nil)+ Task 2(jump 为 nil)。
5. 文档字段表与代码限制(2048)不一致 → Task 3 用 `rg 2048` 核对三处。

---

### Task 1: Payload 字段 + 校验(红→绿 + 变异)

**Files:**
- Modify: `NemoNotch/Models/ExternalToastPayload.swift`(struct 加 `let jumpURL: String?`;`RawExternalToast` 加 `jumpURL`;枚举加两 case + 文案;`parse` 追加校验;文件头顺序注释补 `→ jumpURL`)
- Test: `NemoNotchTests/ExternalToastPayloadTests.swift`(既有 `expected` 构造加 `jumpURL:`;新增用例)

**Interfaces:**
- Produces: `ExternalToastPayload.jumpURL: String?`(已 trim,非空才有值);`ExternalToastRejection.jumpURLInvalid / .jumpURLTooLong`。

- [ ] **Step 1: 写失败测试**(新增,其余既有用例的 `expected` 构造补 `jumpURL: nil`)

```swift
@Test("jumpURL: https and custom scheme accepted, trimmed")
func jumpURLAccepted() {
    let r1 = ExternalToastPayload.parse(json(#"{"schema":1,"app":"Pulse","title":"告警","jumpURL":"pulse://alerts/123"}"#))
    #expect((try? r1.get())?.jumpURL == "pulse://alerts/123")
    let r2 = ExternalToastPayload.parse(json(#"{"schema":1,"app":"Pulse","title":"告警","jumpURL":"  https://example.com/x?y=1  "}"#))
    #expect((try? r2.get())?.jumpURL == "https://example.com/x?y=1")
}
@Test("jumpURL: file scheme (any case), scheme-less and space-containing values are rejected")
func jumpURLRejected() {
    for bad in ["file:///etc/hosts", "FILE:///x", "alerts/123", "pulse://a b"] {
        let r = ExternalToastPayload.parse(json("{\"schema\":1,\"app\":\"Pulse\",\"title\":\"告警\",\"jumpURL\":\"\(bad)\"}"))
        #expect(r == .failure(.jumpURLInvalid), "\(bad)")
    }
}
@Test("jumpURL over 2048 chars is rejected as jumpURLTooLong")
func jumpURLTooLong() {
    let long = "https://e.com/" + String(repeating: "a", count: 2048)
    let r = ExternalToastPayload.parse(json("{\"schema\":1,\"app\":\"Pulse\",\"title\":\"告警\",\"jumpURL\":\"\(long)\"}"))
    #expect(r == .failure(.jumpURLTooLong))
}
@Test("empty or whitespace jumpURL means absent")
func jumpURLEmptyIsNil() {
    for empty in ["", "   "] {
        let r = ExternalToastPayload.parse(json("{\"schema\":1,\"app\":\"Pulse\",\"title\":\"告警\",\"jumpURL\":\"\(empty)\"}"))
        #expect((try? r.get())?.jumpURL == nil, "[\(empty)]")
    }
}
```

- [ ] **Step 2: 跑测试看红**

Run: `sh scripts/test.sh --only ExternalToastPayloadTests`
Expected: 编译失败(`jumpURL` 不存在)或用例失败——红。

- [ ] **Step 3: 实现**

`parse` 在 jumpBundleId 校验后:`let trimmedJump = raw.jumpURL?.trimmingCharacters(in: .whitespacesAndNewlines)`;若非空:`count > 2048 → .jumpURLTooLong`;`URL(string:)` 为 nil 或 `scheme` 为空或 `scheme.lowercased() == "file"` → `.jumpURLInvalid`;成功时 `jumpURL: (trimmedJump?.isEmpty == false) ? trimmedJump : nil`。

- [ ] **Step 4: 跑测试看绿**

Run: `sh scripts/test.sh --only ExternalToastPayloadTests`
Expected: 全部通过。

- [ ] **Step 5: 变异验证(守卫有牙)**

Run: `sh scripts/mutate.sh NemoNotch/Models/ExternalToastPayload.swift 'scheme.lowercased() == "file"' 'false' --only ExternalToastPayloadTests`
Expected: 变异被抓住(`file:///` 用例变红),mutate exit 0。

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Models/ExternalToastPayload.swift NemoNotchTests/ExternalToastPayloadTests.swift
git commit -m "feat(toast): /v1/toast 新增可选 jumpURL(绝对 URL、scheme≠file、≤2048、空串=未提供)"
```

---

### Task 2: Service 映射到 tabLink(红→绿)

**Files:**
- Modify: `NemoNotch/Services/ExternalCardService.swift`(`makeItem` 的 `CompletionJump.make(..., tabLink: payload.jumpURL)`)
- Test: `NemoNotchTests/ExternalCardServiceTests.swift`(`payload(...)` 工厂加 `jumpURL: String? = nil`;新增用例)

**Interfaces:**
- Consumes: Task 1 的 `payload.jumpURL`。
- Produces: `item.jump?.tabLink == payload.jumpURL`。

- [ ] **Step 1: 写失败测试**

```swift
@Test("jumpURL maps to tabLink; alone it still yields a jump; with jumpBundleId both ride along")
func jumpURLMapsToTabLink() {
    let alone = ExternalCardService.makeItem(payload: payload(jumpURL: "pulse://alerts/1"))
    #expect(alone.jump?.tabLink == "pulse://alerts/1")
    #expect(alone.jump?.hostBundleId == nil)
    let both = ExternalCardService.makeItem(payload: payload(jumpBundleId: "com.me.pulse", jumpURL: "pulse://alerts/1"))
    #expect(both.jump?.tabLink == "pulse://alerts/1")
    #expect(both.jump?.hostBundleId == "com.me.pulse")
    #expect(ExternalCardService.makeItem(payload: payload()).jump == nil)
}
```

- [ ] **Step 2: 跑测试看红** — Run: `sh scripts/test.sh --only ExternalCardServiceTests`;Expected: `tabLink` 断言失败(当前恒 nil)。
- [ ] **Step 3: 实现** — `tabLink: payload.jumpURL`。
- [ ] **Step 4: 跑测试看绿** — Run 同上;Expected: 全部通过。
- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/ExternalCardService.swift NemoNotchTests/ExternalCardServiceTests.swift
git commit -m "feat(toast): jumpURL 映射到 CompletionJump.tabLink——点击打开深链,打不开回落 jumpBundleId"
```

---

### Task 3: 文档同步

**Files:**
- Modify: `README.md`、`README_CN.md`(字段表加 `jumpURL` 行、示例 JSON 加字段)、`AGENTS.md`(外部 Toast 段加半句:`jumpURL` 点击开 URL、scheme≠file、URL 优先回落 bundle)

- [ ] **Step 1: 改三文件**;**Step 2: 核对** — Run: `rg -n "jumpURL" README.md README_CN.md AGENTS.md | wc -l; rg -c 2048 README.md README_CN.md NemoNotch/Models/ExternalToastPayload.swift; sh scripts/doc-audit.sh | tail -1`;Expected: 命中 ≥6、三处都含 2048、doc-audit 通过。
- [ ] **Step 3: Commit** — `git add README.md README_CN.md AGENTS.md && git commit -m "docs(toast): jumpURL 字段表/示例/手册同步"`

---

### Task 4: 门禁、评审、合并

- [ ] **Step 1: 全量测试 + lint + doc-audit + check-arch** — Run: `sh scripts/test.sh && sh scripts/lint.sh && sh scripts/doc-audit.sh && sh scripts/check-arch.sh; echo exit=$?`;Expected: `exit=0`(全量绿写锚点)。
- [ ] **Step 2: 评审** — `sh scripts/review.sh external-toast-jump-url && sh scripts/review.sh external-toast-jump-url --prompt` → 填事实派只读评审子代理 → 记录原样落盘单独提交;P1/P2 回流用 `--prev`。
- [ ] **Step 3: 勾满 plan,主检出 `git feat-done external-toast-jump-url`**;合并后用 curl 发一张带 `jumpURL` 的卡点击验证(梯级 5)。
