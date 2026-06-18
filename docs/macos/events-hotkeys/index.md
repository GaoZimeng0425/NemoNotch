---
summary: '事件捕获、拟真输入合成、热键注册三个子主题的入口索引。'
---

# events-hotkeys

本区块覆盖 macOS 上事件捕获与输入注入相关的三个主题:

| 文档 | 何时读 |
|------|--------|
| [global-event-monitor.md](global-event-monitor.md) | 需要全局监听鼠标移动/点击,实现悬浮面板自动展开/收起 |
| [cgevent-input-synthesis.md](cgevent-input-synthesis.md) | 需要合成拟真键盘/鼠标输入,或向 Electron/Chrome 等非原生 app 可靠投递事件 |
| [hotkeys.md](hotkeys.md) | 需要注册用户可自定义的全局快捷键,或从 Carbon `RegisterEventHotKey` 迁移到 KeyboardShortcuts |
