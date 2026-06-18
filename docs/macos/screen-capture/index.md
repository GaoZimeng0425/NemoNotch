---
summary: '屏幕捕获、窗口枚举与 Spaces 管理：ScreenCaptureKit 主路径、CGWindowList 兜底、SkyLight CGS 私有 API。'
sources: ['P08']
last_verified:
  peekaboo: '742eadb991eec3fdf05c5092eb97e8e43d0dabfa'
  nemonotch: 'fe4e9e5'
---

# Screen Capture · 索引

macOS 截图分三层 API：**ScreenCaptureKit**（12.3+，`SCScreenshotManager` 单帧需 14+）主路径、**CGWindowList + CGWindowCreateImage** 兜底、**SkyLight CGS 私有 API** 用于 Spaces 管理（⚠️ 沙盒/MAS 不可用）。

| 文章 | 读它，当你… |
|------|-----------|
| [screencapturekit-and-fallback.md](./screencapturekit-and-fallback.md) | 新建截图功能、多屏 Retina 坐标换算、并发 SCK 调用超时、版本门槛选择 |
| [windows-and-spaces.md](./windows-and-spaces.md) | 枚举窗口元数据（不需像素）、切换 Space、跨 Space 移动窗口、评估 CGS API 发行渠道 |
