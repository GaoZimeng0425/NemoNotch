# Overview Tab Design

**Date:** 2026-04-30  
**Status:** Approved

## Goal

将现有的 Media、Calendar、Weather 三个独立 Tab 合并为一个横向三列的 **Overview（概览）Tab**，减少 TabBar 项目数量，同时在单一面板中呈现最常用的日常信息。

## Decisions

| 问题 | 决定 |
|------|------|
| Tab 名称 | Overview / 概览，icon: `rectangle.3.group` |
| 默认比例 | 日历 2/5，媒体 2/5，天气 1/5 |
| 卡片分隔 | 各自独立轻圆角卡片（`notchCard` 背景） |
| 无媒体时 | 媒体卡折叠隐藏，日历:天气 = 2:1 撑满 |

## Architecture Changes

### Tab enum

移除 `.media`、`.calendar`、`.weather`，新增 `.overview`：

```swift
case overview  // icon: "rectangle.3.group", title: "概览"
```

### AppSettings

- `enabledTabs` 默认值更新：移除三旧 Tab，加入 `.overview`
- 自动选 Tab 逻辑（媒体播放、日历临近）改为跳至 `.overview`

### NotchView

- `tabContent` switch 中移除三旧分支，添加 `.overview` → `OverviewTab()`
- 自动选 Tab 逻辑同步更新

### i18n

- 新增 `models.tab.overview` 本地化 key（中文"概览"，英文"Overview"）
- 移除 `models.tab.media`、`models.tab.calendar`、`models.tab.weather` 的 key

## New Files

### `Tabs/OverviewTab.swift`

顶层视图，使用 `GeometryReader` 计算内容宽度，HStack 横排三卡片。

```
OverviewTab
├── OverviewCalendarSection   // 2/5 宽
├── OverviewMediaSection      // 2/5 宽（无媒体时 withAnimation 折叠）
└── OverviewWeatherSection    // 1/5 宽
```

卡片间距 6pt，每张卡片用 `.notchCard(radius: 8, fill: NotchTheme.surface)`。

### OverviewCalendarSection

内容与现有 `CalendarTab` 一致：
- 月份标签（顶部，小字）
- `DateStripView` 横向日期条
- 事件列表 `ScrollView`（复用 `EventRowContent`）
- 权限未授权时显示简化占位（图标 + 文字，不显示按钮）

### OverviewMediaSection

紧凑布局适配 ~194pt 宽：
- 封面图 36×36pt + 曲名/歌手（`lineLimit(1)`）
- 进度条 2pt 高
- 播放控制：prev / play|pause / next，间距收窄至 20pt
- 无音乐时：整个 Section 以 `withAnimation(.spring(duration: 0.3))` 折叠（`maxWidth: 0`，`opacity: 0`）

### OverviewWeatherSection

宽度约 96pt，全部竖向排列：
- 城市名（小字）
- 大字温度 + 天气图标
- 天气状况文字
- 三项数据竖排：体感温度 / 湿度 / 风速
- **逐时预报隐藏**（宽度不足）

## Layout Spec

面板展开尺寸：500 × 260pt  
内容区左右 padding 各 8pt → 可用宽度 ~484pt  
卡片间距 6pt × 2 = 12pt → 三卡片总宽 ~472pt

| 状态 | 日历 | 媒体 | 天气 |
|------|------|------|------|
| 有媒体 | 2/5 ≈ 189pt | 2/5 ≈ 189pt | 1/5 ≈ 94pt |
| 无媒体 | 2/3 ≈ 315pt | 折叠 | 1/3 ≈ 157pt |

## Deleted Files

直接删除 `Tabs/MediaTab.swift`、`Tabs/CalendarTab.swift`、`Tabs/WeatherTab.swift`。  
三个 Section view 内联复用原有逻辑，无需保留旧文件。

## Out of Scope

- 用户拖拽调整比例（过度设计）
- 天气逐时预报在 Overview 中展示
- 保留旧三 Tab 作为可选项（方案 B/C 已否决）
