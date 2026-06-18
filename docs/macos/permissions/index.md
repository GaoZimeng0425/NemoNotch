---
summary: 'macOS TCC 权限知识库入口：状态机建模、PermissionCard UX 模式、Info.plist 陷阱。'
read_when:
  - '开始接入任何 macOS TCC 权限（Screen Recording / Accessibility / AppleEvents / Calendar / Location / Notifications）'
sources: ['P05', 'N §2', 'N §3', 'N §11']
last_verified:
  peekaboo: '2a523301b0addfe2ce61959d0152e28435491a74'
  nemonotch: 'fe4e9e5'
---

# Permissions — 知识库索引

三篇文章覆盖 macOS TCC 权限的完整实践路径：从状态机建模、UX 模式到构建配置陷阱。

| 文件 | 一句话 | 何时读 |
|------|--------|--------|
| [tcc-state-machine.md](tcc-state-machine.md) | TCC 七态完整模型（Swift 五枚举 + `in_effect`/`denied_sticky` 瞬态）；三类权限生效时机差异与轮询建模 | 接入屏幕录制/AX/AppleEvents；调试"授权后不生效"或"拒绝后 prompt 不弹" |
| [permission-card-ux.md](permission-card-ux.md) | NemoNotch never-auto-prompt 模式；`PermissionCard` Grant 按钮（Calendar / Location / Automation / Notification）；AX 仅跳系统设置 | 设计权限请求 UI；需要"有权限显示功能、无权限显示卡片"的声明式模式 |
| [infoplist-pitfall.md](infoplist-pitfall.md) | `GENERATE_INFOPLIST_FILE=YES` → 必须用 `INFOPLIST_KEY_*`；缺 `NSAppleEventsUsageDescription` 导致 Automation 对话框静默不弹；PlistBuddy 验证步骤 | 新增权限 key；调试 Automation prompt 不弹或系统设置列表找不到 app |
