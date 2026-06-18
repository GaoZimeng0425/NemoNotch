---
summary: '通过 KeyboardShortcuts 库注册用户可自定义全局热键,并与 Tab 跳转 / notch 开关逻辑绑定;兼附历史 Carbon 方案对比。'
read_when:
  - '为 macOS 工具添加用户可自定义的全局快捷键'
  - '调试热键绑定被意外重置或按键等效符无法解析'
  - '理解 KeyboardShortcuts 与历史 Carbon RegisterEventHotKey 的差异'
sources: ['N §6']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# 热键注册:KeyboardShortcuts 用户自定义绑定

## TL;DR

NemoNotch 通过 [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 注册全局热键。库处理了注册/注销、UserDefaults 持久化、SwiftUI `Recorder` 控件三件事,取代了原来需要手写约 80 行 C 桥接的 Carbon `RegisterEventHotKey` 路径。每个 Tab 对应一个固定 `KeyboardShortcuts.Name`,使 Tab 禁用/启用不会改变其他 Tab 的快捷键。

## 可复用模式

### 1 · Name 注册表(一处定义,全局共享)

```swift
// NemoNotch/Services/Hotkeys.swift
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleNotch = Self("toggleNotch")  // 无默认绑定 — 由用户配置
    static let openOverview = Self("openOverview", default: .init(.one, modifiers: [.option, .command]))
    static let openAI       = Self("openAI",       default: .init(.two, modifiers: [.option, .command]))
    // … 每个 Tab 一个 Name,默认 Cmd+Opt+<digit>
}

extension Tab {
    var hotkeyName: KeyboardShortcuts.Name {
        switch self {
        case .overview: return .openOverview
        case .claude:   return .openAI
        // …
        }
    }
}
```

### 2 · 注册回调(applicationDidFinishLaunching)

```swift
// NemoNotch/NemoNotchApp.swift  setupHotkeys(coordinator:)
private func setupHotkeys(coordinator: NotchCoordinator) {
    KeyboardShortcuts.onKeyDown(for: .toggleNotch) { [weak coordinator] in
        guard let c = coordinator else { return }
        switch c.status {
        case .closed: c.notchOpen()
        case .opened: c.notchClose()
        }
    }

    for tab in Tab.allCases {
        KeyboardShortcuts.onKeyDown(for: tab.hotkeyName) { [weak coordinator] in
            guard let c = coordinator else { return }
            c.notchOpen(tab: tab)
        }
    }
}
```

### 3 · Settings UI:KeyboardShortcuts.Recorder

```swift
// NemoNotch/Settings/HotkeysSettingsView.swift
KeyboardShortcuts.Recorder("Open Overview", name: .openOverview)
KeyboardShortcuts.Recorder("Toggle Notch",  name: .toggleNotch)
```

`Recorder` 是 SwiftUI 控件,显示当前绑定,让用户重新录制,自动持久化到 UserDefaults。无需额外代码。

## 锚点

| 位置 | 功能 |
|------|------|
| `NemoNotch/Services/Hotkeys.swift` | `KeyboardShortcuts.Name` 注册表 + `Tab.hotkeyName` 映射 |
| `NemoNotch/NemoNotchApp.swift` | `setupHotkeys(coordinator:)` — 回调注册 |
| `NemoNotch/Settings/HotkeysSettingsView.swift` | `KeyboardShortcuts.Recorder` — Settings UI |

## Pitfalls

**1. Name 字符串是 UserDefaults key,不可随意改名**
传给 `Self("…")` 的字符串是 UserDefaults 的 key。重命名 `"openAI"` 会让所有用户已保存的绑定无效(读不到旧 key → 回退默认值)。只增加新 Name,不改旧 Name。

**2. `import AppKit` 不可省略**
即使文件里看不到显式的 AppKit 调用,`[.option, .command]` 解析为 `NSEvent.ModifierFlags`(定义在 AppKit)。Swift 6 的 `MemberImportVisibility` 特性使 `KeyboardShortcuts` 的传递导入不再暴露这些符号,省略 `import AppKit` 会产生:
```
error: static property 'option' is not available due to missing import of defining module 'AppKit'
```

**3. `KeyboardShortcuts.Recorder` 是控件,不是 monitor**
库在内部处理注册/注销。调用方只声明 `onKeyDown` 回调。不要手动调用 `RegisterEventHotKey` 或 `RemoveEventHotKey`——会与库内部状态冲突。

**4. 固定 per-Tab Name 而非 by-index 分配**
历史 Carbon 实现按 `Tab.sorted(settings.enabledTabs)` 的下标分配热键——禁用某个 Tab 会导致其他 Tab 的快捷键移位。固定 `hotkeyName` 使每个 Tab 的绑定稳定;被禁用 Tab 的绑定闲置,重新启用即恢复。

**5. `[weak coordinator]` 与 app 生命周期**
`AppDelegate.coordinator` 在 `applicationDidFinishLaunching` 赋值后不再清空,库的回调也随 app 存活。`weak` 捕获是防御性写法,避免引用循环方向从库→app delegate。

**6. Carbon RegisterEventHotKey(历史方案)的替换原因**
Carbon 路径需要约 80 行桥接:手动 `Unmanaged.passUnretained(self).toOpaque()` 穿透 userdata、C 函数指针回调、`RemoveEventHotKey` 的平衡调用。`KeyboardShortcuts` 将这些全部封装;切换后热键行为与之前一致,代码量大幅减少。Peninsula 项目保留了 Carbon 方案的参考实现(见下方延伸阅读)。

## 落地 checklist

- [ ] 在 `Hotkeys.swift`(或单独文件)集中定义所有 `KeyboardShortcuts.Name`
- [ ] Name 字符串与 UserDefaults key 对应 — 一旦上线不要改名,只新增
- [ ] 文件顶部有 `import AppKit` + `import KeyboardShortcuts`
- [ ] `setupHotkeys` 在 `applicationDidFinishLaunching` 中调用,传入 coordinator / 需要操作的对象
- [ ] Settings 中为每个 Name 提供 `KeyboardShortcuts.Recorder`
- [ ] 每个 Tab 持有固定 `hotkeyName`,不按下标动态分配

## 延伸阅读

- [全局 NSEvent 监听](global-event-monitor.md) — 鼠标进出监听,与热键互补
- [CGEvent 拟真输入](cgevent-input-synthesis.md) — 合成快捷键(CGEvent modifier + defer 安全)
- *sindresorhus/KeyboardShortcuts* — 开源库,UserDefaults 持久化 + SwiftUI Recorder
- *Peninsula* — Carbon `RegisterEventHotKey` 参考实现(已被 KeyboardShortcuts 取代,仍可作历史对照)
- [../window/](../window/) — NotchCoordinator open/close 状态机(热键触发点)
