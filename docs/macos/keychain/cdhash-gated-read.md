---
summary: 'GUI app 静默读取其他 app Keychain item 的完整方案:attributes-only 探测、cdhash 持久化 grant、SecKeychainSetUserInteractionAllowed 防刷新弹窗。'
read_when:
  - 'macOS GUI app 需要读取由 CLI 工具创建的 Keychain item(如 Claude Code-credentials、Codex Auth)'
  - '需要在后台定时刷新 Keychain 凭证但不能弹出对话框'
  - '实现"首次 Authorize 按钮,后续静默自动读"的 UX 流程'
  - 'app 每次 rebuild 后 Keychain grant 失效,需要理解原因和应对方案'
sources: ['N §14.3']
last_verified:
  nemonotch: 'fe4e9e5'
---

# cdhash-gated 静默读取

## TL;DR

macOS 对其他 app 创建的 Keychain item 的**数据读取**受 ACL 保护——GUI app 无论加什么 no-UI flag 都会弹框。四步组合才能做到"首次用户点按钮,后续静默自动":

| 步骤 | 机制 | 目的 |
|---|---|---|
| 1. File-first | 读文件(`~/.claude/.credentials.json`) | 无权限,完全静默 |
| 2. Attributes-only 探测 | `kSecReturnAttributes`(不取 data) | 检测 item 存在,不弹框 |
| 3. cdhash-gated 数据读 | grant keyed by cdhash in UserDefaults | 只有用户曾主动授权的 binary 才自动读 |
| 4. `SecKeychainSetUserInteractionAllowed(false)` | 过程全局旗标 | 将 ACL 弹框变成 `errSecInteractionNotAllowed` 失败 |

---

## 背景:为什么 no-UI flag 对 GUI app 无效

| 调用方 | attributes 读 | data 读(有 no-UI flags) |
|---|---|---|
| CLI tool | 静默成功 | 返回 `errSecUserCanceled`(-128),**无弹框** |
| **GUI `.app`** | 静默成功 | **仍然弹框** |

`LAContext.interactionNotAllowed = true` 和 `kSecUseAuthenticationUIFail` 只拦截 **LocalAuthentication(Touch ID/密码)** UI,不拦截登录 Keychain 的**跨 app ACL 授权对话框**。windowed app 在 macOS 安全模型里永远会触发该对话框——这是系统设计,不是 bug,且无法通过 entitlement 豁免。

---

## 可复用模式

### Step 1 · File-First 读

CLI 工具可能也写了对应文件:

```swift
// Claude Code 可能写 ~/.claude/.credentials.json
// Codex 可能写 ~/.codex/auth.json
if let cred = try? loadCredentialFromFile(at: "~/.claude/.credentials.json") {
    return cred
}
// 文件不存在或解析失败 → 进入 Keychain 路径
```

注意:Claude Code **不总是**写这个文件——当凭证只在 Keychain 时,文件路径返回 nil,必须继续走 Keychain 探测。

### Step 2 · Attributes-Only 探测(不弹框)

```swift
private enum KeychainProbe { case authorized, needsAuthorization, notFound, failure }

private func keychainProbe(service: String) -> KeychainProbe {
    var query: [String: Any] = [
        kSecClass as String:       kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnAttributes as String: true,   // ← 只取 attributes,绝不放 kSecReturnData
        kSecMatchLimit as String:  kSecMatchLimitOne,
    ]
    applyNoUI(to: &query)                        // 对 attributes 读无害,保留作 belt-and-braces
    var result: AnyObject?
    switch SecItemCopyMatching(query as CFDictionary, &result) {
    case errSecSuccess,
         errSecInteractionNotAllowed: return .authorized   // item 存在(后者表示存在但有访问限制)
    case errSecItemNotFound:          return .notFound
    default:                          return .failure
    }
}
```

`errSecInteractionNotAllowed`(`-25308`)在此路径下意味着 item 存在但禁止交互——仍视为 `.authorized`(item 物理上存在),后续 data 读通过 cdhash gate 决定。

### Step 3 · cdhash-Gated 数据读

```swift
private func readKeychainCredential(
    provider: QuotaProvider,
    service: String,
    parse: (Data) -> Credential?
) -> Credential {
    if keychainGranted(provider) {
        if let data = keychainBlob(service: service),   // 见 Step 4:强制 non-interactive
           let cred = parse(data) { return cred }
        setKeychainGranted(false, provider)             // 读失败 → grant 无效 → 退回显示按钮
    }
    return keychainProbe(service: service) == .notFound
        ? Credential(token: nil, status: .notFound)
        : Credential(token: nil, status: .needsAuthorization)  // → UI 渲染 Authorize 按钮
}
```

**grant 以 cdhash 为 key,而非裸 bool。** 原因:macOS 把 "Always Allow" ACL trust 绑定到 app 的代码签名身份。ad-hoc 签名(`CODE_SIGN_IDENTITY="-"`)下每次 rebuild 都是新身份,旧 cdhash grant 残留 → gated data 读用"旧信任"打开新二进制 → **自动弹框**,与无 gate 无异:

```swift
private func keychainGranted(_ p: QuotaProvider) -> Bool {
    guard let id = Self.currentCodeIdentity() else { return false }
    return UserDefaults.standard.string(forKey: grantedIdentityKey(p)) == id
}

private func setKeychainGranted(_ granted: Bool, _ p: QuotaProvider) {
    if granted, let id = Self.currentCodeIdentity() {
        UserDefaults.standard.set(id, forKey: grantedIdentityKey(p))
    } else {
        UserDefaults.standard.removeObject(forKey: grantedIdentityKey(p))
    }
}

private static func currentCodeIdentity() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var stat: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(stat, [], &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let cdhash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
    return cdhash.map { String(format: "%02x", $0) }.joined()
}

private func grantedIdentityKey(_ p: QuotaProvider) -> String {
    "quota.keychainGrantedIdentity.\(p.rawValue)"
}
```

**结论**:
- ad-hoc 签名:每次 rebuild grant 失效 → Authorize 按钮重新显示 → 需要用户再点一次(开发期正常)
- Developer ID 签名:cdhash 稳定 → 真正一次授权,永久有效

### Step 4 · `SecKeychainSetUserInteractionAllowed(false)` 防刷新弹窗

**问题**:即使 `keychainGranted == true`,两种情况下 data 读仍会弹框:
1. 用户点了 **"Allow"**(一次性)而非 **"Always Allow"** —— grant 被持久化但 ACL 未更新
2. item 的 ACL 本来就不允许其他 app 静默访问

5 分钟自动刷新 timer 触发时,`SecItemCopyMatching` 会弹框,且无任何 log(因为这发生在成功路径的 data 读里)。

**修复**:用 `SecKeychainSetUserInteractionAllowed(false)` 将 ACL 对话框变成 `errSecInteractionNotAllowed`(`-25308`)失败,而非弹框。注意:
- 该 symbol 已废弃,通过 `dlsym` 加载,避免编译期引用废弃符号
- C 函数参数类型是 `Boolean`(1 字节),Swift 桥接为 `DarwinBoolean`
- **进程全局**:设 `false` 后必须在 `defer` 里恢复 `true`,否则用户主动触发的 `authorize()` 读也会被阻断

```swift
// NemoNotch/Services/UsageQuotaService.swift
private static let setUserInteractionAllowed: (@convention(c) (DarwinBoolean) -> OSStatus)? = {
    let path = "/System/Library/Frameworks/Security.framework/Security"
    guard let handle = dlopen(path, RTLD_NOW),     // 必须保留 handle,函数指针依赖它
          let sym = dlsym(handle, "SecKeychainSetUserInteractionAllowed") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (DarwinBoolean) -> OSStatus).self)
}()

private func keychainBlob(service: String) -> Data? {
    var query: [String: Any] = [
        kSecClass as String:       kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String:  true,
        kSecMatchLimit as String:  kSecMatchLimitOne,
    ]
    applyNoUI(to: &query)
    let toggle = Self.setUserInteractionAllowed
    _ = toggle?(false)                             // 进程全局:关闭交互
    defer { _ = toggle?(true) }                   // 必须恢复,authorize() 路径需要交互开启
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
}
```

**为什么是 `DarwinBoolean` 而非 `Bool`**:C 函数签名是 `OSStatus SecKeychainSetUserInteractionAllowed(Boolean allowed)`,`Boolean` 是 `unsigned char`(1 字节)。Swift 的 `Bool` 是 8 字节布局(ABI 不同),会产生未定义行为。`DarwinBoolean` 是 Swift 对 C `Boolean` 的 1 字节桥接类型。

### applyNoUI 辅助(完整实现)

```swift
import Darwin
import LocalAuthentication

// kSecUseAuthenticationUI 也已废弃,通过 dlsym 加载
private static let uiFailPolicy: CFString = {
    let path = "/System/Library/Frameworks/Security.framework/Security"
    guard let handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD),
          let sym = dlsym(handle, "kSecUseAuthenticationUIFail") else {
        return "u_AuthUIF" as CFString
    }
    return Unmanaged<CFString>.fromOpaque(sym).takeUnretainedValue()
}()

private func applyNoUI(to query: inout [String: Any]) {
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    query[kSecUseAuthenticationUI as String] = Self.uiFailPolicy
}
```

### Authorize 按钮 action

UI 渲染 `.needsAuthorization` 状态时显示 "Authorize" 按钮(附一行说明理由)。其 action 做**唯一一次交互式读**,关键:
- 在 `Task.detached`(off MainActor)里执行,因为 `SecItemCopyMatching` 在弹框期间会阻塞线程
- 不调用 `applyNoUI`,不调用 `setUserInteractionAllowed(false)` —— 此处**需要**弹框
- 成功后持久化 grant

```swift
func authorize(_ provider: QuotaProvider) async {
    let service = keychainService(for: provider)
    let granted = await Task.detached {
        Self.interactiveKeychainRead(service: service) != nil
    }.value
    if granted {
        setKeychainGranted(true, provider)
        await refresh(force: true)
    }
}

private static func interactiveKeychainRead(service: String) -> Data? {
    let query: [String: Any] = [
        kSecClass as String:       kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String:  true,
        kSecMatchLimit as String:  kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
}
```

用户点 "Always Allow" 后,该 app 被加入 item ACL;后续 `keychainBlob`(step 4)静默成功。若用户只点 "Allow",grant 持久化但 ACL 不更新——下次 `keychainBlob` 返回 nil,`setKeychainGranted(false)` 被调用,Authorize 按钮重新出现(不会自动弹框)。

---

## 锚点(file:line)

| 符号 | 路径:行 | 说明 |
|---|---|---|
| `keychainProbe(service:)` | `NemoNotch/Services/UsageQuotaService.swift` | Attributes-only 探测,`kSecReturnAttributes` |
| `readKeychainCredential(provider:service:parse:)` | `UsageQuotaService.swift` | cdhash gate 主逻辑 |
| `currentCodeIdentity()` | `UsageQuotaService.swift` | `SecCodeCopySelf` → `SecCodeCopyStaticCode` → `SecCodeCopySigningInformation` → cdhash hex |
| `keychainBlob(service:)` | `UsageQuotaService.swift` | `SecKeychainSetUserInteractionAllowed(false)` 包裹的 data 读 |
| `setUserInteractionAllowed` static let | `UsageQuotaService.swift` | `dlopen/dlsym` 加载废弃 C symbol |
| `authorize(_:)` | `UsageQuotaService.swift` | 用户主动触发的交互式读 + grant 持久化 |
| §14.3(完整叙述) | `macos-cookbook.md:2109` | 原始 NemoNotch cookbook 节 |

---

## Pitfalls

**`setUserInteractionAllowed` 未恢复 `true`。** 忘写 `defer { _ = toggle?(true) }` 时,进程内后续所有 Keychain 交互(包括用户点 Authorize 按钮)都会静默失败,表现为 Authorize 按钮点了没反应。始终在 `defer` 里恢复。

**ad-hoc 签名 rebuild 后 grant 失效是预期行为,不是 bug。** 开发期每次 rebuild 产生新 cdhash → 旧 grant 作废 → Authorize 按钮重新出现。不需要也不应该绕过这个机制——这正是安全保障的来源。发布时使用 Developer ID 签名,cdhash 稳定,用户真正只需授权一次。

**`SecCodeCopySigningInformation` 在 ad-hoc 签名下也正常返回 cdhash。** ad-hoc signed binary 有 cdhash,只是每次 rebuild 变化。不要因为"没有 Developer ID"就跳过 cdhash 路径。

**`kSecReturnData` 混入 attributes probe。** 探测函数里如果误加了 `kSecReturnData: true`,macOS 会弹框——**即使你只想知道 item 是否存在**。探测函数必须只有 `kSecReturnAttributes: true`。

**`SecKeychainSetUserInteractionAllowed` 的 `dlopen` handle 需长期持有。** 函数指针绑定到 dylib 在内存的位置;若 handle 被 `dlclose`,地址失效,调用产生 crash。将 handle 和函数指针存为 `static let`,进程内永远存活。

**用户点 "Allow"(一次性)后,`keychainBlob` 下次仍会失败。** 一次性 Allow 不把 app 加入 ACL,下次 data 读时 `setUserInteractionAllowed(false)` 旗标将弹框转为 `errSecInteractionNotAllowed`(`-25308`) → `keychainBlob` 返回 nil → grant 被清除 → Authorize 按钮重新出现。这是设计预期:用户必须选 "Always Allow" 才能永久授权。

---

## 落地 checklist

- [ ] File-first:优先读 `~/.credentials.json` / `~/.auth.json`,绕开 Keychain 路径
- [ ] Attributes-only probe:只用 `kSecReturnAttributes`,绝对不放 `kSecReturnData`
- [ ] cdhash gate:`UserDefaults` 存的是 cdhash hex 字符串,不是裸 `Bool`
- [ ] `SecKeychainSetUserInteractionAllowed(false)` 通过 `dlsym` 加载,参数类型 `DarwinBoolean`
- [ ] `defer { toggle?(true) }` 恢复进程全局状态
- [ ] `authorize()` action 在 `Task.detached` 里执行(阻塞等待对话框期间不卡 MainActor)
- [ ] Authorize 按钮附一行理由说明(用户需要知道为什么弹框)
- [ ] 发布版使用 Developer ID 签名,确保 cdhash 稳定

---

## 延伸阅读

- [./keychain-basics.md](./keychain-basics.md) — `SecItemCopyMatching` 加载、`SecItemAdd/Update` 存储、accessibility 常量
- [../private-api/](../private-api/) — `dlopen/dlsym` 加载废弃或私有 symbol 的通用模式
- [../build-release/](../build-release/) — Developer ID 签名 vs ad-hoc 签名;cdhash 稳定性
- [../permissions/](../permissions/) — PermissionCard "never-auto-prompt" 设计模式(按钮 + 理由 + 不自动弹权限)
- `macos-cookbook.md §14.3` — NemoNotch 原始 cookbook 节,含完整代码上下文
