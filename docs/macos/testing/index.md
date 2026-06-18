---
summary: 'testing/ 区块索引 — macOS 项目测试策略：Swift Testing 框架用法 + 权限敏感测试四级分层。'
read_when:
  - '进入 testing/ 区块前快速定位目标文档'
sources: []
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# Testing 区块索引

两个主题，每个独立成篇，按需阅读：

| 文档 | 一句话摘要 | 典型场景 |
|------|-----------|---------|
| [swift-testing.md](./swift-testing.md) | Swift Testing（`@Test`/`#expect`）框架用法与 NemoNotch 约定；测纯逻辑，跳过 AX/NSWindow 集成 | 写新单元测试、选框架 |
| [permission-gated-testing.md](./permission-gated-testing.md) | 四级矩阵（safe / automation:read / input / local），编译期 `-Xswiftc -D` + 运行期 env 双重门控，含两个原始 Peekaboo bug 分析 | 设计权限敏感测试分层、CI 报 AXError |

**区块外关联：**  
- 权限状态机与 PermissionCard 模式 → `../permissions/`  
- CI 构建、Xcode 版本固定、DMG 打包 → `../build-release/`
