---
summary: 'Build & release 区块索引：签名/公证/DMG、应用数据路径、Poltergeist 增量构建、UITest 截图 Harness。'
read_when:
  - '查找构建、打包、发布、截图流水线相关条目'
sources: ['N §3', 'N §20', 'P11', 'I-16', 'I-17', 'I-18', 'I-19']
last_verified: { peekaboo: 'n/a', nemonotch: 'fe4e9e5' }
---

# Build & Release

| 文件 | 一句话 |
|------|--------|
| [signing-notarize-dmg.md](./signing-notarize-dmg.md) | xcarchive → ad-hoc 签名 → DMG，INFOPLIST_KEY_* 陷阱，GitHub Actions 发布，ad-hoc cdhash 每次变化对 Keychain 的影响 |
| [app-paths-and-data.md](./app-paths-and-data.md) | `~/.appname/` 下 sqlite/logs/config 的布局惯例，以及防路径逃逸的 `standardizedFileURL` 前缀校验 |
| [poltergeist-incremental.md](./poltergeist-incremental.md) | 混合工程统一进 `.xcworkspace`，Poltergeist 后台监听文件变化触发增量构建，lipo Universal Binary，pnpm 统一任务入口 |
| [uitest-screenshot-harness.md](./uitest-screenshot-harness.md) | `--uitest` 自驱动确定性模式，shell 脚本逐 tab 截图，`--flash` 全屏完成闪光截图，无 XCUITest target |
| [icon-generation.md](./icon-generation.md) | `.appiconset` / `iconutil` 全尺寸生成 + AI 降级 + 确定性 fallback——从 CGImage 到 AppIcon.icns 的完整管线 |
