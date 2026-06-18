---
summary: 'AI 代码生成的端到端管线结构:从脚手架收回所有权到修复循环编排与回滚安全'
read_when:
  - '需要理解整条生成/编辑管线的阶段划分与数据流'
  - '设计或调试修复循环时,想厘清各阶段职责与触发条件'
  - '需要确保编辑失败时不留半成品'
sources: ['I-9 AI 生成管线总览', 'I-15 修复循环编排与回滚安全']
last_verified:
  ironsmith: 'principles 文档(无 SHA,标 doc)'
---

# AI 代码生成管线:总览 + 修复循环编排

## TL;DR

整条管线的核心原则:**收回脚手架所有权**。模型只负责业务逻辑(单个 `ContentView.swift`),Package.swift / @main 入口 / manifest 由宿主写死、不交给模型。修复分三档递进——确定性(免费)→ 模型 diff(便宜)→ 整体重生(贵)——每档失败才升级到下一档,全失败时恢复历史最优而非留最后的烂摊子。

---

## 可复用模式

### 模式 1:脚手架所有权收回

将 AI 可写区域限定为单一文件(本例为 `Sources/<Name>/ContentView.swift`)。构建系统文件(`Package.swift`)、程序入口(`@main`)、元数据(`ironsmith-manifest.json`)全部由宿主代码生成并锁定,不纳入模型生成范围(`AGENTS.md:78-79`)。

**可复用至:** 任何"AI 生成 + 确定性脚手架"架构。把 AI 的写权限框死,是后续所有兜底机制能生效的前提。

### 模式 2:创建 vs. 编辑双模态管线

**创建模式(`SingleFileToolGenerationRuntime`)流程:**
```
取元数据(显示名+图标 prompt)
  → 宿主写包脚手架(Package.swift / @main / manifest)
  → 模型生成 ContentView.swift
  → 清洗/格式化(见 output-sanitize-and-fix.md)
  → 编译修复循环
  → 取二进制 → strip quarantine → 构建内部 app bundle
```

**编辑模式流程:**
```
暂存当前源码 → .ironsmith/versions/pending-ContentView.swift
  → 支持 diff 的模型走"有界 unified diff"
  → 不支持 diff 的模型走"整文件重写"
  → 成功:暂存源提升为 previous-ContentView.swift(供回滚)
  → 失败:恢复原始源码,丢弃暂存(AGENTS.md:84)
```

**关键不变量:** 任何时刻都不能留半成品。失败必须完整回滚到上一个已知好状态。

### 模式 3:三档递进修复循环

`ContentViewBuildRepairLoop.run` 的伪码骨架:

```
for attempt in 1...maxAttempts:
    生成候选 → 清洗/格式化 → swift build → 解析诊断
    ① applyDeterministicRepairsUntilStable(反复跑确定性修复至稳定)
    记录 bestCandidate(错误最少的版本)
    if ContentView 无错: 成功,break
    if 错误数 > 阈值: 整体重生 (continue)
    if 模型不支持 diff 修复: 整体重生 (continue)
    ② runModelRepairForCurrentCandidate:
        - 出 diff → 校验 → 应用 → 重新编译
        - 补丁让 ContentView 错误数增加 → 回滚
        - 编译成占位脚手架 → 回滚
        - 上下文超限 → 压缩对话,再不行整体重生
        - 连续无效/无进展 → 整体重生或切策略
最终全失败前: 恢复 bestCandidate 再报错
```

### 模式 4:五类安全机制

| 机制 | 实现 | 目的 |
|---|---|---|
| 占位脚手架检测 | `compiledContentViewIsPlaceholder` | 发现模型偷懒生成空壳并触发重生 |
| 历史最优保留 | `recordBestCandidate` | 全失败时恢复最好的候选而非最后一个 |
| 失败预算化 | 连续无效达阈值切策略或放弃 | 防止无限烧钱 |
| 阈值集中管理 | `ToolGenerationRepairPolicy` | hunk 上限、尝试数、stall 数等集中配置,不撒魔法数 |
| 结构化诊断日志 | `AgentDiagnosticsLog` (`~/.ironsmith/agent-diagnostics.log`) | DEBUG-only,每步可复盘,不 dump 整个模型响应 |

### 模式 5:模型能力分级选策略

`ToolRepairStrategy` 由 `InferenceStore` 按模型能力选(`AGENTS.md:95-96`)。不同模型走不同修复路径(diff 修复 vs. 整文件重写),让能力差的模型也能稳定收敛,避免把"模型聪不聪明"硬编码进主逻辑。

---

## 锚点(文件:行号)

- `AGENTS.md:78-79` — 脚手架文件由 Ironsmith 写,不交给模型
- `AGENTS.md:84` — 编辑失败恢复原始源码,丢弃暂存
- `AGENTS.md:95-96` — `ToolRepairStrategy` 按模型能力选
- `AGENTS.md:97` — 确定性修复器绑定诊断形状
- `AGENTS.md:99` — 结构化紧凑日志,不 dump 整个模型响应

---

## Pitfalls

- **不收回脚手架所有权就无法兜底。** 若允许模型改 Package.swift / @main,确定性修复器的假设全部失效。
- **编辑模式必须先暂存再操作。** 直接在原始文件上修改、失败后无法恢复,是最常见的数据损坏根源。
- **阈值不集中会导致"魔法数散落"。** 各处硬编码 max\_attempts / stall\_count 等,调参时容易漏改。
- **占位脚手架检测不做会白白浪费 attempt 预算。** 模型偷懒返回空壳是常见失败模式,需在循环最开始识别。
- **bestCandidate 不保存会让全失败时状态比第一次更差。** 修复循环结束时必须确保恢复的是历史最优版本。

---

## 落地 checklist

- [ ] 确认 AI 可写区域限定为单一文件,Package.swift / @main 由宿主锁定
- [ ] 编辑模式:操作前先暂存原始源码到 `pending-*` 路径
- [ ] 修复循环进入前先跑一轮确定性修复,确认稳定后再考虑调用模型
- [ ] 每轮记录当前候选错误数,及时更新 bestCandidate
- [ ] 设置 `ToolGenerationRepairPolicy` 集中管理 hunk 上限 / 尝试上限 / stall 预算
- [ ] 实现 `compiledContentViewIsPlaceholder` 检测
- [ ] 编辑失败路径:恢复原始源码,不留暂存文件
- [ ] 全失败路径:恢复 bestCandidate,不留最后一次尝试的损坏版本
- [ ] DEBUG 模式下启用结构化诊断日志,生产模式关闭

---

## 延伸阅读

- [Prompt 工程原则](prompt-engineering.md) — 管线的输入端:如何约束模型输出形态
- [输出清洗 / 诊断解析 / 确定性修复 / 模型 diff 修复](output-sanitize-and-fix.md) — 管线中段各阶段细节
- 区块树 `../build-release/` — SwiftPM 包生成、签名、app bundle 打包等可复用签名/路径细节
