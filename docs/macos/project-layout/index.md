---
summary: 'project-layout 区块索引:SPM 模块分层与依赖方向、增量构建隔离与构建流程。'
read_when: ['查找模块划分、依赖方向、增量构建、构建脚本相关条目']
sources: ['P01', 'I-2', 'I-16', 'N §3']
last_verified:
  peekaboo: '548989f7299888e25444f15dcf7cab28b876f227'
  nemonotch: 'fe4e9e5'
---

# project-layout 区块

macOS 应用的模块分层、SPM 依赖方向、编译隔离与构建流程。

| 文件 | 内容 |
|---|---|
| [module-and-spm-layout.md](./module-and-spm-layout.md) | 四层单向 SPM 模块(Foundation→Protocols→Impl→Core/Apps)、Package.swift 骨架、`path:` 引用、`@_exported` umbrella、git submodule 切割临界点、协议注入、Ironsmith 式逻辑分层 |
| [build-isolation.md](./build-isolation.md) | 增量构建原理与诊断(43s→5s 数据)、构建命令参考(SPM/xcodebuild)、AI 生成代码管线包生成、SPM cache 清理、GitHub Actions 发布、Info.plist `GENERATE_INFOPLIST_FILE` 陷阱 |
