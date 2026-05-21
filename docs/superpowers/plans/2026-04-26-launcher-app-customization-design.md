# Launcher 应用自定义设计

## 目标

在设置页完善应用管理：浏览已安装应用并勾选添加、拖拽排序调整显示顺序。

## 数据层

### LauncherService 改动

新增 `scanInstalledApps()` 方法：
- 扫描 `/Applications` 和 `~/Applications` 目录
- 读取每个 `.app` 的 `CFBundleName`（显示名）和 `CFBundleIdentifier`
- 以 Bundle Identifier 去重
- 返回 `[AppItem]`

### AppSettings 改动

- `launcherApps` 已有增删逻辑，补充拖拽排序支持（修改数组顺序后自动持久化）

## UI 层

### 设置页 - 应用列表 Section

- 现有 List 加 `onMove` modifier，左侧显示拖拽手柄
- Section 底部新增"添加应用"按钮，点击弹出 Sheet

### AppPicker Sheet

- 顶部搜索栏：实时过滤，同时匹配应用名和 Bundle Identifier
- 应用列表：图标 + 名称 + 勾选状态
- 勾选/取消即时生效，无需确认按钮
- 底部显示已选数量
- 后台线程扫描，避免阻塞 UI

## 边界情况

- 双目录扫描：`/Applications` + `~/Applications`，Bundle Identifier 去重
- 应用被卸载：显示默认图标，不主动删除，用户手动移除
- 不过滤系统应用，用户自行决定显示内容

## 改动范围

| 文件 | 改动 |
|------|------|
| `SettingsView.swift` | 应用列表加 `onMove` + "添加应用"按钮 + AppPicker Sheet |
| `LauncherService.swift` | 新增 `scanInstalledApps()` |
| `AppSettings.swift` | 小调整，支持排序持久化 |
