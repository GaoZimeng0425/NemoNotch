---
summary: 'Swift 6 严格并发知识区块索引'
last_updated: '2026-06-18'
---

# Concurrency 区块索引

Swift 6 严格并发模式在编译期消除数据竞争,三源融合(Peekaboo P02、NemoNotch N §15、Ironsmith I-4)。

## 文件列表

| 文件 | 一句话摘要 | 何时读 |
|---|---|---|
| [`swift6-strict-concurrency.md`](./swift6-strict-concurrency.md) | `@MainActor @Observable final class` 模式、Sendable 边界、`@unchecked Sendable` / `nonisolated(unsafe)` 登记规则、SILGen 崩溃规避 | 迁移 Swift 6 严格并发、设计 actor 隔离边界、新增跨 actor 桥接类型时 |

## 快速导航

- 三层 actor 分层 → [Pattern 1](./swift6-strict-concurrency.md#pattern-1--三层-actor-分层)
- `@unchecked Sendable` 三种合法用法 → [Pattern 2](./swift6-strict-concurrency.md#pattern-2--unchecked-sendable--三种合法用法)
- `nonisolated(unsafe)` 绑定队列 → [Pattern 3](./swift6-strict-concurrency.md#pattern-3--nonisolatedunsafe-绑定到具名队列)
- SILGen crash 规避 → [P8](./swift6-strict-concurrency.md#p8--silgen-key-path-crash-swift-62)
- 迁移 checklist → [落地 checklist](./swift6-strict-concurrency.md#落地-checklist)
