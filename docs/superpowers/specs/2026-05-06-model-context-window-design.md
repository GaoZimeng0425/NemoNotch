# Model Context Window 动态适配

## 问题

`AISessionState.contextPercent` 硬编码 200K 上下文窗口，但不同模型有不同大小（mimo-v2-pro 为 1M，GLM-5.1 为 200K），导致进度条不准确。

## 方案

新增 `ModelContextWindow` 字典查表，按模型名称映射 context window 大小，未知模型 fallback 到 200K。

## 改动

### 1. 新增 `NemoNotch/Models/ModelContextWindow.swift`

```swift
enum ModelContextWindow {
    static let limits: [String: Int] = [
        "mimo-v2-pro": 1_000_000,
        "glm-5.1": 200_000,
    ]
    static let defaultValue = 200_000

    static func limit(for model: String) -> Int {
        limits[model] ?? defaultValue
    }
}
```

### 2. 修改 `AIProvider.swift` — `contextPercent`

```swift
var contextPercent: Double {
    guard lastContextTokens > 0 else { return 0 }
    let limit = ModelContextWindow.limit(for: model)
    return min(Double(lastContextTokens) / Double(limit), 1.0)
}
```

### 3. 修改 `AIProvider.swift` — 新增 `contextLimitDisplay`

```swift
var contextLimitDisplay: String {
    let limit = ModelContextWindow.limit(for: model)
    if limit >= 1_000_000 {
        return String(format: "%.0fM", Double(limit) / 1_000_000)
    }
    return String(format: "%.0fK", Double(limit) / 1000)
}
```

### 4. 修改 `AIChatTab.swift` — `contextBar`

将硬编码 `"/ 200K"` 替换为 `"/ \(session.contextLimitDisplay)"`。

## 扩展

新增模型只需在 `limits` 字典加一行。
