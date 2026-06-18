---
summary: 'Design references for NemoNotch visual style, interaction tone, and future component development.'
read_when:
  - 'building or reviewing a new NemoNotch UI component'
  - 'asking an AI assistant to match the existing NemoNotch visual style'
  - 'checking colors, spacing, shape language, or interaction tone'
---

# NemoNotch Design References

> **领域模块**:本模块是 NemoNotch 专属的视觉身份(单 OS 原生 SwiftUI、固定暖橙品牌色)。其中**可复用的样式 token 与原生交互约定**已抽进区块树 [`../swiftui/`](../swiftui/);需要跨项目复用样式经验时看那里,本模块只承载 NemoNotch 自己的视觉系统。

## Style Guides

- [Warm Noir Utility](./warm-noir-utility.md) — NemoNotch UI 的主设计系统参考:暖黑、macOS 原生、状态驱动、克制高密度。
- [AI UI Prompt](./ai-ui-prompt.md) — 给 AI 助手实现新 UI 时可直接复制的提示词。
- [UI Review Checklist](./ui-review-checklist.md) — 检查新组件是否仍然符合 Warm Noir Utility 的 review 清单。

## How To Use

When asking an AI assistant to design or implement a new NemoNotch component, include the target component requirements and reference:

> Follow `docs/macos/design-system/warm-noir-utility.md`. Match the Warm Noir Utility style: black floating macOS HUD surfaces, restrained warm orange state accents, SF Pro-like typography, compact utility layout, subtle borders, and no marketing-style decorative UI.

For AI-assisted coding sessions, copy the full prompt from [AI UI Prompt](./ai-ui-prompt.md), then ask the assistant to verify the result with [UI Review Checklist](./ui-review-checklist.md).
