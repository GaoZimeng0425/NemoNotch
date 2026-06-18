---
summary: '通过 Accessibility API 读取 Dock 图标角标数字,含权限门控、递归 AXChildren 遍历、AXStatusLabel 提取与 Unicode 不可见字符清洗。'
read_when:
  - '需要读取任意 app 在 Dock 上的通知角标数字'
  - '遭遇 AX 权限检测后 badge 仍为空的排查场景'
  - '角标文本含 WhatsApp 等带隐藏 Unicode 标记的 app 名'
sources: ['N §10']
last_verified:
  peekaboo: 'n/a'
  nemonotch: 'fe4e9e5'
---

# Dock 角标读取

## TL;DR

Dock 角标没有公开 API。读取路径:

1. `AXIsProcessTrusted()` 门控 → 未授权则引导用户去 System Settings
2. `AXUIElementCreateApplication(dockPID)` 获取 Dock 根节点
3. 递归 `AXChildren` 遍历所有 Dock tile 子元素
4. `kAXTitleAttribute` 匹配 app 名 → 读 `"AXStatusLabel"` 取角标文本
5. Unicode normalize 消除不可见控制字符(LRM、RLM、ZWNBSP)

关键注意:`"AXStatusLabel"` 是**未公开属性**,作为 CFString literal 传入,随 macOS 版本可能变化。

## 可复用模式

### Pattern 1 · AX 权限门控

```swift
// NotificationService.swift:14,84
var isAXTrusted: Bool = AXIsProcessTrusted()   // Read-only probe,不弹窗

// 每次 poll 重新读取,反映运行时授权变化
isAXTrusted = AXIsProcessTrusted()

// 一次性弹窗(仅首次引导时调用,当前代码未使用):
// let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
// _ = AXIsProcessTrustedWithOptions(opts)
```

### Pattern 2 · 获取 Dock AX 根节点

```swift
// NotificationService.swift:93-100  pollDock()
guard let dockPID = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.dock"
).last?.processIdentifier else {
    LogService.warn("NotificationService: Dock not found", category: "Notification")
    return
}
let dockApp = AXUIElementCreateApplication(dockPID)
```

### Pattern 3 · 递归 AXChildren 遍历

```swift
// NotificationService.swift:187-205  getSubElements(root:)
private func getSubElements(root: AXUIElement) -> [AXUIElement] {
    var count: CFIndex = 0
    let err = AXUIElementGetAttributeValueCount(root, "AXChildren" as CFString, &count)
    guard err == .success, count > 0 else { return [] }

    var children: CFArray?
    let copyErr = AXUIElementCopyAttributeValues(
        root, "AXChildren" as CFString, 0, count, &children)
    guard copyErr == .success, let elements = children as? [AXUIElement] else { return [] }

    var result: [AXUIElement] = []
    result.append(contentsOf: elements)
    for element in elements {
        result.append(contentsOf: getSubElements(root: element))
    }
    return result
}
```

### Pattern 4 · 提取角标文本

```swift
// NotificationService.swift:129-146  pollDock() match loop
for element in allElements {
    var title: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    guard err == .success, let titleStr = title as? String else { continue }
    let normalized = normalizeName(titleStr)
    guard let bundleID = nameToBundleID[normalized] else { continue }

    var statusLabel: AnyObject?
    AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &statusLabel)
    let label = statusLabel as? String ?? ""
    // parseBadgeCount(label) -> Int?   "3" -> 3,  "•" -> 0,  "" -> nil
}
```

`"AXStatusLabel"` 未在公开 `kAX*` 枚举中,直接以 CFString literal 传入。

### Pattern 5 · Unicode 不可见字符清洗

```swift
// NotificationService.swift:65-70  normalizeName(_:)
private func normalizeName(_ name: String) -> String {
    name.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0)
            && !($0.properties.generalCategory == .format)
    }.map(String.init).joined()
}

// 等价的精确替换形式(只处理已知标记):
// name.replacingOccurrences(of: "\u{200E}", with: "")   // LRM
//     .replacingOccurrences(of: "\u{200F}", with: "")   // RLM
//     .replacingOccurrences(of: "\u{FEFF}", with: "")   // ZWNBSP
```

## 锚点(file:line)

所有锚点均位于 `NemoNotch/Services/NotificationService.swift`:

| 描述 | 锚点 |
|------|------|
| `AXIsProcessTrusted()` 门控 + poll 重读 | `:14,84` |
| Dock PID 获取 + `AXUIElementCreateApplication` | `:93-100` |
| `getSubElements` 递归遍历 | `:187-205` |
| `kAXTitleAttribute` + `"AXStatusLabel"` 提取循环 | `:129-146` |
| `normalizeName` Unicode 清洗 | `:65-70` |

## Pitfalls

**P1 · AX 权限弹窗只出现一次**
`AXIsProcessTrustedWithOptions` 携带 `kAXTrustedCheckOptionPrompt=true` 只在首次(或撤权后)弹窗。用户拒绝后后续调用静默返回 false。
处置:弹窗失败后通过 `openAccessibilitySettings()` 打开 `x-apple.systempreferences:…Accessibility` 深链接,引导用户手动授权。参见 `[§11.3]`。

**P2 · 授权后不立即生效,需重启或等待**
在应用运行期间授予 AX 权限后,部分场景不会立即生效。
处置:在 `pollDock()` 内每次 poll 都重新调用 `AXIsProcessTrusted()`,或提示用户重启 app。

**P3 · Dock 重启过渡期有两个 PID**
`killall Dock` 或 OS 更新时 Dock 会短暂出现两个进程。
处置:用 `.last` 而非 `.first` 取 PID(较新的进程是存活的那个);Dock 无 PID 时 bail 并在下次 poll 重试,不要 crash。

**P4 · `AXUIElementCopyAttributeValues` 在叶节点返回 `kAXErrorNoValue`**
叶节点 `count == 0` 是正常信号,不是错误。
处置:`count > 0` guard 提前返回空数组即可,不要把它当硬错误处理。

**P5 · Dock tile 深度不固定**
Dock tile 内嵌套若干子元素(图标、标签、角标容器),深度随 macOS 版本和 tile 类型变化。
处置:递归遍历直到穷举子树,在调用方按属性过滤,不要假设固定深度。

**P6 · `"AXStatusLabel"` 未公开,可能随 macOS 版本变化**
处置:打印 / 日志原始值以便感知回归。属性不存在时返回 nil,视为"无角标"处理。

**P7 · 重复 Dock tile 同名(如 WhatsApp 多实例)**
某些 app 有时会出现两个同名 Dock tile。
处置:遍历所有匹配项,优先取 `AXStatusLabel` 非空的那个。

**P8 · WhatsApp 等 app 名含隐藏 Unicode 标记**
WhatsApp 的 Dock tile title 含 `U+200E`(LRM);某些 CJK 区域版本含 `U+FEFF`(ZWNBSP)。朴素的 `titleStr == "WhatsApp"` 永远不匹配,角标静默消失。
处置:`normalizeName` 过滤 Unicode 通用类别 `Cf`(Format)+ 控制字符,**不要**用 `precomposedStringWithCompatibilityMapping`(会破坏 emoji 和连字)。**两侧都要 normalize**:AX title 和 `NSRunningApplication.localizedName`。

## 落地 checklist

- [ ] `AXIsProcessTrusted()` 门控:false → 渲染 PermissionCard + "Grant" 按钮(不自动弹窗)
- [ ] 授权链接指向 `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
- [ ] `pollDock()` 循环内每次重新读取 `isAXTrusted`,反映运行时授权变化
- [ ] Dock PID 获取失败 → log warn,本次 poll 跳过,下次重试
- [ ] `getSubElements` 用 `count > 0` guard 处理叶节点,不 throw 错误
- [ ] `"AXStatusLabel"` 读取失败 → label 视为 `""`,即"无角标"
- [ ] 遍历所有同名 tile,优先 `AXStatusLabel` 非空的
- [ ] `normalizeName` 对 AX title 和 `localizedName` 两侧都调用
- [ ] 日志记录原始 `AXStatusLabel` 值,便于感知 macOS 版本回归

## 延伸阅读

- [AX 树遍历与 Focus 保护](./ax-tree-and-focus.md) — AXorcist 类型安全 AX 遍历、app resolving、stale 引用防范
- [../permissions/](../permissions/) — 权限门控完整流程(PermissionCard 模式)
- DockDoor 参考项目 — SCWindow 窗口缩略图 + AXUIElement 窗口控制,Dock 交互延伸用法
