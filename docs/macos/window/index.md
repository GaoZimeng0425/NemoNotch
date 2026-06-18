---
summary: 'macOS 窗口层：NSPanel/NSWindow 配置、多屏 overlay、原生约定三篇集合'
last_verified: { nemonotch: 'fe4e9e5' }
---
# window/ — macOS 窗口层知识库

| 文件 | 主题 |
|------|------|
| [nspanel-and-notch.md](nspanel-and-notch.md) | NSPanel `.statusBar+8`、三属性 collectionBehavior、tri-state 状态机、hotkey-aware dismiss、completion flash/glow ring 的 `.mask`/`.screen` |
| [multi-screen-overlay.md](multi-screen-overlay.md) | per-screen WindowController、`didChangeScreenParameters` 重建、"看得见点不到不抢焦点"；并列两种 overlay level：`.screenSaver` vs `.statusBar+8` |
| [window-conventions.md](window-conventions.md) | OS 原生窗口约定（阴影/圆角/激活策略/焦点还原）；无边框 notch 面板须自绘形状，两者适用场景并列说明 |
