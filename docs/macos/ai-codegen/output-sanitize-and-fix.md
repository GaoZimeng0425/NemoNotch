---
summary: '模型输出后的四层处理:确定性清洗 → 编译诊断解析 → 确定性修复器 → 模型 diff 修复与校验'
read_when:
  - '实现或调试生成代码的清洗/格式化步骤'
  - '需要解析 swift build 诊断并将其映射到可修复的错误'
  - '编写新的确定性修复器或理解现有修复器的覆盖范围'
  - '设计模型 diff 修复的校验与拒绝规则'
sources: ['I-11 输出清洗:确定性预处理', 'I-12 编译诊断解析', 'I-13 确定性修复器:负面清单兜底', 'I-14 模型 diff 修复与校验']
last_verified:
  ironsmith: 'principles 文档(无 SHA,标 doc)'
---

# 输出清洗、编译诊断解析、确定性修复与模型 diff 修复

## TL;DR

模型产出后到交给编译器之前有四道处理:① **确定性清洗**(纯文本变换,移除脚手架 / 修正 footgun / 规范化 import) → ② **编译诊断解析**(结构化 `swift build` 输出)→ ③ **确定性修复器**(按错误形状匹配的 60+ 个规则,免费且无需模型)→ ④ **模型 diff 修复**(有严格校验拒绝规则)。越早的阶段越便宜,尽量在前两道消化掉问题。

---

## 可复用模式

### 第 11 章:确定性预处理(清洗管线)

`ContentViewSourceCleanup.swift` 在把代码交给编译器前,按固定顺序跑一连串确定性变换:

```
normalizedSource
  → cleanedSource
  → removeGeneratedScaffolding
  → normalizeCommonMacOSFootguns
  → removeMemberScopeViewBlocks
  → moveTopLevelStateIntoContentView
  → scaffoldContentViewIfNeeded
  → normalizeImports
```

代表性转换:

| 转换 | 锚点 | 细节 |
|---|---|---|
| 去脚手架 | `ContentViewSourceCleanup.swift:76-103` | 移除 ` ```swift ` 围栏、`@main`、`#Preview`、App/AppDelegate/PreviewProvider |
| struct→class | `ContentViewSourceCleanup.swift:117-120` | 正则把 `struct X: ObservableObject` 改成 `final class X: ObservableObject` |
| system color | `ContentViewSourceCleanup.swift:122-126` | `Color.system*` → `Color.gray.opacity(0.15)` |
| windowBackground | `ContentViewSourceCleanup.swift:128-131` | `Color(.windowBackground)` → `Color(NSColor.windowBackgroundColor)` |
| 删 keyboardType | `ContentViewSourceCleanup.swift:151-158` | 过滤含 `keyboardType(` 的行 |
| 裸修饰符补点 | `ContentViewSourceCleanup.swift:165-187` | 90+ 修饰符名集合,缺前导 `.` 时自动补上 |
| import 规范化 | `ContentViewSourceCleanup.swift:34-74` | 固定顺序 SwiftUI→Foundation→AppKit→UTI,其余字母序;按用到的符号**自动插入**缺失 import |
| 顶层 state 提升 | `ContentViewSourceCleanup.swift:465-523` | 把游离 `@State`/var 移进 `ContentView` 的 `// MARK: - State` |
| 缺 ContentView 兜底 | `ContentViewSourceCleanup.swift:353-463` | 没有 `struct ContentView: View` 就自动生成骨架 |

**自动 import 推断正则**(`ContentViewSourceCleanup.swift:50-57`):
- `AppKit`: `NSPasteboard|NSOpenPanel|NSSavePanel|NSWorkspace|NSImage|NSColor`
- `Foundation`: `URL|Date|FileManager|Data|Regex|NumberFormatter|DateFormatter|JSONDecoder|JSONEncoder|UUID|pow\(`
- `UniformTypeIdentifiers`: `UTType`

最后调用 swift-format 格式化(`SwiftPackageProcessClient.swift`):
```bash
xcrun swift-format format --in-place --no-color-diagnostics <file>
```

**原则:** 把代码交给编译器前,先用确定性变换清掉已知脏东西/footgun,减少需要昂贵修复的次数。

---

### 第 12 章:编译诊断解析

`SwiftPackageProcessClient.parseDiagnostics` 把 `swift build` 输出解析成结构化诊断。

**诊断头正则:**
```
(.+\.swift):(\d+):(\d+):\s+(error|warning|note):\s+(.+)
```
→ 映射到 `(path, line, column, severity, message)`

**结构体:**
```swift
struct SwiftCompilerDiagnostic {
    let relativePath: String?       // 相对 package root
    let line: Int; let column: Int  // 1-based
    let severity: Severity          // .error / .warning / .note
    let message: String
    let supportingLines: [String]   // 累积到下一个诊断头
}
```

**路径处理:** 去掉 package root 前缀,保留 `Sources/` / `Tests/` 相对路径。

**supportingLines 边界:** 累积直到下一个诊断头或构建进度行(`[`、`Build`、`Compile`、`[#`)。

**筛选到可操作错误**(`ContentViewRepairSupport.actionableErrors`):
- 只保留 `relativePath == ContentView.swift && severity == .error`
- **类型检查超时排到最后**(优先级最低)
- 去重 key:`[path, line, column, severity, message]` 用 `\u{1f}` 连接

**诊断分组(`selectedDiagnosticGroup`)** — 把同根因的诊断打包给一次修复:
- 特例优先单独处理:重复 body 声明、ObservedObject 类型错
- 根因 key:`weak-self`、`optional-chaining`、`comparison-spacing`、`range-iteration`、`missing-symbol`、`extra-argument`、`unsupported-member`(后几类可批量)

---

### 第 13 章:确定性修复器(负面清单兜底)

`ContentViewDeterministicRepairs.swift` 是一长串 `if let patch = xxxFix(for: diagnostic, ...)`,每条绑定一类编译错误的"形状",而非某个 app 的业务(`AGENTS.md:97`)。约 60+ 个,代表性修复器:

| 修复器 | 触发的编译错误 | 修法 |
|---|---|---|
| `observableObjectStructFix` | struct + ObservableObject | `struct X: ObservableObject` → `final class X` |
| `observedObjectStateFix` | `@ObservedObject` 但非 ObservableObject | `@ObservedObject` → `@State` |
| `mutableLetAssignmentFix` | cannot assign to 'let' | `let` → `var` |
| `roundedToPlacesFix` | rounded 无 toPlaces | `.rounded(toPlaces:n)` → `.rounded()` |
| `numericIsEmptyFix` | numeric 无 isEmpty | `!n.isEmpty` → `n > 0` |
| `numericTextFieldFix` | Binding\<String\> 不匹配数字 | `TextField(text: $n)` → `TextField(value: $n, format: .number)` |
| `unsupportedSystemColorFix` | Color 无 system* | → `Color.gray.opacity(0.15)` |
| `indexPathMacOSFix` | IndexPath row/item 混用 | `.row` → `.item` |
| `unsupportedModifierFix` | 无 onDoubleClick / keyboardType | `.onDoubleClick` → `.onTapGesture(count:2)`,删 keyboardType |
| `exponentOperatorFix` | 无 `**` 运算符 | `x ** y` → `pow(x, y)` |
| `methodPowFix` | 无 `.pow` 成员 | `.pow(e)` → `pow(base, e)` |
| `frameArgumentOrderFix` | width 须先于 height | 交换 `.frame` 参数顺序 |
| `identifiableConformanceFix` | 不符合 Identifiable | 加 `let id = UUID()` |
| `missingStoredPropertyFromInitializerFix` | has no member | 推导并插入缺失存储属性 |
| `invalidImportFix` | no such module | 删无效 import 行 |
| `uiAlertHelperNoopFix` | UIAlertController (iOS) | 把含 UIAlert* 的函数替换为空体 |

> 完整列表见 `DeterministicRepairs/`(`Basics.swift` / `Expressions.swift` / `StateAndTypes.swift`)

**原则:**
- **prompt 的每条负面清单,几乎都有同名确定性修复器兜底**(双保险:先引导别犯,犯了免费修)
- 修复器**绑定诊断形状**,广泛适用,不写成某个 prompt 的实现
- **每加一个修复器,在 `AgentPipelineTests` 加聚焦测试;** 失败的确定性编辑必须能安全跳过或回滚

---

### 第 14 章:模型 diff 修复与校验

确定性修复仍解决不了时,才让模型出 diff。层层设防。

#### Prompt 裁剪(`RepairPrompt.swift`、`makeRepairPromptPlan`)

- **只选一组相关诊断**(有 batch 上限),不一股脑全塞
- 附三类片段:出错行、所在可编辑块、相关片段,并声明"这些是上下文提示,不是编辑边界"
- **限制 hunk 数**(`maxHunksPerTurn`),要求"做一个连贯修复步骤就停"
- 带"上次修复结果" + "压缩摘要",并声明"当前源码取代对话里所有旧版本"

#### Diff / 编辑校验(`ContentViewDeterministicEditApplier.swift`,`applyValidatedDiff`)

**拒绝条件:**

| 类别 | 判断标准 |
|---|---|
| 尺寸 | 操作数 > 上限;`target` 或 `replacement` > **1200 字符** |
| 结构 | 重复 target;操作不在允许类型白名单内 |
| prose 泄露 | 含 `compiler diagnostic` / `the prompt` / `i will` / `let's` / `here is` / `to fix` |
| 占位符 | 含 `placeholder` / `todo` / `tbd` / `dummy` |
| 禁止内容 | 含 `@main` / `Package.swift` / `AppDelegate` / `SceneDelegate` |
| 越界 | 操作目标不是 `ContentView.swift` |

**接受时的容错匹配**(`replaceLine` / `replaceSection`):精确 → trim 相等 → 规范化空格相等 → snippet 内唯一匹配。字段先清洗(剥围栏、去注释、去说明性前缀行)。

**允许的编辑操作类型:**
- `addImport`
- `addStateProperty`
- `replaceLine`
- `replaceSection`
- `addHelperFunction`
- `renameIdentifierInSection`

插入点锚定到 `// MARK:` 段。

---

## 锚点(文件:行号)

- `ContentViewSourceCleanup.swift:34-74` — import 规范化
- `ContentViewSourceCleanup.swift:50-57` — 自动 import 推断正则
- `ContentViewSourceCleanup.swift:76-103` — 去脚手架
- `ContentViewSourceCleanup.swift:117-131` — struct→class / system color / windowBackground
- `ContentViewSourceCleanup.swift:151-187` — keyboardType 过滤 / 裸修饰符补点
- `ContentViewSourceCleanup.swift:353-463` — 缺 ContentView 兜底
- `ContentViewSourceCleanup.swift:465-523` — 顶层 state 提升
- `AGENTS.md:97` — 确定性修复器绑定诊断形状而非业务
- `DeterministicRepairs/Basics.swift` — 基础修复器列表
- `DeterministicRepairs/Expressions.swift` — 表达式修复器列表
- `DeterministicRepairs/StateAndTypes.swift` — 状态和类型修复器列表

---

## Pitfalls

- **清洗顺序不固定导致互相干扰。** `scaffoldContentViewIfNeeded` 必须在 `normalizeImports` 之前跑,否则新生成的骨架 import 会被漏掉。
- **不过滤 `warning` 和 `note` 就塞给修复器。** 修复器只针对 error,把所有诊断都传进去会触发误命中。
- **类型检查超时不排最后。** 超时诊断本身不代表逻辑错误,如果排在前面会优先触发整体重生。
- **prose 泄露检测用 case-sensitive 正则。** 模型可能返回 `I will` / `Here is` 等大写开头形式,需 case-insensitive 匹配。
- **target > 1200 字符却没拒绝。** 超长 target 通常意味着模型把整段上下文当成 diff 的一部分,应直接拒绝而非尝试应用。
- **修复器没有测试。** 确定性修复是免费的兜底,但没有聚焦测试的修复器容易出现误匹配,反而破坏已编译的代码。
- **import 推断正则遗漏常用符号。** 每新增一类依赖符号,需同步更新推断正则(`ContentViewSourceCleanup.swift:50-57`)。

---

## 落地 checklist

- [ ] 确认清洗管线步骤顺序与上方一致
- [ ] import 推断正则覆盖项目中所有依赖的符号模式
- [ ] `swift-format` 命令用 `--no-color-diagnostics` 避免颜色码污染日志
- [ ] 诊断解析只保留 `ContentView.swift` 的 `.error` 级别条目
- [ ] 类型检查超时诊断排到 actionableErrors 末尾
- [ ] 去重 key 用 `\u{1f}` 分隔五个字段
- [ ] 每个确定性修复器在 `AgentPipelineTests` 有聚焦测试
- [ ] 修复器失败时能安全跳过(不崩溃,不破坏文件)
- [ ] diff 拒绝规则:prose 泄露检测用 case-insensitive 匹配
- [ ] diff 拒绝规则:target / replacement > 1200 字符直接拒绝
- [ ] 容错匹配路径:精确 → trim → 规范化空格 → 唯一 snippet 顺序实现

---

## 延伸阅读

- [AI 代码生成管线:总览 + 修复循环](pipeline.md) — 本篇是管线中段,整体流程见此
- [Prompt 工程原则](prompt-engineering.md) — 负面清单与修复器的对应关系
- 区块树 `../build-release/` — SwiftPM 包生成与构建中的 `swift build` 调用细节
