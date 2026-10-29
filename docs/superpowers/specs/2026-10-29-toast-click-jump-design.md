# 完成卡片点击跳转 — 设计(短)

## 背景

- 改之前:刘海下方的完成卡片只有 × 可点,点卡片其余部分无反应。
- 改之后:点卡片(× 以外)跳到该会话所在的 app(终端 / IDE / ZCode…),和边栏卡片的 Go 同一套跳转;跳完卡片关闭。没有宿主 app 的卡片(agent、番茄钟、日历)点一下直接关闭。
- 用户拍板(2026-10-29):跳转后关闭卡片。

## 设计

- **跳转目标在完成那一刻快照**:`CompletionCandidate` / `CompletionItem` 携带 `jump: CompletionJump?`(`hostPID`、`hostBundleId`、`tabLink`,取自 `AISessionState.launchingAppPID` / `launchingAppBundleId` / `tabLinkURL`)。不在点击时回查 store——卡片挂 5 分钟,会话可能已被 stale 回收,快照仍能按 bundle id 兜底。
- **复用 `AppActivator.activate(pid:expectedBundleId:tabLink:)`**:tab 链接 → PID → bundle id 的既有降级链,不另写。
- **点击决策是纯函数** `CompletionToastClick.action(hit:toasts:)` → `.dismiss(id)` / `.jump(id, target)` / `.none`(已单测);控制器只执行。× 永远只关闭。
- 同会话刷新(`CompletionFlashNames.merge`)时 `jump` 同其他富字段:新值非空才覆盖。

## 不做

- 不改 hit-testing 几何(卡片区域与 × 区域已由 `CompletionToastLayout.hit` 区分)。
- 不给非 AI 卡片造跳转目标(日历打开日历 app 等)——需求未提,另议。
