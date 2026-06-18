---
summary: '通用 macOS app + AI 生成类项目的落地 checklist,附"文档即真相"文档约定一节'
read_when:
  - '开始新项目或新功能时做完整性检查'
  - '合并代码前的 self-review'
  - '编写 AI agent 工程文档时'
sources: ['I-22', 'I-23']
last_verified:
  ironsmith: 'principles 文档'
---

# Checklist + 文档约定

## TL;DR

两张 checklist(通用 macOS app / AI 生成类)可直接 copy 到 PR 描述或项目 README 作为 self-review 门槛。文档约定一节说明"如何写出能长期维护的工程指南"——核心是诚实标注已知的文档与代码 drift。

---

## 一、文档即真相(及其反面)

### 原则

`AGENTS.md` 是范本:详述每层职责,**并明确标注哪些旧设计已废弃**(旧 `MenuBarExtra`、architecture-agent、action-plan、protocol 文件思路均标 obsolete),还点名 `docs/ironsmith-spec.md` 部分已过时,强调"**源码和测试才是操作上的真相源**"(`AGENTS.md:159-160`)。

> 给 AI agent / 新人写的工程指南,价值在于「**明确不该做什么** + 诚实标注哪里已不准」。  
> 把指南当导航,**关键细节以源码为准**——落地前用 `grep`/阅读确认那个文件/函数/标志仍存在。

### ⚠️ 文档 vs. 代码 Drift 的真实案例

Ironsmith 自身踩到的坑(I-22 第22章):

> `AGENTS.md:144` 声称 `IronsmithModelContainerFactory` 在重建数据库前会把坏的 `sqlite/wal/shm` 备份到 `~/.ironsmith/Backups/`。  
> **当前代码(17 行)并不存在此逻辑。**

这是一个好原则(永不静默删除用户数据,删除/重建前先备份),但若你依赖这个保障——你需要自己补上,不能假设它已存在。

### 文档约定:如何避免 Drift

1. **⚠️ 标记已知 drift**——在文档里发现描述与代码不符时,就地加 `⚠️` 并说明差异,而不是删掉描述或假装没看见。
2. **标注"可能过时"的节**——不确定是否最新时,加 `(可能过时,请以源码为准)` 而非删除。
3. **废弃旧设计时在文档里标 `[obsolete]`**——让 AI agent 和新人不会按旧设计实现。
4. **不要在文档里描述"计划实现但尚未完成"的机制**——除非单独一节并标注状态。
5. **每次改代码,顺手更新对应文档**——没时间时至少加 `⚠️ 此节未验证,请以源码为准`。

---

## 二、通用 macOS App Checklist

### 应用外壳

- [ ] 菜单栏/后台型?优先 AppKit `NSStatusItem` + `NSPopover`,`App.body` 只放 `Settings` 场景。
- [ ] `applicationShouldTerminateAfterLastWindowClosed → false` 避免菜单栏 app 意外退出。
- [ ] 手动补 Edit 菜单(Cut / Copy / Paste / Select All 快捷键),菜单栏 app 默认没有标准菜单。
- [ ] `NSPopover.behavior = .applicationDefined`;显示时 `NSApp.activate(ignoringOtherApps: true)` + `makeKey()`。
- [ ] 测试环境(`isRunningTests`)不安装菜单栏控制器和窗口,核心逻辑可无 UI 跑。

### 架构分层

- [ ] 严格四层:View / Store(`@Observable`) / Repository / Closure Client。
- [ ] 写下各层**禁止事项**——Repository 禁发网络/碰 Keychain/起进程;局部 UI 状态禁进共享 Store。
- [ ] 区分共享态与局部态,显式列出"不该进共享 store 的状态"。

### 状态管理

- [ ] `@MainActor @Observable final class` 作为 Store 标准形式。
- [ ] 持久化字段用 `didSet` 钩子写回 UserDefaults。
- [ ] 不参与观察的依赖用 `@ObservationIgnored`。
- [ ] `init(userDefaults: UserDefaults = .standard)` —— 默认值方便测试时注入隔离的 `UserDefaults`。
- [ ] View 里要 binding 时,`body` 内建局部 `@Bindable var x = x`。

### 依赖注入

- [ ] 副作用收敛成"struct + 闭包" client,不用 protocol/mock 仪式。
- [ ] `.live` 工厂 + 依赖容器(`InferenceDependencies`)。
- [ ] 测试注入 fake 闭包,AI 修复流程同样可高度可测。
- [ ] 并发闭包加 `@Sendable`。

### 持久化

- [ ] SwiftData 测试/预览用 `isStoredInMemoryOnly: true`(内存库)。
- [ ] 稳定标识符不改名;字段重命名用 `@Attribute(originalName: "旧名")` 兼容历史库。
- [ ] 约定常量集中放(provider/model 标识符)。
- [ ] **删/重建库前先备份**,永不静默删除用户数据。⚠️ Ironsmith 文档描述了此原则但代码未实现,需自行补充。
- [ ] 路径/preference key 集中到 `Paths`/`PreferenceKeys` 枚举,不硬编码字符串。

### Keychain

- [ ] 可访问性:`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`(解锁后、仅本机、不随 iCloud 同步)。
- [ ] 统一 `service` 名 + `account = 引用串`。
- [ ] 更新优先于插入(`SecItemUpdate` → 失败再 `SecItemAdd`),避免重复项。
- [ ] "不存在"不是错误:load 返回 `nil`,delete 当成功处理。

### Provider / 多来源

- [ ] 把多 provider / 多来源元数据做成单一 catalog 真相源(`ProviderCatalog`)。
- [ ] 三态命名:persisted / remote / available,remote 禁止写入 SwiftData。
- [ ] 选择标识符格式 `providerIdentifier::modelIdentifier`,跨列表刷新稳定。
- [ ] UI / 预览 / 测试必须容忍空目录数组。

### SwiftUI 约定

- [ ] 条件渲染用 `@ViewBuilder` 私有计算属性,不深层 if-else 嵌套。
- [ ] 展示辅助(logo / 名称清洗)集中,优先扩展不重复。
- [ ] 预览 frame 贴近真实 surface 尺寸。

### 构建与测试

- [ ] 不开 Xcode,SwiftPM + `script/*.sh` 统一构建/测试/清理。
- [ ] 用 Swift Testing(`@Test` / `#expect`),不用 XCTest。
- [ ] 每个新确定性修复器都配聚焦测试。

---

## 三、AI 生成 / Agent 类 Checklist

### 脚手架与输出约束

- [ ] 收回脚手架所有权:模型只动最小可编辑面(仅 `ContentView.swift`),入口/清单/配置由你写死。
- [ ] Prompt 四件套:①约束输出形态(+format-only 样例) ②锁死架构骨架 ③原生审美正负清单 ④范围与安全边界。
- [ ] 给模型最小必要上下文 + 限量(hunk / 操作数上限)+ 声明"权威版本是哪份"。
- [ ] 输入侧精炼:用独立 agent 把用户原始请求扩写成"紧凑构建 prompt"(失败时 fallback 到原始 prompt)。

### 清洗与诊断

- [ ] 产出先过确定性清洗(去脚手架、规范 import、修 footgun、格式化)再编译。
- [ ] 把校验信号结构化:编译诊断解析 + 分组 + 去重 + 优先级排序。
- [ ] 负面清单 ↔ 确定性修复器一一对应,每条配测试,失败可安全跳过/回滚。

### 模型输出校验

- [ ] 拒 prose 泄露(含 "i will" / "let's" / "to fix" 等说明性词)。
- [ ] 拒占位符(`placeholder` / `todo` / `tbd` / `dummy`)。
- [ ] 拒越界(只能改指定文件,越界一律拒绝)。
- [ ] 拒超长(target / replacement > 1200 字符)。
- [ ] 拒禁止内容(`@main` / `Package.swift` / `AppDelegate` / `SceneDelegate`)。
- [ ] 容错匹配应用:精确 → trim 相等 → 规范化空格 → snippet 内唯一匹配。

### 修复循环与回滚安全

- [ ] 分档升级:确定性 → 受限模型调用 → 整体重生;阈值/预算集中一处(`ToolGenerationRepairPolicy`)。
- [ ] 记历史最优版本(`recordBestCandidate`);全失败时恢复它,不留最后那个烂摊子。
- [ ] 占位空壳检测(`compiledContentViewIsPlaceholder`);偷懒生成空壳 → 重生。
- [ ] 失败预算化:连续无效达阈值就切策略或放弃,不无限烧 token。
- [ ] 编辑模式:修改前暂存,失败后恢复原始源码。

### 安全与沙箱

- [ ] 运行不可信代码:默认沙箱(`com.apple.security.app-sandbox = true`)+ 强化运行时 + ad hoc 签名。
- [ ] 路径逃逸检查:`standardizedFileURL` + 前缀校验,防 `../../../etc/passwd`。
- [ ] Strip quarantine:`xattr -d com.apple.quarantine <binary>`。
- [ ] 敏感权限(camera / mic / automation / location)显式 entitlement + usage description。

### 富功能与 Fallback

- [ ] 富功能(AI 图标、元数据增强)必须有确定性 fallback(程序化渐变图标 / 原始 prompt)。
- [ ] 结构化紧凑日志(DEBUG-only,不 dump 整段模型响应)。

---

## 锚点

| 内容 | 来源 |
|------|------|
| 文档即真相原则 / AGENTS.md 废弃标注范本 | I-22 第22章(`AGENTS.md:159-160`) |
| 文档 drift 案例(坏库备份) | I-22 第22章(`IronsmithModelContainerFactory`) |
| 通用 macOS App checklist | I-23 第23章 |
| AI 生成 / agent 类 checklist | I-23 第23章 |

---

## Pitfalls

- **把文档当代码跑**——文档描述的机制不代表代码实现了。尤其是"安全保障"类的描述(备份、回滚、权限检查),落地前必须读源码确认。
- **checklist 一次性用完即弃**——checklist 的价值在于每次 PR / 每次新功能都跑一遍;只在项目初期用一次等于没用。
- **不标 ⚠️**——发现文档与代码不符后选择沉默,会导致下一个人(包括 AI agent)在错误假设上继续建设。

---

## 延伸阅读

- [philosophy.md](philosophy.md) — 核心工程哲学:为什么这样设计 checklist 背后的原则
- [pipeline.md](pipeline.md) — 修复循环的具体编排(checklist 中回滚安全条目的实现)
- [output-sanitize-and-fix.md](output-sanitize-and-fix.md) — 确定性修复器完整列表(checklist 中"负面清单↔修复器"的落地)
- [prompt-engineering.md](prompt-engineering.md) — Prompt 四件套的展开细节
