---
summary: 'macOS app 架构区块总入口:@Observable 服务层、状态所有权与 DI 选型、单一真相源 store、protocol-first provider、持久化选型。'
read_when:
  - '开始设计一个新 macOS app 的架构骨架'
  - '不确定该读哪篇时，从这里导航'
sources:
  - 'N §17 Architecture patterns'
  - 'I §2/§3/§4/§5/§6/§8'
last_verified:
  nemonotch: 'fe4e9e5'
  ironsmith: 'principles 文档'
---

# Architecture 区块索引

从两个真实项目（NemoNotch / Ironsmith）提炼，覆盖 macOS 原生 app 架构的核心决策点。

## 文件列表

| 文件 | 一句话 |
|---|---|
| [observable-service-layer.md](./observable-service-layer.md) | `@Observable` 服务标准形态、AppDelegate 装配/所有权、`@Environment` 注入、`LifecycleAware` 激活、刷新节流 |
| [state-ownership-and-di.md](./state-ownership-and-di.md) | 状态所有权边界（哪些禁止进共享 store）+ DI 并列两种选型：闭包 client（Ironsmith）vs protocol-first（NemoNotch） |
| [single-source-store.md](./single-source-store.md) | 多 provider 写入同一中心 store：upsert/mutate/mutateOrCreate、activeSession 优先级比较器、UI 只读 sortedSessions |
| [protocol-first-providers.md](./protocol-first-providers.md) | AIProvider / MultiAgentMonitor 协议、Registry 聚合、独立 Result 类型不强行统一、添加 provider 零改 UI |
| [persistence.md](./persistence.md) | 持久化并列两种选型：SwiftData `@Model`/迁移（Ironsmith）vs UserDefaults + `~/.App/*.json`（NemoNotch），按数据形态/规模选 |

## 阅读路径

- **新项目起步**：先读 `observable-service-layer.md`（服务骨架） → `state-ownership-and-di.md`（状态边界与 DI）→ `persistence.md`（持久化选型）。
- **多 provider 扩展**：读 `single-source-store.md` + `protocol-first-providers.md`。
- **选 DI 方式**：`state-ownership-and-di.md` §3/§4 并列对比，§5 有选型表。
- **选持久化方式**：`persistence.md` 开头选型表 + 两种方式对比表。
