---
summary: '幂等安装/卸载 AI CLI hook：写 ~/.claude/settings.json、~/.gemini/settings.json、~/.hermes/config.yaml'
read_when:
  - '向 Claude Code / Gemini CLI / Hermes 注入 hook，或调试"hook 未生效"'
  - '需要在 app 启动时幂等地修改第三方 CLI 配置文件'
  - '处理 YAML 配置文件的字符串级 patch'
sources: ['§13 Hook installers', '§12.5']
last_verified: { nemonotch: 'fe4e9e5' }
---

# Hook Installer — 幂等注入 AI CLI Hook

## TL;DR

三个目标（Claude、Gemini、Hermes）共享同一核心思路：**先全量删除所有 NemoNotch 条目，再追加当前事件集**。这一"先删后写"模式是实现幂等的唯一可靠方法——只追加会在每次 install 后产生重复条目。

---

## 可复用模式

### 1. 幂等安装核心逻辑

```
read config
for each hook event bucket:
    REMOVE all entries whose command path ends with "nemonotch/hooks/hook-sender.sh"
for each currently-supported event:
    APPEND fresh entry
write back
```

锚点 `HookInstaller.swift:63-103  install(_:)`。

### 2. Claude / Gemini JSON 安装

```swift
// HookInstaller.swift:74-87  — 先删
for (event, entries) in hooks {
    if var eventEntries = entries as? [[String: Any]] {
        eventEntries.removeAll { entry in
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { isOurHookCommand($0["command"] as? String) }
        }
        // 空桶直接移除 key
        if eventEntries.isEmpty { hooks.removeValue(forKey: event) }
        else { hooks[event] = eventEntries }
    }
}

// HookInstaller.swift:89-99  — 再写
let hookEntry: [String: Any] = [
    "matcher": "",
    "hooks": [["type": "command", "command": hookCommand]],
]
for event in target.hookEvents {
    var entries = hooks[event] as? [[String: Any]] ?? []
    entries.append(hookEntry)
    hooks[event] = entries
}
```

写回时使用 `.prettyPrinted + .sortedKeys`（`HookInstaller.swift:234-237`），key 顺序稳定，避免用户手动编辑后 `git diff` 噪声。

### 3. 路径匹配（大小写不敏感）

```swift
// HookInstaller.swift:40-43  isOurHookCommand(_:)
return command.lowercased().hasSuffix("nemonotch/hooks/hook-sender.sh")
```

覆盖历史版本 `~/.nemonotch/...`（小写）和当前 `~/.NemoNotch/...`（驼峰）两种路径形式。

### 4. Hermes YAML 字符串级 Patch

Hermes 使用 YAML，不做结构化解析，而是**逐行字符串操作**：

```swift
// HermesHookInstaller.swift:141-183  addHooksBlock(to:)
// 1. 先删：removeAll { line.lowercased().contains("nemonotch/hooks/hermes-hook-sender.sh") }
// 2. 找 "hooks:" 行插入，或末尾追加
// 3. 设置 hooks_auto_accept: true
```

卸载时清理空的 event block（如 `  pre_llm_call:` 后无子项）和 `hooks_auto_accept: true`。锚点 `HermesHookInstaller.swift:186-232`。

### 5. 多 Profile 扫描

```swift
// HermesHookInstaller.swift:58-73  allConfigPaths()
var paths = [hermesDir + "/config.yaml"]
let profilesDir = hermesDir + "/profiles"
// 扫描 ~/.hermes/profiles/*/config.yaml
```

**每次 install/uninstall 都重新扫描**，不缓存 —— 用户可能在首次安装后新增 profile。

### 6. 脚本生成与版本校验

```swift
// HookInstaller.swift:134-146  ensureScriptExists()
if contents.contains(scriptVersion) && contents.contains(portMarker) {
    return  // 版本和端口都匹配，跳过重写
}
// 否则重写（版本升级 或 端口回退后改变）
```

版本字符串 `# version: N` + 端口标记 `# port: <port>` 双重校验，确保端口变更时脚本同步更新。

```swift
// HookInstaller.swift:221-225
try script.write(to: scriptURL, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptPath)
```

---

## 锚点（file:line）

| 位置 | 内容 |
|------|------|
| `NemoNotch/Services/HookInstaller.swift:3-25` | `HookTarget` enum — settingsPath + hookEvents |
| `HookInstaller.swift:29-43` | 路径常量 + `isOurHookCommand` |
| `HookInstaller.swift:45-61` | `isInstalled(_:)` — 检测是否已安装 |
| `HookInstaller.swift:63-103` | `install(_:)` — 幂等安装主流程 |
| `HookInstaller.swift:105-132` | `uninstall(_:)` — 卸载 |
| `HookInstaller.swift:134-226` | `ensureScriptExists()` — 脚本生成（含版本+端口校验） |
| `HookInstaller.swift:228-239` | `writeSettings` — `.prettyPrinted + .sortedKeys` 写回 |
| `NemoNotch/Services/HermesHookInstaller.swift:4-17` | 路径常量 + hookEvents（Hermes 专属事件名） |
| `HermesHookInstaller.swift:21-29` | `isInstalled` — 字符串 contains 检查 |
| `HermesHookInstaller.swift:32-46` | `install()` / `uninstall()` |
| `HermesHookInstaller.swift:58-73` | `allConfigPaths()` — 根 config + profiles 扫描 |
| `HermesHookInstaller.swift:77-117` | `ensureScriptExists()` — Hermes 脚本模板 |
| `HermesHookInstaller.swift:141-183` | `addHooksBlock` — YAML 注入 |
| `HermesHookInstaller.swift:186-232` | `removeHooksBlock` / `removeNemonotchLines` — YAML 清理 |

---

## Pitfalls

1. **只追加不删除 = 每次 install 重复条目**：这是最常见的 hook installer 缺陷。先删再写是核心不变量。

2. **脚本权限 0644 → 静默不执行**：`String.write(to:atomically:encoding:)` 产生 0644 文件，CLI 拒绝执行，现象是"hooks 永远不触发"，不报任何错误。必须显式调用 `setAttributes([.posixPermissions: 0o755])`。

3. **JSON immutable cast**：`JSONSerialization.jsonObject` 即使不带 `.mutableContainers` 选项，cast 到 `[String: Any]` 时也会复制为可变 Swift dict——但要用 `var` 变量承接，否则是 `let` 不可变。

4. **Hermes YAML 字符串匹配脆弱**：`isInstalled` 用 `content.contains("nemonotch/hooks/hermes-hook-sender.sh")`，脚本路径一旦改名就失效。路径字符串必须提取为单一常量 `scriptCommand`，install / uninstall / isInstalled 三处统一引用。

5. **Hermes profile 动态扫描**：不要缓存 `allConfigPaths()` 结果，每次 install/uninstall 都重新扫描。

6. **端口变更后脚本需同步**：`HookServer` 落地非默认端口时，必须立即调用 `HookInstaller.ensureScriptExists()` 重写脚本，否则旧脚本指向已失效端口（锚点 `HookServer.swift:83-89`）。

7. **`hooks_auto_accept: true`（Hermes）**：安装时注入，卸载时必须同步删除，否则 Hermes 会在无 NemoNotch 的情况下继续静默接受所有 hook 请求。

---

## 落地 Checklist

- [ ] install() 先删后写，不是先检查再追加
- [ ] 路径匹配用 `lowercased().hasSuffix(...)` 覆盖大小写变体
- [ ] JSON 写回：`.prettyPrinted + .sortedKeys`
- [ ] 脚本写入后立即 `setAttributes([.posixPermissions: 0o755])`
- [ ] 脚本嵌入 `# version: N` 和 `# port: <port>` 双标记
- [ ] Hermes：每次操作重扫 profiles 目录
- [ ] 端口改变时 `HookInstaller.ensureScriptExists()` 同步调用

---

## 延伸阅读

- [hook-server.md](hook-server.md) — HookServer 事件接收端
- [unix-socket-and-subprocess.md](unix-socket-and-subprocess.md) — TCP loopback 底层
- ../build-release/ — Info.plist GENERATE_INFOPLIST_FILE 注意事项
