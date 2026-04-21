# UI & Animation Redesign

**Date:** 2026-04-21

**Goal:** 重构 tab 布局（NotchNook 风格）和修复/改进所有动画效果，使其符合直觉。

## 1. Tab 布局：NotchNook 风格

### 当前
- Tab 栏水平居中放在展开面板内容顶部（刘海下方）
- 展开 500x260pt 固定大小面板

### 改为
- Tab 图标放在硬件刘海黑色区域内，左对齐排列
- 关闭状态：图标直接显示在刘海内，选中高亮，未选中低透明度
- 展开状态：图标保持在刘海内，内容面板从刘海底部向下展开
- 内容面板是独立的圆角矩形（底部圆角，顶部无圆角，和刘海无缝衔接）

### 布局示意

```
Closed:
┌──[🎵][📅][🤖][🦞][🚀][🌤️][⚙️]──┐  ← icons in notch, left-aligned
└──────────────────────────────────┘

Expanded:
┌──[🎵][📅][🤖][🦞][🚀][🌤️][⚙️]──┐  ← icons stay in notch
│                                  │
│     Selected tab content area    │  ← content panel drops down
│                                  │
└──────────────────────────────────┘
```

### 实现要点
- Tab 图标尺寸约 16-18pt，间距 2-4pt，适配 ~200pt 刘海宽度
- 展开时刘海区域不变，内容面板从底部滑出
- 面板宽度 = 刘海宽度，高度根据内容自适应（最大 260pt）
- Badge 仍在刘海左右两侧，和 tab 图标互不干扰
- 关闭状态下 tab 图标常驻刘海内，不需要 hover 才显示

## 2. Badge 动画改进

### 2.1 左右 Badge icon 出现/消失

**当前：** opacity 淡入淡出 + scale，无方向性

**改为方向性滑动：**

| Badge | 出现（向外） | 消失（向内） |
|-------|------------|------------|
| 左侧 | 从刘海边缘向左滑出 | 从左向刘海边缘滑回 |
| 右侧 | 从刘海边缘向右滑出 | 从右向刘海边缘滑回 |

**实现：** 用 `.move(edge:)` + opacity 组合 transition

```swift
// 左侧 badge
.transition(.asymmetric(
    insertion: .opacity.combined(with: .move(edge: .trailing)),  // 从右(刘海边)向左滑出
    removal: .opacity.combined(with: .move(edge: .leading))      // 向右(刘海边)滑回
))

// 右侧 badge（方向相反）
.transition(.asymmetric(
    insertion: .opacity.combined(with: .move(edge: .leading)),   // 从左(刘海边)向右滑出
    removal: .opacity.combined(with: .move(edge: .trailing))     // 向左(刘海边)滑回
))
```

### 2.2 第二排 Badge Row 出现/消失

**当前：** opacity + scale(0.8)

**改为：** 从刘海中心向下展开出现，向上收回消失

```swift
.transition(.asymmetric(
    insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.8)),
    removal: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.8))
))
```

## 3. Tab 切换动画修复

### 3.1 方向判断修复

**当前 bug：** 点击 tab 按钮时 `slideForward` 不会更新，用的是上次滑动手势残留值

**修复：** 在 `selectedTab` 变化时自动计算方向

```swift
.onChange(of: coordinator.selectedTab) { oldTab, newTab in
    let tabs = Tab.sorted(appSettings.enabledTabs)
    let oldIndex = tabs.firstIndex(of: oldTab) ?? 0
    let newIndex = tabs.firstIndex(of: newTab) ?? 0
    slideForward = newIndex > oldIndex
}
```

### 3.2 滑动方向规则

| 操作 | 新 tab 位置 | 内容进入方向 | 内容离开方向 |
|------|-----------|------------|------------|
| 点击右侧 tab / 向左滑 | 右侧 | 从右滑入 (.trailing) | 向左滑出 (.leading) |
| 点击左侧 tab / 向右滑 | 左侧 | 从左滑入 (.leading) | 向右滑出 (.trailing) |

### 3.3 保留方向性滑动过渡

保持当前的 `.asymmetric` transition 但修复方向判断：

```swift
.transition(.asymmetric(
    insertion: .opacity.combined(with: .move(edge: slideForward ? .trailing : .leading)),
    removal: .opacity.combined(with: .move(edge: slideForward ? .leading : .trailing))
))
```

## 4. 内容面板展开动画

**当前：** 纯 opacity，内容突然出现

**改为：** 内容从上方向下滑入

```swift
.transition(.opacity.combined(with: .move(edge: .top)))
```

## 5. 其他动画优化

### 5.1 TabBarView 点击动画冲突

**问题：** TabBarView 内部用 `withAnimation(.interactiveSpring(duration: 0.3))` 包裹 `selectedTab` 变更，但 NotchView 的 transition 也有自己的动画。两者可能冲突。

**修复：** TabBarView 只负责更新状态，不包 withAnimation。动画由 NotchView 的 transition 统一控制。

### 5.2 内容淡入延迟

**当前：** `openContentDelay = 0.157s`，用 `.onAppear { contentOpacity = 1 }` 手动控制

**问题：** onAppear 只触发一次，如果面板已经打开再切换 tab 不会再触发

**修复：** 用 `.onChange(of: coordinator.status)` 替代 `.onAppear`，或者直接用 transition 不需要手动 opacity

## 实施顺序

1. **Tab 布局重构** — 将 tab 图标移入刘海内，内容面板独立展开
2. **Badge 动画** — 改为方向性滑动出现/消失
3. **Tab 切换方向修复** — 添加 onChange 计算方向
4. **内容面板展开动画** — 改为 move(edge: .top)
5. **清理动画冲突** — TabBarView 移除 withAnimation，统一控制

## 涉及文件

- `Notch/NotchView.swift` — 主要改动（布局、动画、badge）
- `Notch/TabBarView.swift` — 移入刘海内，移除 withAnimation
- `Notch/NotchCoordinator.swift` — 可能需要调整面板尺寸计算
- `Notch/CompactBadge.swift` — badge 动画方向
- `Helpers/NotchConstants.swift` — 可能需要新常量
