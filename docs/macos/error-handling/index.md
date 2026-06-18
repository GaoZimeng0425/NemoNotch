---
summary: '多域 macOS app 的类型化错误设计:域枚举、顶层包装、跨进程 Codable 信封三层架构。'
read_when:
  - '开始为新模块设计错误类型层次结构'
  - '需要跨 CLI/GUI/Daemon 进程边界序列化错误'
sources: ['P04']
last_verified:
  peekaboo: 'd576fa0f'
  nemonotch: 'fe4e9e5'
---

# error-handling/

macOS 系统集成应用的错误处理参考。核心主题:用户消息与诊断 payload 严格分离、机器可读错误码、跨进程 Codable 信封序列化、`logged()` 日志桥。

## 文章

| 文件 | 摘要 |
|------|------|
| [three-layer-errors.md](three-layer-errors.md) | 三层错误模型完整指南:域枚举 → `StandardizedError` 顶层包装 → 跨进程 Codable 信封;含 7 个可复用 Pattern、完整锚点、Pitfalls 和落地 checklist |
