# 设置内 Agent 接入指南(一键复制)设计

- 日期:2026-11-03
- 状态:已批准(方案于 2026-11-01 脑暴轮拍板:设置内、折叠展开、复制按钮常驻、正文为 agent 提示词)
- 前置:外部 Toast API 已交付(specs/2026-11-01-external-toast-api-design.md);指南全文已定稿于 docs/external-toast-agent-guide.md

## 意图

改之前:想接入 toast API,要把指南文档翻出来手动复制喂给 agent。
改之后:设置 → 提醒与动效、「外部应用 Toast」区块里就有一键复制的 agent 提示词——复制出来交给任何 agent,它就能为宿主应用生成接入脚本(自带端点发现、契约、验收清单)。

## 目标 / 非目标

**目标**
1. 指南以折叠区块挂在「外部应用 Toast」开关同一 Section(开关与指南同居,发现性最好);
2. 「复制指南」按钮常驻(不展开也能复制),复制后有短暂「已复制」反馈;
3. 正文 = `docs/external-toast-agent-guide.md` 的完整内容,Swift 多行字符串常量(代码内注明同源纪律:改契约两处同一提交);
4. 展开后 monospace 可滚动、支持手动文本选择;
5. 搜索可发现:新 key 登记 `SettingsSearchIndex`(教训①:漏登记出过 P2)。

**非目标**
- 正文本地化——它是技术工件不是 UI 文案,常量 verbatim 渲染(只有区块标题/按钮文案进 xcstrings);
- 指南与 README 的机器对账——第一版接受手动同步(注释标注),漂移风险已记录。

## 方案备选记录

- **独立设置页**:内容虽长但只有一个动作(复制),单开一页过重。弃。
- **About 页**:与功能开关分家,发现性差。弃。
- **选定:AlertsSettingsPage 的 external_toast Section 内加子块**(折叠 DisclosureGroup + 复制按钮)。

## 默认决策(my call)

| 决策 | 理由 |
|---|---|
| 复制反馈 = 按钮文案瞬变「已复制」2s 后复位 | 最轻的可感知反馈,无弹窗 |
| 正文常量放独立文件 `ExternalToastGuideSection.swift` | 150 行文本别挤设置页文件;常量与视图同文件,单一职责 |
| 复制用 `NSPasteboard.clearContents + setString` | 仓库既有先例(KeepAwakeSettingsView.swift:62) |

## 测试(判别剃刀)

- 纯逻辑单测:指南常量锚点断言(含 `v1/toast`、`hook-port`、`hook-token`、`X-NemoNotch-Token`、字段表关键词、验收清单段)——防常量被误清空/字段名改丢;变更有牙。
- e2e(部署后,配方进 plan):设置打开 → 展开指南 → 点复制 → `pbpaste` 含 `v1/toast`。

## 交给实现者

- DisclosureGroup 在 macOS Form 里的样式适配(必要时换自定义 chevron 行);
- xcstrings 走 `scripts/xcstrings.py format` 归一。
