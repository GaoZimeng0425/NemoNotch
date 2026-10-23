# Usage Quota Alerts — Design

> 2026-10-23. 用户原话:「监听用量, 当超出阈值的时候提醒, 不消失, 只有用户点击知道了才消失, 额度恢复也要提醒, 也是不消失, 用户点击才消失」。

## Goal

When any provider's quota window (Claude 5h / 7d / 7d Opus / 7d Sonnet, Codex rolling windows, Gemini per-model, zcode) reaches the user's threshold, show a reminder that **stays until the user clicks 知道了 (Got it)**. When that window comes back under the threshold (its reset), show a "quota recovered" reminder with the same persistence.

## Decisions

1. **Surface = edge bar card.** The edge bar already owns AI sessions, draws the usage block and has cards with geometry-routed buttons (Deny/Allow, ask options). A quota alert is one more card kind (`EdgeBarAlertCard`) with a single loud button, 知道了. Toasts auto-dismiss and system notifications cannot be held, so neither fits "不消失". Consequence: **no edge bar, no alert surface** — the feature is inert while `aiStatusFabEnabled` is off (the settings page says so).
2. **Monitoring = the monitor polls itself.** `UsageQuotaService.setActive` is a view lifecycle hook (polls only while the AI tab is visible) and the bar refreshes only when it opens. `QuotaAlertMonitor` runs its own 5-minute timer (`usageQuota.refreshInterval`) calling `refresh(force: false)` while the feature is on; the service's 60 s throttle de-duplicates against other callers. It does not touch `setActive` (a view disappearing would kill a shared timer).
3. **Detection is a pure fold** (`QuotaAlertDetector.plan`): per (provider, window) key, `utilization >= threshold` while not yet "above" fires **exceeded** and marks the key above — a first reading already over counts (the user must learn about an exhausted window at launch). A key that is above fires **recovered** when `utilization < threshold - 5` (hysteresis: a reading wobbling at the line must not fire twice) and is unmarked. A key with no reading this round (fetch failed, not logged in) keeps its state — transient failures never read as recovery. Readings come only from `.valid` quotas with tiers.
4. **One alert per key, the newest event speaks for it.** `QuotaAlerts.apply` removes any pending alert of the same key before appending the new one. An unseen "exceeded" replaced by "recovered" is not lost information: the recovery card implies it. The alert id carries the kind (`claude:5h:recovered`), so a replacement is a **new card id** — the bar treats it as an arrival and opens.
5. **Opening is edge-triggered, holding is state-triggered.** `EdgeBarAlertCards.plan(previous:pending:…)` opens the closed bar (or takes the card on an open one) only for card ids that were not pending at the last refresh — a bar the user folded by drag is not re-opened by alerts it already showed. While the bar is open and any alert is pending, a pointer exit does not fold it (`holdsBarForAlert`, independent of `autoOpened`). The approval auto-close ("no approval waiting") additionally requires no alert pending. Explicit exits (drag, Go, chat bubble, feature off) still fold.
6. **Approval first; the cursor's card wins while the cursor is on the bar.** An arriving alert never takes the card from a selected approval (the CLI is blocked on it); it waits and is reclaimed later. Hovering rows swaps to row cards as today; when the pointer leaves a held bar, or when the bar opens by hover with alerts pending and nothing selected, `EdgeBarAlertCards.reclaim` brings the oldest pending alert's card back.
7. **Reset on reconfiguration.** Turning the feature (or the bar) off clears pending alerts and the above-set. A threshold change clears both too and restarts detection — what is over the new threshold fires as an arrival; a merely raised threshold never fires a bogus "recovered".
8. **Settings** (Settings → 提醒与动效, new section 用量提醒): `quotaAlertEnabled` **default off** (alerts are opt-in in this app, like the waiting reminder), `quotaAlertThreshold` ∈ {50, 60, 70, 80, 90, 100} default **80**.
9. **Card content**: provider heading (small caps) + kind title (red "超过阈值" / green "额度已恢复"), window name + percent in the usage level's colour, meter, "阈值 80%", the reset line when known (`EdgeBarUsageCardText.reset`, minute tick), and the 知道了 button. Width `EdgeBarMetrics.cardWidth`; sits level with the provider's usage section, else the block's top.

## Non-goals

System notifications, a notch surface, persistence across restarts (an unacknowledged alert re-fires at next launch if still over — acceptable), per-provider toggles, projected run-out alerts (the usage card's pace already shows that).

## Assumptions stated

- Utilization is monotonic within a window, so recovery coincides with a reset; hysteresis only guards API noise.
- A held-open bar with an alert card is the intended intrusion level ("不消失").
- Default off means the user enables it once in Settings after deployment.
