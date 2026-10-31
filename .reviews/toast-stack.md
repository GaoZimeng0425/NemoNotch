# Code Review — feature/toast-stack

Reviewer: independent review subagent (Claude, fresh session; did not author this branch)
Date: 2026-10-31
Reviewed-Head: c2e88a4
Verdict: APPROVED
Scope:  8 files changed, 161 insertions(+), 36 deletions(-)

```
AGENTS.md
NemoNotch/Services/AppActivator.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/CompletionToastQueue.swift
NemoNotch/Services/NotificationToastService.swift
NemoNotchTests/CompletionToastQueueTests.swift
README.md
README_CN.md
```

## Findings

- [P2] `NemoNotch/Services/CompletionToastQueue.swift:77`: the refill after `replace(key:with: nil)` on a **shown** card (the path where a notification card leaves the row because its messages left Notification Center, which is the "removed" case in the intent) has no test. Mutation evidence (level 4): `sh scripts/mutate.sh NemoNotch/Services/CompletionToastQueue.swift '…toasts.remove(at: idx)\n                refill(now: now)' '…toasts.remove(at: idx)' --only CompletionToastQueueTests` gave **exit 1, the mutation survived (20 passed)**. Dropping that `refill` would leave a free slot while cards wait, and the suite would stay green. Fix: add a test where a full row has a waiting card, then `replace(key: <shown notify key>, with: nil, now: T)`, and assert the waiting card is shown with `deadline == T + duration`. Re-run the mutation and confirm it goes red.
- [P3] Comments still describe the old "evict = gone" behaviour:
  - `NemoNotch/Helpers/Constants.swift:115` says "a newer one evicts the oldest".
  - `NemoNotch/Services/CompletionFlashService.swift:24-25` says "Eviction by a newer card is deliberately not reported — the user never got to see that card". A parked card *was* seen, and what actually goes unreported now is parking plus dropping from the 20-card pile. Same for line 31 "(not when evicted)".
  - `NemoNotch/Services/NotificationToastService.swift:11` and `NemoNotch/Services/NotificationInbox.swift:43-44` still say "evicted from the row … ride along with the app's next card". Per AGENTS.md that is now only true for a card dropped from the full pile; a parked card comes back by itself.

  AGENTS.md's 推翻旧口径 ⇒ 全仓 grep rule applies here. The historical spec and plan under `docs/superpowers/` are dated records, so leave them.
- Checked, no defect found:
  - State machine. Invariant: a non-empty `waiting` implies `toasts.count == capacity`. Every removal path (`dismiss`, `expire`, `replace` nil) refills, and when `add` merges a card back from waiting it re-parks the stalest card. Only `add` grows the pile, and it is trimmed there. The most recently parked card comes back first (`popLast`) with a fresh deadline (`now + duration`); mutations `waiting.popLast()`→`waiting.first` and dropping `card.deadline = …` both turn the suite red (exit 0). When a parked card arrives again it keeps its id, its fields merge, it appends as newest and gets a full timer (tested). While paused, a refilled card's deadline is overwritten by `resume`, so that's harmless.
  - The expiry timer re-arms after a refill: `syncToasts` (CompletionFlashService.swift:296-313) runs after `dismiss`, `expire` and `replace`, and reads `nextDeadline`, which only looks at shown cards, so waiting cards don't tick.
  - `onToastRemoved` fires only for `dismissToast` and expiry. Parking and pile overflow don't call it, so a waiting notification card is not "handled", as the intent says. `NotificationToastService.apply` → `updateNotificationToast` now reaches waiting cards (tested in `replaceReachesWaiting`).
  - `AppActivator.bringForward` is `@MainActor`. The `asyncAfter` closure captures only `pid` (Int32) and `name` (String), runs on main and compiles clean under Swift 6: `affected-tests.sh` exit 0, 43 passed, no warnings in changed files in `build/test.log`. It logs the result of the activation request plus a warning 0.5s later when the app isn't frontmost, with no root-cause claim, which matches the intent.
  - README, README_CN and the AGENTS.md toast and notification-card bullets match the new behaviour.

### 教训候选

- `CompletionToastQueue.swift:77`: in a queue where every exit path must call the same follow-up (`refill`), the tests usually cover the obvious exits (dismiss/expire) and miss the side door (`replace` nil). Rule for reviews: when one helper is called from N removal paths, run one mutation per call site (scripts/mutate.sh). A suite that kills only some of those mutations has a hole.
- When a semantic word changes meaning (here "evict" went from "gone" to "parked"), doc comments in neighbouring services drift silently, and doc-audit can't see prose. `rg` the old verb across `NemoNotch/` in the same commit.

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**: the new tests assert literal names, ids and deadlines. Two of three mutations died. One survived (P2 above).
- [x] **证据纪律**: I re-ran `affected-tests.sh` (exit 0, 43 passed) and 3 mutations.
- [x] **Swift 6 并发**: the delayed check runs on main and captures only Sendable values. It compiles with no warnings.
- [x] **最小改动**: every line traces back to intent 1 or 2.
- [x] **错误路径**: a missing running app now logs a warn (`activateBundle`), and a declined activation is logged.
- [x] **坑总目录对照**: the toast and notification-card invariants were updated. 被挤出 ≠ 已处理 is kept and refined.
- [x] **教训候选**: see above.
- [ ] **文档同步**: AGENTS.md and the READMEs are in sync, but the code comments are stale (P3).

## Re-review (c2e88a4)

- P2 resolved: `replaceNilRevealsWaiting` fills the row, parks A, removes the shown `notify:slack` card via `replace(key:with:nil,now:)` and asserts A comes back with `deadline == now + 30s`. Evidence (level 4): `sh scripts/test.sh --only CompletionToastQueueTests` exit 0, 21 passed. `sh scripts/mutate.sh ... 'toasts.remove(at: idx)' 'toasts.remove(at: idx); return true'` exit 0, mutation caught (1 failed, 20 passed). The earlier survivor is dead.
- P3 resolved: the four comments (Constants.swift, CompletionFlashService.swift, NotificationToastService.swift, NotificationInbox.swift) now say waiting off-row / dropped from the full pile. `rg evict NemoNotch` leaves only unrelated HermesService stale-agent eviction.
- Diff outside .reviews is comments plus one test. No behaviour change.
