---
summary: 'AI 代码生成业务领域的模块索引'
read_when:
  - '进入 ai-codegen/ 时需要导航到正确的篇目'
sources: ['I-9~15']
last_verified:
  ironsmith: 'principles 文档(无 SHA,标 doc)'
---

# ai-codegen/ 模块索引

本模块提炼自 Ironsmith 项目第 9–15 章,覆盖 AI 代码生成管线的工程原则与可复用实现细节。

## 篇目

- [philosophy.md](philosophy.md) — 核心哲学:不靠模型聪明保质量,靠强约束 + 工程兜底(I-1 第1章)
- [checklist.md](checklist.md) — 落地 checklist(通用 macOS app + AI 生成类)+ 文档约定/"文档即真相"节(I-22/I-23)
- [pipeline.md](pipeline.md) — 管线总览(脚手架收回所有权、创建/编辑双模态流程)+ 修复循环编排与回滚安全
- [prompt-engineering.md](prompt-engineering.md) — Prompt 工程原则:输出约束、架构锁定、UI 规范、负面清单、输入侧精炼 agent
- [output-sanitize-and-fix.md](output-sanitize-and-fix.md) — 输出清洗 / 编译诊断解析 / 确定性修复器(60+ 条)/ 模型 diff 修复与校验

---

本模块是 AI 代码生成业务领域,非 macOS 系统区块;可复用的签名/路径/SwiftPM 细节见区块树 `../build-release/` 等。
