---
summary: 'Index and navigation guide for the Peekaboo macOS playbook set covering 12 reusable implementation patterns.'
read_when:
  - 'starting a new macOS app and choosing which playbooks to follow'
  - 'looking for the right playbook to address a specific macOS capability'
---

# Peekaboo → macOS App Playbook 套件

## 这是什么

从 Peekaboo 提炼出可在未来 macOS 应用开发中复用的实施方案,聚焦 GUI 桌面应用 + 辅助功能/自动化/截屏能力。每篇 playbook 对应一个独立主题,包含来自真实工程的模式、陷阱与落地 checklist,可独立阅读,也可组合使用。

## 怎么用

- **新建 macOS 项目时**:从 01 开始,按编号顺序对照执行,建立模块结构、并发模型、日志与错误处理等基础,再逐步引入系统集成能力。
- **已有项目要补某能力**:直接跳到对应编号,每篇都自带"落地 checklist"与"Pitfalls",可独立对照检查。
- **查找相关主题**:每篇末尾的"延伸阅读 → 其它 playbook"列出强相关篇目,形成双向网络。

## 目录

### 基础设施

- [01 · 模块划分与依赖方向](./01-module-layout.md) — 单向层次模块 + SPM 编译隔离,把增量构建从 43 秒压到 5 秒以内
- [02 · Swift 6 严格并发实践](./02-swift6-concurrency.md) — 在编译期而非运行期消除数据竞争,含 SILGen 崩溃规避方法
- [03 · 日志与可观测性](./03-logging-observability.md) — OSLog 统一后端 + CLI stderr 双轨输出,不阻塞主线程
- [04 · 错误处理](./04-error-handling.md) — 三层架构:域错误 → 跨域包装 → 跨进程序列化,用户消息与诊断 payload 分离

### 系统集成

- [05 · 权限三态状态机](./05-permissions-state-machine.md) — Screen Recording/Accessibility/AppleEvents 三类 TCC 权限的生效时机差异与轮询建模
- [06 · AXorcist 元素查找 + Focus](./06-ax-automation-axorcist.md) — 类型安全的 AX 树遍历,操作前必须重新 query 以防 stale 引用
- [07 · CGEvent 拟真输入](./07-cgevent-input-synthesis.md) — 对数正态击键间隔 + 风/重力鼠标轨迹,可注入随机源保持测试确定性
- [08 · 屏幕捕获 + 窗口 + Spaces](./08-screen-capture-windows-spaces.md) — ScreenCaptureKit 优先,旧版 OS 回退 CGWindowList,Spaces 管理走 CGS 私有 API

### 视觉与交互

- [09 · SwiftUI + AppKit + Liquid Glass](./09-swiftui-appkit-liquid-glass.md) — `@main App` + `@NSApplicationDelegateAdaptor` 混合架构,Liquid Glass 效果统一适配器封装
- [10 · Visualizer 屏上 overlay](./10-visualizer-overlay.md) — 无边框 `NSWindow` 实现"看得见、点不到、不抢焦点"的屏上 overlay

### 工程实践

- [11 · SwiftPM + Xcode + Poltergeist](./11-swiftpm-xcode-poltergeist.md) — 混合工程统一进 `.xcworkspace`,Poltergeist 后台监听文件变化触发增量构建
- [12 · 测试策略 + 权限敏感测试 gating](./12-testing-permission-gated.md) — 编译期标志 + 运行期环境变量四级分层,CI 只跑安全集、本地按需解锁

## 设计 Spec

[2026-05-20 设计文档](../../specs/2026-05-20-peekaboo-macos-playbook-design.md)

---
*Last verified against Peekaboo @ `bae941f4`*
