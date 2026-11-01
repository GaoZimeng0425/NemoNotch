# 外部 Toast API 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 本机任意应用通过 `POST /v1/toast`(共享令牌 + 端口文件)在刘海下方弹外来 toast 卡;keyed 推送刷新同一张卡;复用既有内容管线,对外来数据零语义翻译。

**Architecture:** wire schema(`ExternalToastPayload`,版本化 JSON)→ `ExternalCardService`(开关门禁 + 校验 + 组装,唯一落点)→ `CompletionItem`(`.external` source,照 `notice`/`calendar` 先例)→ 既有 `CompletionToastQueue` 与 toast 面板。`HookServer` 加路由,沿用令牌与 DoS 上限;`~/.NemoNotch/hook-port` 文件供外部应用发现端口。

**Tech Stack:** Swift 6 / SwiftUI / Network.framework(NWListener)/ Swift Testing

**Spec:** `docs/superpowers/specs/2026-11-01-external-toast-api-design.md`(已批准;含契约纪律与边界规则,执行者必读)

## Global Constraints

- 一切开发在 `git feat external-toast-api` 建的 worktree 内;提交走 pre-commit lint 门禁。
- 测试用 Swift Testing(`import Testing` / `@Test` / `#expect`),跑 `sh scripts/test.sh --only <Class>`;引用退出码与日志,不凭记忆。
- **红线(来自 spec):`ExternalCardService` 除校验外不得含任何翻译外来领域数据的逻辑**——请求体即完整卡面,缺省即清空。
- `~/.NemoNotch/hook-port` 只在 `UITestMode.ownsSharedHookConfig` 为真时写(测试宿主/`--uitest` 不写)。
- wire schema 契约:未知字段忽略;`app`/`key` 禁含 `::`;长度上限 app 1–48 / key 1–128 / title 1–120 / body ≤280;`schema != 1` 拒收;`duration` 刻意不存在。
- 外来卡**不触发**全屏辉光、**不受** `completionFlashEnabled` 门禁(走自己的开关,默认开)。
- UI 字符串全部进 xcstrings(en + zh-Hans),用 `scripts/xcstrings.py format` 归一。

## Review Focus

1. **令牌错/缺失 → 401 且不弹卡**——Task 4 e2e 配方含无令牌 curl;`headerToken` 纯函数已有既有测试。
2. **`schema != 1` → 400 拒收**(不静默吞)——Task 1 `parse` 测试 `testRejectsUnknownSchemaVersion`。
3. **`app`/`key` 含 `::` → 400**(防构造 `ext:` 碰撞键)——Task 1 测试 `testRejectsSeparatorInAppAndKey`。
4. **同 app 无 key 连推 → 各自成卡不互刷**——Task 3 测试 `testKeylessPushesGetUniqueCardKeys`。
5. **端口回落(45831 被占)后 `hook-port` 文件反映实际端口**——Task 4 e2e 验证(读文件与日志端口一致)。

---

### Task 1: Wire schema 模型与解析校验(纯函数)

**Files:**
- Create: `NemoNotch/Models/ExternalToastPayload.swift`
- Test: `NemoNotchTests/ExternalToastPayloadTests.swift`

**Interfaces:**
- Produces(后续任务依赖的确切签名):
  - `struct ExternalToastPayload: Equatable, Sendable` — 字段 `let schema: Int; let app: String; let key: String?; let title: String; let body: String?; let iconSymbol: String?; let jumpBundleId: String?`(`iconSymbol` 为解析结果:入参 `icon` 合法 `"sf:<名>"` 时取 `<名>`,否则 nil)
  - `enum ExternalToastRejection: Equatable, Sendable` — cases:`malformedJSON, badSchemaVersion, appInvalid, appTooLong, keyTooLong, separatorInAppOrKey, titleInvalid, titleTooLong, bodyTooLong`
  - `extension ExternalToastRejection { var localizedDescription: String }`(日志/响应体用,英文短句即可)
  - `struct ExternalCardContent: Equatable, Sendable` — `let app: String; let title: String; let body: String?; let jumpBundleId: String?`
  - `extension ExternalToastPayload { static func parse(_ data: Data) -> Result<ExternalToastPayload, ExternalToastRejection> }`
  - `extension ExternalToastPayload { func cardKey(makeUniqueID: () -> String = UUID().uuidString) -> String }` — `key` 非空且非空串 → `"ext:\(app)::\(key)"`;否则 → `"ext:\(app)::\(makeUniqueID())"`(一次性卡每次唯一)

- [ ] **Step 1: 写失败测试**(Swift Testing,一组 `@Test`):合法全字段解码、最小字段(app+title)解码、未知字段忽略(带 `"extra": 1` 仍成功)、`schema: 2` → `.badSchemaVersion`、缺/空 `app` → `.appInvalid`、缺/空 `title` → `.titleInvalid`、超长 app(49)/key(129)/title(121)/body(281) 各拒、`app` 或 `key` 含 `::` → `.separatorInAppOrKey`、`icon: "hammer"`(无 `sf:` 前缀)→ `iconSymbol == nil` 且整体成功、畸形 JSON → `.malformedJSON`、`cardKey`:有 key → `"ext:MyApp::dl-1"`,无 key 两次调用 makeUniqueID 给不同值 → 两个 cardKey 不同
- [ ] **Step 2: 跑测试确认全红**

  Run: `sh scripts/test.sh --only ExternalToastPayloadTests`
  Expected: 编译失败(类型不存在)——记为红
- [ ] **Step 3: 实现 `ExternalToastPayload.swift`**:`Codable` 结构(解码未知字段天然忽略)+ `parse` = JSONDecoder → 逐项校验(顺序:malformed → schema → app/key 分隔符 → 长度 → title → body;icon 降级不拒)。`parse` 与校验为纯函数,无 MainActor。
- [ ] **Step 4: 跑测试确认全绿**

  Run: `sh scripts/test.sh --only ExternalToastPayloadTests`
  Expected: PASS(引退出码)
- [ ] **Step 5: Commit**

  ```bash
  git add NemoNotch/Models/ExternalToastPayload.swift NemoNotchTests/ExternalToastPayloadTests.swift
  git commit -m "feat(external-toast): wire schema parse + validation (pure)"
  ```

### Task 2: 卡片模型接入 + toast 渲染

**Files:**
- Modify: `NemoNotch/Services/CompletionDetector.swift`(CompletionSource / CompletionItem)
- Modify: `NemoNotch/Notch/CompletionToastView.swift`(sourceIcon case + externalText)
- Test: `NemoNotchTests/CompletionDetectorTests.swift`(补两个测试)

**Interfaces:**
- Consumes: `ExternalCardContent`(Task 1)
- Produces:
  - `CompletionSource` 新 case:`case external(iconSymbol: String?)`(Equatable 自动合成;switch 穷尽性会强制渲染同步补 case)
  - `CompletionItem` 新字段:`var external: ExternalCardContent?`(两个既有 init 默认 nil)
  - 渲染:`CompletionToastView.externalText(_ content: ExternalCardContent) -> some View`

- [ ] **Step 1: 写失败测试**(补进 CompletionDetectorTests):
  - `testMergeReplacesExternalPayloadWholeCard`:同 toastKey 的旧 item `external.body = "A"` 被新 item(`external.body = nil`)merge 后,结果 `external.body == nil`——钉"完整卡面、缺省即清空"契约(`CompletionFlashNames.merge` 的 nil-保旧只作用于 AI 富字段,external 随 `merged = item` 天然整体替换;此测试防回归)
  - `testExternalItemToastKeyUsesProvidedKey`:`item.key = "ext:App::k1"` 时 `toastKey == "ext:App::k1"`(既有逻辑,钉行为)
- [ ] **Step 2: 跑测试确认红**(第一个测试因 `external` 字段不存在编译失败)
- [ ] **Step 3: 实现**:加 `CompletionSource.external(iconSymbol:)`;`CompletionItem` 加 `external` 字段并入两个 init 的默认 nil;`CompletionToastView.sourceIcon` 补 case(`Image(systemName: iconSymbol ?? "app.dashed")`,尺寸/字重照 `.agent` case);`externalText(_:)` 照 `noticeText(_:)` 三行结构——行1 = `item.name`(app 名,titleRow 样式),行2 = `external.title`(medium/secondary),行3 = `external.body`(tertiary,可 nil)。body 里的 `if let notice` 链在 calendar 之前插 `else if let external = item.external { externalText(external) }`。
- [ ] **Step 4: 跑测试确认绿**

  Run: `sh scripts/test.sh --only CompletionDetectorTests,CompletionToastQueueTests`
  Expected: PASS(队列既有测试守绿)
- [ ] **Step 5: Commit**

  ```bash
  git add NemoNotch/Services/CompletionDetector.swift NemoNotch/Notch/CompletionToastView.swift NemoNotchTests/CompletionDetectorTests.swift
  git commit -m "feat(external-toast): CompletionItem .external source + card rendering"
  ```

### Task 3: 呈现管线(服务 + 入口 + 开关)

**Files:**
- Modify: `NemoNotch/Services/CompletionFlashService.swift`(外来入口)
- Create: `NemoNotch/Services/ExternalCardService.swift`
- Modify: `NemoNotch/Models/AppSettings.swift`(开关)
- Modify: `NemoNotch/Helpers/AppDependencies.swift`(组装)
- Test: `NemoNotchTests/ExternalCardServiceTests.swift`

**Interfaces:**
- Consumes: `ExternalToastPayload.parse` / `cardKey`(Task 1);`CompletionSource.external` / `CompletionItem.external`(Task 2)
- Produces:
  - `enum ExternalToastAcceptance: Equatable, Sendable { case ok; case rejected(ExternalToastRejection) }`
  - `final class ExternalCardService`(`@MainActor`):`init(settings: AppSettings, present: @escaping (CompletionItem) -> Void)`;`func handle(body: Data) -> ExternalToastAcceptance`。职责顺序:开关关 → `.ok`(记 debug 日志,fire-and-forget);开 → `parse` 失败 → `.rejected`;成功 → `makeItem` → `present(item)` → `.ok`
  - `static func makeItem(payload: ExternalToastPayload, makeUniqueID: () -> String = UUID().uuidString) -> CompletionItem`:`key = payload.cardKey(makeUniqueID:)`、`name = payload.app`、`source = .external(iconSymbol: payload.iconSymbol)`、`external = ExternalCardContent(app: payload.app, title: payload.title, body: payload.body, jumpBundleId: payload.jumpBundleId)`、`jump = CompletionJump.make(hostPID: nil, hostBundleId: payload.jumpBundleId, tabLink: nil)`、其余字段 nil
  - `CompletionFlashService.showExternalToast(_ item: CompletionItem)`:照 `showNotificationToast` 模式——直接 `addToasts` + debug 日志,不触发辉光、不查 `completionFlashEnabled`
  - `AppSettings.externalToastEnabled: Bool`(didSet 持久化;load 默认 **true**;key `"externalToastEnabled"`——照 `notificationToastEnabled` 模式,AppSettingsNotificationToastTests 是抄写范本)

- [ ] **Step 1: 写失败测试**(注入 `present` 闭包记录调用):
  - `testHandleParsesAndPresents`:开关开 + 合法 JSON → `.ok`,`present` 恰好调用一次,item 的 `name/title/body/source/icon` 与 JSON 一致
  - `testHandleRejectsBadPayload`:开关开 + 畸形 JSON → `.rejected(.malformedJSON)`,`present` 零调用
  - `testHandleGateClosedIsSilentOk`:开关关 + 畸形 JSON → `.ok`(门禁先于解析),`present` 零调用
  - `testKeylessPushesGetUniqueCardKeys`:`makeItem` 同一无 key payload 调两次 → 两个 item 的 `toastKey` 不同(一次性卡独立身份)
  - `testKeyedPushesShareCardKey`:带 key payload 两次 → `toastKey` 相同
  - `testMakeItemMapsJumpBundleId`:`jumpBundleId` 传入 → `item.jump?.hostBundleId` 相等且 `hostPID == nil`;缺省 → `item.jump == nil`
- [ ] **Step 2: 跑测试确认红**
- [ ] **Step 3: 实现**服务 + 入口 + AppSettings 开关;`AppDependencies.build()` 在 `completionFlash` 构造之后建 `let externalCard = ExternalCardService(settings: settings, present: { completionFlash.showExternalToast($0) })`,加入成员列表("AI-derived events" 组)
- [ ] **Step 4: 跑测试确认绿**

  Run: `sh scripts/test.sh --only ExternalCardServiceTests,AppSettingsNotificationToastTests`
  Expected: PASS
- [ ] **Step 5: Commit**

  ```bash
  git add NemoNotch/Services/ExternalCardService.swift NemoNotch/Services/CompletionFlashService.swift NemoNotch/Models/AppSettings.swift NemoNotch/Helpers/AppDependencies.swift NemoNotchTests/ExternalCardServiceTests.swift
  git commit -m "feat(external-toast): ExternalCardService gate + makeItem + flash entry"
  ```

### Task 4: HTTP 面(/v1/toast 路由 + 端口文件)

**Files:**
- Modify: `NemoNotch/Services/HookServer.swift`(路由分支 + 回调 + hook-port 写入)
- Modify: `NemoNotch/Helpers/AppDependencies.swift`(接线)
- Test: `NemoNotchTests/HookServerRouteTests.swift`

**Interfaces:**
- Consumes: `ExternalToastAcceptance`(Task 3);`isAuthorized` / `sendHTTP` / 既有 body 提取模式(HookServer 内部)
- Produces:
  - `HookServer.onExternalToast: ((Data) -> ExternalToastAcceptance)?`
  - `nonisolated static func toastResponseStatus(_ acceptance: ExternalToastAcceptance) -> String`(`.ok` → `"200 OK"`;`.rejected` → `"400 Bad Request"`)
  - `static var portFilePath: String`(`~/.NemoNotch/hook-port`)

- [ ] **Step 1: 写失败测试**:`testToastResponseStatusMapping` 两断言(`.ok` → "200 OK",`.rejected(.malformedJSON)` → "400 Bad Request")
- [ ] **Step 2: 跑测试确认红**
- [ ] **Step 3: 实现**:
  - `processRequest` 在 `POST /hook` 分支旁加 `POST /v1/toast` 分支:令牌校验(复用 `isAuthorized`,失败 401)→ body 提取(照 `/hook` 的 `\r\n\r\n` 模式)→ `onExternalToast?(bodyData)` 映射响应:`.ok` → `{"status":"ok"}`;`.rejected(r)` → `{"status":"error","reason":"<localizedDescription>"}`;回调为 nil(未接线,防御)→ 500。校验失败记 `.warn` 日志(外来坏输入是最高发源)。
  - `handleListenerState` 的 `.ready` 分支、`ownsSharedHookConfig` 为真时(与 `setHookServerPort` 同处)写 `portFilePath`:`"\(port)\n"` 原子写 + 0600(照 `loadOrCreateAuthToken` 的写文件模式)。
  - `AppDependencies.build()` 在 `externalCard` 构造后:`aiMonitor.hookServer.onExternalToast = { externalCard.handle(body: $0) }`(注意在 `startServer()` 已调用与否无关——回调属性随时可设)。
- [ ] **Step 4: 跑测试确认绿 + e2e 手动验证**(真 app,`./build.sh` 部署后):

  ```bash
  PORT=$(cat ~/.NemoNotch/hook-port)          # 与日志 "listening on 127.0.0.1:<p>" 一致
  TOKEN=$(cat ~/.NemoNotch/hook-token)
  curl -s -X POST "127.0.0.1:$PORT/v1/toast" -H "X-NemoNotch-Token: $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"schema":1,"app":"Demo","key":"dl-1","title":"下载完成","body":"84 MB","icon":"sf:arrow.down.circle"}'
  # 期望:刘海下弹"Demo"卡,5 分钟自灭;同 key 再推 → 原卡刷新计时
  curl -s "127.0.0.1:$PORT/v1/toast" -X POST -d '{}'            # 期望 401(无令牌)
  curl -s -X POST "127.0.0.1:$PORT/v1/toast" -H "X-NemoNotch-Token: $TOKEN" -d 'not json'  # 期望 400
  ```

  Run: `sh scripts/test.sh --only HookServerRouteTests`
  Expected: PASS;e2e 三条 curl 输出与注释一致(记入提交信息或评审记录)
- [ ] **Step 5: Commit**

  ```bash
  git add NemoNotch/Services/HookServer.swift NemoNotch/Helpers/AppDependencies.swift NemoNotchTests/HookServerRouteTests.swift
  git commit -m "feat(external-toast): POST /v1/toast route + hook-port discovery file"
  ```

### Task 5: 设置开关 + 文档 + 收尾

**Files:**
- Modify: `NemoNotch/Settings/Pages/AlertsSettingsPage.swift`(开关,照该页既有 toggle 行模式)
- Modify: `NemoNotch/Resources/Localizable.xcstrings`
- Modify: `README.md` / `README_CN.md` / `AGENTS.md`
- Test: `NemoNotchTests/AppSettingsExternalToastTests.swift`

**Interfaces:**
- Consumes: `AppSettings.externalToastEnabled`(Task 3)

- [ ] **Step 1: 写失败测试**:`AppSettingsExternalToastTests` 断言新 UserDefaults 域下 `externalToastEnabled` 默认 `true`、set false 后重启(新实例)保持 false(照 `AppSettingsNotificationToastTests` 的双实例模式)
- [ ] **Step 2: 跑测试确认红 → 实现 Settings 页开关**(标题「外部应用 Toast」/ "External app toasts",副标题说明一行:外部应用经本地 API 弹卡)→ xcstrings 补 en + zh-Hans(`sh scripts/xcstrings.py format` 归一)
- [ ] **Step 3: 文档**:README×2 功能列表加一条 + 「外部 API」小节(端点、令牌、端口发现、schema 表、curl 示例——从 spec 的 Wire Schema 节照抄);AGENTS.md「Hook 端口与发送脚本」节补 `/v1/toast` 与 `hook-port` 两行事实(不动既有 doc-audit 断言字符串)
- [ ] **Step 4: 全量验证**

  Run: `sh scripts/affected-tests.sh && sh scripts/lint.sh`
  Expected: 全绿(引退出码);`./build.sh` 部署成功
- [ ] **Step 5: Commit**

  ```bash
  git add NemoNotch/Settings/Pages/AlertsSettingsPage.swift NemoNotch/Resources/Localizable.xcstrings README.md README_CN.md AGENTS.md NemoNotchTests/AppSettingsExternalToastTests.swift
  git commit -m "feat(external-toast): settings toggle + localization + docs"
  ```
