---
summary: 'AI 代码生成的 Prompt 工程原则:从输出约束、架构锁定到输入侧精炼的 7 类可复用模式'
read_when:
  - '编写或迭代 coding agent / repair agent 的系统提示'
  - '设计输入侧 prompt 精炼 agent 时需要参考约束规范'
  - '需要为生成的代码定义 UI/架构审美边界'
sources: ['I-10 Prompt 工程原则']
last_verified:
  ironsmith: 'principles 文档(无 SHA,标 doc)'
---

# Prompt 工程原则

## TL;DR

Prompt 设计分两端:输出端 (A–E) 约束模型返回什么形态,输入端 (F) 在调用 coding agent 之前先精炼用户意图。这两端都需要硬约束 + 软增强(精炼失败回落原始),并与确定性修复器形成双保险。本仓库共 4 类 agent 角色:① coding agent ② repair/edit agent ③ prompt refinement agent ④ metadata agent。

---

## 可复用模式

### A. 约束输出形态(让结果可被机器消费)

这是最基础的约束。要求:
- 只返回源码,不要前言/解释/散文。
- 除 `MARK` 注释外不要其他注释。
- 修复阶段更严:**只返回 unified diff**,带 `@@` 头和足够上下文行;**禁止**散文、markdown 围栏、`*** Begin Patch` 标记(参考 `ToolGenerationPrompts.swift:39-49`)。
- **给"format-only"样例**:明确标注"仅示范格式,别抄内容"(`ToolGenerationPrompts.swift:209-216`)。

**可复用至:** 任何需要机器解析模型输出的场景。纯文本 / unified diff / JSON 任选,关键是明示格式 + 禁止散文 + 提供格式样例。

### B. 锁死架构骨架

明确告诉模型"哪些东西只能有一份、不能出现、不能改":
- 恰好一个 `struct ContentView: View`;状态用 `@State` 直接放进 `ContentView`。
- **禁止:** `ObservableObject / @Published / @StateObject / @ObservedObject`
- **禁止:** `#Preview / Package.swift / AppDelegate / SceneDelegate`
- **禁止:** 给任何 struct 加 `@main`(入口已存在)

**原则:** 凡是脚手架所有权已被宿主收回的文件或声明,都要在 prompt 里对应地禁止模型写。

### C. 原生感硬性审美(等于 UI 规范)

把 UI/控件规范直接写进系统提示:
- **推荐清单:** `Form / List / Table / Picker / Toggle / Slider / Stepper / DatePicker / NavigationSplitView`、工具栏、菜单、快捷键、系统色、自适应材质。
- **反模式清单:** 移动端布局、营销式大版面、假网页 dashboard、能用原生控件时不要自造。
- **平台专属:** macOS,不要 iOS-only 修饰符(如 `keyboardType`)。
- **框架优先:** 能用原生框架实现的功能显式点名——OCR→Vision、PDF→PDFKit、媒体→AVFoundation。

**可复用至:** 任何有原生感要求的代码生成场景。把审美约束写进 prompt,比事后人工 review 或修复器成本低。

### D. 防"常犯错误"的负面清单

把已知的高频错误模式逐条写进 prompt。重要:每一条都应有同名确定性修复器兜底(双保险,见 [output-sanitize-and-fix.md](output-sanitize-and-fix.md))。

典型条目:
- 数字输入用 `TextField("Label", value: $n, format: .number)`,不要用 `text:` 参数
- 显示取整用 `String(format:)`,别调 `rounded(toPlaces:)`(方法不存在)
- 不要给 `let` 常量赋值;计算结果直接写回 `@State`
- 别对数字调 `isEmpty`,要和 `0` 比较

**原则:** prompt 里的负面清单 = 确定性修复器的"先验版本"。prompt 引导不犯,犯了修复器免费修。

### E. 范围与安全硬约束

- **先窄而能编译,而不是宽而做不完:** `Build the smallest complete version`(`ToolGenerationPrompts.swift:69-70`)。
- **明确不要引入:** 后端服务、自建 server、账号系统、iCloud/CloudKit、推送、分析、订阅、跨设备同步。
- **沙箱上下文注入:** 把运行时沙箱状态作为上下文传入(`sandboxContext`);开启时用用户选择文件 / open/save 面板;关闭时也"非必要不改用户系统"。

### F. 输入侧约束:先精炼用户 prompt(软增强)

在调用 coding agent 之前,先用独立 refinement agent 把用户的原始请求扩写成"紧凑构建 prompt"(`ToolMetadataClient.swift`,`promptRefinementInstructions:258`)。

精炼 agent 的约束规范:
- **只返回纯文本**,禁止 JSON/代码/markdown/bullet/标签/文件名。
- **一段话、<750 字符。**
- 扩写内容:具体产品意图、核心功能、预期交互、布局与视觉方向、empty/loading/complete/error 等有用状态。
- **每个请求默认当"首版原型"**(除非用户明确要全功能)。
- **最多 3 个核心面向用户的功能;** 用户列一堆时,保留最重要的,**显式简化或省略其余**。
- **宁可一个打磨好的主工作流,而非一堆次要工作流。**
- 能用原生框架实现的功能显式点名。
- 同样框死"自包含、本地优先、无后端/账号/同步"。

**失败降级:** 精炼失败或返回空时,回落到原始 prompt(`live()` 里 catch 后 `return nil`)。软增强的标配模式。

### G. 元数据 agent:命名与图标短语

生成 app 显示名与图标 prompt 的小 agent(软增强,有确定性 fallback,参考第 19 章):

**displayName 约束:**
- 一到两个词、Title Case、snappy/playful
- **禁止:** 标点 / emoji / `App` / `Tool` 等通用后缀

**iconPrompt 约束:**
- 2–5 词的**小物件短语**(非句子),例如 "Calculator in front of house"
- **禁止提:** app icon / macOS / 风格 / 文字 / 字母 / 截图 / UI / logo / 背景

---

## 锚点(文件:行号)

- `ToolGenerationPrompts.swift:4-37` — 主系统提示 `singleFileCodingInstructions`
- `ToolGenerationPrompts.swift:39-49` — 修复阶段 diff 格式约束
- `ToolGenerationPrompts.swift:69-70` — `Build the smallest complete version`
- `ToolGenerationPrompts.swift:116` — `metadataInstructions`(命名与图标)
- `ToolGenerationPrompts.swift:209-216` — format-only 样例标注
- `ToolGenerationPrompts.swift:258` — `promptRefinementInstructions`

---

## Pitfalls

- **不给格式样例就要求格式。** 只写"返回 unified diff"但不附样例,模型对格式的理解容易漂移。
- **负面清单没有修复器兜底。** 只靠 prompt 引导不犯错,一旦犯了就只能人工修复或整体重生,成本高。
- **精炼 agent 没有降级路径。** 精炼失败/超时导致整个生成流程挂起,而不是 fallback 到原始 prompt。
- **范围约束漏掉了 iCloud/CloudKit/推送。** 单文件沙箱应用里引入这些 API 会导致签名或编译问题。
- **把"禁止 @main"写在修复器里但没写在 prompt 里。** 两端只有一端的防护有效,双保险才稳健。
- **iconPrompt 里出现"macOS icon"等词语。** 会让图片生成 API 返回 UI 截图而非真实物件图。

---

## 落地 checklist

- [ ] 系统提示里明确规定输出格式(纯源码 / unified diff)并附格式样例
- [ ] 明确禁止散文/前言/markdown 围栏
- [ ] 锁死架构骨架:单 ContentView、禁用 ObservableObject 相关、禁止 @main
- [ ] 写入"原生感"推荐控件清单 + 反模式清单
- [ ] prompt 负面清单每条都对应一个确定性修复器
- [ ] 沙箱上下文作为运行时参数注入,不硬编码
- [ ] 实现 prompt refinement agent,失败时 catch 并 fallback 到原始 prompt
- [ ] displayName / iconPrompt 的禁止项都覆盖到

---

## 延伸阅读

- [AI 代码生成管线:总览 + 修复循环](pipeline.md) — prompt 是管线的输入端,本篇是管线整体的前序
- [输出清洗 / 确定性修复 / 模型 diff 修复](output-sanitize-and-fix.md) — prompt 约束的每条负面清单,在这里有对应的修复器
