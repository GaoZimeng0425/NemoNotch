---
summary: '`.appiconset` / `iconutil` 全尺寸生成 + AI 降级 + 确定性 fallback——从 CGImage 到 AppIcon.icns 的完整管线。'
read_when:
  - '需要为 macOS app 生成 AppIcon.icns 或 .appiconset'
  - '集成 Image Playground / AI 图标生成时需要确定性 fallback'
  - '理解 iconutil 命令行用法及所需尺寸规格'
sources: ['I-19']
last_verified: { ironsmith: 'principles 文档' }
---

# 图标生成 (Icon Generation)

## TL;DR

`iconutil` 将一个 `AppIcon.iconset/` 目录（放置 5 个逻辑尺寸 × @1x/@2x = 10 张 PNG）编译为 `AppIcon.icns`。整个流程带三级降级：AI 生成 → 程序化渐变 fallback → 缓存复用。**富功能（AI 图标）必须有确定性 fallback**，这是 Ironsmith 的核心原则之一。

---

## 可复用模式

### 1. 三级降级管线

```
缓存命中(.ironsmith/AppIcon.icns)
  └─ 命中 → 直接使用，跳过生成
  └─ 未命中 ↓

Image Playground(AI 生成)
  └─ 成功 → CGImage → 继续走 iconutil 步骤
  └─ 失败 / 不支持 ↓

程序化渐变图标(确定性 fallback)
  └─ 1024×1024，按 app 名称哈希选 7 套配色之一
  └─ 叠加首字母（首字母图标）
  └─ 继续走 iconutil 步骤
```

来源：Ironsmith principles 第19章(I-19)（第 19 章）

### 2. `iconutil` 尺寸规格

`AppIcon.iconset/` 目录中必须包含以下文件名（macOS 标准命名，`iconutil` 强制要求）：

| 文件名 | 逻辑尺寸 | 实际像素 |
|--------|---------|---------|
| `icon_16x16.png` | 16 pt @1x | 16 × 16 |
| `icon_16x16@2x.png` | 16 pt @2x | 32 × 32 |
| `icon_32x32.png` | 32 pt @1x | 32 × 32 |
| `icon_32x32@2x.png` | 32 pt @2x | 64 × 64 |
| `icon_128x128.png` | 128 pt @1x | 128 × 128 |
| `icon_128x128@2x.png` | 128 pt @2x | 256 × 256 |
| `icon_256x256.png` | 256 pt @1x | 256 × 256 |
| `icon_256x256@2x.png` | 256 pt @2x | 512 × 512 |
| `icon_512x512.png` | 512 pt @1x | 512 × 512 |
| `icon_512x512@2x.png` | 512 pt @2x | 1024 × 1024 |

> 原始 CGImage 建议从 1024×1024 生成，按比例缩放得到各尺寸。

### 3. `iconutil` 命令

```bash
# 编译 iconset → icns（临时目录用完即删）
/usr/bin/iconutil -c icns -o /path/to/AppIcon.icns /path/to/AppIcon.iconset

# 完整流程示例（Shell）
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
# ...写入各尺寸 PNG...
/usr/bin/iconutil -c icns -o "$OUTPUT/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET"
```

来源：Ironsmith principles 第19章(I-19)

### 4. PNG 预览缓存

生成完整 ICNS 之前，可先写一张 ≤256px 的 PNG 预览缓存（用于 UI 快速展示，避免每次重新渲染）。完整的 ICNS 异步生成，UI 先显示预览。

来源：Ironsmith principles 第19章(I-19)

### 5. App bundle 中的图标引用

生成 `AppIcon.icns` 后需放入 bundle 并在 `Info.plist` 中声明：

```
bundle/
  Contents/
    Resources/
      AppIcon.icns        ← 复制到此处，权限无特殊要求
    Info.plist            ← 添加 CFBundleIconFile = "AppIcon"
```

`Info.plist` 关键键：`CFBundleIconFile`（值为 `"AppIcon"`，不含扩展名）。

来源：Ironsmith principles 第19章(I-19)

### 6. 哈希选色的程序化渐变（确定性 fallback 细节）

- 输入：app 显示名称字符串
- 算法：对名称哈希取模 7，映射到预定义的 7 套渐变配色
- 内容：1024×1024 渐变背景 + 叠加首字母（大写，居中，`CGContext` 绘制）
- 输出：`CGImage`，后续走相同的 iconutil 管线

此方案保证：即使 AI 服务不可用，图标生成步骤永远不会失败。

来源：Ironsmith principles 第19章(I-19)

---

## 锚点（file:line）

| 原则 / 实现 | 位置 |
|------------|------|
| 第 19 章全文（`ToolIconClient.swift` 完整流程） | Ironsmith principles 第19章(I-19) |
| 三级降级管线（缓存→AI→程序化） | Ironsmith principles 第19章(I-19) |
| `iconutil` 命令（5 尺寸 ×@1/@2x → icns） | Ironsmith principles 第19章(I-19) |
| PNG 预览缓存（≤256px） | Ironsmith principles 第19章(I-19) |
| 复制图标到 bundle（步骤 5） | Ironsmith principles 第19章(I-19) |
| `CFBundleIconFile` 条件键 | Ironsmith principles 第19章(I-19) |
| "富功能必须有确定性 fallback" 原则 | Ironsmith principles 第19章(I-19) |
| Checklist 条目 | Ironsmith principles 第19章(I-19) |

---

## Pitfalls

1. **`iconutil` 对文件名严格**：文件名必须完全匹配 `icon_NxN.png` / `icon_NxN@2x.png` 格式，大小写敏感，拼错则该尺寸被跳过或报错，生成的 icns 可能缺损。

2. **iconset 目录名必须以 `.iconset` 结尾**：`iconutil` 通过目录扩展名识别格式，改名会导致命令报错。

3. **icns 缺失时 `CFBundleIconFile` 仍需声明**：如果 Info.plist 声明了 `CFBundleIconFile` 但文件不存在，Finder 会回退到系统默认图标，不会崩溃，但会在 console 留警告。反之，有 icns 但未声明时，系统也找不到图标。

4. **Image Playground API 平台版本门控**：`ImagePlayground` 框架仅在较新的 macOS 版本可用，必须做 `#available` 检查或直接走降级路径，否则低系统版本会崩溃。

5. **不要在主线程上做 CGContext 绘制**（程序化生成）：生成 1024×1024 图标的 CGContext 操作在主线程上会卡 UI，应放到后台 Task/actor 执行。

6. **临时 iconset 目录要及时清理**：`iconutil` 执行后，临时的 `AppIcon.iconset/` 目录没有价值，需主动 `rm -rf`；未清理会在构建目录积累大量 PNG 文件。

7. **缓存 key 需绑定内容指纹**：`.ironsmith/AppIcon.icns` 的缓存命中逻辑若只检查文件存在，换了 app 名称或 prompt 后会复用旧图标，需额外校验 prompt/名称哈希。

---

## 落地 Checklist

- [ ] 原始图像从 1024×1024 开始生成（AI 或程序化渐变）
- [ ] 创建临时 `AppIcon.iconset/` 目录，写入全部 10 张 PNG（5 尺寸 × @1x/@2x）
- [ ] 文件名严格匹配 `icon_NxN.png` / `icon_NxN@2x.png`（区分大小写）
- [ ] 调用 `/usr/bin/iconutil -c icns -o <output.icns> <AppIcon.iconset>`
- [ ] 验证输出 icns 文件存在且 `size > 0`
- [ ] `rm -rf` 临时 iconset 目录
- [ ] 将 icns 复制到 `bundle/Contents/Resources/AppIcon.icns`
- [ ] `Info.plist` 中设置 `CFBundleIconFile = "AppIcon"`（不含扩展名）
- [ ] AI 生成路径做 `#available` 门控 + `do/catch` 包裹，失败自动走程序化 fallback
- [ ] 程序化 fallback 的 CGContext 绘制放到后台 Task（不阻塞主线程）
- [ ] 缓存 icns 命中逻辑绑定内容 hash（名称/prompt），避免跨 app 复用

---

## 延伸阅读

- [signing-notarize-dmg.md](./signing-notarize-dmg.md) — app bundle 打包、ad-hoc 签名、DMG 发布（图标所在 bundle 的后续步骤）
- [app-paths-and-data.md](./app-paths-and-data.md) — `.ironsmith/` 缓存目录的路径安全约定（缓存 icns 存放位置相关）
