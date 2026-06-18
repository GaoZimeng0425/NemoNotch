---
summary: '辅助功能(Accessibility API)区块:AX 树遍历、Focus 保护、Dock 角标读取。'
sources: ['P06', 'N §10']
last_verified:
  peekaboo: 'b8c6c48bc7e788949421b8aa48655bcbb491b348'
  nemonotch: 'fe4e9e5'
---

# Accessibility 区块

macOS Accessibility API(`AXUIElementRef` / AXorcist)的两个主要用途:驱动第三方 app 的 UI 自动化,以及读取 Dock 角标通知数。核心陷阱是 **stale element 句柄**与**不可见 Unicode 字符**。

## 文章列表

| 文章 | 内容 |
|------|------|
| [ax-tree-and-focus.md](./ax-tree-and-focus.md) | AXorcist 类型安全遍历 AX 树、app resolving 三态策略、Focus 保护包装、stale 引用防范、Electron/终端非原生目标降级路径 |
| [dock-badges.md](./dock-badges.md) | 通过 Accessibility API 读取 Dock 图标角标:权限门控、递归 AXChildren 遍历、`AXStatusLabel` 提取、Unicode LRM/RLM 清洗 |
