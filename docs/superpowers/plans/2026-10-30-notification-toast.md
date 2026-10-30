# 通知中心 → toast 卡片 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Mail / Slack / 微信等指定 app 的通知中心新通知,按 app 归一成刘海下方的 toast 卡片;撤掉刘海两侧的 Dock 红点通知徽章。

**Architecture:** 后台定时器对 usernoted 的 sqlite 库做「文件变了才读」的只读轮询 → 纯解码器把 `record.data` bplist 解成 `NotificationRecord` → 纯状态机 `NotificationInbox` 维护基线 / 已处理 / 每个 app 的未处理集合 → `NotificationToastService` 把每个 app 的未处理集合渲染成一张 `CompletionItem`(source `.notification`)推进现有 `CompletionToastQueue`,并在卡被关 / 到期时回写「已处理」。

**Tech Stack:** Swift 6、SwiftUI、SQLite3 C API(`SQLITE_OPEN_READONLY`)、`PropertyListSerialization`、Swift Testing。

**Spec:** `docs/superpowers/specs/2026-10-30-notification-toast-design.md`(原型:`docs/superpowers/specs/2026-10-30-notification-toast-mockup.html` 选项 B)

## Global Constraints

- 数据源只读:`~/Library/Group Containers/group.com.apple.usernoted/db2/db`,`sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)`;**任何代码路径都不写这个库**。读库在主线程外。
- `record.data` 字段:`app`(bundle id)、`uuid`(16 字节 Data)、`date`(CFAbsoluteTime)、`req.titl` / `req.subt` / `req.body`。
- bundle id 一律**小写后比较**(实测 `com.tencent.xinWeChat` vs `com.tencent.xinwechat`)。
- 与 AI 完成卡共用 `NotchConstants.completionToastCapacity`(4)与 `completionToastDuration`(300s);卡高保持 `CompletionToastLayout.cardHeight`(66)。
- 每个 app 至多一张卡,卡 key = `"notify:" + bundleID.lowercased()`。
- 点卡片 = 打开 app(未运行则启动)+ 关卡 + 卡内通知记为已处理;× = 关卡 + 记为已处理;到期 = 记为已处理;**被挤出卡位不算已处理**。
- 启动基线 = 第一次**成功**读库时的全部记录(不按 app 过滤);读失败不种基线。
- 已处理集合只在内存。
- 独立开关 `notificationToastEnabled`(默认 true),**不受** `completionFlashEnabled` 门禁;不触发辉光、不动闪光节流。
- 设置:新 key `notificationToastApps`,默认 `["com.apple.mail", "com.tinyspeck.slackmacgap", "com.tencent.xinWeChat"]`;旧 `monitoredApps` 删除不迁移。
- 非真实 app(`UITestMode` 单测宿主 / `--uitest`)不启动读库服务。
- 日志只记状态迁移(读库 ok / 无权限 / 格式不认识),不记每 tick。
- UI 字符串进 `Localizable.xcstrings`(en + zh-Hans),经 `scripts/xcstrings.py`。

## Review Focus

1. **授权前启动、启动后才授权**:第一次读失败(无完全磁盘访问权限)时若误种空基线,授权后通知中心里积压的几百条会一次性刷成卡。期望:基线只在第一次成功读时种下。→ Task 3 测试 `baselineSeedsOnFirstSuccessfulRead`。
2. **bundle id 大小写不一致**:设置里是 `com.tencent.xinWeChat`,库里 `app` 字段可能是另一种大小写。期望:照样匹配。→ Task 3 测试 `watchedMatchIsCaseInsensitive`。
3. **运行中把新 app 加进列表**:该 app 早已在通知中心里的旧通知不该刷成卡。期望:基线覆盖所有 app 的记录,不只监控中的。→ Task 3 测试 `baselineCoversUnwatchedApps`。
4. **微信隐私文案 / 无 title**:微信记录没有 `titl`,body 是「你收到了一条…」。期望:单条卡显示 body,多条卡发送人列表回落 app 名且不出现空串。→ Task 3 测试 `missingTitleFallsBackToAppName`。
5. **通知在卡片显示期间从通知中心消失**(app 自己撤回 / 用户在通知中心清掉):期望卡就地缩减且**不重置计时**;全没了卡就消失。→ Task 3 测试 `removalShrinksWithoutArrival` + Task 4 测试 `replaceKeepsDeadline`。

---

### Task 1: 撤掉 Dock 红点通知徽章(先删后加)

**Files:**
- Delete: `NemoNotch/Services/NotificationService.swift`、`NemoNotchTests/BadgeParsingTests.swift`
- Modify: `NemoNotch/Notch/Badge/BadgeItem.swift`(删 `case notification` 及其 switch 分支)、`BadgeGrouping.swift:41`、`BadgeIconView.swift`(删 `notificationBadge` 与 `notificationService` 属性/传参)、`BadgeViewModel.swift`(删 `notificationService` 依赖与 :58-60)、`NotchView.swift`(删 `@Environment(NotificationService.self)`、传参、`handleBadgeTap` 的 `.notification` 分支)、`NemoNotchApp.swift:115`、`Helpers/AppDependencies.swift`(:34、:102 及其他引用)、`Settings/SettingsView.swift`(:111、:146)、`Models/AppSettings.swift`(删 `monitoredApps` 属性与 :243 读取)、`NemoNotchTests/BadgeDebounceTests.swift:48`
- Modify: `NemoNotch/Settings/Pages/NotificationListSettingsPage.swift` → 暂时只剩 `Form { }.formStyle(.grouped)` 空壳(Task 5 填充)
- Modify: `NemoNotch/Resources/Localizable.xcstrings` 删只被旧页面使用的 key(`settings.monitored_apps`、`settings.no_monitored_apps`、`settings.add_monitored_app`、`settings.select_monitored_app`、`settings.monitored_footer`——删前 `rg` 确认无其他引用);`SettingsSearchIndex.swift` 的 `.notifications` 条目同步去掉已删 key。

**Interfaces:** Produces 无。删除后 `rg -n "NotificationService|monitoredApps|\.notification\(" NemoNotch NemoNotchTests` 零命中。`PermissionPane.swift` 注释里提到 NotificationService 的两处改成中性描述。

- [x] **Step 1:** 按上表删除 / 修改。
- [x] **Step 2:** `sh scripts/test.sh` → 退出码 0(编译通过 + 现有测试绿;引日志)。
- [x] **Step 3:** Commit `refactor: remove Dock-badge notification polling and notch badge`

### Task 2: 通知记录解码(纯)

**Files:**
- Create: `NemoNotch/Services/NotificationRecord.swift`
- Test: `NemoNotchTests/NotificationRecordTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct NotificationRecord: Equatable, Sendable {
      let id: UUID          // record.data["uuid"](16 字节)
      let bundleID: String  // record.data["app"],原样保存
      let title: String?    // req.titl,空串归 nil
      let subtitle: String? // req.subt,空串归 nil
      let body: String?     // req.body,空串归 nil
      let date: Date        // Date(timeIntervalSinceReferenceDate: data["date"])
      static func decode(_ data: Data) -> NotificationRecord?
  }
  ```
  `decode` 用 `PropertyListSerialization`;缺 `uuid`(或不是 16 字节)/ 缺 `app` / 不是 plist → nil。

- [x] **Step 1: 写测试**(fixture 在测试里用 `PropertyListSerialization.data(fromPropertyList:format:.binary)` 构造,形状照抄实测 Slack / 微信记录):
  - `decodesSlackShape`:`app="com.tinyspeck.slackmacgap"`,`uuid`=16 字节,`date=814968448.7`,`req={titl:"王小明", subt:"#design", body:"hi"}` → 各字段字面相等,`date == Date(timeIntervalSinceReferenceDate: 814968448.7)`。
  - `decodesWeChatWithoutTitle`:`req={body:"你收到了一条消息"}` → `title == nil`、`subtitle == nil`、`body == "你收到了一条消息"`。
  - `emptyStringsBecomeNil`:`titl:""` → `title == nil`。
  - `rejectsMissingUUID` / `rejectsShortUUID`(8 字节)/ `rejectsMissingApp` / `rejectsGarbage`(`Data("x".utf8)`)→ nil。
- [x] **Step 2:** `sh scripts/test.sh --only NotificationRecordTests` → 编译失败(类型不存在)。
- [x] **Step 3:** 实现 `NotificationRecord.decode`。
- [x] **Step 4:** 同命令 → 全绿;`sh scripts/mutate.sh NemoNotch/Services/NotificationRecord.swift '"titl"' '"subt"' --only NotificationRecordTests` → exit 0(变红)。
- [x] **Step 5:** Commit `feat: decode Notification Center records`

### Task 3: 收件箱状态机与卡片文案(纯)

**Files:**
- Create: `NemoNotch/Services/NotificationInbox.swift`
- Test: `NemoNotchTests/NotificationInboxTests.swift`

**Interfaces:**
- Consumes: `NotificationRecord`(Task 2)。
- Produces:
  ```swift
  struct NotificationCard: Equatable {
      let count: Int
      let line1: String?   // 单条: [title, subtitle] 非 nil 者用 " · " 连接,都 nil 则 nil
                           // 多条: 发送人去重列表(新→旧),发送人 = title ?? subtitle ?? appName,用 "、" 连接
      let line2: String?   // 单条: body
                           // 多条: latestPrefix + "<最新发送人> — <最新 body>"(body 为 nil 时只有发送人)
      static func make(appName: String, pending: [NotificationRecord], latestPrefix: String) -> NotificationCard?
      // pending 空 → nil;pending 按 date 新→旧自行排序
  }

  struct NotificationInbox {
      private(set) var isSeeded: Bool
      /// 一次成功读库的全量记录。首次调用只种基线(全部记为已见)并返回 []。
      /// 之后:返回「有新 id 到达」的 app(小写 bundle id,仅限 watched);
      /// 从 records 中消失的 id 同时从未处理集合移除。
      mutating func ingest(_ records: [NotificationRecord], watched: Set<String>) -> Set<String>
      /// 某 app(小写)当前未处理的记录(仍在库里、基线后出现、未被处理)。
      func pending(for app: String) -> [NotificationRecord]
      /// 有未处理记录的全部 app(小写)。
      var appsWithPending: Set<String> { get }
      /// 把该 app 当前未处理的记录全部记为已处理。
      mutating func markHandled(app: String)
      /// 开关关闭 / 重新开启时用:回到未种基线状态。
      mutating func reset()
  }
  ```
  `watched` 由调用方传小写集合;记录的 `bundleID` 在内部小写化。不在 `watched` 的 app 的新记录也记为已见(否则后来加入监控时会补出旧通知)。

- [x] **Step 1: 写测试**(用一个 `rec(_ n: UInt8, app:, title:, body:, t:)` helper 造记录,uuid 由 n 决定):
  - `baselineSeedsOnFirstSuccessfulRead`:新建 inbox 先**不**调用 ingest(模拟读失败)→ `isSeeded == false`;`ingest([r1, r2])` → 返回 `[]`、`appsWithPending.isEmpty`;再 `ingest([r1, r2, r3(slack)])` → 返回 `["com.tinyspeck.slackmacgap"]`,`pending(for:)` 只含 r3。
  - `watchedMatchIsCaseInsensitive`:记录 app `"com.tencent.xinwechat"`,watched `["com.tencent.xinwechat"]`(调用方已小写)而记录写 `"com.tencent.xinWeChat"` 也命中。
  - `baselineCoversUnwatchedApps`:基线含 mail 的 m1;之后 watched 加入 mail,`ingest([m1])` → `[]`。
  - `unwatchedArrivalNeverSurfaces`:基线后 mail 来 m2 但 watched 不含 mail → 返回 `[]`;之后 watched 加入 mail 再 ingest 同一批 → 仍 `[]`。
  - `markHandledHidesForever`:slack s1 到达 → `markHandled(app:)` → `pending` 空;下一次 ingest 仍含 s1 → 返回 `[]`;s2 到达 → `pending` 只有 s2。
  - `removalShrinksWithoutArrival`:s1、s2 未处理,下一次 ingest 只剩 s2 → 返回 `[]`(无新到达)且 `pending == [s2]`;再一次 ingest 两者都无 → `appsWithPending.isEmpty`。
  - `resetReseeds`:`reset()` 后 `isSeeded == false`,下一次 ingest 只种基线。
  - `cardSingle`:`make(appName:"Slack", pending:[s1 title "王小明" subt "#design" body "hi"], latestPrefix:"最新:")` → `count 1, line1 "王小明 · #design", line2 "hi"`。
  - `cardMultipleDedupesSendersNewestFirst`:3 条(t=1 李华、t=2 王小明、t=3 李华)→ `count 3, line1 "李华、王小明", line2 "最新:李华 — <t3 body>"`。
  - `missingTitleFallsBackToAppName`:微信 2 条都无 title/subtitle → `line1 "微信"`(去重后单个),`line2 "最新:微信 — 你收到了一条消息"`;单条无 title → `line1 nil, line2 "你收到了一条消息"`。
  - `cardEmptyIsNil`:`pending: []` → nil。
- [x] **Step 2:** `sh scripts/test.sh --only NotificationInboxTests` → 编译失败。
- [x] **Step 3:** 实现。
- [x] **Step 4:** 同命令全绿;变异:`sh scripts/mutate.sh NemoNotch/Services/NotificationInbox.swift '.lowercased()' '' --only NotificationInboxTests`(取文件中第一处小写化)→ exit 0。
- [x] **Step 5:** Commit `feat: notification inbox state machine and card text`

### Task 4: toast 管线支持通知卡

**Files:**
- Modify: `NemoNotch/Services/CompletionDetector.swift`(`CompletionSource` 加 `case notification(bundleID: String)`;`CompletionItem` 加 `var notice: NotificationCard?`,两个 init 默认 nil)
- Modify: `NemoNotch/Services/CompletionToastQueue.swift`
- Modify: `NemoNotch/Notch/CompletionToastLayout.swift`(`CompletionToastClick`)
- Modify: `NemoNotch/Services/CompletionFlashService.swift`
- Modify: `NemoNotch/Notch/CompletionToastView.swift`(通知卡渲染)
- Modify: `NemoNotch/Notch/CompletionToastWindow.swift:350-364`(`handleClick`)
- Modify: `NemoNotch/Services/AppActivator.swift`(新增 `openApp`)
- Test: `NemoNotchTests/CompletionToastQueueTests.swift`、`NemoNotchTests/CompletionToastClickTests.swift`

**Interfaces:**
- Consumes: `NotificationCard`(Task 3)。
- Produces:
  ```swift
  // CompletionToastQueue
  /// 就地换掉 key 对应卡的 item,不动 deadline;item 为 nil 则删卡。无此卡 → 无操作,返回 false。
  @discardableResult mutating func replace(key: String, with item: CompletionItem?) -> Bool
  // dismiss / expire 不变;add 的挤出行为不变(被挤出的卡不回调「已处理」)

  // CompletionToastClick
  case open(UUID, bundleID: String)   // 卡片主体点击且 item.source == .notification(bundleID)

  // CompletionFlashService
  enum ToastRemoval { case dismissed, expired }
  /// 卡被用户关(含点击跳转后的关)或到期时回调;被挤出不回调。
  var onToastRemoved: ((CompletionItem, ToastRemoval) -> Void)?
  /// 通知卡入口:**不**看 completionFlashEnabled(开关门禁在 Task 5 的服务里),不触发辉光、不动节流。新到达 → add(重计时)。
  func showNotificationToast(_ item: CompletionItem)
  /// 内容变化但无新到达 → replace(不重计时);nil 删卡。
  func updateNotificationToast(key: String, item: CompletionItem?)

  // AppActivator
  /// 运行中则 activate,否则 NSWorkspace.openApplication 启动。
  static func openApp(bundleId: String)
  ```
  通知卡的 `CompletionItem`:`key = "notify:<小写 bundle id>"`,`name` = app 显示名,`source = .notification(bundleID: 原样)`,`notice` = 卡片文案。`dismissToast` 与到期路径在移除前取到 item 再回调。

- [x] **Step 1: 写测试**
  - Queue `replaceKeepsDeadline`:add A(now=0)→ `replace(key:A.key, with:A')` at 任意时刻 → `toasts[0].item == A'` 且 `deadline == 300`。
  - Queue `replaceNilRemoves`:→ `toasts.isEmpty`,返回 true;`replace` 不存在的 key → false、队列不变。
  - Queue `notificationCardsShareCapacity`:4 张 AI 卡 + 1 张 `notify:` 卡 → 共 4 张,最旧 AI 卡被挤出,通知卡在。
  - Click `notificationCardOpensApp`:`.card(0)` 命中 source `.notification(bundleID:"com.tinyspeck.slackmacgap")` 的卡 → `.open(id, bundleID:"com.tinyspeck.slackmacgap")`;`.close(0)` 同卡 → `.dismiss(id)`。
- [x] **Step 2:** `sh scripts/test.sh --only CompletionToastQueueTests,CompletionToastClickTests` → 编译失败。
- [x] **Step 3:** 实现 queue / click / service / AppActivator;`handleClick` 的 `.open` 分支 = `AppActivator.openApp` + `dismissToast`。
- [x] **Step 4:** `CompletionToastView`:`item.notice != nil` 时,图标位放 app 图标(新增 `@MainActor enum AppIconCache { static func icon(bundleID: String) -> NSImage? }`,同文件,按 bundle id 经 `NSWorkspace.urlForApplication` + `icon(forFile:)` 解析并字典缓存);标题行 = app 名 + `count > 1` 时红色计数胶囊;第二行 `line1`(textSecondary);第三行 `line2`(textTertiary);保持 66pt、色环、×。`sourceIcon` switch 补 `.notification` 分支(兜底 `bell.fill`)。
- [x] **Step 5:** `sh scripts/affected-tests.sh` → 退出码 0(引日志)。
- [x] **Step 6:** Commit `feat: toast pipeline carries per-app notification cards`

### Task 5: 读库服务、设置与接线

**Files:**
- Create: `NemoNotch/Services/NotificationCenterReader.swift`
- Create: `NemoNotch/Services/NotificationToastService.swift`
- Modify: `NemoNotch/Models/AppSettings.swift`、`NemoNotch/Helpers/AppDependencies.swift`、`NemoNotch/NemoNotchApp.swift`(environment)、`NemoNotch/Settings/Pages/NotificationListSettingsPage.swift`、`NemoNotch/Settings/SettingsSearchIndex.swift`、`NemoNotch/Resources/Localizable.xcstrings`
- Test: `NemoNotchTests/AppSettingsNotificationToastTests.swift`(若已有 AppSettings 测试文件则并入)

**Interfaces:**
- Consumes: Task 2–4 全部。
- Produces:
  ```swift
  enum NotificationCenterReadResult: Sendable, Equatable {
      case records([NotificationRecord])
      case noAccess            // 打开失败且文件存在(TCC/EPERM)→ 需要完全磁盘访问权限
      case unavailable(String) // 文件不存在 / 表结构不认识 / sqlite 其他错误(带原因)
  }
  enum NotificationCenterReader {
      static let databaseURL: URL  // ~/Library/Group Containers/group.com.apple.usernoted/db2/db
      /// 主线程外调用。SELECT data FROM record;逐条 NotificationRecord.decode,解不出的跳过(debug 日志)。
      static func read() -> NotificationCenterReadResult
      /// (db, db-wal) 的 (mtime, size);用于「变了才读」。
      static func fingerprint() -> [Int64]?
  }

  @MainActor @Observable
  final class NotificationToastService {
      private(set) var status: Status   // .idle(开关关)/ .ok / .noAccess / .unavailable(String)
      init(settings: AppSettings, flash: CompletionFlashService)
      func start()            // UITestMode 下不调用(AppDependencies 门禁)
      func settingsChanged()  // 开关 / app 列表变化时设置页调用
  }

  // AppSettings
  var notificationToastEnabled: Bool   // key "notificationToastEnabled",默认 true
  var notificationToastApps: [String]  // key "notificationToastApps",默认见 Global Constraints
  ```
  服务行为:后台 `DispatchSourceTimer` 每 2s 取 `fingerprint()`,变了(或首次 / 上次失败)才 `read()`;结果回主线程 → `inbox.ingest`;对返回的「新到达」app 调 `flash.showNotificationToast`,对其余仍有卡但 pending 变化的 app 调 `updateNotificationToast`(pending 空传 nil);`flash.onToastRemoved` 对 `.notification` 源的卡调 `inbox.markHandled(app:)`。开关关:停定时器、对所有 `notify:` 卡 `updateNotificationToast(nil)`、`inbox.reset()`、`status = .idle`。app 名用 `FileManager.default.displayName(atPath:)`(由 bundle URL 得),解析不到用 bundle id。`status` 只在变化时写日志(info / warn)。

- [x] **Step 1: 写测试** `notificationToastDefaults`:清掉两个 key 后新建 `AppSettings` → `notificationToastEnabled == true`、`notificationToastApps == ["com.apple.mail", "com.tinyspeck.slackmacgap", "com.tencent.xinWeChat"]`;写入 `false` / `["x"]` 后新建实例读回相同值(测试前后恢复原 UserDefaults 值)。
- [x] **Step 2:** 跑 → 编译失败。实现 AppSettings 两个属性 → 绿。
- [x] **Step 3:** 实现 `NotificationCenterReader`(参照 `ZcodeUsageReader` 的 SQLite3 用法)与 `NotificationToastService`;`AppDependencies` 在 `UITestMode.ownsSharedHookConfig` 为真(即真实 app)时 `start()`。
- [x] **Step 4:** 设置页:开关行;`status == .noAccess` 时 `PermissionCard`(`openSettings: { PermissionFlowController.shared.start(pane: .fullDiskAccess) }`,新文案 key `permission.fullDiskAccess.notifications.title/detail`);`.unavailable(reason)` 时一行说明 + reason;app 列表增删(沿用旧页的 NSOpenPanel 交互,写 `notificationToastApps` 并调 `settingsChanged()`)。设置窗口激活时调 `settingsChanged()` 以便授权后立即重读(替代旧的 `refreshAXTrust`)。新 key 进 xcstrings(en + zh-Hans)并登记进 `SettingsSearchIndex` 的 `.notifications`。
- [x] **Step 5:** `sh scripts/affected-tests.sh` 与 `sh scripts/lint.sh` → 均退出码 0(引日志)。
- [x] **Step 6:** Commit `feat: surface Notification Center messages as toast cards`

### Task 6: 文档与真机验证

**Files:**
- Modify: `AGENTS.md`(「完成闪光 / Toast」节加一条通知卡不变量与坑:私有库只读路径、基线只在首次成功读、被挤出 ≠ 已处理、bundle id 小写、不受 completionFlashEnabled 门禁;「Keychain / 权限 / TCC」节加完全磁盘访问用途)、`README.md`、`README_CN.md`(功能描述:通知徽章 → 通知 toast)
- Modify: 本 plan 勾选

- [x] **Step 1:** 更新三份文档;`rg -n "Dock 红点|Dock badge|monitoredApps|通知徽章" AGENTS.md README.md README_CN.md docs` 清理旧口径残留。
- [x] **Step 2:** `sh scripts/doc-audit.sh` → 退出码 0。
- [x] **Step 3:** Commit `docs: notification toast`
- **合并部署后真机验证(feat-done 之后做,不在分支内勾选):** 给 NemoNotch 授完全磁盘访问 → 让 Slack 来一条消息 → 刘海下出 Slack 卡(单条文案);再来两条 → 同一张卡计数 3、发送人列表;点卡 → Slack 前台、卡消失、`log` 里无重复出卡;刘海两侧不再有铃铛 / app 徽章。
